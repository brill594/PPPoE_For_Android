import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'history_screen.dart';
import 'pppoe_bridge.dart';
import 'nothing_theme.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: getNothingTheme(),
      home: Home(),
    );
  }
}

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _HomeState(); }

class _HomeState extends State<Home> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _mtu = TextEditingController(text: "1492");
  final _mru = TextEditingController(text: "1492");
  List<String> _availableInterfaces = [];
  String? _selectedInterface;
  bool _isLoadingInterfaces = false;
  final _logScrollController = ScrollController();
  final List<String> _logLines = [];
  StreamSubscription? _logSubscription;
  final _customDns1 = TextEditingController();
  final _customDns2 = TextEditingController();
  bool _useCustomDns = false;
  Map _peer = {};
  Timer? _poll;

  bool _isTesting = false;
  String _downloadRate = '0.0';
  String _errorMessage = '';

  String _speedTestUrl = "https://speed.cloudflare.com/__down?bytes=10000000";
  final _speedTestUrlController = TextEditingController();
  final _uiUpdateThrottle = Stopwatch();
  @override
  void initState() {
    super.initState();
    _refreshInterfaces();
    _startPeerPolling();
    _listenToLogStream();
    _loadDnsSettings();
    _loadSpeedTestUrl();
  }

  Future<void> _loadSpeedTestUrl() async {
    final url = await PppoeBridge.loadSpeedTestUrl();
    setState(() {
      _speedTestUrl = url ?? _speedTestUrl; // 如果未设置，则保留默认值
      _speedTestUrlController.text = _speedTestUrl;
    });
  }

  Future<void> _refreshInterfaces() async {
    if (_isLoadingInterfaces) return;

    setState(() {
      _isLoadingInterfaces = true;
      _availableInterfaces = [];
      _selectedInterface = null;
    });

    try {
      print("Calling PppoeBridge.getNetworkInterfaces...");
      final interfaces = await PppoeBridge.getNetworkInterfaces();
      print("Received interfaces from Native: $interfaces");
      setState(() {
        _availableInterfaces = interfaces;
      });
    } catch (e) {
      print("Error calling getNetworkInterfaces: $e");
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
  void _startPeerPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final peer = await PppoeBridge.readPeerEnv();
      setState(() { _peer = Map.from(peer); });
    });
  }

  void _listenToLogStream() {
    _logSubscription?.cancel();
    _logSubscription = PppoeBridge.logStream.listen(
          (newLine) {
        setState(() {
          _logLines.add(newLine);
          if (_logLines.length > 500) {
            _logLines.removeAt(0);
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logScrollController.hasClients) {
            _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
          }
        });
      },
      onError: (e) {
        setState(() { _logLines.add("!!! 日志流错误: $e"); });
      },
    );
  }


  @override
  void dispose() {
    _poll?.cancel();
    _logSubscription?.cancel();
    _logScrollController.dispose();
    _customDns1.dispose();
    _customDns2.dispose();
    _saveDnsDebounce?.cancel();
    _speedTestUrlController.dispose();
    super.dispose();
  }
  Future<void> _applyAndStart() async {
    setState(() { _logLines.clear(); });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Starting dialing attempt...')));
    int? savedLogId;
    String finalStatusMessage = "Unknown error occurred";

    try {
      await PppoeBridge.writeCreds(_user.text, _pass.text);
      final ifaceToSend = (_selectedInterface?.trim().isEmpty ?? true) ? null : _selectedInterface!.trim();
      await PppoeBridge.writeIface(ifaceToSend);
      await PppoeBridge.writeMtuMru(int.tryParse(_mtu.text), int.tryParse(_mru.text));

      final dialResult = await PppoeBridge.startDialingAttempt();
      final initialStatus = dialResult['status'] as String? ?? "Failure (Unknown)";
      savedLogId = dialResult['logId'] as int?;
      finalStatusMessage = initialStatus;

      print("[DEBUG] Dial result: Status='$initialStatus', LogID=$savedLogId");

      if (initialStatus.startsWith("Success")) {
        print("[DEBUG] Dialing succeeded. Preparing VPN...");
        final vpnPrepared = await PppoeBridge.prepareVpn();
        print("[DEBUG] prepareVpn returned: $vpnPrepared");

        if (vpnPrepared == true) {
          print("[DEBUG] VPN prepared. Calling startVpn...");
          await PppoeBridge.startVpn();
          print("[DEBUG] startVpn called.");
          finalStatusMessage = "Success (VPN Started)";
          if (savedLogId != null) {
            await PppoeBridge.updateLogStatus(savedLogId, finalStatusMessage);
          }
        } else {
          print("[ERROR] VPN prepareVpn returned false.");
          finalStatusMessage = "Failure (VPN Permission)";
          if (savedLogId != null) {
            await PppoeBridge.updateLogStatus(savedLogId, finalStatusMessage);
          }
          throw finalStatusMessage;
        }
      } else {
        print("[ERROR] Dialing attempt failed with status: $initialStatus");
        throw finalStatusMessage;
      }

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(finalStatusMessage)));

    } catch (e) {
      print("[ERROR] Exception in _applyAndStart: $e");
      final errorMessage = e.toString();
      final displayError = (e is String && e.startsWith("Failure")) ? e : "Error: $errorMessage";

      if (savedLogId != null && !finalStatusMessage.startsWith("Failure") && !finalStatusMessage.startsWith("Timeout")) {
        finalStatusMessage = "Failure (Unknown)";
        await PppoeBridge.updateLogStatus(savedLogId, finalStatusMessage);
      }

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(displayError), backgroundColor: NothingColors.redAccent));
    }
  }

  Future<void> _testStartVpn() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
            const SnackBar(content: Text('Test: startVpn command sent successfully.'))
        );
      } else {
        print("[DEBUG_TEST] VPN prepareVpn returned false. Permission likely needed or denied.");
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Test: VPN permission needed or denied.'))
        );
      }
    } catch (e, s) {
      print("[DEBUG_TEST] Exception in _testStartVpn: $e\n$s");
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Test Error: $e'), backgroundColor: NothingColors.redAccent));
    }
  }
  Future<void> _stopAll() async {
    await PppoeBridge.stopVpn();
    await PppoeBridge.control("stop");
  }


  HttpClient? _httpClient;
  Future<void> _startSpeedTest() async {
    setState(() {
      _isTesting = true;
      _errorMessage = '';
      _downloadRate = '0.0';
    });

    _httpClient = HttpClient();
    final stopwatch = Stopwatch()..start(); // 主计时器
    _uiUpdateThrottle.reset();             // 重置 UI 计时器
    _uiUpdateThrottle.start();
    int bytesReceived = 0;

    try {
      final request = await _httpClient!.getUrl(
          Uri.parse(_speedTestUrl)
      );
      final response = await request.close();

      await for (var chunk in response) {
        if (!_isTesting) {
          _httpClient?.close(force: true);
          break;
        }

        bytesReceived += chunk.length;
        final elapsedMs = stopwatch.elapsedMilliseconds;

        // --- 这就是节流阀 ---
        // 仅当 (A)  elapsedMs > 0
        // 并且 (B) 距离上次 UI 更新已超过 250 毫秒
        if (elapsedMs > 0 && _uiUpdateThrottle.elapsedMilliseconds > 250) {
          final speed = (bytesReceived / (elapsedMs / 1000.0)) / 1048576.0;

          setState(() {
            _downloadRate = speed.toStringAsFixed(2);
          });

          _uiUpdateThrottle.reset(); // 重置 UI 计时器
        }
      }

      stopwatch.stop();
      _uiUpdateThrottle.stop();
      _uiUpdateThrottle.reset();

      if (_isTesting) { // 仅在测试未被取消时执行
        // 确保显示最终的精确速度，而不是 250ms 前的速度
        final elapsedMs = stopwatch.elapsedMilliseconds;
        if (elapsedMs > 0) {
          final speed = (bytesReceived / (elapsedMs / 1000.0)) / 1048576.0;
          setState(() {
            _downloadRate = speed.toStringAsFixed(2);
            _isTesting = false;
          });
        } else {
          setState(() { _isTesting = false; });
        }
      }

    } catch (e) {
      setState(() {
        if (e is FormatException) {
          _errorMessage = "Test failed: Invalid URL format.";
        } else {
          _errorMessage = "Test failed: Check URL or connection.";
        }
        print("Speed test error: $e");
        _isTesting = false;
      });
    } finally {
      _httpClient?.close(force: true);
      _httpClient = null;
      if (stopwatch.isRunning) stopwatch.stop();
      if (_uiUpdateThrottle.isRunning) _uiUpdateThrottle.stop();
    }
  }

  void _cancelSpeedTest() {
    setState(() {
      _isTesting = false;
      _errorMessage = "Test canceled.";
      _downloadRate = '0.0';
    });
  }

  Future<void> _showSpeedTestSettingsDialog() async {
    // 确保控制器与当前状态同步
    _speedTestUrlController.text = _speedTestUrl;

    await showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text("Speed Test Settings"),
            content: TextField(
              controller: _speedTestUrlController,
              decoration: const InputDecoration(
                  labelText: "Download Test URL",
                  hintText: "https://... (e.g., 10MB file)"
              ),
            ),
            actions: [
              TextButton(
                child: const Text("Cancel"),
                onPressed: () => Navigator.pop(context),
              ),
              ElevatedButton(
                child: const Text("Save"),
                onPressed: () {
                  final newUrl = _speedTestUrlController.text.trim();
                  setState(() {
                    _speedTestUrl = newUrl; // 立即更新 UI
                  });
                  PppoeBridge.saveSpeedTestUrl(newUrl); // 异步保存
                  Navigator.pop(context);
                },
              ),
            ],
          );
        }
    );
  }


  @override
  Widget build(BuildContext context) {
    final dns1 = _peer["DNS1"] ?? "-";
    final dns2 = _peer["DNS2"] ?? "-";
    final logText = _logLines.join('\n');

    return Scaffold(
      appBar: AppBar(
        title: const Text("PPPoE Controller"),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: "View Log History",
            onPressed: () {
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
                onChanged: (_) => _saveDnsSettings(),
              )),
              const SizedBox(width: 12),
              Expanded(child: TextField(
                controller: _customDns2,
                decoration: const InputDecoration(labelText: "自定义 DNS 2 (可选)"),
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _saveDnsSettings(),
              )),
            ]),
            SwitchListTile(
              title: const Text("使用自定义 DNS"),
              value: _useCustomDns,
              onChanged: (bool value) {
                setState(() {
                  _useCustomDns = value;
                });
                _saveDnsSettings();
              },
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
            Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              alignment: WrapAlignment.start,
              children: [
                ElevatedButton(
                    onPressed: _applyAndStart,
                    child: const Text("启动拨号 + VPN")
                ),
                OutlinedButton(
                  onPressed: _stopAll,
                  child: const Text("停止"),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: NothingColors.redAccent,
                    foregroundColor: NothingColors.white,
                    side: BorderSide(color: NothingColors.redAccent),
                  ),
                ),
                TextButton(
                    onPressed: () => PppoeBridge.control("cycle"),
                    child: const Text("切换接口")
                ),
                OutlinedButton(
                  onPressed: _testStartVpn,
                  child: const Text("Test VPN"),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: NothingColors.white,
                    foregroundColor: NothingColors.black,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kNothingBorderRadius),
                  side: BorderSide(color: NothingColors.grey)
              ),
              clipBehavior: Clip.antiAlias,
              // 使用 Stack 来添加齿轮按钮
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildSpeedStat(Icons.arrow_downward, '下载', _downloadRate),
                          ],
                        ),
                        const SizedBox(height: 16),

                        if (_isTesting)
                          OutlinedButton(
                            onPressed: _cancelSpeedTest,
                            child: const Text("取消测试"),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: NothingColors.redAccent,
                              side: BorderSide(color: NothingColors.redAccent),
                            ),
                          )
                        else
                          ElevatedButton(
                            onPressed: _startSpeedTest,
                            child: const Text("开始下载测试"),
                          ),

                        if (_errorMessage.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Text(
                              _errorMessage,
                              style: const TextStyle(color: NothingColors.redAccent),
                            ),
                          ),
                      ],
                    ),
                  ),

                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: IconButton(
                      icon: const Icon(Icons.settings_outlined, size: 20),
                      color: NothingColors.grey,
                      tooltip: "Speed Test Settings",
                      onPressed: _showSpeedTestSettingsDialog,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            Text("日志：", style: Theme.of(context).textTheme.labelMedium),
            Container(
              padding: const EdgeInsets.all(8),
              height: 320,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                border: Border.all(color: NothingColors.grey),
                borderRadius: BorderRadius.circular(kNothingBorderRadius),
              ),
              child: SingleChildScrollView(
                controller: _logScrollController,
                child: Text(
                    logText,
                    style: const TextStyle(
                      fontFamily: "monospace",
                      color: NothingColors.white,
                    )
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedStat(IconData icon, String title, String value) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, color: NothingColors.grey, size: 16),
            const SizedBox(width: 4),
            Text(title, style: const TextStyle(color: NothingColors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.bold,
            color: NothingColors.white,
          ),
        ),
        const Text("MB/s", style: TextStyle(color: NothingColors.grey)),
      ],
    );
  }
}