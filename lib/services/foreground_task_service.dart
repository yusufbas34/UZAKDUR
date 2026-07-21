import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'location_service.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(_ProximityHandler());

class _ProximityHandler extends TaskHandler {
  StreamSubscription<Position>? _posSub;
  double? _myLat, _myLon;
  String _deviceId = '';
  bool _alarming = false;
  int _tick = 0;
  final _battery = Battery();

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
    if (_deviceId.isEmpty) return;
    await LocationService.heartbeat(_deviceId);
    _tick++;
    if (_tick % 12 == 0) { // ~every 60s at 5s interval
      try { await LocationService.writeBattery(_deviceId, await _battery.batteryLevel); } catch (_) {}
    }
    if (_myLat == null || _myLon == null) return;
    try {
      final deviceSnap = await FirebaseDatabase.instance.ref('devices/$_deviceId').get();
      final deviceMap = deviceSnap.value as Map?;
      final role = deviceMap?['role'] as String?;

      // Bir cihaz birden fazla eşleşmede yer alabilir (ör. 1 korunan –
      // 2..4 uzaklaştırılan); devices altında tek bir pairId referansı
      // tutulmaz, bu yüzden tüm pairs koleksiyonu taranıp bu cihazı
      // içeren ilişkiler bulunur.
      final pairsSnap = await FirebaseDatabase.instance.ref('pairs').get();
      final pairsMap = pairsSnap.value as Map?;
      if (pairsMap == null) return;

      ZoneData? alarmZone;
      double? alarmDistance;
      String? alarmSoundId;
      bool anyAlarm = false;

      for (final entry in pairsMap.entries) {
        final pairId = entry.key as String;
        PairData pair;
        try {
          pair = PairData.fromMap(pairId, entry.value as Map);
        } catch (_) {
          continue;
        }
        if (pair.protectedDeviceId != _deviceId && pair.trackedDeviceId != _deviceId) continue;

        ZoneData? breachedZone;
        if (role == 'tracked') {
          for (final z in pair.zones) {
            final zd = LocationService.calculateDistance(_myLat!, _myLon!, z.lat, z.lon);
            if (zd < z.radius) { breachedZone = z; break; }
          }
        }

        final otherId = pair.otherDeviceId(_deviceId);
        final locSnap = await FirebaseDatabase.instance.ref('locations/$otherId').get();
        double? d;
        if (locSnap.exists && locSnap.value != null) {
          final other = LocationData.fromMap(locSnap.value as Map);
          d = LocationService.calculateDistance(_myLat!, _myLon!, other.lat, other.lon);
        }

        final proximityAlarm = d != null && d < pair.threshold;
        final isAlarm = proximityAlarm || breachedZone != null;

        if (isAlarm) {
          anyAlarm = true;
          alarmZone ??= breachedZone;
          alarmDistance ??= d;
          alarmSoundId ??= pair.alarmSound;
          if (breachedZone != null) {
            await LocationService.writeAlarmLog(pairId, _deviceId, 0, type: 'zone', zoneLabel: breachedZone.label);
          } else if (d != null) {
            await LocationService.writeAlarmLog(pairId, _deviceId, d);
          }
        }
      }

      sendPort?.send({'type': 'distance', 'value': alarmDistance});

      if (anyAlarm) {
        if (!_alarming) {
          _alarming = true;
          await NotificationService.startAlarm(alarmDistance ?? 0, soundId: alarmSoundId ?? 'siren');
        }
        FlutterForegroundTask.updateService(
          notificationTitle: alarmZone != null ? '⚠️ YASAK BÖLGE — ${alarmZone.label}' : '⚠️ YAKLAŞMA — ${alarmDistance?.round()}m',
          notificationText: 'Aktif alarm',
        );
      } else {
        if (_alarming) { _alarming = false; await NotificationService.stopAlarm(); }
        FlutterForegroundTask.updateService(
          notificationTitle: alarmDistance != null ? 'UZAKDUR — Güvenli (${alarmDistance.round()}m)' : 'UZAKDUR — İzleniyor',
          notificationText: 'İzleniyor',
        );
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
