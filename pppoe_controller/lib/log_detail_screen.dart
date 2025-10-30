// lib/log_detail_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // (保留，为了“复制”功能)
import 'package:intl/intl.dart';
import 'pppoe_bridge.dart';
import 'nothing_theme.dart';

class LogDetailScreen extends StatefulWidget {
  final int logId;
  const LogDetailScreen({super.key, required this.logId});

  @override
  State<LogDetailScreen> createState() => _LogDetailScreenState();
}

class _LogDetailScreenState extends State<LogDetailScreen> {
  // ... (所有变量和 initState/dispose/loadDetails/saveNote/deleteEntry 保持不变) ...
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
    final success = await PppoeBridge.updateLogNote(widget.logId, _noteController.text.trim());
    if (!mounted) return;
    setState(() => _isSavingNote = false);

    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(success ? 'Note saved.' : 'Failed to save note.'),
            backgroundColor: success ? null : NothingColors.redAccent
        )
    );
    if(success) {
      setState(() => _logDetail = _logDetail?.copyWith(note: _noteController.text.trim()));
    }
  }

  Future<void> _deleteEntry() async {
    final confirmed = await showDialog<bool>(
      context: context,
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

    if (confirmed == true) {
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

  Future<void> _copyLogToClipboard() async {
    if (_logDetail == null) return;
    await Clipboard.setData(ClipboardData(text: _logDetail!.logContent));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Log content copied to clipboard.'))
      );
    }
  }

  // --- MODIFIED: (重要) 这就是新的导出功能 ---
  Future<void> _shareLogNatively() async {
    if (_logDetail == null) return;

    // 1. 准备内容 (和以前一样)
    final detail = _logDetail!;
    final dateTime = DateTime.fromMillisecondsSinceEpoch(detail.timestamp);
    final formattedDate = DateFormat('yyyy-MM-dd_HH-mm-ss').format(dateTime);
    final fileName = 'pppoe_log_$formattedDate.txt';

    final content = """
Log Entry: $formattedDate
Status: ${detail.status}
Note: ${detail.note ?? '(No note)'}
-------------------------------------
Log Content:
-------------------------------------
${detail.logContent}
""";

    try {
      // 2. 调用新的 MethodChannel 方法
      await PppoeBridge.shareLogAsText(
        text: content,
        subject: fileName, // (Email app 会使用这个作为标题)
      );
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
    // ... (Build 方法的 if/else 逻辑不变) ...
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
          Text('Status: ${detail.status}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: NothingColors.grey)),
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
          Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Log Content:', style: TextStyle(color: NothingColors.grey)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.fromLTRB(8.0, 8.0, 40.0, 8.0),
                    clipBehavior: Clip.antiAlias,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      border: Border.all(color: NothingColors.grey),
                      borderRadius: BorderRadius.circular(kNothingBorderRadius),
                    ),
                    child: SelectableText(
                      detail.logContent.isEmpty ? '(No log content captured)' : detail.logContent,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 30,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 20),
                  onPressed: _copyLogToClipboard,
                  tooltip: 'Copy Log Content',
                  color: NothingColors.grey,
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          // --- MODIFIED: “导出”按钮现在调用 _shareLogNatively ---
          if (_logDetail != null)
            IconButton(
              icon: const Icon(Icons.ios_share_outlined),
              onPressed: _shareLogNatively, // <-- 调用新函数
              tooltip: 'Share / Export Log', // <-- 更新提示
            ),
          // ---
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

// (copyWith 扩展保持不变)
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