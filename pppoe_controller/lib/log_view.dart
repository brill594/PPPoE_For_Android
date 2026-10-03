import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'log_diagnostics.dart';

class LogView extends StatefulWidget {
  final LogReport report;
  const LogView({super.key, required this.report});
  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  bool _verbose = false;
  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final rows = report.rows(verbose: _verbose);
    final diagnosis = report.diagnosis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.copy_outlined),
            label: const Text('复制脱敏报告'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await Clipboard.setData(ClipboardData(text: report.exportText));
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Sanitized report copied.')),
                  );
                }
              } catch (_) {
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Failed to copy report.')),
                  );
                }
              }
            },
          ),
        ),
        if (report.evidenceIncomplete) const Text('日志证据不完整：曾发生日志截断或采集中断。'),
        if (diagnosis != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(diagnosis.summary),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('详细日志 / Debug'),
          subtitle: Text(
            '${report.entries.length} lines · ${rows.length} visible groups${report.omitted > 0 ? ' · ${report.omitted} earlier lines omitted' : ''}',
          ),
          value: _verbose,
          onChanged: (value) => setState(() => _verbose = value),
        ),
        if (rows.isEmpty) const Text('暂无重要事件 / No important events'),
        ...rows.map(
          (row) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SelectableText(
              '${row.entry.timestamp ?? ""} [${row.entry.severity.name.toUpperCase()}] '
              '[${row.entry.source} · ${row.entry.stage}] '
              '${row.entry.message}${row.count > 1 ? ' ×${row.count} (last: ${row.lastTimestamp ?? "unknown"})' : ''}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: row.entry.severity == LogSeverity.error
                    ? Colors.redAccent
                    : null,
              ),
            ),
          ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('脱敏原始日志 / Sanitized raw log'),
          children: [
            SelectableText(
              report.entries.map((e) => e.text).join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }
}
