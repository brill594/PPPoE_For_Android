// lib/history_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'pppoe_bridge.dart';
import 'log_detail_screen.dart';
import 'nothing_theme.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<LogSummary> _history = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final history = await PppoeBridge.getLogHistory();
      if (!mounted) return;
      setState(() {
        _history = history;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "Failed to load history: $e";
        _isLoading = false;
      });
    }
  }

  // 此函数负责后端删除，并在失败时恢复 UI
  Future<void> _performDelete(LogSummary entryToDelete, int index) async {
    final success = await PppoeBridge.deleteLogEntry(entryToDelete.id);

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry deleted.')));
      // 删除成功，UI 已更新，无需操作
    } else if (mounted) {
      // 删除失败！把条目加回到列表中
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to delete entry. Restoring...'),
          backgroundColor: NothingColors.redAccent
      ));
      // 在原来的位置插回去
      setState(() {
        _history.insert(index, entryToDelete);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(child: Text(_error!, style: const TextStyle(color: NothingColors.redAccent)));
    } else if (_history.isEmpty) {
      body = const Center(child: Text('No log history found.'));
    } else {
      body = RefreshIndicator(
        onRefresh: _loadHistory,
        child: ListView.builder(
          itemCount: _history.length,
          itemBuilder: (context, index) {
            final entry = _history[index];
            final dateTime = DateTime.fromMillisecondsSinceEpoch(entry.timestamp);
            final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime);

            return Dismissible(
              key: Key(entry.id.toString()), // Key 必须唯一
              direction: DismissDirection.endToStart,

              // --- MODIFIED: 移除了 confirmDismiss 对话框 ---

              // onDismissed 会在滑动动画完成后立即触发
              onDismissed: (direction) {
                // 1. (重要!) 同步从 UI 移除
                setState(() {
                  _history.removeAt(index);
                });

                // 2. 异步调用后端删除 (如果失败会恢复)
                _performDelete(entry, index);
              },

              background: Container(
                color: NothingColors.redAccent,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const Icon(Icons.delete_outline, color: NothingColors.white),
              ),
              child: ListTile(
                title: Text(formattedDate),
                subtitle: Text(
                  'Status: ${entry.status}${entry.note != null ? "\nNote: ${entry.note}" : ""}',
                  style: const TextStyle(color: NothingColors.grey),
                ),
                trailing: _getStatusIcon(entry.status),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => LogDetailScreen(logId: entry.id),
                    ),
                  ).then((_) => _loadHistory());
                },
              ),
            );
          },
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Log History')),
      body: body,
    );
  }

  Icon _getStatusIcon(String status) {
    final lowerStatus = status.toLowerCase();

    if (lowerStatus.startsWith('success')) {
      return const Icon(Icons.check_circle_outline, color: NothingColors.white);
    }
    else if (lowerStatus.startsWith('failure')) {
      return const Icon(Icons.error_outline, color: NothingColors.redAccent);
    }
    else if (lowerStatus.startsWith('timeout')) {
      return const Icon(Icons.hourglass_empty, color: NothingColors.grey);
    }
    else {
      return const Icon(Icons.question_mark, color: NothingColors.grey);
    }
  }
}