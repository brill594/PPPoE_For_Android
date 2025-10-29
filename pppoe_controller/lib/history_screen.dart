import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // Add intl package for date formatting: flutter pub add intl
import 'pppoe_bridge.dart';
import 'log_detail_screen.dart'; // We'll create this next

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

  Future<void> _deleteEntry(int id) async {
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
      final success = await PppoeBridge.deleteLogEntry(id);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry deleted.')));
        _loadHistory(); // Refresh the list
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete entry.'), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
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
            final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime); // Format timestamp

            return Dismissible( // Wrap ListTile in Dismissible for swipe-to-delete
              key: Key(entry.id.toString()),
              direction: DismissDirection.endToStart,
              onDismissed: (direction) => _deleteEntry(entry.id),
              background: Container(
                color: Colors.red,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              child: ListTile(
                title: Text(formattedDate),
                subtitle: Text('Status: ${entry.status}${entry.note != null ? "\nNote: ${entry.note}" : ""}'),
                trailing: _getStatusIcon(entry.status),
                onTap: () {
                  // Navigate to detail screen
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => LogDetailScreen(logId: entry.id),
                    ),
                  ).then((_) => _loadHistory()); // Refresh list when returning from detail screen
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
    switch (status.toLowerCase()) {
      case 'success':
        return const Icon(Icons.check_circle, color: Colors.green);
      case 'failure':
      case 'failure (control)': // Handle specific failure
        return const Icon(Icons.error, color: Colors.red);
      case 'timeout':
        return const Icon(Icons.timer_off, color: Colors.orange);
      default:
        return const Icon(Icons.question_mark, color: Colors.grey);
    }
  }
}