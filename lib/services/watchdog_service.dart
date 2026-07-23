import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_core/firebase_core.dart';
import '../firebase_options.dart';
import '../models/roles.dart';
import 'foreground_task_service.dart';

const _taskName = 'uzakdur_watchdog_task';
const _uniqueName = 'uzakdur_watchdog';

// Android'in kendisi bile arka plan servislerinin OEM'ler tarafından
// öldürülmesini tam olarak engelleyemiyor; bu yüzden ek bir güvenlik ağı
// olarak WorkManager üzerinden ~15 dakikada bir çalışan bir "bekçi" görevi
// kuruyoruz. Bu, servisin arka planda çalışması garantisi değil — sadece
// öldürülmüşse kendini toparlama şansı. Gerçek zamanlama Android'in kendi
// pil/iş zamanlayıcısına bağlı olduğu için ~15dk bazen daha uzun sürebilir.
@pragma('vm:entry-point')
void watchdogCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      // WorkManager da kendi ayrı isolate'inde çalışır — bu görev servisi
      // yeniden başlatırken (ForegroundTaskService.start) yazdığı
      // serviceStartError teşhis kaydının çalışabilmesi için Firebase bu
      // isolate'te de initialize edilmiş olmalı.
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('device_id');
      final role = prefs.getString('device_role');
      if (deviceId == null || role == null) return true;

      final running = await FlutterForegroundTask.isRunningService;
      if (!running) {
        try { await ForegroundTaskService.start(deviceId: deviceId); } catch (_) {}

        // Uzaklaştırılan rolüne, izleme durduğunda ~30 dakikada bir hatırlatma
        // bildirimi — korunan tarafın habersiz kalmaması için uygulamayı
        // tekrar açması gerektiğini fark etsin diye.
        if (role == kRoleTracked) {
          final lastNotified = prefs.getInt('watchdog_last_notified') ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastNotified > const Duration(minutes: 25).inMilliseconds) {
            await _showReminder();
            await prefs.setInt('watchdog_last_notified', now);
          }
        }
      }
    } catch (_) {}
    return true;
  });
}

Future<void> _showReminder() async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'uzakdur_reminder', 'UZAKDUR Hatırlatma',
        description: 'Takip durduğunda hatırlatma', importance: Importance.high,
      ));
  await plugin.show(
    202,
    '⚠️ UZAKDUR Takip Durdu',
    'Konum takibi durmuş görünüyor. Devam etmesi için uygulamayı aç.',
    const NotificationDetails(android: AndroidNotificationDetails(
      'uzakdur_reminder', 'UZAKDUR Hatırlatma',
      importance: Importance.high, priority: Priority.high,
    )),
  );
}

class WatchdogService {
  static Future<void> init() => Workmanager().initialize(watchdogCallbackDispatcher);

  static Future<void> register() => Workmanager().registerPeriodicTask(
        _uniqueName, _taskName,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
}
