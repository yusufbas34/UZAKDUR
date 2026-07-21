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
  String _deviceId = '';
  bool _alarming = false;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    _deviceId = await FlutterForegroundTask.getData<String>(key: 'deviceId') ?? '';
    _posSub = LocationService.startLocationStream().listen((pos) async {
      _myLat = pos.latitude;
      _myLon = pos.longitude;
      await LocationService.writeLocation(_deviceId, pos.latitude, pos.longitude);
      FlutterForegroundTask.updateService(
        notificationTitle: 'UZAKDUR aktif',
        notificationText: 'GPS alınıyor…',
      );
    });
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    if (_myLat == null || _myLon == null || _deviceId.isEmpty) return;
    try {
      final deviceSnap = await FirebaseDatabase.instance.ref('devices/$_deviceId/pairId').get();
      final pairId = deviceSnap.value as String?;
      if (pairId == null) return;
      final pairSnap = await FirebaseDatabase.instance.ref('pairs/$pairId').get();
      if (!pairSnap.exists || pairSnap.value == null) return;
      final pair = PairData.fromMap(pairId, pairSnap.value as Map);
      final otherId = pair.otherDeviceId(_deviceId);
      final locSnap = await FirebaseDatabase.instance.ref('locations/$otherId').get();
      if (!locSnap.exists || locSnap.value == null) return;
      final other = LocationData.fromMap(locSnap.value as Map);
      final d = LocationService.calculateDistance(_myLat!, _myLon!, other.lat, other.lon);
      sendPort?.send({'type': 'distance', 'value': d});
      if (d < pair.threshold) {
        if (!_alarming) { _alarming = true; await NotificationService.startAlarm(d, soundId: pair.alarmSound); await LocationService.writeAlarmLog(pairId, _deviceId, d); }
        FlutterForegroundTask.updateService(notificationTitle: '⚠️ YAKLAŞMA — ${d.round()}m', notificationText: 'Eşik: ${pair.threshold.round()}m');
      } else {
        if (_alarming) { _alarming = false; await NotificationService.stopAlarm(); }
        FlutterForegroundTask.updateService(notificationTitle: 'UZAKDUR — Güvenli (${d.round()}m)', notificationText: 'İzleniyor');
      }
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    await _posSub?.cancel();
    await LocationService.setOnline(_deviceId, false);
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
        buttons: [const NotificationButton(id: 'stop_alarm', text: 'Alarmı Durdur')],
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
      foregroundTaskOptions: const ForegroundTaskOptions(interval: 5000, isOnceEvent: false, autoRunOnBoot: false, allowWakeLock: true, allowWifiLock: true),
    );
  }

  static Future<void> start({required String deviceId}) async {
    await FlutterForegroundTask.saveData(key: 'deviceId', value: deviceId);
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: 'UZAKDUR Başlatıldı', notificationText: 'İzleme aktif', callback: startCallback,
      );
    }
  }

  static Future<void> stop() => FlutterForegroundTask.stopService();
}
