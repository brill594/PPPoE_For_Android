import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LogSummary {
  final int id;
  final int timestamp;
  final String? note;
  final String status;

  LogSummary({required this.id, required this.timestamp, this.note, required this.status});

  factory LogSummary.fromMap(Map map) {
    return LogSummary(
      id: map['id'] as int,
      timestamp: map['timestamp'] as int,
      note: map['note'] as String?,
      status: map['status'] as String,
    );
  }
}
class LogDetail extends LogSummary {
  final String logContent;

  LogDetail({
    required super.id,
    required super.timestamp,
    super.note,
    required super.status,
    required this.logContent,
  });

  factory LogDetail.fromMap(Map map) {
    return LogDetail(
      id: map['id'] as int,
      timestamp: map['timestamp'] as int,
      note: map['note'] as String?,
      status: map['status'] as String,
      logContent: map['logContent'] as String,
    );
  }
}

class PppoeConnectionState {
  final Map<String, String> peer;
  final bool connected;
  final bool running;
  final bool vpnActive;
  final String? pendingCommand;

  const PppoeConnectionState({
    this.peer = const {},
    this.connected = false,
    this.running = false,
    this.vpnActive = false,
    this.pendingCommand,
  });

  factory PppoeConnectionState.fromMap(Map<dynamic, dynamic> value) => PppoeConnectionState(
    peer: Map<String, String>.from(value['peer'] as Map? ?? {}),
    connected: value['connected'] == true,
    running: value['running'] == true,
    vpnActive: value['vpnActive'] == true,
    pendingCommand: value['pendingCommand'] as String?,
  );
}

class PppoeBridge {
  static const _channel = MethodChannel('pppoe/bridge');
  static const _logChannel = EventChannel('pppoe/log_stream');

  static Stream<String> get logStream {
    return _logChannel.receiveBroadcastStream().map((event) => event as String);
  }

  // 返回包含状态和日志 ID 的 Map
  static Future<Map<String, dynamic>> startDialingAttempt() async {
    try {
      final result = await _channel.invokeMethod('startDialingAttempt');
      // 确保返回的是 Map<String, dynamic>
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      } else {
        // 如果 Kotlin 返回的不是 Map，则抛出错误
        throw "Unexpected result type from native: ${result.runtimeType}";
      }
    } on PlatformException catch (e) {
      // 如果 Kotlin 使用 error 返回，这里会捕获
      throw e.message ?? "Failed to start dialing";
    } catch (e) {
      // 捕获其他潜在错误 (比如类型转换错误)
      throw "Error processing dialing result: $e";
    }
  }
  static Future<bool> saveDnsSettings({required bool useCustom, String? dns1, String? dns2}) async {
    return await _channel.invokeMethod('saveDnsSettings', {
      'useCustom': useCustom,
      'dns1': dns1,
      'dns2': dns2,
    }) ?? false;
  }

  static Future<Map<String, dynamic>> loadDnsSettings() async {
    final Map<dynamic, dynamic>? settings = await _channel.invokeMethod('loadDnsSettings');
    // 返回默认值以防 native 返回 null
    return Map<String, dynamic>.from(settings ?? {'useCustom': false, 'dns1': '', 'dns2': ''});
  }

  static Future<bool> updateLogStatus(int id, String status) async {
    try {
      return await _channel.invokeMethod('updateLogStatus', {'id': id, 'status': status}) ?? false;
    } catch (e) {
      debugPrint("Error updating log status for ID $id: $e");
      return false;
    }
  }

  static Future<List<String>> getNetworkInterfaces() async {
    final List<dynamic>? interfaces = await _channel.invokeMethod('getNetworkInterfaces');
    return interfaces?.map((e) => e.toString()).toList() ?? [];
  }
  static Future<bool> writeCreds(String user, String pass) async {
    final ok = await _channel.invokeMethod<bool>('writeCreds', {'user': user, 'pass': pass});
    return ok ?? false;
  }

  static Future<bool> writeIface(String? iface) async {
    final ok = await _channel.invokeMethod<bool>('writeIface', {'iface': iface});
    return ok ?? false;
  }

  static Future<bool> writeMtuMru(int? mtu, int? mru) async {
    final ok = await _channel.invokeMethod<bool>('writeMtuMru', {'mtu': mtu, 'mru': mru});
    return ok ?? false;
  }

  static Future<bool> control(String cmd) async {
    final ok = await _channel.invokeMethod<bool>('control', {'cmd': cmd});
    return ok ?? false;
  }

  static Future<Map<String, String>> readPeerEnv() async {
    // 用 invokeMapMethod 直接拿到强类型 Map
    final m = await _channel.invokeMapMethod<String, String>('readPeerEnv');
    return m ?? <String, String>{};
  }

  static Future<PppoeConnectionState> getConnectionState() async {
    final state = await _channel.invokeMapMethod<dynamic, dynamic>('getConnectionState');
    if (state == null) throw StateError('Connection state unavailable');
    return PppoeConnectionState.fromMap(state);
  }

  static Future<bool> prepareVpn({bool firstLaunchOnly = false}) async {
    final ok = await _channel.invokeMethod<bool>('prepareVpn', {'firstLaunchOnly': firstLaunchOnly});
    return ok ?? false;
  }

  static Future<bool> startVpn() async {
    final ok = await _channel.invokeMethod<bool>('startVpn');
    return ok ?? false;
  }

  static Future<bool> stopVpn() async {
    final ok = await _channel.invokeMethod<bool>('stopVpn');
    return ok ?? false;
  }

  static Future<List<LogSummary>> getLogHistory() async {
    final List<dynamic>? history = await _channel.invokeMethod('getLogHistory');
    return history?.map((map) => LogSummary.fromMap(map as Map)).toList() ?? [];
  }

  static Future<LogDetail?> getLogDetails(int id) async {
    final Map<dynamic, dynamic>? detail = await _channel.invokeMethod('getLogDetails', {'id': id});
    return detail != null ? LogDetail.fromMap(detail) : null;
  }

  static Future<bool> updateLogNote(int id, String? note) async {
    try {
      return await _channel.invokeMethod('updateLogNote', {'id': id, 'note': note}) ?? false;
    } catch (e) {
      debugPrint("Error updating note for ID $id: $e");
      return false;
    }
  }

  static Future<bool> deleteLogEntry(int id) async {
    try {
      return await _channel.invokeMethod('deleteLogEntry', {'id': id}) ?? false;
    } catch (e) {
      debugPrint("Error deleting log entry ID $id: $e");
      return false;
    }
  }

  static Future<bool> shareLogAsText({required String text, required String subject}) async {
    try {
      final result = await _channel.invokeMethod<bool>('shareLogAsText', {
        'text': text,
        'subject': subject,
      });
      return result ?? false; // 如果原生代码返回 null，则默认为 false
    } catch (e) {
      debugPrint("Error calling shareLogAsText: $e");
      return false;
    }
  }

  static Future<void> saveSpeedTestUrl(String url) async {
    final saved = await _channel.invokeMethod<bool>('saveSpeedTestUrl', {'url': url});
    if (saved != true) throw StateError('Failed to save speed test URL');
  }

  static Future<String?> loadSpeedTestUrl() async {
    return _channel.invokeMethod<String>('loadSpeedTestUrl');
  }
}
