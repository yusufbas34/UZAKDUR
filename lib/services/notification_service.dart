import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _alarming = false;

  static Future<void> init() async {
    await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'uzakdur_alarm', 'UZAKDUR Alarm',
          description: 'Yaklaşma uyarısı', importance: Importance.max, enableVibration: true,
        ));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'uzakdur_status', 'UZAKDUR Servis',
          description: 'Arka plan servisi', importance: Importance.low,
        ));
  }

  static Future<void> startAlarm(double distance) async {
    if (_alarming) return;
    _alarming = true;
    await _plugin.show(101, '⚠️  YAKLAŞMA ALGILANDI',
        'Mesafe: ${distance.round()} metre — Uzaklaşın!',
        const NotificationDetails(
            android: AndroidNotificationDetails('uzakdur_alarm', 'UZAKDUR Alarm',
                importance: Importance.max, priority: Priority.max,
                fullScreenIntent: true, ongoing: true, autoCancel: false,
                color: Color(0xFFFF3B30), category: AndroidNotificationCategory.alarm)));
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 600, 150, 600, 150, 900], repeat: 0);
    }
  }

  static Future<void> stopAlarm() async {
    if (!_alarming) return;
    _alarming = false;
    await _plugin.cancel(101);
    Vibration.cancel();
  }

  static bool get isAlarming => _alarming;
}
