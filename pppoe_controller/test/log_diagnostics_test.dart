import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pppoe_controller/log_view.dart';
import 'package:pppoe_controller/log_diagnostics.dart';

void main() {
  test('protocol evidence provides qualified Windows references', () {
    const examples = {
      'PAP authentication failed': '691',
      '[ERROR] [module] event=daemon_exit exit=19': '691',
      'CHAP authentication failed': '691',
      'Timeout waiting for PADO packets': '678 / 815',
      'Timeout waiting for PADS packets': '678 / 815',
      'LCP: timeout sending Config-Requests': '718',
      'peer refused to agree to our IP address': '735',
      'Could not determine local IP address': '738',
      'LCP terminated by peer': '734',
      "Couldn't open the /dev/ppp device": '651',
    };
    for (final e in examples.entries) {
      final diagnosis = LogReport.parse(e.key).diagnosis!;
      expect(diagnosis.windowsCode, e.value, reason: e.key);
      expect(diagnosis.summary, contains('approximate'));
      expect(diagnosis.summary, contains(rasReference));
    }
  });
  test('local and generic failures never invent a Windows RAS code', () {
    for (final line in [
      'ping timeout',
      'LCP echo timeout',
      'IPCP rejected DNS address',
      'DNS lookup failed',
      'VPN permission denied',
      'root access denied',
      'unknown failure',
      'pppd exited with code 10',
      '[ERROR] [module] event=daemon_exit exit=11',
    ]) {
      expect(
        LogReport.parse(line).diagnosis?.windowsCode,
        isNull,
        reason: line,
      );
    }
  });
  test('cleanup and buffer eviction retain cause until explicit recovery', () {
    final buffer = LogBuffer(maxEntries: 2)..add('PAP authentication failed');
    buffer.add(
      'Connection terminated.\n[ERROR] [app] event=attempt_failed\nheartbeat',
    );
    expect(buffer.report.diagnosis!.windowsCode, '691');
    expect(buffer.report.omitted, 2);
    buffer.add('[INFO] [module] event=peer_up iface=ppp0');
    expect(buffer.report.diagnosis, isNull);
    buffer.add('LCP: timeout sending Config-Requests');
    buffer.add('[INFO] [app] event=attempt_start');
    expect(buffer.report.diagnosis, isNull);
  });
  test('debug is hidden but available and adjacent repeated events fold', () {
    final report = LogReport.parse(
      '2026-10-04T00:00:00Z [WARN] [module] event=peer_down\n'
      '2026-10-04T00:00:01Z [WARN] [module] event=peer_down\n'
      'rcvd [LCP EchoRep id=0x1]\n[DEBUG] [app] event=status_poll',
    );
    expect(report.rows(), hasLength(1));
    expect(report.rows().single.count, 2);
    expect(report.rows().single.lastTimestamp, '2026-10-04T00:00:01Z');
    expect(report.rows(verbose: true), hasLength(3));
    expect(report.exportText, contains('EchoRep'));
  });
  test('legacy secrets are removed from display evidence and export', () {
    final report = LogReport.parse(
      'user "alice@example.org" password "secret with spaces"\n'
      'sent [PAP AuthReq id=0x1 user="alice" password="hunter2"]\n'
      'rcvd [CHAP Challenge id=0x1 <deadbeef>, name="bob"]\n'
      'PAP authentication failed username=carol\n'
      'https://dave:secret@example.org/\n',
    );
    for (final secret in [
      'alice',
      'secret with spaces',
      'hunter2',
      'deadbeef',
      'bob',
      'carol',
      'dave:secret',
    ]) {
      expect(report.exportText, isNot(contains(secret)));
    }
    expect(report.diagnosis!.windowsCode, '691');
  });
  test('shell credential traces do not survive legacy export', () {
    final report = LogReport.parse(
      "printf '%s' 'a secret' > /data/pppoe.user\necho hidden > /data/password",
    );
    expect(report.exportText, isNot(contains('a secret')));
    expect(report.exportText, isNot(contains('hidden')));
  });
  testWidgets(
    'verbose opt-in and copy preserve evidence without exposing credentials',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String;
            }
            return null;
          });
      final report = LogReport.parse(
        '[DEBUG] [app] event=status_poll\nPAP authentication failed password=hidden',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: LogView(report: report)),
          ),
        ),
      );
      expect(find.textContaining('event=status_poll'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.textContaining('event=status_poll'), findsOneWidget);
      await tester.tap(find.text('复制脱敏报告'));
      await tester.pump();
      expect(copied, contains('691'));
      expect(copied, contains('event=status_poll'));
      expect(copied, isNot(contains('hidden')));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    },
  );
  test('authentication direction determines whether 691 is justified', () {
    for (final packet in ['PAP AuthNak', 'CHAP Failure']) {
      expect(LogReport.parse('sent [$packet id=0x1]').diagnosis?.windowsCode, isNull);
      expect(LogReport.parse('rcvd [$packet id=0x1]').diagnosis?.windowsCode, '691');
    }
  });
  test('ambiguous legacy credentials redact remainder including escaped quotes', () {
    for (final line in [r'password="abc\" tail" extra', r'password=secret withspaces',
      r'+ PASSWORD=secret withspaces', r'user unquoted name password xyz']) {
      final text = sanitizeLog(line);
      for (final secret in ['abc', 'tail', 'extra', 'secret', 'withspaces', 'unquoted', 'xyz']) {
        expect(text, isNot(contains(secret)), reason: line);
      }
    }
  });
  test('observed pppd timestamp and legacy noise are distinguished', () {
    final entry = LogEntry.parse('2026-10-04T00:00:00Z [pppd] LCP: timeout sending Config-Requests');
    expect(entry.timestamp, '2026-10-04T00:00:00Z');
    expect(entry.source, 'pppd (observed)');
    expect(diagnose(entry)!.windowsCode, '718');
    expect(LogReport.parse('[DEBUG old] poll\n+ ip link show').rows(), isEmpty);
  });
  test('missing evidence remains visible without overwriting protocol cause', () {
    final buffer = LogBuffer()..add('PAP authentication failed');
    for (final event in ['logs_truncated', 'log_truncated', 'oversized_line', 'capture_error']) {
      buffer.add('[WARN] [app] event=$event');
      expect(buffer.report.diagnosis!.windowsCode, '691');
    }
    expect(buffer.report.evidenceIncomplete, isTrue);
    expect(buffer.report.exportText, contains('Evidence incomplete'));
    buffer.add('[WARN] [app] event=log_reset');
    expect(buffer.report.diagnosis, isNull);
  });
  test('local failures offer actionable causes without a Windows code', () {
    for (final event in ['route_setup_failed', 'binaries_prepare_failed', 'interface_missing',
      'no_active_interface', 'vpn_permission_denied', 'vpn_failed', 'capture_error', 'attempt_timeout']) {
      final diagnosis = LogReport.parse('[ERROR] [app] event=$event').diagnosis!;
      expect(diagnosis.windowsCode, isNull);
      expect(diagnosis.cause, isNot('Connection or local operation needs attention'));
    }
    final timeout = LogReport.parse('[ERROR] [app] event=attempt_timeout').diagnosis!;
    expect(timeout.action, contains('ICMP may be blocked'));
    final buffer = LogBuffer()..add('[ERROR] [app] event=capture_error');
    buffer.add('[INFO] [app] event=capture_recovered');
    expect(buffer.report.diagnosis, isNull);
    expect(buffer.report.evidenceIncomplete, isTrue);
  });

}
