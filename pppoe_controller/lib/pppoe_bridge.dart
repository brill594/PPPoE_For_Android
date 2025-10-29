import 'package:flutter/services.dart';

class PppoeBridge {
  static const _ch = MethodChannel('pppoe/bridge');
  static const _channel = MethodChannel('pppoe/bridge');
  // 1. 添加新的 EventChannel
  static const _logChannel = EventChannel('pppoe/log_stream');

  // 2. 创建一个 getter 来暴露日志流
  static Stream<String> get logStream {
    // 强制转换为 String
    return _logChannel.receiveBroadcastStream().map((event) => event as String);
  }
  static Future<List<String>> getNetworkInterfaces() async {
    try {
      final List<dynamic>? interfaces = await _channel.invokeMethod('getNetworkInterfaces');
      // 将 List<dynamic> 转换为 List<String>
      return interfaces?.map((e) => e.toString()).toList() ?? [];
    } catch (e) {
      // 发生错误时返回空列表
      print("Error getting network interfaces: $e");
      return [];
    }
  }
  static Future<bool> writeCreds(String user, String pass) async {
    final ok = await _ch.invokeMethod<bool>('writeCreds', {'user': user, 'pass': pass});
    return ok ?? false;
  }

  static Future<bool> writeIface(String? iface) async {
    final ok = await _ch.invokeMethod<bool>('writeIface', {'iface': iface});
    return ok ?? false;
  }

  static Future<bool> writeMtuMru(int? mtu, int? mru) async {
    final ok = await _ch.invokeMethod<bool>('writeMtuMru', {'mtu': mtu, 'mru': mru});
    return ok ?? false;
  }

  static Future<bool> control(String cmd) async {
    final ok = await _ch.invokeMethod<bool>('control', {'cmd': cmd});
    return ok ?? false;
  }

  static Future<Map<String, String>> readPeerEnv() async {
    // 用 invokeMapMethod 直接拿到强类型 Map
    final m = await _ch.invokeMapMethod<String, String>('readPeerEnv');
    return m ?? <String, String>{};
  }

  static Future<bool> prepareVpn() async {
    final ok = await _ch.invokeMethod<bool>('prepareVpn');
    return ok ?? false;
  }

  static Future<bool> startVpn() async {
    final ok = await _ch.invokeMethod<bool>('startVpn');
    return ok ?? false;
  }

  static Future<bool> stopVpn() async {
    final ok = await _ch.invokeMethod<bool>('stopVpn');
    return ok ?? false;
  }
}
