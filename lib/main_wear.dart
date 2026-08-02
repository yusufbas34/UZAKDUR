import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'firebase_options.dart';
import 'services/notification_service.dart';
import 'services/watchdog_service.dart';
import 'services/push_service.dart';
import 'wear/wear_app.dart';

// Wear OS (saat) uygulamasının ayrı giriş noktası — telefon uygulamasıyla
// (main.dart) aynı Firebase projesini ve aynı servis katmanını
// (location_service, foreground_task_service, watchdog_service) kullanır,
// sadece arayüz saat ekranına göre küçültülmüştür (bkz. wear/wear_app.dart).
// Ayrı bir Android product flavor'dan (`wear`) derlenir, telefon build'ini
// hiç etkilemez.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.init();
  await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  await WatchdogService.init();
  await PushService.registerBackgroundHandler();
  runApp(const WearApp());
}
