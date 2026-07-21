import 'package:flutter/services.dart';

class DisguiseService {
  static const _channel = MethodChannel('uzakdur/disguise');

  static Future<void> apply() async {
    try { await _channel.invokeMethod('applyDisguise'); } catch (_) {}
  }

  static Future<void> remove() async {
    try { await _channel.invokeMethod('removeDisguise'); } catch (_) {}
  }
}
