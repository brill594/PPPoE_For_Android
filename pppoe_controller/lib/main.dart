import 'dart:async';
import 'package:flutter/material.dart';
import 'history_screen.dart';
import 'pppoe_bridge.dart';
import 'nothing_theme.dart';
import 'speed_test.dart';
import 'log_diagnostics.dart';
import 'log_view.dart';
import 'motion.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: getNothingTheme(),
      home: const Home(),
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
  final _logs = LogBuffer();
  StreamSubscription? _logSubscription;
  final _customDns1 = TextEditingController();
  final _customDns2 = TextEditingController();
  bool _useCustomDns = false;
  Map<String, String> _peer = {};
  Timer? _poll;

  bool _isTesting = false;
  String _downloadRate = '0.0';
  String _errorMessage = '';

  String _speedTestUrl = "https://speed.cloudflare.com/__down?bytes=10000000";
  final _speedTestUrlController = TextEditingController();
  SpeedTest? _speedTest;
  bool _isPolling = false;
  bool _isOperating = false;
  bool _isStopping = false;
  int _operation = 0;
  bool _connected = false;
  bool _daemonRunning = false;
  bool _vpnActive = false;
  bool _connectionKnown = false;
  String? _pendingCommand;
  String? _connectionError;
  bool? _vpnPermissionGranted;
  Future<bool>? _vpnPreparation;
  Future<void>? _connectionRead;
  int? _lastConnectionOperation;
  bool _connectRequested = false;
  bool _vpnActivationAttempted = false;
  bool _suppressDisconnectNotice = false;

  bool get _hasSession => _isOperating || _connected || _daemonRunning || _pendingCommand != null;

  String get _connectionLabel {
    if (_isStopping) return '正在断开…';
    if (_connectionError != null) return '连接状态读取失败';
    if (!_connectionKnown) return '正在检查连接…';
    if (_isOperating) return _connected ? 'PPPoE 已连接，正在启用 VPN…' : '正在拨号…';
    if (_connected) return _vpnActive ? '已连接 · VPN 已启用' : 'PPPoE 已连接 · VPN 未启用';
    if (_daemonRunning || _pendingCommand != null) return '正在拨号 / 重试中…';
    return _vpnPermissionGranted == false ? '未连接 · VPN 未授权' : '未连接';
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: error ? NothingColors.redAccent : null,
      ));
  }

  void _requireSuccess(bool success, String message) {
    if (!success) throw StateError(message);
  }
  @override
  void initState() {
    super.initState();
    _refreshInterfaces();
    _startPeerPolling();
    _listenToLogStream();
    _loadDnsSettings();
    _loadSpeedTestUrl();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestVpnPermission(firstLaunchOnly: true);
    });
  }

  Future<bool> _requestVpnPermission({bool firstLaunchOnly = false}) {
    return _vpnPreparation ??= _prepareVpn(firstLaunchOnly).whenComplete(() => _vpnPreparation = null);
  }

  Future<bool> _prepareVpn(bool firstLaunchOnly) async {
    try {
      final granted = await PppoeBridge.prepareVpn(firstLaunchOnly: firstLaunchOnly);
      if (mounted) setState(() => _vpnPermissionGranted = granted);
      return granted;
    } catch (e) {
      if (mounted) {
        setState(() => _vpnPermissionGranted = false);
        _showMessage('VPN 授权请求失败：$e', error: true);
      }
      return false;
    }
  }

  Future<void> _loadSpeedTestUrl() async {
    try {
      final url = await PppoeBridge.loadSpeedTestUrl();
      if (!mounted) return;
      setState(() {
        _speedTestUrl = url ?? _speedTestUrl;
        _speedTestUrlController.text = _speedTestUrl;
      });
    } catch (e) {
      _showMessage('Failed to load speed test URL: $e', error: true);
    }
  }

  Future<void> _refreshInterfaces() async {
    if (_isLoadingInterfaces) return;
    setState(() => _isLoadingInterfaces = true);
    try {
      final interfaces = await PppoeBridge.getNetworkInterfaces();
      if (!mounted) return;
      setState(() {
        _availableInterfaces = interfaces.toSet().toList();
        if (!_availableInterfaces.contains(_selectedInterface)) {
          _selectedInterface = null;
        }
      });
    } catch (e) {
      _showMessage('Failed to load interfaces: $e', error: true);
    } finally {
      if (mounted) setState(() => _isLoadingInterfaces = false);
    }
  }

  Future<void> _loadDnsSettings() async {
    try {
      final settings = await PppoeBridge.loadDnsSettings();
      if (!mounted) return;
      setState(() {
        _useCustomDns = settings['useCustom'] as bool? ?? false;
        _customDns1.text = settings['dns1'] as String? ?? '';
        _customDns2.text = settings['dns2'] as String? ?? '';
      });
    } catch (e) {
      _showMessage('Failed to load DNS settings: $e', error: true);
    }
  }

  Timer? _saveDnsDebounce;
  Future<void> _persistDnsSettings() async {
    _requireSuccess(await PppoeBridge.saveDnsSettings(
      useCustom: _useCustomDns,
      dns1: _customDns1.text,
      dns2: _customDns2.text,
    ), 'Failed to save DNS settings');
  }

  void _saveDnsSettings() {
    _saveDnsDebounce?.cancel();
    _saveDnsDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        await _persistDnsSettings();
      } catch (e) {
        _showMessage('$e', error: true);
      }
    });
  }

  void _startPeerPolling() {
    _poll?.cancel();
    _refreshConnection();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshConnection());
  }

  Future<void> _refreshConnection() {
    return _connectionRead ??= _readConnection().whenComplete(() => _connectionRead = null);
  }

  Future<void> _readConnection() async {
    final operation = _operation;
    _isPolling = true;
    try {
      final state = await PppoeBridge.getConnectionState();
      if (!_isCurrentOperation(operation)) return;
      final restoringConnection = !_connectionKnown;
      final becameConnected = !_connected && state.connected;
      final disconnected = _connected && !state.connected;
      setState(() {
        _connectionKnown = true;
        _connectionError = null;
        _lastConnectionOperation = operation;
        _peer = state.peer;
        _connected = state.connected;
        _daemonRunning = state.running;
        _vpnActive = state.vpnActive;
        _pendingCommand = state.pendingCommand;
        if (!state.connected) _vpnActivationAttempted = false;
      });
      if (becameConnected && !_isStopping) _showMessage(restoringConnection ? '检测到已有 PPPoE 连接' : 'PPPoE 拨号成功，连接已建立');
      if (disconnected && !_isOperating && !_isStopping && !_suppressDisconnectNotice) {
        _showMessage('PPPoE 连接已断开', error: true);
      }
      _suppressDisconnectNotice = false;
      // A persistent daemon may finish negotiation after the initial attempt timed out.
      if (_connectRequested && _connected && !_vpnActive && !_isOperating && !_vpnActivationAttempted) {
        _activateVpnAfterReconnect(operation);
      }
    } catch (e) {
      if (_isCurrentOperation(operation)) setState(() => _connectionError = '$e');
    } finally {
      _isPolling = false;
    }
  }

  Future<void> _activateVpnAfterReconnect(int operation) async {
    _vpnActivationAttempted = true;
    try {
      // Only use an existing grant here; automatic reconnect must not reopen a denied dialog.
      _requireSuccess(await _requestVpnPermission(firstLaunchOnly: true), 'VPN 未授权，请断开后重新拨号授权');
      if (!_isCurrentOperation(operation) || !_connectRequested || !_connected) return;
      _requireSuccess(await PppoeBridge.startVpn(), 'VPN failed to start');
      if (!_isCurrentOperation(operation)) return;
      setState(() => _vpnActive = true);
      _showMessage('拨号成功，PPPoE 与 VPN 已连接');
    } catch (e) {
      if (_isCurrentOperation(operation)) _showMessage('$e', error: true);
    }
  }

  void _listenToLogStream() {
    _logSubscription?.cancel();
    _logSubscription = PppoeBridge.logStream.listen(
          (newLine) {
        if (!mounted) return;
        setState(() {
          _logs.add(newLine);
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() { _logs.add("[ERROR] [app] event=capture_error $e"); });
      },
    );
  }


  @override
  void dispose() {
    _operation++;
    _speedTest?.cancel();
    _user.dispose();
    _pass.dispose();
    _mtu.dispose();
    _mru.dispose();
    _poll?.cancel();
    _logSubscription?.cancel();
    _customDns1.dispose();
    _customDns2.dispose();
    _saveDnsDebounce?.cancel();
    _speedTestUrlController.dispose();
    super.dispose();
  }
  bool _isCurrentOperation(int operation) => mounted && operation == _operation;

  Future<void> _applyAndStart() async {
    if (_hasSession || !_connectionKnown || _connectionError != null) return;
    final operation = ++_operation;
    setState(() {
      _isOperating = true;
      _logs.clear();
      _vpnActivationAttempted = false;
    });
    _showMessage('正在准备拨号…');
    int? savedLogId;
    bool dialSucceeded = false;
    bool dialRequested = false;
    try {
      _requireSuccess(await _requestVpnPermission(), 'VPN permission denied');
      if (!_isCurrentOperation(operation)) return;
      _requireSuccess(await PppoeBridge.writeCreds(_user.text, _pass.text), 'Failed to save credentials');
      if (!_isCurrentOperation(operation)) return;
      final iface = _selectedInterface?.trim();
      _requireSuccess(await PppoeBridge.writeIface(iface == null || iface.isEmpty ? null : iface), 'Failed to save interface');
      if (!_isCurrentOperation(operation)) return;
      _requireSuccess(await PppoeBridge.writeMtuMru(int.tryParse(_mtu.text), int.tryParse(_mru.text)), 'Failed to save MTU/MRU');
      if (!_isCurrentOperation(operation)) return;
      _saveDnsDebounce?.cancel();
      await _persistDnsSettings();
      if (!_isCurrentOperation(operation)) return;
      dialRequested = true;
      _connectRequested = true;
      final result = await PppoeBridge.startDialingAttempt();
      if (!_isCurrentOperation(operation)) return;
      savedLogId = result['logId'] as int?;
      final status = result['status'] as String? ?? 'Failure (Unknown)';
      if (!status.startsWith('Success')) throw StateError(status);
      dialSucceeded = true;
      _vpnActivationAttempted = true;
      setState(() => _connected = true);
      _requireSuccess(await PppoeBridge.startVpn(), 'VPN failed to start');
      if (!_isCurrentOperation(operation)) return;
      setState(() => _vpnActive = true);
      if (savedLogId != null) {
        final saved = await PppoeBridge.updateLogStatus(savedLogId, 'Success (VPN Started)');
        if (!saved) {
          if (_isCurrentOperation(operation)) _showMessage('VPN started, but failed to update log status', error: true);
          return;
        }
      }
      if (_isCurrentOperation(operation)) _showMessage('拨号成功，PPPoE 与 VPN 已连接');
    } catch (e) {
      if (!_isCurrentOperation(operation)) return;
      if (savedLogId == null) {
        setState(() => _logs.add(
          '${DateTime.now().toUtc().toIso8601String()} [ERROR] [app] '
          'event=${dialRequested ? 'bridge_failed' : 'configuration_failed'} $e',
        ));
      }
      if (savedLogId != null && dialSucceeded) {
        await PppoeBridge.updateLogStatus(savedLogId, 'Failure ($e)');
      }
      if (_isCurrentOperation(operation)) {
        _suppressDisconnectNotice = true;
        _showMessage('$e', error: true);
      }
    } finally {
      if (_isCurrentOperation(operation)) {
        setState(() => _isOperating = false);
        _refreshConnection();
      }
    }
  }

  Future<void> _stopAll() async {
    if (_isStopping) return;
    final operation = ++_operation;
    _connectRequested = false;
    setState(() {
      _isStopping = true;
      _isOperating = true;
    });
    final errors = <String>[];
    // Both cleanup operations must run even when one fails.
    for (final action in [() => PppoeBridge.control('stop'), PppoeBridge.stopVpn]) {
      try {
        _requireSuccess(await action(), 'Stop command failed');
      } catch (e) {
        errors.add('$e');
      }
    }
    var stopped = false;
    for (var attempt = 0; attempt < 30 && _isCurrentOperation(operation); attempt++) {
      await _refreshConnection();
      if (_lastConnectionOperation == operation && _connectionError == null &&
          !_connected && !_daemonRunning && !_vpnActive && _pendingCommand == null) {
        stopped = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!_isCurrentOperation(operation)) return;
    if (!stopped) errors.add('停止命令已发送，尚未确认断开，请重试');
    setState(() {
      _isStopping = false;
      _isOperating = false;
    });
    _showMessage(errors.isEmpty ? '连接已断开' : errors.join('; '), error: errors.isNotEmpty);
  }

  Future<void> _cycleInterface() async {
    if (_isOperating) return;
    final operation = ++_operation;
    setState(() => _isOperating = true);
    try {
      _requireSuccess(await PppoeBridge.control('cycle'), 'Failed to switch interface');
    } catch (e) {
      if (_isCurrentOperation(operation)) _showMessage('$e', error: true);
    } finally {
      if (_isCurrentOperation(operation)) setState(() => _isOperating = false);
    }
  }

  Future<void> _startSpeedTest() async {
    if (_isTesting) return;
    final test = SpeedTest();
    _speedTest = test;
    setState(() {
      _isTesting = true;
      _errorMessage = '';
      _downloadRate = '0.0';
    });
    bool isCurrent() => mounted && identical(_speedTest, test);
    try {
      final rate = await test.run(_speedTestUrl, onProgress: (rate) {
        if (isCurrent()) setState(() => _downloadRate = rate.toStringAsFixed(2));
      });
      if (isCurrent()) setState(() => _downloadRate = rate.toStringAsFixed(2));
    } catch (e) {
      if (isCurrent()) setState(() => _errorMessage = 'Test failed: $e');
    } finally {
      if (isCurrent()) {
        setState(() {
          _speedTest = null;
          _isTesting = false;
        });
      }
    }
  }

  void _cancelSpeedTest() {
    final test = _speedTest;
    _speedTest = null;
    test?.cancel();
    setState(() {
      _isTesting = false;
      _errorMessage = 'Test canceled.';
      _downloadRate = '0.0';
    });
  }

  Future<void> _showSpeedTestSettingsDialog() async {
    // 确保控制器与当前状态同步
    _speedTestUrlController.text = _speedTestUrl;

    await showDialog(
        context: context,
        animationStyle: reduceMotion(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                duration: Duration(milliseconds: 200),
                reverseDuration: Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
              ),
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
                onPressed: () async {
                  final newUrl = _speedTestUrlController.text.trim();
                  try {
                    SpeedTest.parseUrl(newUrl);
                    await PppoeBridge.saveSpeedTestUrl(newUrl);
                    if (!mounted || !context.mounted) return;
                    setState(() => _speedTestUrl = newUrl);
                    Navigator.pop(context);
                  } catch (e) {
                    _showMessage('Failed to save URL: $e', error: true);
                  }
                },
              ),
            ],
          );
        }
    );
  }


  @override
  Widget build(BuildContext context) {

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
                  initialValue: _selectedInterface,
                  hint: const Text("自动选择接口"),
                  disabledHint: _isLoadingInterfaces ? const Text("正在加载...") : null,
                  decoration: const InputDecoration(labelText: "网络接口"),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text("自动选择")),
                    ..._availableInterfaces.map((iface) {
                      return DropdownMenuItem<String?>(value: iface, child: Text(iface));
                    }),
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
                controller: _mtu,
                enabled: !_isOperating,
                decoration: const InputDecoration(labelText: "MTU (576–1492)"),
                keyboardType: TextInputType.number,
              )),
              const SizedBox(width: 12),
              Expanded(child: TextField(
                controller: _mru,
                enabled: !_isOperating,
                decoration: const InputDecoration(labelText: "MRU (576–1492)"),
                keyboardType: TextInputType.number,
              )),
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
                ElevatedButton.icon(
                  key: const ValueKey('connection-toggle'),
                  onPressed: _isStopping ? null : _hasSession ? _stopAll
                      : (!_connectionKnown || _connectionError != null) ? (_isPolling ? null : _refreshConnection) : _applyAndStart,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _hasSession ? NothingColors.redAccent : NothingColors.white,
                    foregroundColor: _hasSession ? NothingColors.white : NothingColors.black,
                  ),
                  icon: Icon(_hasSession ? Icons.stop_rounded : Icons.power_settings_new),
                  label: Text(_isStopping ? '正在断开…' : _hasSession ? (_isOperating ? '取消拨号' : '断开连接')
                      : (!_connectionKnown || _connectionError != null) ? '检查连接' : '启动拨号'),
                ),
                TextButton(
                  onPressed: _isOperating || !_connectionKnown || _connectionError != null ? null : _cycleInterface,
                  child: const Text("切换接口"),
                ),
              ],
            ),

            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: AnimatedSwitcher(
                duration: motionDuration(context),
                child: Row(
                  key: ValueKey(_connectionLabel),
                  children: [
                    Icon(
                      _isStopping ? Icons.stop_circle_outlined : _connected ? Icons.check_circle : _isOperating || _daemonRunning ? Icons.sync : Icons.circle_outlined,
                      size: 14,
                      color: _isStopping || _connectionError != null ? NothingColors.redAccent : _connected ? NothingColors.white : NothingColors.grey,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_connectionLabel)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "接口: ${_peer['IF'] ?? '-'}  IP: ${_peer['IPLOCAL'] ?? '-'}\n"
              "DNS 1: ${_peer['DNS1'] ?? '-'}  DNS 2: ${_peer['DNS2'] ?? '-'}",
              style: Theme.of(context).textTheme.bodySmall,
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
                            style: OutlinedButton.styleFrom(
                              foregroundColor: NothingColors.redAccent,
                              side: BorderSide(color: NothingColors.redAccent),
                            ),
                            child: const Text("取消测试"),
                          )
                        else
                          ElevatedButton(
                            onPressed: _startSpeedTest,
                            child: const Text("开始下载测试"),
                          ),

                        AnimatedSize(
                          duration: motionDuration(context),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: _errorMessage.isEmpty ? const SizedBox(width: double.infinity) : Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Text(
                              _errorMessage,
                              style: const TextStyle(color: NothingColors.redAccent),
                            ),
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
            LogView(report: _logs.report),
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
        Semantics(
          label: '$title $value MB/s',
          child: ExcludeSemantics(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: double.tryParse(value) ?? 0),
              duration: motionDuration(context, 240),
              curve: Curves.easeOutCubic,
              builder: (context, rate, child) => Text(
                rate.toStringAsFixed(2),
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: NothingColors.white,
                ),
              ),
            ),
          ),
        ),
        const Text("MB/s", style: TextStyle(color: NothingColors.grey)),
      ],
    );
  }
}