import 'dart:async';
import 'package:flutter/material.dart';
import 'pppoe_bridge.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: Home());
  }
}

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _HomeState(); }

class _HomeState extends State<Home> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _iface = TextEditingController(text: "eth0");
  final _mtu = TextEditingController(text: "1492");
  final _mru = TextEditingController(text: "1492");

  String _log = "";
  Map _peer = {};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final log = await PppoeBridge.readLog();
      final peer = await PppoeBridge.readPeerEnv();
      setState(() { _log = log; _peer = Map.from(peer); });
    });
  }

  @override
  void dispose() { _poll?.cancel(); super.dispose(); }

  Future<void> _applyAndStart() async {
    await PppoeBridge.writeCreds(_user.text, _pass.text);
    await PppoeBridge.writeIface(_iface.text.trim().isEmpty ? null : _iface.text.trim());
    await PppoeBridge.writeMtuMru(int.tryParse(_mtu.text), int.tryParse(_mru.text));
    await PppoeBridge.control("start");
    // 等待 peer.env 出现 DNS
    for (int i=0;i<10;i++) {
      final peer = await PppoeBridge.readPeerEnv();
      if (peer["DNS1"] != null || peer["DNS2"] != null) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (await PppoeBridge.prepareVpn() == true) {
      await PppoeBridge.startVpn();
    }
  }

  Future<void> _stopAll() async {
    await PppoeBridge.stopVpn();
    await PppoeBridge.control("stop");
  }

  @override
  Widget build(BuildContext context) {
    final dns1 = _peer["DNS1"] ?? "-";
    final dns2 = _peer["DNS2"] ?? "-";
    return Scaffold(
      appBar: AppBar(title: const Text("PPPoE Helper")),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ListView(
          children: [
            Row(children: [
              Expanded(child: TextField(controller: _user, decoration: const InputDecoration(labelText: "PPPoE 用户名"))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _pass, decoration: const InputDecoration(labelText: "密码"), obscureText: true)),
            ]),
            Row(children: [
              Expanded(child: TextField(controller: _iface, decoration: const InputDecoration(labelText: "网络接口(可空自动)"))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _mtu, decoration: const InputDecoration(labelText: "MTU"), keyboardType: TextInputType.number)),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _mru, decoration: const InputDecoration(labelText: "MRU"), keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 8),
            Text("DNS: $dns1  $dns2"),
            const SizedBox(height: 8),
            Row(children: [
              ElevatedButton(onPressed: _applyAndStart, child: const Text("启动拨号 + 启动VPN")),
              const SizedBox(width: 12),
              ElevatedButton(onPressed: _stopAll, child: const Text("停止")),
              const SizedBox(width: 12),
              ElevatedButton(onPressed: () => PppoeBridge.control("cycle"), child: const Text("切换接口(cycle)")),
            ]),
            const SizedBox(height: 12),
            const Text("日志："),
            Container(
              padding: const EdgeInsets.all(8),
              height: 320,
              decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
              child: SingleChildScrollView(child: Text(_log, style: const TextStyle(fontFamily: "monospace"))),
            ),
          ],
        ),
      ),
    );
  }
}
