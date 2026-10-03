import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'pppoe_bridge.dart';
import 'nothing_theme.dart';
import 'log_diagnostics.dart';
import 'log_view.dart';
import 'motion.dart';

class LogDetailScreen extends StatefulWidget {
  final int logId;
  const LogDetailScreen({super.key, required this.logId});

  @override
  State<LogDetailScreen> createState() => _LogDetailScreenState();
}

class _LogDetailScreenState extends State<LogDetailScreen> {
  LogDetail? _logDetail;
  bool _isLoading = true;
  String? _error;
  final _noteController = TextEditingController();
  bool _isSavingNote = false;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }
  Future<void> _loadDetails() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final detail = await PppoeBridge.getLogDetails(widget.logId);
      if (!mounted) return;
      setState(() {
        _logDetail = detail;
        _noteController.text = detail?.note ?? '';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _saveNote() async {
    if (_isSavingNote || _logDetail == null) return;
    setState(() => _isSavingNote = true);
    final note = _noteController.text.trim();
    final success = await PppoeBridge.updateLogNote(widget.logId, note);
    if (!mounted) return;
    setState(() => _isSavingNote = false);

    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(success ? 'Note saved.' : 'Failed to save note.'),
            backgroundColor: success ? null : NothingColors.redAccent
        )
    );
    if(success) {
      setState(() => _logDetail = _logDetail?.copyWith(note: note));
    }
  }

  Future<void> _deleteEntry() async {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: reduceMotion(context) ? AnimationStyle.noAnimation : null,
      builder: (context) => AlertDialog(
        title: const Text('Delete Log Entry?'),
        content: const Text('Are you sure you want to delete this log entry?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: NothingColors.redAccent))
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await PppoeBridge.deleteLogEntry(widget.logId);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry deleted.')));
        Navigator.pop(context); // Go back to history screen
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Failed to delete entry.'),
            backgroundColor: NothingColors.redAccent
        ));
      }
    }
  }

  Future<void> _shareLogNatively() async {
    if (_logDetail == null) return;

    final detail = _logDetail!;
    final dateTime = DateTime.fromMillisecondsSinceEpoch(detail.timestamp);
    final formattedDate = DateFormat('yyyy-MM-dd_HH-mm-ss').format(dateTime);
    final fileName = 'pppoe_log_$formattedDate.txt';

    final content = """
Log Entry: $formattedDate
Status: ${sanitizeLog(detail.status)}
Note: ${sanitizeLog(detail.note ?? '(No note)')}
-------------------------------------
Log Content:
-------------------------------------
${LogReport.parse(detail.logContent).exportText}
""";

    try {
      // 2. 调用新的 MethodChannel 方法
      final success = await PppoeBridge.shareLogAsText(
        text: content,
        subject: fileName, // (Email app 会使用这个作为标题)
      );
      if (!success) throw StateError('Share request failed');
    } catch (e) {
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to share log: $e'), backgroundColor: NothingColors.redAccent)
        );
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    Widget body;
    String title = 'Log Details';

    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(child: Text(_error!, style: const TextStyle(color: NothingColors.redAccent)));
    } else if (_logDetail == null) {
      body = const Center(child: Text('Log entry not found.'));
    } else {
      final detail = _logDetail!;
      final dateTime = DateTime.fromMillisecondsSinceEpoch(detail.timestamp);
      final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime);
      title = formattedDate;

      body = ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Text('Status: ${sanitizeLog(detail.status)}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: NothingColors.grey)),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            decoration: InputDecoration(
              labelText: 'Note',
              hintText: 'Add a note (optional)',
              suffixIcon: IconButton(
                icon: _isSavingNote ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined),
                onPressed: _isSavingNote ? null : _saveNote,
                tooltip: 'Save Note',
              ),
            ),
            maxLines: 3,
            minLines: 1,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 16),
          LogView(report: LogReport.parse(detail.logContent)),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_logDetail != null)
            IconButton(
              icon: const Icon(Icons.ios_share_outlined),
              onPressed: _shareLogNatively,
              tooltip: 'Share / Export Log',
            ),
          if (_logDetail != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: NothingColors.redAccent),
              onPressed: _deleteEntry,
              tooltip: 'Delete Entry',
            ),
        ],
      ),
      body: body,
    );
  }
}

extension LogDetailCopyWith on LogDetail {
  LogDetail copyWith({
    int? id,
    int? timestamp,
    String? note,
    String? status,
    String? logContent,
  }) {
    return LogDetail(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      note: note ?? this.note,
      status: status ?? this.status,
      logContent: logContent ?? this.logContent,
    );
  }
}