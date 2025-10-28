import 'package:flutter/services.dart';

class PppoeBridge {
  static const _ch = MethodChannel('pppoe/bridge');

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

  static Future<String> readLog() async {
    final s = await _ch.invokeMethod<String>('readLog');
    return s ?? '';
    // 如需截断/限制长度，可在这里处理
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
