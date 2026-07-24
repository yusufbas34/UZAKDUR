import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart';
import 'location_service.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(_ProximityHandler());

class _ProximityHandler extends TaskHandler {
  double? _myLat, _myLon;
  String _deviceId = '';
  bool _alarming = false;
  String _lastTier = 'safe'; // 'safe' | 'sinir' | 'kritik' — bir önceki tam kontroldeki en kötü kademe (acil hariç)
  String _lastRouteTier = 'safe'; // aynı, ama rota (güzergah) bölgeleri için — asla 'acil' olmaz
  DateTime? _lastRouteRepeatAt; // rota 'sinir' (içeride) durumunda 30sn'de bir tekrar bildirim için
  String? _lastBreachedZoneId; // yasak bölgeye en son ne zaman girildiği — tekrar bildirim göndermemek için
  // Bildirim üzerindeki "Alarmı Durdur" butonuna basıldığında alarm tamamen
  // kapanmıyor — tehlike sürüyorsa kademeli olarak (30sn/60sn/120sn) geri
  // geliyor (uygulama içindeki davranışla aynı, bkz. monitor_screen.dart).
  int _alarmStopCount = 0;
  DateTime? _alarmSnoozedUntil;
  bool _startErrorCleared = false;
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
      if (z.threshold <= 0) continue;
      final d = z.distanceFrom(_myLat!, _myLon!);
      final ratio = d / z.threshold;
      if (minRatio == null || ratio < minRatio) minRatio = ratio;
    }
    _lastZoneRatio = minRatio;
  }

  // Pil %30 altına düşünce bir kez, %15 altına düşünce bir kez daha uyarır
  // (SharedPreferences'taki kademe izolat yeniden başlasa da hatırlanır).
  // Kullanıcı şarja takmazsa (seviye yükselmezse) yarım saatte bir aynı
  // uyarı tekrarlanır. Pil %40'ın üstüne çıkınca kademe sıfırlanır, böylece
  // bir sonraki deşarj döngüsünde uyarılar yeniden tetiklenebilir.
  Future<void> _checkBatteryWarning(int level, {required bool isTracked}) async {
    final prefs = await SharedPreferences.getInstance();
    final tier = prefs.getInt('battery_warn_tier') ?? 0;
    final lastWarnTs = prefs.getInt('battery_warn_last_ts') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const recheckMs = 30 * 60 * 1000;

    if (level <= 15) {
      if (tier < 2 || (nowMs - lastWarnTs) >= recheckMs) {
        await NotificationService.showBatteryWarning(level, critical: true, isTracked: isTracked);
        await prefs.setInt('battery_warn_tier', 2);
        await prefs.setInt('battery_warn_last_ts', nowMs);
      }
    } else if (level <= 30) {
      if (tier < 1 || (nowMs - lastWarnTs) >= recheckMs) {
        await NotificationService.showBatteryWarning(level, critical: false, isTracked: isTracked);
        await prefs.setInt('battery_warn_tier', 1);
        await prefs.setInt('battery_warn_last_ts', nowMs);
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
        // Admin panelin "gönderildi mi, telefona ulaştı mı" farkını
        // görebilmesi için — aksi halde iletim gerçekten başarısız olduğunda
        // bunu tahmin etmekten başka yol yok.
        await FirebaseDatabase.instance.ref('devices/$_deviceId/adminMsg/ackTs').set(ServerValue.timestamp);
      }
    } catch (e) {
      await _reportDebugError('adminMsg: $e');
    }
  }

  // Sessiz catch(_) blokları neyin başarısız olduğunu görmemizi
  // imkansızlaştırıyordu — gerçek hatayı Firebase'e yazıp admin panelde
  // görünür kılıyoruz (tahmin yerine kanıt).
  Future<void> _reportDebugError(String msg) async {
    try {
      await FirebaseDatabase.instance.ref('devices/$_deviceId/debugError').set({'msg': msg, 'ts': ServerValue.timestamp});
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
      await FirebaseDatabase.instance.ref('devices/$_deviceId/locationRequest/ackTs').set(ServerValue.timestamp);
      await NotificationService.showLocationRequestNotice();
    } catch (e) {
      await _reportDebugError('locationRequest: $e');
    }
  }

  bool _shouldFullCheck() {
    if (_alarming) return true; // alarm aktifken her zaman tam kontrol (yasak bölge çıkışı da dahil)
    final candidates = [_lastMinRatio, _lastZoneRatio].whereType<double>();
    if (candidates.isEmpty) return true;
    final ratio = candidates.reduce((a, b) => a < b ? a : b);
    if (ratio < 1.3) return _tick % 2 == 0;   // yakın: ~10sn
    if (ratio < 2.5) return _tick % 12 == 0;  // orta: ~1dk
    return _tick % 24 == 0;                   // uzak: ~2dk
  }

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    // getData yerel/native bir çağrı, Firebase'e bağımlı değil — bu yüzden
    // aşağıdaki adımlardan biri patlarsa bile hatayı YİNE DE hangi cihaz
    // için raporlayacağımızı bilebilelim diye en başta alınıyor.
    _deviceId = await FlutterForegroundTask.getData<String>(key: 'deviceId') ?? '';
    try {
      // KÖK SEBEP: flutter_foreground_task bu callback'i ayrı bir Dart
      // isolate'inde çalıştırır — bu isolate'in Firebase'i main.dart'taki
      // Firebase.initializeApp() çağrısından HABERİ YOK, kendi başına ayrıca
      // initialize edilmesi gerekiyor. Bu satır olmadan bu isolate içindeki
      // HER FirebaseDatabase çağrısı (serviceTick, heartbeat, adminMsg,
      // locationRequest, hatta debugError'ın kendisi) "no Firebase App
      // [DEFAULT]" hatasıyla patlıyordu — ve hepsi try/catch(_){}  içinde
      // sessizce yutuluyordu. Bu, "servis hiç tick atmıyor" teşhisinin asıl
      // sebebiydi: servis aslında BAŞLIYORDU, ama içindeki her Firebase
      // işlemi ilk satırda sessizce başarısız oluyordu — OEM pil kısıtlaması
      // hiç devreye girmeden.
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      // flutter_local_notifications'ın da aynı sebeple bu isolate'te kendi
      // initialize()'ı gerekiyor (Android bildirim kanalı OS seviyesinde
      // kalıcı olsa da, eklentinin Dart-native köprüsü isolate başına ayrı).
      await NotificationService.init();
      await _pollLocation();
    } catch (e) {
      // onStart() eskiden hiçbir try/catch olmadan çalışıyordu — burada
      // atılan bir istisna (ör. Firebase "duplicate app" hatası) muhtemelen
      // eklentinin kendi isolate giriş noktası tarafından sessizce
      // yutuluyordu ve onRepeatEvent hiç çalışmaya başlamıyordu, hiçbir yerde
      // görünmeden. Artık en azından denemesi mümkünse Firebase'e yazılıyor.
      if (_deviceId.isNotEmpty) {
        try {
          await FirebaseDatabase.instance.ref('devices/$_deviceId/serviceStartError')
              .set({'msg': 'onStart: $e', 'ts': ServerValue.timestamp});
        } catch (_) {}
      }
    }
  }

  // Arka planda GPS'i sürekli açık tutmak (stream) en çok pil tüketen ve
  // OEM'lerin (Honor/Huawei/Xiaomi vb.) arka plan servisini agresif şekilde
  // öldürmesine en çok sebep olan davranış. Bunun yerine ilk konumu hemen
  // alıp sonrasında sadece 5 dakikada bir tek seferlik ölçüm yapıyoruz —
  // pil tüketimi çok daha düşük, servisin hayatta kalma ihtimali daha
  // yüksek. Bedeli: arka planda alarm hassasiyeti artık ~5dk'lık bir
  // aralığa bağlı (uygulama ekranı açıkken bu geçerli değil, oradaki canlı
  // harita akışı ayrı ve sürekli).
  static const _locationPollTicks = 60; // 60 * 5sn = 5 dakika
  static const _batteryReportTicks = 120; // 120 * 5sn = 10 dakika

  Future<void> _pollLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );
      _myLat = pos.latitude;
      _myLon = pos.longitude;
      await LocationService.writeLocation(_deviceId, pos.latitude, pos.longitude);
      FlutterForegroundTask.updateService(
        notificationTitle: 'UZAKDUR aktif',
        notificationText: 'GPS alınıyor…',
      );
    } catch (_) {}
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    if (_deviceId.isEmpty) return;
    // "Çevrimiçi" durumu monitor_screen'in KENDİ 5sn'lik zamanlayıcısından da
    // beslenebiliyor (uygulama ekranı açıkken) — bu da arka plan servisinin
    // gerçekten çalıştığını KANITLAMIYOR, sadece ekranın açık olduğunu
    // gösteriyor olabilir. Admin panelin ikisini ayırt edebilmesi için SADECE
    // bu isolate'ten (yani servis gerçekten tick attığında) yazılan ayrı bir
    // zaman damgası.
    try {
      await FirebaseDatabase.instance.ref('devices/$_deviceId/serviceTick').set(ServerValue.timestamp);
      // Buraya kadar geldiysek servis gerçekten tıklıyor demektir — daha
      // önce yazılmış olabilecek eski bir serviceStartError artık geçersiz,
      // admin panelde asılı kalmasın diye bir kereliğine temizleniyor.
      if (!_startErrorCleared) {
        _startErrorCleared = true;
        FirebaseDatabase.instance.ref('devices/$_deviceId/serviceStartError').remove().ignore();
      }
    } catch (_) {}
    await LocationService.heartbeat(_deviceId);
    await _checkAdminMessage();
    await _checkLocationRequest();
    _tick++;
    if (_tick % _locationPollTicks == 0) await _pollLocation();
    if (_tick % _batteryReportTicks == 0) {
      try {
        final level = await _battery.batteryLevel;
        await LocationService.writeBattery(_deviceId, level);
        final roleSnap = await FirebaseDatabase.instance.ref('devices/$_deviceId/role').get();
        await _checkBatteryWarning(level, isTracked: roleSnap.value == 'tracked');
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

      double? alarmDistance;
      String? alarmSoundId;
      bool anyAlarm = false;
      ZoneData? breachedZoneOverall;
      String? breachedZonePairId;
      // Üç kademeli sistem: sınırın (pair.threshold) %50'sinin altı ACİL (tam
      // alarm), %50-%80 arası KRİTİK, %80-%100 arası SINIR (yeni girildi).
      // Birden fazla eşleşme varsa en kötü (en yakın) kademe esas alınır.
      String worstTier = 'safe';
      String? worstTierPairId;
      double? worstTierDistance;
      // Rota (güzergah) bölgeleri sadece kademeli kritik/sınır uyarısı verir,
      // asla tam alarm tetiklemez. Her iki taraf da değerlendirilir.
      String worstRouteTier = 'safe';
      String? worstRouteLabel;
      double? worstRouteDistance;
      String? worstRoutePairId;
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

        final otherId = pair.otherDeviceId(_deviceId);
        final locSnap = await FirebaseDatabase.instance.ref('locations/$otherId').get();
        double? d;
        LocationData? other;
        if (locSnap.exists && locSnap.value != null) {
          try { other = LocationData.fromMap(locSnap.value as Map); } catch (_) {}
        }
        if (other != null) {
          d = LocationService.calculateDistance(_myLat!, _myLon!, other.lat, other.lon);
        }

        // Yasak bölgeler (daire, korunan cihaza bağlı — eşleşme silinip
        // yeniden kurulunca kaybolmasın diye) hem tam alarm (uzaklaştırılan
        // için) hem rota (güzergah, her iki taraf için) kontrolünde kullanılır.
        final zonesSnap = await FirebaseDatabase.instance.ref('devices/${pair.protectedDeviceId}/zones').get();
        final zonesMap = zonesSnap.value as Map?;
        final pairZones = <ZoneData>[];
        if (zonesMap != null) {
          zonesMap.forEach((zid, zval) {
            try { pairZones.add(ZoneData.fromMap(zid as String, zval as Map)); } catch (_) {}
          });
        }
        zonesSeen.addAll(pairZones);

        // Rota yakınlığı: uzaklaştırılan kendi konumuna göre, korunan ise
        // uzaklaştırılanın (otherId) konumuna göre değerlendirilir.
        final routeSubjectLat = role == 'protected' ? other?.lat : _myLat;
        final routeSubjectLon = role == 'protected' ? other?.lon : _myLon;

        ZoneData? breachedZone;
        for (final z in pairZones) {
          if (z.type == 'route') {
            if (z.threshold <= 0 || routeSubjectLat == null || routeSubjectLon == null) continue;
            final zd = z.distanceFrom(routeSubjectLat, routeSubjectLon);
            final ratio = zd / z.threshold;
            String rTier = 'safe';
            if (ratio <= kKritikRatio) rTier = 'kritik';
            else if (ratio <= 1.0) rTier = 'sinir';
            if (rTier == 'kritik' && worstRouteTier != 'kritik') {
              worstRouteTier = 'kritik'; worstRouteLabel = z.label; worstRouteDistance = zd; worstRoutePairId = pairId;
            }
            if (rTier == 'sinir' && worstRouteTier == 'safe') {
              worstRouteTier = 'sinir'; worstRouteLabel = z.label; worstRouteDistance = zd; worstRoutePairId = pairId;
            }
            continue;
          }
          if (role == 'tracked' && _myLat != null && _myLon != null) {
            final zd = z.distanceFrom(_myLat!, _myLon!);
            if (zd < z.threshold) { breachedZone = z; break; }
          }
        }
        if (breachedZone != null && breachedZoneOverall == null) {
          breachedZoneOverall = breachedZone;
          breachedZonePairId = pairId;
        }

        bool proximityAlarm = false;
        String tier = 'safe'; // 'safe' | 'sinir' | 'kritik'
        if (d != null && pair.threshold > 0) {
          // Tam kontrol seyreltme sıklığı sınıra (pair.threshold) olan
          // yakınlığa göre belirlenir — sabit bir mesafe yok, tamamen orana
          // dayalı.
          final ratio = d / pair.threshold;
          if (minRatio == null || ratio < minRatio) minRatio = ratio;
          proximityAlarm = ratio <= kAcilRatio;
          if (!proximityAlarm) {
            if (ratio <= kKritikRatio) tier = 'kritik';
            else if (ratio <= 1.0) tier = 'sinir';
          }
        }
        if (tier == 'kritik' && worstTier != 'kritik') { worstTier = 'kritik'; worstTierPairId = pairId; worstTierDistance = d; }
        if (tier == 'sinir' && worstTier == 'safe') { worstTier = 'sinir'; worstTierPairId = pairId; worstTierDistance = d; }

        if (proximityAlarm) {
          anyAlarm = true;
          alarmDistance ??= d;
          alarmSoundId ??= pair.alarmSound;
          await LocationService.writeAlarmLog(pairId, _deviceId, d ?? 0);
        }
      }
      _lastMinRatio = minRatio;
      _cachedZones = zonesSeen;
      _updateZoneRatioFromCache();

      sendPort?.send({'type': 'distance', 'value': alarmDistance});

      // Yasak bölgeye YENİ girildiğinde (tam alarm DEĞİL) bir kez
      // bildirim+titreşim; aynı bölgede kalırken tekrar etmez.
      if (breachedZoneOverall != null && breachedZoneOverall.id != _lastBreachedZoneId) {
        await NotificationService.showZoneEnteredNotice(breachedZoneOverall.label);
        if (breachedZonePairId != null) {
          await LocationService.writeAlarmLog(breachedZonePairId, _deviceId, 0, type: 'zone', zoneLabel: breachedZoneOverall.label);
        }
      }
      _lastBreachedZoneId = breachedZoneOverall?.id;

      final nowDt = DateTime.now();
      // "Alarmı Durdur" butonuna basıldığında tehlike hâlâ sürüyorsa
      // kademeli olarak (30sn/60sn/120sn) geri gelir (bkz. onButtonPressed).
      final snoozed = anyAlarm && _alarmSnoozedUntil != null && nowDt.isBefore(_alarmSnoozedUntil!);
      final showAlarm = anyAlarm && !snoozed;
      if (!anyAlarm) { _alarmStopCount = 0; _alarmSnoozedUntil = null; }

      if (anyAlarm) {
        if (showAlarm) {
          if (!_alarming) {
            _alarming = true;
            await NotificationService.startAlarm(alarmDistance ?? 0, soundId: alarmSoundId ?? 'siren');
          }
          FlutterForegroundTask.updateService(
            notificationTitle: '⚠️ YAKLAŞMA — ${alarmDistance?.round()}m',
            notificationText: 'Aktif alarm',
          );
        } else {
          if (_alarming) { _alarming = false; await NotificationService.stopAlarm(); }
          FlutterForegroundTask.updateService(
            notificationTitle: '⏸ Uyarı Ertelendi',
            notificationText: 'Tehlike sürüyor, tekrar kontrol ediliyor…',
          );
        }
        _lastTier = 'safe';
        _lastRouteTier = 'safe';
        _lastRouteRepeatAt = null;
      } else {
        if (_alarming) { _alarming = false; await NotificationService.stopAlarm(); }
        // Sadece kademe KÖTÜLEŞTİĞİNDE bildirim/titreşim tetiklenir, aynı
        // kademede kalırken her tam kontrolde tekrar bildirim gösterilmez.
        // Bu erken uyarılar sadece uzaklaştırılan tarafa gösterilir.
        if (role == 'tracked' && worstTier != _lastTier && worstTier != 'safe') {
          if (worstTier == 'kritik') {
            await NotificationService.showApproachWarning();
          } else {
            await NotificationService.showBoundaryEnteredNotice();
          }
          if (worstTierPairId != null) {
            await LocationService.writeAlarmLog(worstTierPairId, _deviceId, worstTierDistance ?? 0, type: worstTier);
          }
        }
        _lastTier = worstTier;

        // Rota: 'kritik' (yaklaşıyor) sadece kademe kötüleştiğinde bir kez;
        // 'sinir' (güzergahın içinde) girişte bir kez VE çıkana kadar
        // 30sn'de bir tekrarlanır — hem korunan hem uzaklaştırılan için.
        if (worstRouteTier != 'safe') {
          final isNewTier = worstRouteTier != _lastRouteTier;
          final dueForRepeat = worstRouteTier == 'sinir' && _lastRouteTier == 'sinir' &&
              _lastRouteRepeatAt != null && nowDt.difference(_lastRouteRepeatAt!) >= const Duration(seconds: 30);
          if (isNewTier || dueForRepeat) {
            if (worstRouteTier == 'kritik') {
              await NotificationService.showRouteApproachNotice(worstRouteLabel ?? 'Yol', isProtectedSide: role == 'protected');
            } else {
              await NotificationService.showRouteInsideNotice(worstRouteLabel ?? 'Yol', isProtectedSide: role == 'protected');
              _lastRouteRepeatAt = nowDt;
            }
            if (worstRoutePairId != null) {
              await LocationService.writeAlarmLog(worstRoutePairId, _deviceId, worstRouteDistance ?? 0,
                  type: worstRouteTier, zoneLabel: worstRouteLabel);
            }
          }
        } else {
          _lastRouteRepeatAt = null;
        }
        _lastRouteTier = worstRouteTier;

        FlutterForegroundTask.updateService(
          notificationTitle: alarmDistance != null ? 'UZAKDUR — Güvenli (${alarmDistance.round()}m)' : 'UZAKDUR — İzleniyor',
          notificationText: 'İzleniyor',
        );
      }
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    await LocationService.setOnline(_deviceId, false);
    await NotificationService.stopAlarm();
  }

  @override
  // Uygulama içindeki "ALARMI DURDUR" ile aynı kademeli erteleme mantığı
  // (30sn/60sn/120sn) — ama burada arka plan isolate'i bir dialog
  // gösteremediği için "iyi misin" onayı bu yoldan sorulamıyor; 3. kezden
  // sonra sadece 120sn'de bir ertelemeye devam eder. Uygulama açıldığında
  // ön plandaki mantık devralır.
  void onButtonPressed(String id) {
    if (id != 'stop_alarm') return;
    _alarmStopCount++;
    final seconds = _alarmStopCount == 1 ? 30 : _alarmStopCount == 2 ? 60 : 120;
    _alarmSnoozedUntil = DateTime.now().add(Duration(seconds: seconds));
    NotificationService.stopAlarm();
  }
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

  // Servisin BAŞLATILMASI kendisi başarısız olabilir (ör. Android 14'te
  // foreground service type izni eksikse, OEM bir kısıtlama uygularsa, ya
  // da eklenti bir istisna fırlatırsa) — önceden bu, çağıran taraflarda
  // sessizce yutuluyordu (fire-and-forget ya da boş catch), bu yüzden
  // "servis hiç tick atmıyor" teşhisi konsa da GERÇEK sebep hiçbir zaman
  // görünmüyordu. Artık gerçek istisna Firebase'e yazılıp admin panelde
  // görünür — "başlatılamadı" ile "başladı ama sonra öldürüldü" birbirinden
  // ayırt edilebiliyor.
  static Future<void> start({required String deviceId}) async {
    try {
      await FlutterForegroundTask.saveData(key: 'deviceId', value: deviceId);
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          notificationTitle: 'UZAKDUR Başlatıldı', notificationText: 'İzleme aktif', callback: startCallback,
        );
      }
      await FirebaseDatabase.instance.ref('devices/$deviceId/serviceStartError').remove();
    } catch (e) {
      try {
        await FirebaseDatabase.instance.ref('devices/$deviceId/serviceStartError')
            .set({'msg': e.toString(), 'ts': ServerValue.timestamp});
      } catch (_) {}
    }
  }

  static Future<void> stop() => FlutterForegroundTask.stopService();
}
