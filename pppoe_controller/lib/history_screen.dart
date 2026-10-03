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
  int _loadVersion = 0;
  final Set<int> _deleting = {};

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    final version = ++_loadVersion;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final history = await PppoeBridge.getLogHistory();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _history = history.where((entry) => !_deleting.contains(entry.id)).toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = "Failed to load history: $e";
        _isLoading = false;
      });
    }
  }

  Future<void> _performDelete(LogSummary entry) async {
    final success = await PppoeBridge.deleteLogEntry(entry.id);
    _deleting.remove(entry.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success ? 'Entry deleted.' : 'Failed to delete entry.'),
      backgroundColor: success ? null : NothingColors.redAccent,
    ));
    // Reload the authoritative list; indices can change during concurrent swipes.
    await _loadHistory();
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
              key: Key(entry.id.toString()),
              direction: DismissDirection.endToStart,

              onDismissed: (direction) {
                setState(() {
                  _deleting.add(entry.id);
                  _history.removeWhere((item) => item.id == entry.id);
                });
                _performDelete(entry);
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