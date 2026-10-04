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
        case 'getConnectionState':
          return {'peer': <String, String>{}, 'connected': false, 'running': false, 'vpnActive': false, 'pendingCommand': null};
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
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(calls, isNot(contains('startDialingAttempt')));
    expect(find.descendant(of: find.byType(SnackBar), matching: find.textContaining('Failed to save credentials')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one toggle cancels dialing and invalidates late success', (tester) async {
    final dial = Completer<Object?>();
    final stop = Completer<Object?>();
    override = (call) async {
      if (call.method == 'startDialingAttempt') return dial.future;
      if (call.method == 'control') return stop.future;
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    final toggle = find.byKey(const ValueKey('connection-toggle'));
    expect(find.text('未连接'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('取消拨号'), findsOneWidget);
    expect(calls.where((call) => call == 'startDialingAttempt'), hasLength(1));
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<ElevatedButton>(toggle).onPressed, isNull);
    stop.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('启动拨号'), findsOneWidget);
    dial.complete({'status': 'Success', 'logId': 1});
    await tester.pump();
    expect(calls, contains('stopVpn'));
    expect(calls, isNot(contains('startVpn')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('successful dial remains visible after the transient notification and polling', (tester) async {
    var connected = false;
    override = (call) async {
      if (call.method == 'startVpn') connected = true;
      if (call.method == 'getConnectionState') {
        return {'peer': {}, 'connected': connected, 'running': connected, 'vpnActive': connected};
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('拨号成功，PPPoE 与 VPN 已连接'), findsOneWidget);
    expect(find.text('已连接 · VPN 已启用'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已连接 · VPN 已启用'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    expect(calls.where((call) => call == 'startDialingAttempt'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a timed-out dial that later connects enables VPN once and keeps the disconnect action', (tester) async {
    var running = false;
    var connected = false;
    var vpnActive = false;
    final permissionRequests = <bool>[];
    override = (call) async {
      if (call.method == 'prepareVpn') {
        permissionRequests.add(call.arguments['firstLaunchOnly'] as bool);
        return true;
      }
      if (call.method == 'startDialingAttempt') {
        running = true;
        return {'status': 'Failure (Timeout)', 'logId': 1};
      }
      if (call.method == 'startVpn') vpnActive = true;
      if (call.method == 'getConnectionState') {
        return {'peer': {}, 'connected': connected, 'running': running, 'vpnActive': vpnActive};
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(find.text('正在拨号 / 重试中…'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    expect(calls, isNot(contains('startVpn')));
    connected = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已连接 · VPN 已启用'), findsOneWidget);
    expect(permissionRequests, [true, false, true]);
    await tester.pump(const Duration(seconds: 2));
    expect(calls.where((call) => call == 'startVpn'), hasLength(1));
    expect(calls.where((call) => call == 'startDialingAttempt'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening an existing connection allows disconnect without rewriting credentials', (tester) async {
    var connected = true;
    override = (call) async {
      if (call.method == 'control') connected = false;
      if (call.method == 'getConnectionState') {
        return {'peer': {}, 'connected': connected, 'running': connected, 'vpnActive': false};
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    expect(find.text('PPPoE 已连接 · VPN 未启用'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(calls, contains('control'));
    expect(calls, isNot(contains('writeCreds')));
    expect(find.text('启动拨号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stop acknowledgement keeps toggle disabled until the daemon actually exits', (tester) async {
    var running = true;
    override = (call) async => call.method == 'getConnectionState'
        ? {'peer': {}, 'connected': false, 'running': running, 'vpnActive': false}
        : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    final toggle = find.byKey(const ValueKey('connection-toggle'));
    await tester.tap(toggle);
    await tester.pump();
    expect(calls, contains('stopVpn'));
    expect(tester.widget<ElevatedButton>(toggle).onPressed, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<ElevatedButton>(toggle).onPressed, isNull);
    running = false;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('启动拨号'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(toggle).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('blocked Root stop cannot prevent VPN cleanup or leave the toggle locked', (tester) async {
    final root = Completer<Object?>();
    var vpnActive = true;
    override = (call) async {
      if (call.method == 'control') return root.future;
      if (call.method == 'stopVpn') vpnActive = false;
      if (call.method == 'getConnectionState') {
        return {'peer': {}, 'connected': false, 'running': false, 'vpnActive': vpnActive};
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    final toggle = find.byKey(const ValueKey('connection-toggle'));
    await tester.tap(toggle);
    await tester.pump();
    expect(calls, contains('stopVpn'));
    expect(vpnActive, isFalse);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 13));
    expect(tester.widget<ElevatedButton>(toggle).onPressed, isNotNull);
    expect(find.text('断开连接'), findsOneWidget);
    expect(find.text('尚未确认断开，请重试'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 13));
    expect(calls.where((call) => call == 'control'), hasLength(1));
    expect(find.text('断开连接'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(toggle).onPressed, isNotNull);
    root.complete(true);
    await tester.pump();
    expect(find.text('断开连接'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('启动拨号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stalled verification is bounded and late reads cannot erase retry state', (tester) async {
    final state = Completer<Object?>();
    var stall = false;
    override = (call) async {
      if (call.method == 'control') stall = true;
      if (call.method == 'getConnectionState') {
        if (stall) return state.future;
        return {'peer': {}, 'connected': true, 'running': true, 'vpnActive': true};
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    final toggle = find.byKey(const ValueKey('connection-toggle'));
    await tester.tap(toggle);
    await tester.pump();
    final reads = calls.where((call) => call == 'getConnectionState').length;
    await tester.pump(const Duration(seconds: 18));
    expect(tester.widget<ElevatedButton>(toggle).onPressed, isNotNull);
    expect(find.text('断开连接'), findsOneWidget);
    expect(find.text('尚未确认断开，请重试'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(seconds: 18));
    expect(calls.where((call) => call == 'stopVpn'), hasLength(2));
    expect(calls.where((call) => call == 'getConnectionState'), hasLength(reads));
    state.complete({'peer': {}, 'connected': false, 'running': false, 'vpnActive': false});
    await tester.pump();
    expect(find.text('断开连接'), findsOneWidget);
    expect(find.text('尚未确认断开，请重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('VPN without a PPP session remains visible and can be disconnected', (tester) async {
    var vpnActive = true;
    override = (call) async {
      if (call.method == 'stopVpn') vpnActive = false;
      if (call.method == 'getConnectionState') {
        return {'peer': {}, 'connected': false, 'running': false, 'vpnActive': vpnActive};
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    expect(find.text('VPN 已启用 · PPPoE 未连接'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(calls, contains('stopVpn'));
    expect(calls, isNot(contains('startDialingAttempt')));
    expect(find.text('启动拨号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('startup permission and immediate dial share one pending permission request', (tester) async {
    final permission = Completer<Object?>();
    final requests = <bool>[];
    override = (call) async {
      if (call.method == 'prepareVpn') {
        requests.add(call.arguments['firstLaunchOnly'] as bool);
        return permission.future;
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    expect(requests, [true]);
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(requests, [true]);
    expect(calls, isNot(contains('writeCreds')));
    permission.complete(true);
    await tester.pump();
    expect(calls.where((call) => call == 'startDialingAttempt'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('denied VPN permission prevents dialing and explicit retry requests permission again', (tester) async {
    final requests = <bool>[];
    var granted = false;
    override = (call) async {
      if (call.method == 'prepareVpn') {
        requests.add(call.arguments['firstLaunchOnly'] as bool);
        return granted;
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(requests, [true, false]);
    expect(calls, isNot(contains('writeCreds')));
    expect(calls, isNot(contains('startDialingAttempt')));
    granted = true;
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(requests, [true, false, false]);
    expect(calls.where((call) => call == 'startDialingAttempt'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unknown connection state cannot start another dial or claim connection', (tester) async {
    override = (call) async {
      if (call.method == 'getConnectionState') throw PlatformException(code: 'ROOT_FAILED');
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    expect(find.text('连接状态读取失败'), findsOneWidget);
    expect(find.text('已连接 · VPN 已启用'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(calls, isNot(contains('startDialingAttempt')));
    expect(calls, isNot(contains('writeCreds')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed VPN establishment is never shown as success', (tester) async {
    var connected = false;
    override = (call) async {
      if (call.method == 'startDialingAttempt') connected = true;
      if (call.method == 'startVpn') return false;
      if (call.method == 'getConnectionState') {
        return {'peer': {}, 'connected': connected, 'running': connected, 'vpnActive': false};
      }
      return null;
    };
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    expect(find.textContaining('VPN failed to start'), findsOneWidget);
    expect(find.text('已连接 · VPN 已启用'), findsNothing);
    expect(find.text('PPPoE 已连接 · VPN 未启用'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a disconnect immediately after failed VPN activation preserves the actionable error', (tester) async {
    override = (call) async => call.method == 'startVpn' ? false : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('connection-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('VPN failed to start'), findsOneWidget);
    expect(find.text('已连接 · VPN 已启用'), findsNothing);
    expect(find.text('启动拨号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('slow polling never overlaps and late results survive disposal', (tester) async {
    final peer = Completer<Object?>();
    override = (call) async => call.method == 'getConnectionState' ? peer.future : null;
    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    expect(calls.where((call) => call == 'getConnectionState'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    peer.complete({'peer': {'DNS1': '1.1.1.1'}, 'connected': false, 'running': false, 'vpnActive': false});
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('peer polling displays negotiated interface IP and DNS', (tester) async {
    override = (call) async => call.method == 'getConnectionState'
        ? {'peer': {'IF': 'ppp0', 'IPLOCAL': '192.0.2.1', 'DNS1': '1.1.1.1', 'DNS2': '8.8.8.8'}, 'connected': false, 'running': false, 'vpnActive': false}
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
