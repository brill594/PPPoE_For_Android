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
  final _mtu = TextEditingController(text: "1492");
  final _mru = TextEditingController(text: "1492");
  List<String> _availableInterfaces = [];
  String? _selectedInterface; // null 表示自动 (由脚本选择)
  bool _isLoadingInterfaces = false;
  // --- 修正日志 ---
  final _logScrollController = ScrollController(); // 1. 用于自动滚动
  final List<String> _logLines = [];               // 2. 用列表保存日志行
  StreamSubscription? _logSubscription;          // 3. 日志流的订阅

  // --- 状态轮询 ---
  Map _peer = {};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refreshInterfaces();
    _startPeerPolling();  // 启动 peer env 轮询
    _listenToLogStream(); // 启动日志流监听
  }
  Future<void> _refreshInterfaces() async {
    if (_isLoadingInterfaces) return; // 防止重复点击

    setState(() {
      _isLoadingInterfaces = true;
      // 清空旧列表和选择，显示加载状态
      _availableInterfaces = [];
      _selectedInterface = null;
    });

    try {
      print("Calling PppoeBridge.getNetworkInterfaces..."); // <-- 日志 2
      final interfaces = await PppoeBridge.getNetworkInterfaces();
      print("Received interfaces from Native: $interfaces"); // <-- 日志 3
      setState(() {
        _availableInterfaces = interfaces;
        // (可选) 如果有接口，默认选中第一个
        // if (interfaces.isNotEmpty) {
        //   _selectedInterface = interfaces.first;
        // }
      });
    } catch (e) { // <-- 添加 catch 块
      print("Error calling getNetworkInterfaces: $e"); // <-- 日志 4
    }finally {
      setState(() {
        _isLoadingInterfaces = false;
      });
    }
  }
  // 轮询 peer env (每秒一次)
  void _startPeerPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final peer = await PppoeBridge.readPeerEnv();
      setState(() { _peer = Map.from(peer); });
    });
  }

  // 监听日志流 (实时)
  void _listenToLogStream() {
    _logSubscription?.cancel();
    _logSubscription = PppoeBridge.logStream.listen(
          (newLine) {
        // 当有新日志行时
        setState(() {
          _logLines.add(newLine); // 4. 只添加新行
          if (_logLines.length > 500) { // (可选) 防止列表无限增长
            _logLines.removeAt(0);
          }
        });
        // 5. 自动滚动到底部
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logScrollController.hasClients) {
            _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
          }
        });
      },
      onError: (e) {
        // (可选) 在日志中显示错误
        setState(() { _logLines.add("!!! 日志流错误: $e"); });
      },
    );
  }


  @override
  void dispose() {
    _poll?.cancel();
    _logSubscription?.cancel(); // 6. 清理订阅
    _logScrollController.dispose(); // 7. 清理控制器
    super.dispose();
  }

  Future<void> _applyAndStart() async {
    setState(() { // 添加 setState 来更新 UI
      _logLines.clear(); // 清空日志列表
    });
    await PppoeBridge.writeCreds(_user.text, _pass.text);
    final ifaceToSend = (_selectedInterface?.trim().isEmpty ?? true) ? null : _selectedInterface!.trim();
    await PppoeBridge.writeIface(ifaceToSend);
    await PppoeBridge.writeMtuMru(int.tryParse(_mtu.text), int.tryParse(_mru.text));
    await PppoeBridge.control("start");
    // 等待 peer.env 出现 DNS
    for (int i = 0; i < 10; i++) {
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

    // 8. 将日志列表合并为一个字符串
    final logText = _logLines.join('\n');

    return Scaffold(
      appBar: AppBar(title: const Text("PPPoE Controller")),
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
              // 使用 Flexible 允许下拉菜单在需要时收缩
              Flexible(
                child: DropdownButtonFormField<String?>(
                  value: _selectedInterface,
                  hint: const Text("自动选择接口"),
                  disabledHint: _isLoadingInterfaces ? const Text("正在加载...") : null,
                  decoration: const InputDecoration(labelText: "网络接口"),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text("自动选择")),
                    ..._availableInterfaces.map((iface) {
                      return DropdownMenuItem<String?>(value: iface, child: Text(iface));
                    }).toList(),
                  ],
                  onChanged: _isLoadingInterfaces ? null : (String? newValue) {
                    setState(() { _selectedInterface = newValue; });
                  },
                ),
              ),
              const SizedBox(width: 8),
              // 刷新按钮
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _isLoadingInterfaces ? null : _refreshInterfaces,
                tooltip: "刷新网络接口列表",
              ),
            ]),
            Row(children: [
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _mtu, decoration: const InputDecoration(labelText: "MTU"), keyboardType: TextInputType.number)),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _mru, decoration: const InputDecoration(labelText: "MRU"), keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 8),
            Text("DNS: $dns1  $dns2"),
            const SizedBox(height: 8),
            Row(children: [
              ElevatedButton(onPressed: _applyAndStart, child: const Text("启动拨号+VPN")),
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
              child: SingleChildScrollView(
                controller: _logScrollController, // 9. 关联控制器
                child: Text(logText, style: const TextStyle(fontFamily: "monospace")), // 10. 显示合并后的日志
              ),
            ),
          ],
        ),
      ),
    );
  }
}
