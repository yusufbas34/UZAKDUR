import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'location_service.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(_ProximityHandler());

class _ProximityHandler extends TaskHandler {
  StreamSubscription<Position>? _posSub;
  double? _myLat, _myLon;
  String _role = 'B';
  String _otherRole = 'A';
  double _threshold = 100.0;
  bool _alarming = false;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    _role = await FlutterForegroundTask.getData<String>(key: 'role') ?? 'B';
    _otherRole = _role == 'A' ? 'B' : 'A';
    _threshold = (await FlutterForegroundTask.getData<double>(key: 'threshold')) ?? 100.0;
    await LocationService.setOnline(_role, true);
    _posSub = LocationService.startLocationStream().listen((pos) async {
      _myLat = pos.latitude;
      _myLon = pos.longitude;
      await LocationService.writeLocation(_role, pos.latitude, pos.longitude);
      FlutterForegroundTask.updateService(
        notificationTitle: 'UZAKDUR — Cihaz $_role aktif',
        notificationText: 'GPS alınıyor…',
      );
    });
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    if (_myLat == null || _myLon == null) return;
    try {
      final snap = await FirebaseDatabase.instance.ref('locations/$_otherRole').get();
      if (!snap.exists || snap.value == null) return;
      final other = LocationData.fromMap(snap.value as Map);
      final d = LocationService.calculateDistance(_myLat!, _myLon!, other.lat, other.lon);
      sendPort?.send({'type': 'distance', 'value': d});
      if (d < _threshold) {
        if (!_alarming) { _alarming = true; await NotificationService.startAlarm(d); await LocationService.writeAlarmLog(_role, d); }
        FlutterForegroundTask.updateService(notificationTitle: '⚠️ YAKLAŞMA — ${d.round()}m', notificationText: 'Eşik: ${_threshold.round()}m');
      } else {
        if (_alarming) { _alarming = false; await NotificationService.stopAlarm(); }
        FlutterForegroundTask.updateService(notificationTitle: 'UZAKDUR — Güvenli (${d.round()}m)', notificationText: 'Cihaz $_role izleniyor');
      }
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    await _posSub?.cancel();
    await LocationService.setOnline(_role, false);
    await NotificationService.stopAlarm();
  }

  @override
  void onButtonPressed(String id) { if (id == 'stop_alarm') NotificationService.stopAlarm(); }
  @override
  void onNotificationPressed() {}
}

class ForegroundTaskService {
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'uzakdur_fg', channelName: 'UZAKDUR Arka Plan',
        channelDescription: 'Konum takibi',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(resType: ResourceType.mipmap, resPrefix: ResourcePrefix.ic, name: 'launcher'),
        buttons: [const NotificationButton(id: 'stop_alarm', text: 'Alarmu Durdur')],
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
      foregroundTaskOptions: const ForegroundTaskOptions(interval: 5000, isOnceEvent: false, autoRunOnBoot: false, allowWakeLock: true, allowWifiLock: true),
    );
  }

  static Future<void> start({required String role, required double threshold}) async {
    await FlutterForegroundTask.saveData(key: 'role', value: role);
    await FlutterForegroundTask.saveData(key: 'threshold', value: threshold);
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: 'UZAKDUR Başlatıldı', notificationText: 'Cihaz $role aktif', callback: startCallback,
      );
    }
  }

  static Future<void> stop() => FlutterForegroundTask.stopService();
}
