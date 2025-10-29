import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'pppoe_bridge.dart';

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
        _noteController.text = detail?.note ?? ''; // Set initial note text
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "Failed to load details: $e";
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
        SnackBar(content: Text(success ? 'Note saved.' : 'Failed to save note.'), backgroundColor: success ? Colors.green : Colors.red)
    );
    if(success) {
      // Update local state immediately
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
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await PppoeBridge.deleteLogEntry(widget.logId);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry deleted.')));
        Navigator.pop(context); // Go back to history screen
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete entry.'), backgroundColor: Colors.red));
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
      body = Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    } else if (_logDetail == null) {
      body = const Center(child: Text('Log entry not found.'));
    } else {
      final detail = _logDetail!;
      final dateTime = DateTime.fromMillisecondsSinceEpoch(detail.timestamp);
      final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime);
      title = formattedDate; // Update AppBar title

      body = ListView( // Use ListView to prevent overflow if log is huge
        padding: const EdgeInsets.all(16.0),
        children: [
          Text('Status: ${detail.status}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            decoration: InputDecoration(
              labelText: 'Note',
              hintText: 'Add a note (optional)',
              suffixIcon: IconButton(
                icon: _isSavingNote ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
                onPressed: _isSavingNote ? null : _saveNote,
                tooltip: 'Save Note',
              ),
            ),
            maxLines: 3,
            minLines: 1,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 16),
          const Text('Log Content:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(4),
            ),
            // Constrain height or let ListView handle scrolling
            // constraints: const BoxConstraints(maxHeight: 400),
            child: SelectableText( // Use SelectableText for easy copying
              detail.logContent.isEmpty ? '(No log content captured)' : detail.logContent,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_logDetail != null) // Only show delete if details loaded
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteEntry,
              tooltip: 'Delete Entry',
            ),
        ],
      ),
      body: body,
    );
  }
}

// Add copyWith to LogDetail for easier state update after saving note
extension LogDetailCopyWith on LogDetail {
  LogDetail copyWith({
    int? id,
    int? timestamp,
    String? note, // Note is nullable
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