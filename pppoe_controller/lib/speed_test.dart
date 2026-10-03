import 'dart:async';
import 'dart:io';

/// Owns one download so cancellation cannot close a later test's connection.
class SpeedTest {
  SpeedTest({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;
  final _client = HttpClient();
  final _cancelled = Completer<double>();
  bool _started = false;
  bool _isCancelled = false;

  static Uri parseUrl(String url) {
    final uri = Uri.parse(url);
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException('Expected an HTTP or HTTPS URL');
    }
    return uri;
  }

  Future<double> run(String url, {void Function(double)? onProgress}) async {
    if (_started) throw StateError('Speed test already started');
    _started = true;
    try {
      if (_isCancelled) return 0;
      final uri = parseUrl(url);
      return await Future.any([
        _download(uri, onProgress),
        _cancelled.future,
      ]).timeout(timeout);
    } finally {
      _isCancelled = true;
      _client.close(force: true);
    }
  }

  Future<double> _download(Uri uri, void Function(double)? onProgress) async {
    final watch = Stopwatch()..start();
    final throttle = Stopwatch()..start();
    var bytes = 0;
    double rate() => bytes / (watch.elapsedMicroseconds.clamp(1, 1 << 62) / 1000000) / 1048576;
    final request = await _client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    await for (final chunk in response) {
      if (_isCancelled) return 0;
      bytes += chunk.length;
      if (throttle.elapsedMilliseconds >= 250) {
        onProgress?.call(rate());
        throttle.reset();
      }
    }
    return rate();
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _client.close(force: true);
    _cancelled.complete(0);
  }
}
