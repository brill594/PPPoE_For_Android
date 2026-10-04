// Diagnostics are based on protocol evidence, not pppd exit-code numbers.
const rasReference =
    'https://learn.microsoft.com/en-us/windows/win32/rras/routing-and-remote-access-error-codes';

String sanitizeLog(String text) => text
    .split('\n')
    .map((line) {
      // Packet dumps and command/config echoes can contain quoted or spaced secrets.
      if (RegExp(
        r'(?:PAP|CHAP).*(?:AuthReq|Challenge|Response)|(?:pap|chap)-secrets|(?:echo|printf|cat|tee).*pppoe[._-](?:user|pass|cred)|(?:echo|printf|cat|tee).*[/](?:user|pass|password|credentials)(?:[.\s]|$)',
        caseSensitive: false,
      ).hasMatch(line)) {
        return '[DEBUG] [pppd] Authentication payload redacted';
      }
      // Unquoted shell values and malformed quotes make the tail ambiguous.
      // Redact through end-of-line rather than risk exporting part of a secret.
      return line
          .replaceAllMapped(
            RegExp(
              r'''\b(user(?:name)?|password|passwd|pass|secret|token|authorization|name)(\s*[=:]\s*|\s+).*$''',
              caseSensitive: false,
            ),
            (m) => '${m[1]}=[REDACTED]',
          )
          .replaceAllMapped(
            RegExp(r'(https?://)[^\s/@]+:[^\s/@]+@'),
            (m) => '${m[1]}[REDACTED]@',
          );
    })
    .join('\n');

enum LogSeverity { debug, info, warn, error }

class LogEntry {
  final String text;
  final String message;
  final String? timestamp;
  final String source;
  final String stage;
  final String? event;
  final LogSeverity severity;
  const LogEntry(
    this.text,
    this.message,
    this.timestamp,
    this.source,
    this.stage,
    this.event,
    this.severity,
  );

  factory LogEntry.parse(String raw) {
    final text = sanitizeLog(raw.trim());
    final structured = RegExp(
      r'^(?:(\S+)\s+)?\[(DEBUG|INFO|WARN|ERROR)\]\s+\[([^\]]+)\]\s*(.*)$',
    ).firstMatch(text);
    final observed = RegExp(r'^(\S+) \[pppd\] (.*)$').firstMatch(text);
    final message = structured?[4] ?? observed?[2] ?? text;
    final event = RegExp(r'\bevent=([a-z_]+)\b').firstMatch(message)?[1];
    final lower = message.toLowerCase();
    final stage =
        lower.contains('pap') ||
            lower.contains('chap') ||
            lower.contains('authentication')
        ? 'Authentication'
        : lower.contains('pado') ||
              lower.contains('pads') ||
              lower.contains('padi')
        ? 'Discovery'
        : lower.contains('ipcp') || lower.contains('ip address')
        ? 'IP negotiation'
        : lower.contains('lcp')
        ? 'PPP negotiation'
        : lower.contains('vpn')
        ? 'VPN'
        : lower.contains('dns')
        ? 'DNS'
        : 'Session';
    final noise = RegExp(
      r'^\+|\[debug\b|\b(?:sent|rcvd) \[|\becho(?:req|rep)\b|\bheartbeat\b|\bpeer_poll\b|\bstatus_poll\b|authentication payload redacted',
      caseSensitive: false,
    ).hasMatch(message);
    final severity = structured != null
        ? LogSeverity.values.byName(structured[2]!.toLowerCase())
        : noise
        ? LogSeverity.debug
        : RegExp(
            r'fail|error|timed? ?out|timeout|reject|denied|unable|could not',
            caseSensitive: false,
          ).hasMatch(message)
        ? LogSeverity.error
        : RegExp(r'terminated|disconnect|peer_down').hasMatch(lower)
        ? LogSeverity.warn
        : LogSeverity.info;
    return LogEntry(
      text,
      message,
      structured?[1] ?? observed?[1],
      structured?[3] ?? (observed != null ? 'pppd (observed)' : 'pppd/legacy'),
      stage,
      event,
      noise && severity == LogSeverity.info ? LogSeverity.debug : severity,
    );
  }
}

class LogDiagnosis {
  final String cause;
  final String evidence;
  final String action;
  final String? windowsCode;
  final int priority;
  const LogDiagnosis(
    this.cause,
    this.evidence,
    this.action,
    this.windowsCode,
    this.priority,
  );
  String get summary =>
      '$cause\nEvidence: $evidence\nNext step: $action\n'
      '${windowsCode == null ? 'No justified Windows RAS equivalent.' : 'Windows RAS reference: $windowsCode (approximate; not a native pppd error or proof of an incorrect password).\nMapping confidence: analogous reference; cause requires the evidence above.\nReference: $rasReference'}';
}

LogDiagnosis? diagnose(LogEntry entry) {
  final s = entry.message.toLowerCase();
  LogDiagnosis result(
    String cause,
    String action,
    String? code,
    int priority,
  ) => LogDiagnosis(cause, entry.text, action, code, priority);
  if (RegExp(
        r'^(?!.*\bsent \[)(?:.*\b(?:pap|chap) authentication failed|.*\brcvd \[(?:pap authnak|chap failure))',
      ).hasMatch(s) ||
      (entry.event == 'daemon_exit' &&
          RegExp(r'\bexit=19(?:\s|$)').hasMatch(s))) {
    return result(
      'PPP authentication rejected',
      'Check account status, credentials and the provider authentication policy; rejection alone does not identify which is wrong.',
      '691',
      100,
    );
  }
  if (RegExp(
    r'(?:timeout|timed out).*waiting for (?:pado|pads)|(?:pado|pads).*(?:timeout|timed out)',
  ).hasMatch(s)) {
    return result(
      'PPPoE access concentrator did not respond',
      'Check Ethernet link, selected interface, VLAN and provider availability.',
      '678 / 815',
      90,
    );
  }
  if (RegExp(
    r'lcp:.*(?:timeout|timed out).*config|lcp.*config.*(?:timeout|timed out)',
  ).hasMatch(s)) {
    return result(
      'PPP LCP negotiation timed out',
      'Check the peer and link; inspect the preceding LCP exchange.',
      '718',
      85,
    );
  }
  if (RegExp(
    r'(?:ipcp.*(?:reject|refus).*(?:local ip|our ip|ip address)|peer refused to agree to our ip address)',
  ).hasMatch(s)) {
    return result(
      'PPP IP address proposal rejected',
      'Check static address settings and the provider address policy.',
      '735',
      90,
    );
  }
  if (s.contains('could not determine local ip address') ||
      s.contains('ipcp: no local ip address')) {
    return result(
      'PPP did not receive a local IP address',
      'Check IPCP negotiation and the provider address pool.',
      '738',
      90,
    );
  }
  if (s.contains('lcp terminated by peer')) {
    return result(
      'Peer terminated the PPP link',
      'Inspect earlier authentication and negotiation evidence; the peer may have ended the session by policy.',
      '734',
      40,
    );
  }
  if (RegExp(
    r"couldn't open the /dev/ppp device|kernel (?:does not support|lacks) ppp|ppp generic driver.*not (?:loaded|available)",
  ).hasMatch(s)) {
    return result(
      'Local PPP device or driver unavailable',
      'Check root module installation and kernel PPP support.',
      '651',
      90,
    );
  }
  switch (entry.event) {
    case 'route_setup_failed':
      return result(
        'Local PPP routing setup failed',
        'Inspect the failed route/rule step, root permissions and conflicting policy rules.',
        null,
        80,
      );
    case 'binaries_prepare_failed':
      return result(
        'Local PPP binaries could not be prepared',
        'Check module installation, executable permissions and device ABI compatibility.',
        null,
        80,
      );
    case 'interface_missing':
    case 'no_active_interface':
      return result(
        'No usable Ethernet interface',
        'Connect Ethernet, check link state and select an existing interface.',
        null,
        80,
      );
    case 'capture_error':
      return result(
        'Log capture unavailable; evidence is incomplete',
        'Check root permission and module log-file access. Reconnect capture before diagnosing a missing PPP failure.',
        null,
        20,
      );
    case 'attempt_timeout':
      if (s.contains('ppp0_link_not_ready')) {
        return result(
          'PPPoE link negotiation has not completed',
          'Check the interface and preceding discovery/authentication logs. The daemon may still be retrying; use the connection button to stop it.',
          null,
          20,
        );
      }
      return result(
        'Connectivity verification timed out',
        'A ping bound to PPP is inconclusive: ICMP may be blocked. Check assigned IP, route, DNS and actual traffic. This does not establish a PPP negotiation timeout.',
        null,
        20,
      );
    case 'vpn_permission_denied':
      return result(
        'Android VPN permission denied',
        'Approve the Android VPN consent prompt and check whether device policy or another always-on VPN prevents access.',
        null,
        80,
      );
    case 'vpn_failed':
      return result(
        'Android VPN could not start',
        'Check VPN permission, negotiated PPP settings and conflicting VPN/device policy; inspect the native VPN error.',
        null,
        80,
      );
    case 'log_truncated':
    case 'logs_truncated':
    case 'oversized_line':
      return null;
  }
  if (RegExp(
    r'root.*(?:denied|unavailable|fail)|(?:denied|fail).*root',
  ).hasMatch(s)) {
    return result(
      'Root access unavailable',
      'Grant root access in the root manager and verify the module is enabled.',
      null,
      80,
    );
  }
  if (entry.severity == LogSeverity.error ||
      entry.severity == LogSeverity.warn) {
    return result(
      'Connection or local operation needs attention',
      'Inspect this event and preceding protocol logs. There is not enough evidence for a specific RAS code.',
      null,
      10,
    );
  }
  return null;
}

class LogRow {
  final LogEntry entry;
  int count = 1;
  String? lastTimestamp;
  LogRow(this.entry) : lastTimestamp = entry.timestamp;
}

class LogReport {
  final List<LogEntry> entries;
  final LogDiagnosis? diagnosis;
  final int omitted;
  final bool evidenceIncomplete;
  const LogReport(
    this.entries,
    this.diagnosis,
    this.omitted,
    this.evidenceIncomplete,
  );
  factory LogReport.parse(String text) {
    final buffer = LogBuffer(maxEntries: null)..add(text);
    return buffer.report;
  }
  List<LogRow> rows({bool verbose = false}) {
    final rows = <LogRow>[];
    // Fold before filtering so hidden packets never join unrelated events.
    for (final entry in entries) {
      if (rows.isNotEmpty &&
          rows.last.entry.message == entry.message &&
          rows.last.entry.source == entry.source &&
          rows.last.entry.severity == entry.severity) {
        rows.last.count++;
        rows.last.lastTimestamp = entry.timestamp;
      } else {
        rows.add(LogRow(entry));
      }
    }
    return rows
        .where((row) => verbose || row.entry.severity != LogSeverity.debug)
        .toList();
  }

  String get exportText =>
      '${diagnosis?.summary ?? 'No active failure diagnosed from the available evidence.'}\n'
      '${evidenceIncomplete ? 'Evidence incomplete: capture interruption or log truncation was observed.\n' : ''}'
      '${omitted > 0 ? 'Earlier live lines omitted: $omitted\n' : ''}\nSanitized log details:\n${entries.map((e) => e.text).join('\n')}';
}

class LogBuffer {
  final int? maxEntries;
  final List<LogEntry> _entries = [];
  LogDiagnosis? _diagnosis;
  int _omitted = 0;
  bool _evidenceIncomplete = false;
  LogBuffer({this.maxEntries = 500});
  void clear() {
    _entries.clear();
    _diagnosis = null;
    _omitted = 0;
    _evidenceIncomplete = false;
  }

  void add(String text) {
    for (final line
        in text.split('\n').where((line) => line.trim().isNotEmpty)) {
      final entry = LogEntry.parse(line);
      final lower = entry.message.toLowerCase();
      if (const {
        'log_truncated',
        'logs_truncated',
        'oversized_line',
        'capture_error',
        'log_reset',
      }.contains(entry.event)) {
        _evidenceIncomplete = true;
      }
      if (entry.event == 'log_reset') {
        _diagnosis = null;
      } else if ((entry.event == 'capture_recovered' &&
              _diagnosis?.cause ==
                  'Log capture unavailable; evidence is incomplete') ||
          (entry.event == 'vpn_started' &&
              (_diagnosis?.cause.startsWith('Android VPN') ?? false))) {
        _diagnosis = null;
      } else if (const {
            'attempt_start',
            'daemon_start',
            'attempt_success',
            'peer_up',
          }.contains(entry.event) ||
          RegExp(r'\blocal\s+ip address\s+\d').hasMatch(lower)) {
        _diagnosis = null;
      } else {
        final candidate = diagnose(entry);
        if (candidate != null &&
            candidate.priority >= (_diagnosis?.priority ?? 0)) {
          _diagnosis = candidate;
        }
      }
      _entries.add(entry);
      if (maxEntries != null && _entries.length > maxEntries!) {
        _entries.removeAt(0);
        _omitted++;
      }
    }
  }

  LogReport get report => LogReport(
    List.unmodifiable(_entries),
    _diagnosis,
    _omitted,
    _evidenceIncomplete,
  );
}
