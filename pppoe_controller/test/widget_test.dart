import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pppoe_controller/history_screen.dart';
import 'package:pppoe_controller/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bridge = MethodChannel('pppoe/bridge');
  final calls = <String>[];
  Future<Object?> Function(MethodCall)? override;

  setUp(() {
    calls.clear();
    override = null;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('pppoe/log_stream'), (_) async => null);
    messenger.setMockMethodCallHandler(bridge, (call) async {
      calls.add(call.method);
      if (override != null) {
        final result = await override!(call);
        if (result != null) return result;
      }
      switch (call.method) {
        case 'getNetworkInterfaces':
          return ['eth0'];
        case 'loadDnsSettings':
          return {'useCustom': false};
        case 'loadSpeedTestUrl':
          return 'https://example.com/test';
        case 'readPeerEnv':
          return <String, String>{};
        case 'startDialingAttempt':
          return {'status': 'Success', 'logId': 1};
        case 'getLogHistory':
          return [];
        default:
          return true;
      }
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(bridge, null);
    messenger.setMockMethodCallHandler(const MethodChannel('pppoe/log_stream'), null);
  });

  testWidgets('failed credential write prevents dialing stale credentials', (tester) async {
    override = (call) async => call.method == 'writeCreds' ? false : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.text('启动拨号 + VPN'));
    await tester.pump();
    expect(calls, isNot(contains('startDialingAttempt')));
    expect(find.descendant(of: find.byType(SnackBar), matching: find.textContaining('Failed to save credentials')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stop invalidates pending dialing and blocks duplicate starts', (tester) async {
    final dial = Completer<Object?>();
    override = (call) async => call.method == 'startDialingAttempt' ? dial.future : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.text('启动拨号 + VPN'));
    await tester.pump();
    await tester.tap(find.text('启动拨号 + VPN'));
    await tester.pump();
    expect(calls.where((call) => call == 'startDialingAttempt'), hasLength(1));
    await tester.tap(find.text('停止'));
    await tester.pump();
    dial.complete({'status': 'Success', 'logId': 1});
    await tester.pump();
    expect(calls, contains('stopVpn'));
    expect(calls, isNot(contains('startVpn')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('operation indicators leave stop immediately available during transitions', (tester) async {
    final dial = Completer<Object?>();
    final stop = Completer<Object?>();
    override = (call) async {
      if (call.method == 'startDialingAttempt') return dial.future;
      if (call.method == 'control') return stop.future;
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    expect(find.text('就绪'), findsOneWidget);
    await tester.tap(find.text('启动拨号 + VPN'));
    await tester.pump();
    expect(find.text('正在处理…'), findsOneWidget);
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(find.text('正在停止…'), findsOneWidget);
    final stopButton = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '停止'));
    expect(stopButton.onPressed, isNull);
    stop.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('就绪'), findsOneWidget);
    expect(find.text('正在停止…'), findsNothing);
    dial.complete({'status': 'Success', 'logId': 1});
    await tester.pump();
    expect(calls, isNot(contains('startVpn')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed VPN establishment is never shown as success', (tester) async {
    override = (call) async => call.method == 'startVpn' ? false : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.text('启动拨号 + VPN'));
    await tester.pump();
    expect(find.textContaining('VPN failed to start'), findsOneWidget);
    expect(find.text('Success (VPN Started)'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('slow polling never overlaps and late results survive disposal', (tester) async {
    final peer = Completer<Object?>();
    override = (call) async => call.method == 'readPeerEnv' ? peer.future : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    expect(calls.where((call) => call == 'readPeerEnv'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    peer.complete(<String, String>{'DNS1': '1.1.1.1'});
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('peer polling displays negotiated interface IP and DNS', (tester) async {
    override = (call) async => call.method == 'readPeerEnv'
        ? {'IF': 'ppp0', 'IPLOCAL': '192.0.2.1', 'DNS1': '1.1.1.1', 'DNS2': '8.8.8.8'}
        : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('ppp0'), findsOneWidget);
    expect(find.textContaining('192.0.2.1'), findsOneWidget);
    expect(find.textContaining('1.1.1.1'), findsOneWidget);
    expect(find.textContaining('8.8.8.8'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late initialization callbacks cannot update a disposed page', (tester) async {
    final interfaces = Completer<Object?>();
    final dns = Completer<Object?>();
    final url = Completer<Object?>();
    override = (call) async {
      switch (call.method) {
        case 'getNetworkInterfaces': return interfaces.future;
        case 'loadDnsSettings': return dns.future;
        case 'loadSpeedTestUrl': return url.future;
        default: return null;
      }
    };
    await tester.pumpWidget(const App());
    await tester.pumpWidget(const SizedBox());
    interfaces.complete(['eth0']);
    dns.complete({'useCustom': false});
    url.complete('https://example.com/test');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('history storage errors are not misreported as an empty history', (tester) async {
    override = (call) async {
      if (call.method == 'getLogHistory') throw PlatformException(code: 'READ_FAILED');
      return null;
    };
    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to load history'), findsOneWidget);
    expect(find.text('No log history found.'), findsNothing);
  });

  testWidgets('failed overlapping history deletes reload by ID without stale indices', (tester) async {
    final deletes = {1: Completer<Object?>(), 2: Completer<Object?>()};
    override = (call) async {
      if (call.method == 'getLogHistory') {
        return [
          {'id': 1, 'timestamp': 1000, 'status': 'Success'},
          {'id': 2, 'timestamp': 2000, 'status': 'Failure'},
        ];
      }
      if (call.method == 'deleteLogEntry') {
        return deletes[call.arguments['id']]!.future;
      }
      return null;
    };
    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    await tester.pumpAndSettle();
    await tester.fling(find.byKey(const Key('1')), const Offset(-600, 0), 1000);
    await tester.pumpAndSettle();
    await tester.fling(find.byKey(const Key('2')), const Offset(-600, 0), 1000);
    await tester.pumpAndSettle();
    deletes[2]!.complete(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('1')), findsNothing);
    expect(find.byKey(const Key('2')), findsOneWidget);
    deletes[1]!.complete(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('1')), findsOneWidget);
    expect(find.byKey(const Key('2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
