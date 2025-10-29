import 'dart:async';
import 'package:flutter/material.dart';
import 'pppoe_bridge.dart';
import 'history_screen.dart';
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
  final _customDns1 = TextEditingController();
  final _customDns2 = TextEditingController();
  bool _useCustomDns = false;
  // --- 状态轮询 ---
  Map _peer = {};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refreshInterfaces();
    _startPeerPolling();  // 启动 peer env 轮询
    _listenToLogStream(); // 启动日志流监听
    _loadDnsSettings(); // <-- 加载设置
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
  Future<void> _loadDnsSettings() async {
    final settings = await PppoeBridge.loadDnsSettings();
    setState(() {
      _useCustomDns = settings['useCustom'] as bool? ?? false;
      _customDns1.text = settings['dns1'] as String? ?? '';
      _customDns2.text = settings['dns2'] as String? ?? '';
    });
  }

  // 稍微延迟保存，避免频繁写入 SharedPreferences
  Timer? _saveDnsDebounce;
  void _saveDnsSettings() {
    _saveDnsDebounce?.cancel();
    _saveDnsDebounce = Timer(const Duration(milliseconds: 500), () {
      PppoeBridge.saveDnsSettings(
          useCustom: _useCustomDns,
          dns1: _customDns1.text,
          dns2: _customDns2.text
      );
    });
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
    _customDns1.dispose();
    _customDns2.dispose();
    _saveDnsDebounce?.cancel();
    super.dispose();
  }
  Future<void> _applyAndStart() async {
    setState(() { _logLines.clear(); });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Starting dialing attempt...')));
    int? savedLogId; // 用于保存日志 ID
    String finalStatusMessage = "Unknown error occurred"; // 默认消息

    try {
      // 1. 写入配置
      await PppoeBridge.writeCreds(_user.text, _pass.text);
      final ifaceToSend = (_selectedInterface?.trim().isEmpty ?? true) ? null : _selectedInterface!.trim();
      await PppoeBridge.writeIface(ifaceToSend);
      await PppoeBridge.writeMtuMru(int.tryParse(_mtu.text), int.tryParse(_mru.text));

      // 2. 启动拨号并获取结果 (Map)
      final dialResult = await PppoeBridge.startDialingAttempt();
      final initialStatus = dialResult['status'] as String? ?? "Failure (Unknown)";
      savedLogId = dialResult['logId'] as int?; // 保存 ID
      finalStatusMessage = initialStatus; // 先用初始状态

      print("[DEBUG] Dial result: Status='$initialStatus', LogID=$savedLogId");

      // 3. 检查拨号是否成功
      if (initialStatus.startsWith("Success")) { // 比如 "Success (DNS)"
        print("[DEBUG] Dialing succeeded. Preparing VPN...");
        final vpnPrepared = await PppoeBridge.prepareVpn();
        print("[DEBUG] prepareVpn returned: $vpnPrepared");

        if (vpnPrepared == true) {
          print("[DEBUG] VPN prepared. Calling startVpn...");
          await PppoeBridge.startVpn();
          print("[DEBUG] startVpn called.");
          finalStatusMessage = "Success (VPN Started)"; // 更新最终成功状态
          // (可选) 更新数据库中的状态
          if (savedLogId != null) {
            await PppoeBridge.updateLogStatus(savedLogId, finalStatusMessage);
          }
        } else {
          print("[ERROR] VPN prepareVpn returned false.");
          finalStatusMessage = "Failure (VPN Permission)"; // 设置失败状态
          // 更新数据库中的状态
          if (savedLogId != null) {
            await PppoeBridge.updateLogStatus(savedLogId, finalStatusMessage);
          }
          throw finalStatusMessage; // 抛出错误以便在 catch 中显示
        }
      } else {
        // 拨号本身就失败了 (Timeout 或 Failure (Control))
        print("[ERROR] Dialing attempt failed with status: $initialStatus");
        throw finalStatusMessage; // 抛出错误
      }

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(finalStatusMessage), backgroundColor: Colors.green));

    } catch (e) {
      print("[ERROR] Exception in _applyAndStart: $e");
      final errorMessage = e.toString();
      // 如果是已知错误，直接显示，否则显示通用错误
      final displayError = (e is String && e.startsWith("Failure")) ? e : "Error: $errorMessage";

      // 如果我们有 logId 并且状态不是最终失败状态，尝试更新数据库
      if (savedLogId != null && !finalStatusMessage.startsWith("Failure") && !finalStatusMessage.startsWith("Timeout")) {
        finalStatusMessage = "Failure (Unknown)"; // 设置一个通用的失败状态
        await PppoeBridge.updateLogStatus(savedLogId, finalStatusMessage);
      }

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(displayError), backgroundColor: Colors.red));
    }
  }

  Future<void> _testStartVpn() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar(); // Hide previous messages
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Testing VPN start...')));

    try {
      print("[DEBUG_TEST] Calling prepareVpn...");
      final vpnPrepared = await PppoeBridge.prepareVpn();
      print("[DEBUG_TEST] prepareVpn returned: $vpnPrepared");

      if (vpnPrepared == true) {
        print("[DEBUG_TEST] VPN prepared. Calling startVpn...");
        await PppoeBridge.startVpn();
        print("[DEBUG_TEST] startVpn called.");
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Test: startVpn command sent successfully.'), backgroundColor: Colors.green)
        );
      } else {
        print("[DEBUG_TEST] VPN prepareVpn returned false. Permission likely needed or denied.");
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Test: VPN permission needed or denied.'), backgroundColor: Colors.orange)
        );
        // Note: If permission was needed, the system dialog appeared,
        // and the result is handled by the vpnPermissionLauncher callback.
        // We don't get the direct result here if startActivityForResult was launched.
      }
    } catch (e, s) {
      print("[DEBUG_TEST] Exception in _testStartVpn: $e\n$s");
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Test Error: $e'), backgroundColor: Colors.red));
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
      appBar: AppBar(
          title: const Text("PPPoE Controller"),
          actions: [
            IconButton(
            icon: const Icon(Icons.history),
            tooltip: "View Log History",
            onPressed: () {
              // Navigate to the new HistoryScreen
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const HistoryScreen()),
              );
            },
          ),
          ],
      ),

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
              Expanded(child: TextField(
                controller: _customDns1,
                decoration: const InputDecoration(labelText: "自定义 DNS 1 (可选)"),
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _saveDnsSettings(), // <-- 输入时触发保存
              )),
              const SizedBox(width: 12),
              Expanded(child: TextField(
                controller: _customDns2,
                decoration: const InputDecoration(labelText: "自定义 DNS 2 (可选)"),
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _saveDnsSettings(), // <-- 输入时触发保存
              )),
            ]),
            // --- 修改 SwitchListTile ---
            SwitchListTile(
              title: const Text("使用自定义 DNS"),
              value: _useCustomDns,
              onChanged: (bool value) {
                setState(() {
                  _useCustomDns = value;
                });
                _saveDnsSettings(); // <-- 切换时触发保存
              },
              dense: true,
            ),
            Wrap(
              spacing: 8.0, // 水平间距 (相当于 SizedBox(width: 8))
              runSpacing: 8.0, // 垂直间距 (当换行时)
              alignment: WrapAlignment.start, // (可选) 对齐方式
              children: [ // 不再需要 Expanded 或 SizedBox
                ElevatedButton(onPressed: _applyAndStart, child: const Text("启动拨号 + VPN")),
                ElevatedButton(onPressed: _stopAll, child: const Text("停止")),
                ElevatedButton(onPressed: () => PppoeBridge.control("cycle"), child: const Text("切换接口")),
                ElevatedButton(
                  onPressed: _testStartVpn,
                  child: const Text("Test VPN"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                ),
              ],
            ),
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
