import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  // Uzaktayken her 5sn'de bir Firebase'den tüm eşleşmeleri + partner
  // konumlarını çekmek gereksiz pil/veri tüketir. En son bilinen mesafe/eşik
  // oranına göre bu tam kontrolü seyrekleştiriyoruz: eşiğe yakınken (veya
  // henüz bilinmiyorken) her tick'te, orta mesafede ~10sn'de, uzaktayken
  // ~30sn'de bir. Kalp atışı (heartbeat) her zaman her tick'te gönderilir ki
  // admin panelinde "çevrimdışı" görünmesin.
  double? _lastMinRatio;

  // Yasak bölgeler partnere olan mesafeden bağımsız olabilir (ör. ev/iş
  // konumu partnerden uzakta olabilir); sadece partner mesafesine göre
  // seyreltmek bölgeye yaklaşmayı geç fark etmeye yol açardı. Bölge
  // koordinatları son tam kontrolde önbelleğe alınır, her tick'te (ağ
  // isteği olmadan, bedava) buna karşı mesafe hesaplanıp seyreltme kararına
  // dahil edilir.
  List<ZoneData> _cachedZones = [];
  double? _lastZoneRatio;

  void _updateZoneRatioFromCache() {
    if (_myLat == null || _myLon == null || _cachedZones.isEmpty) {
      _lastZoneRatio = null;
      return;
    }
    double? minRatio;
    for (final z in _cachedZones) {
      if (z.radius <= 0) continue;
      final d = LocationService.calculateDistance(_myLat!, _myLon!, z.lat, z.lon);
      final ratio = d / z.radius;
      if (minRatio == null || ratio < minRatio) minRatio = ratio;
    }
    _lastZoneRatio = minRatio;
  }

  // Pil %30 altına düşünce bir kez, %15 altına düşünce bir kez daha uyarır
  // (SharedPreferences'taki kademe izolat yeniden başlasa da hatırlanır).
  // Pil %40'ın üstüne çıkınca kademe sıfırlanır, böylece bir sonraki
  // deşarj döngüsünde uyarılar yeniden tetiklenebilir.
  Future<void> _checkBatteryWarning(int level) async {
    final prefs = await SharedPreferences.getInstance();
    final tier = prefs.getInt('battery_warn_tier') ?? 0;
    if (level <= 15) {
      if (tier < 2) {
        await NotificationService.showBatteryWarning(level, critical: true);
        await prefs.setInt('battery_warn_tier', 2);
      }
    } else if (level <= 30) {
      if (tier < 1) {
        await NotificationService.showBatteryWarning(level, critical: false);
        await prefs.setInt('battery_warn_tier', 1);
      }
    } else if (level >= 40 && tier != 0) {
      await prefs.setInt('battery_warn_tier', 0);
    }
  }

  // Admin panelden gönderilen mesajı yakalar; ts, SharedPreferences'taki
  // son görülenden yeniyse bildirim gösterip son görüleni günceller
  // (aynı mesajın her tick'te tekrar bildirilmesini önler).
  Future<void> _checkAdminMessage() async {
    try {
      final snap = await FirebaseDatabase.instance.ref('devices/$_deviceId/adminMsg').get();
      final map = snap.value as Map?;
      if (map == null) return;
      final text = map['text'] as String?;
      if (text == null || text.isEmpty) return;
      final tsRaw = map['ts'];
      final ts = tsRaw is int ? tsRaw : (tsRaw as num?)?.toInt() ?? 0;
      final prefs = await SharedPreferences.getInstance();
      final lastTs = prefs.getInt('admin_msg_last_ts') ?? 0;
      if (ts > lastTs) {
        await NotificationService.showAdminMessage(text);
        await prefs.setInt('admin_msg_last_ts', ts);
      }
    } catch (_) {}
  }

  // Admin panelden "Konum İste" ile tetiklenir. Konum akışı bir süredir yeni
  // nokta üretmemişse (ör. GPS geçici sinyal kaybetti, cihaz hareketsiz vb.)
  // beklemeden anında taze bir GPS okuması alıp yazar.
  Future<void> _checkLocationRequest() async {
    try {
      final snap = await FirebaseDatabase.instance.ref('devices/$_deviceId/locationRequest').get();
      final map = snap.value as Map?;
      if (map == null) return;
      final tsRaw = map['ts'];
      final ts = tsRaw is int ? tsRaw : (tsRaw as num?)?.toInt() ?? 0;
      final prefs = await SharedPreferences.getInstance();
      final lastTs = prefs.getInt('loc_req_last_ts') ?? 0;
      if (ts <= lastTs) return;
      await prefs.setInt('loc_req_last_ts', ts);
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
      _myLat = pos.latitude;
      _myLon = pos.longitude;
      await LocationService.writeLocation(_deviceId, pos.latitude, pos.longitude);
    } catch (_) {}
  }

  bool _shouldFullCheck() {
    if (_alarming) return true; // alarm aktifken her zaman tam kontrol (yasak bölge çıkışı da dahil)
    final candidates = [_lastMinRatio, _lastZoneRatio].whereType<double>();
    if (candidates.isEmpty) return true;
    final ratio = candidates.reduce((a, b) => a < b ? a : b);
    if (ratio < 1.3) return true;
    if (ratio < 2.5) return _tick % 2 == 0;
    return _tick % 6 == 0;
  }

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
    await _checkAdminMessage();
    await _checkLocationRequest();
    _tick++;
    if (_tick % 12 == 0) { // ~every 60s at 5s interval
      try {
        final level = await _battery.batteryLevel;
        await LocationService.writeBattery(_deviceId, level);
        await _checkBatteryWarning(level);
      } catch (_) {}
    }
    if (_myLat == null || _myLon == null) return;
    _updateZoneRatioFromCache();
    if (!_shouldFullCheck()) return;
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
      double? minRatio;
      final zonesSeen = <ZoneData>[];

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
          // Yasak bölgeler pair'e değil korunan cihaza bağlıdır (eşleşme
          // silinip yeniden kurulunca kaybolmasın diye).
          final zonesSnap = await FirebaseDatabase.instance.ref('devices/${pair.protectedDeviceId}/zones').get();
          final zonesMap = zonesSnap.value as Map?;
          final pairZones = <ZoneData>[];
          if (zonesMap != null) {
            zonesMap.forEach((zid, zval) {
              try { pairZones.add(ZoneData.fromMap(zid as String, zval as Map)); } catch (_) {}
            });
          }
          zonesSeen.addAll(pairZones);
          for (final z in pairZones) {
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

        if (d != null && pair.threshold > 0) {
          final ratio = d / pair.threshold;
          if (minRatio == null || ratio < minRatio) minRatio = ratio;
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
      _lastMinRatio = minRatio;
      _cachedZones = zonesSeen;
      _updateZoneRatioFromCache();

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
      // Telefon yeniden başlatıldığında (pil bitip şarj sonrası, zorunlu
      // yeniden başlatma vb.) izleme kendiliğinden devam etsin diye açık.
      foregroundTaskOptions: const ForegroundTaskOptions(interval: 5000, isOnceEvent: false, autoRunOnBoot: true, allowWakeLock: true, allowWifiLock: true),
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
