import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pppoe_controller/speed_test.dart';

void main() {
  test('rejects non-HTTP and hostless URLs before downloading', () async {
    for (final url in ['file:///tmp/test', 'https:', 'example.com']) {
      await expectLater(SpeedTest().run(url), throwsFormatException);
    }
  });

  test('HTTP errors cannot be reported as successful downloads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 503;
      await request.response.close();
    });
    try {
      await expectLater(SpeedTest().run('http://127.0.0.1:${server.port}/'), throwsA(isA<HttpException>()));
    } finally {
      await server.close(force: true);
    }
  });

  test('stalled responses time out', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((_) {});
    try {
      await expectLater(
        SpeedTest(timeout: const Duration(milliseconds: 100)).run('http://127.0.0.1:${server.port}/'),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('cancel completes a stalled test without affecting its replacement', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      if (++requests == 1) {
        received.complete();
      } else {
        request.response.add(List.filled(1024, 1));
        await request.response.close();
      }
    });
    try {
      final first = SpeedTest();
      final result = first.run('http://127.0.0.1:${server.port}/');
      await received.future;
      first.cancel();
      expect(await result, 0);
      expect(await SpeedTest().run('http://127.0.0.1:${server.port}/'), greaterThan(0));
    } finally {
      await server.close(force: true);
    }
  });
}
