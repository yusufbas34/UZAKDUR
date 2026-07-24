import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/roles.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../services/foreground_task_service.dart';
import '../services/disguise_service.dart';
import '../services/update_service.dart';
import '../services/watchdog_service.dart';
import '../services/device_admin_service.dart';
import '../theme/app_theme.dart';

class LogEntry {
  final String time;
  final double distance;
  final bool isAlarm;
  LogEntry(this.time, this.distance, this.isAlarm);
}

class MonitorScreen extends StatefulWidget {
  final String deviceId;
  final String name;
  final String role;
  const MonitorScreen({super.key, required this.deviceId, required this.name, required this.role});
  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // Bir cihaz aynı anda birden fazla eşleşmede yer alabilir (ör. 1 korunan
  // – 2..4 uzaklaştırılan). Her eşleşme pairId'siyle ayrı takip edilir;
  // harita/ayarlar ekranı ise her an "odaklanılan" tek bir eşleşmeyi gösterir.
  Map<String, PairData> _pairs = {};
  Map<String, LocationData> _otherLocByPair = {};
  Map<String, bool> _otherOnlineByPair = {};
  Map<String, String> _otherNameByPair = {};
  // Yasak bölgeler korunan cihaza bağlıdır (bkz. LocationService), ama bir
  // uzaklaştırılan farklı korunan kişilerle eşleşebildiği için her eşleşme
  // kendi protectedDeviceId'sinden bölgelerini ayrıca dinler.
  Map<String, List<ZoneData>> _zonesByPair = {};
  Map<String, String> _pairStatus = {}; // pairId -> 'acil' | 'kritik' | 'sinir' | 'safe' | 'unknown'
  final Map<String, StreamSubscription> _otherLocSubs = {};
  final Map<String, StreamSubscription> _otherOnlineSubs = {};
  final Map<String, StreamSubscription> _otherNameSubs = {};
  final Map<String, StreamSubscription> _zonesSubs = {};
  // Acil durum kişileri ise doğrudan korunan kişinin kendi cihazına bağlıdır
  // (hangi uzaklaştırılanla eşleşmiş olursa olsun aynıdır), bu yüzden pair
  // başına değil, sadece korunan rolüyse tek bir dinleyici yeterli.
  List<EmergencyContact> _myContacts = [];
  StreamSubscription? _myContactsSub;
  StreamSubscription? _pairsSub;
  String? _focusedPairId;
  String? _lastAlarmPairId;
  bool _fgStarted = false;

  PairData? get _pair => _focusedPairId != null ? _pairs[_focusedPairId] : null;
  LocationData? get _otherLocation => _focusedPairId != null ? _otherLocByPair[_focusedPairId] : null;
  bool get _otherOnline => _focusedPairId != null ? (_otherOnlineByPair[_focusedPairId] ?? false) : false;
  String? get _otherName => _focusedPairId != null ? _otherNameByPair[_focusedPairId] : null;

  LocationData? _myLocation;
  double? _distance;
  bool _isAlarm = false, _isRunning = false;
  String _lastTier = 'safe'; // 'safe' | 'sinir' | 'kritik' — bir önceki tick'teki en kötü kademe (acil hariç)
  String _lastRouteTier = 'safe'; // aynı, ama rota (güzergah) bölgeleri için — asla 'acil' olmaz
  String _statusText = 'GPS bekleniyor…';
  String? _alarmZoneLabel;
  String? _errorText;
  bool _panicSending = false;
  bool _disguised = false;
  UpdateInfo? _updateInfo;
  bool _notifDenied = false;
  // null: henüz kontrol edilmedi (banner o ana kadar gösterilmez, aksi
  // halde her açılışta bir an için yanlışlıkla "kapalı" görünürdü).
  bool? _adminProtectionActive;
  bool? _batteryOptOn; // true: OS hâlâ pil kısıtlaması uyguluyor (kötü)
  int _bottomTab = 0;
  // null: izinler henüz kontrol edilmedi (kısa bir yükleniyor ekranı
  // gösterilir). true: kurulum kontrolü tam ekran gösteriliyor.
  bool? _showGate;
  final List<LogEntry> _log = [];
  final _fmt = DateFormat('HH:mm:ss');
  final _battery = Battery();

  StreamSubscription<Position>? _posSub;
  Timer? _pollTimer, _batteryTimer;

  late AnimationController _alarmCtrl;
  late Animation<double> _alarmAnim;

  GoogleMapController? _mapCtrl;
  Set<Marker> _markers = {};
  Set<Circle> _circles = {};
  Set<Polyline> _polylines = {};
  bool _mapReady = false, _mapFollowsMe = true;

  bool get _isProtected => widget.role == kRoleProtected;

  static const _darkMapStyle = '''[
    {"elementType":"geometry","stylers":[{"color":"#1a1a2e"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#8888aa"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#1a1a2e"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2a2a3e"}]},
    {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#6666aa"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0d0d1a"}]},
    {"featureType":"poi","stylers":[{"visibility":"off"}]},
    {"featureType":"transit","stylers":[{"visibility":"off"}]}
  ]''';

  static const _panicKeysChannel = MethodChannel('uzakdur/panic_keys');

  @override
  void initState() {
    super.initState();
    _alarmCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _alarmAnim = CurvedAnimation(parent: _alarmCtrl, curve: Curves.easeInOut);
    WidgetsBinding.instance.addObserver(this);
    ForegroundTaskService.init();
    _initHealthGate();
    _start();
    if (_isProtected) {
      _loadDisguiseState();
      // Ses tuşuna arka arkaya 3 kez basmak da (uygulama ön plandayken)
      // sessiz panik tetikler — uzun basışa alternatif, daha hızlı bir yol.
      _panicKeysChannel.setMethodCallHandler((call) async {
        if (call.method == 'triplePress') _triggerPanic();
        return null;
      });
    }
  }

  // Bildirim izni sistemin ilk açılış diyaloğuyla reddedilirse (ya da
  // kullanıcı fark etmeden kapatırsa) plugin bunu bir daha soramaz — Android
  // bunu yalnızca Ayarlar üzerinden değiştirmeye izin verir. Bu yüzden
  // durumu uygulama içinde görünür kılıp doğrudan ayar sayfasını açan bir
  // yol sunuyoruz; aksi halde mesaj/pil/alarm bildirimleri hiç görünmez ve
  // kullanıcının bunu fark etmesinin hiçbir yolu olmaz.
  Future<void> _checkNotifPermission() async {
    final status = await Permission.notification.status;
    if (!mounted) return;
    setState(() => _notifDenied = !status.isGranted);
  }

  Future<void> _checkDeviceAdmin() async {
    final active = await DeviceAdminService.isActive();
    if (!mounted) return;
    setState(() => _adminProtectionActive = active);
  }

  // Pil kısıtlaması hem korunan hem uzaklaştırılan tarafta arka plan
  // servisini etkiliyor — bu yüzden role bakılmaksızın kontrol ediliyor.
  Future<void> _checkBatteryOpt() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (!mounted) return;
    setState(() => _batteryOptOn = !status.isGranted);
  }

  // Dağınık banner'lar kullanıcının bir tanesini atlayıp fark etmeden
  // devam etmesine izin veriyordu — bu oturumdaki neredeyse tüm sorunların
  // kökü buydu. İlk kurulumda (ya da hâlâ çözülmemiş bir sorun varsa) tüm
  // izinleri tek bir tam ekran kontrolde, sırayla, ✓/✗ ile gösterip devam
  // etmeden önce görülmesini zorunlu kılıyoruz.
  Future<void> _initHealthGate() async {
    final checks = <Future>[_checkNotifPermission(), _checkBatteryOpt()];
    if (!_isProtected) checks.add(_checkDeviceAdmin());
    await Future.wait(checks);
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('setup_gate_done') ?? false;
    setState(() => _showGate = !done || _permIssueCount > 0);
  }

  Future<void> _dismissGate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_gate_done', true);
    if (!mounted) return;
    setState(() => _showGate = false);
  }

  Future<void> _onGateContinueTap() async {
    if (_permIssueCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Emin misin?', style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          content: Text(
            'Bu izinler açık olmadan mesaj, alarm ya da konum takibi güvenilir çalışmayabilir. Yine de devam etmek istiyor musun?',
            style: GoogleFonts.inter(color: AppColors.textSecondary, height: 1.4),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Geri Dön', style: GoogleFonts.inter(color: AppColors.textMuted))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Yine de Devam Et', style: GoogleFonts.inter(color: AppColors.danger, fontWeight: FontWeight.w700))),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _dismissGate();
  }

  Future<void> _loadDisguiseState() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _disguised = p.getBool('app_disguised') ?? false);
  }

  Future<void> _toggleDisguise() async {
    final next = !_disguised;
    if (next) {
      await DisguiseService.apply();
    } else {
      await DisguiseService.remove();
    }
    final p = await SharedPreferences.getInstance();
    await p.setBool('app_disguised', next);
    if (!mounted) return;
    setState(() => _disguised = next);
  }

  // Android'in standart pil optimizasyonu izni bazı üreticilerde (Xiaomi/MIUI,
  // Huawei, Oppo/Realme, Vivo vb.) yeterli olmuyor; bu üreticiler uygulamayı
  // arka planda tamamen öldürebiliyor. Bunun tek gerçek düzeltmesi kullanıcının
  // kendi telefon ayarlarından "Otomatik Başlatma" ve "Pil kısıtlaması yok"
  // seçeneklerini elle açması — hiçbir genel Android API'si bunu programatik
  // olarak açtırtamıyor. Bu yüzden bir kez bilgilendirme gösteriyoruz.
  Future<void> _maybeShowBatteryDialog() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('battery_dialog_shown') ?? false) return;
    await p.setBool('battery_dialog_shown', true);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Arka Planda Çalışma', style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        content: Text(
          'Bazı telefonlarda (Xiaomi/MIUI, Huawei, Oppo, Vivo gibi) Android\'in pil izni yeterli olmuyor ve uygulama kapatıldığında/arka plana atıldığında sistem konum takibini durdurabiliyor.\n\n'
          'Kesintisiz çalışması için telefonunun Ayarlar > Pil > Uygulama pil kullanımı bölümünden UZAKDUR için "Kısıtlama Yok" seç ve varsa "Otomatik Başlatma" iznini aç.',
          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Tamam', style: GoogleFonts.inter(color: AppColors.textMuted))),
          TextButton(onPressed: () { Navigator.pop(ctx); openAppSettings(); }, child: Text('Ayarları Aç', style: GoogleFonts.inter(color: AppColors.danger, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  Future<void> _start() async {
    setState(() { _errorText = null; _statusText = 'Konum izni kontrol ediliyor…'; });
    final result = await LocationService.requestPermissions();
    if (!mounted) return;
    switch (result) {
      case LocationPermissionResult.serviceDisabled: _setError('GPS kapalı. Lütfen konumu etkinleştir.'); return;
      case LocationPermissionResult.denied: _setError('Konum izni reddedildi.'); return;
      case LocationPermissionResult.deniedForever: _setError('Konum izni kalıcı reddedildi. Ayarlardan aç.'); return;
      case LocationPermissionResult.granted: break;
    }
    setState(() { _isRunning = true; _statusText = 'Konum alınıyor…'; });
    await LocationService.setOnline(widget.deviceId, true);
    _reportBattery();
    _batteryTimer = Timer.periodic(const Duration(seconds: 60), (_) => _reportBattery());
    _maybeShowBatteryDialog();
    _checkForUpdate();
    WatchdogService.register().ignore();

    if (_isProtected) {
      _myContactsSub = LocationService.listenDeviceContacts(widget.deviceId, (contacts) {
        if (!mounted) return;
        setState(() => _myContacts = contacts);
      });
    }

    _pairsSub = LocationService.listenPairsForDevice(widget.deviceId, _handlePairsUpdate);

    _posSub = LocationService.startLocationStream().listen((pos) async {
      final loc = LocationData(lat: pos.latitude, lon: pos.longitude, timestamp: DateTime.now());
      if (!mounted) return;
      setState(() => _myLocation = loc);
      await LocationService.writeLocation(widget.deviceId, pos.latitude, pos.longitude);
      _updateMap();
      _checkDistance();
    }, onError: (e) => _setError('GPS hatası: $e'));

    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      LocationService.heartbeat(widget.deviceId);
      _checkDistance();
    });
  }

  Future<void> _reportBattery() async {
    try {
      final level = await _battery.batteryLevel;
      await LocationService.writeBattery(widget.deviceId, level);
    } catch (_) {}
  }

  Future<void> _checkForUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (!mounted || info == null) return;
    setState(() => _updateInfo = info);
  }

  void _handlePairsUpdate(Map<String, PairData> newPairs) {
    final oldIds = _pairs.keys.toSet();
    final newIds = newPairs.keys.toSet();

    for (final removedId in oldIds.difference(newIds)) {
      _otherLocSubs.remove(removedId)?.cancel();
      _otherOnlineSubs.remove(removedId)?.cancel();
      _otherNameSubs.remove(removedId)?.cancel();
      _zonesSubs.remove(removedId)?.cancel();
      _otherLocByPair.remove(removedId);
      _otherOnlineByPair.remove(removedId);
      _otherNameByPair.remove(removedId);
      _zonesByPair.remove(removedId);
      _pairStatus.remove(removedId);
    }

    for (final addedId in newIds.difference(oldIds)) {
      final pair = newPairs[addedId]!;
      final otherId = pair.otherDeviceId(widget.deviceId);
      _otherLocSubs[addedId] = LocationService.listenOtherLocation(otherId, (loc) {
        if (!mounted) return;
        setState(() => _otherLocByPair[addedId] = loc);
        _checkDistance();
        _updateMap();
      });
      _otherOnlineSubs[addedId] = LocationService.listenOtherOnline(otherId, (online) {
        if (!mounted) return;
        setState(() => _otherOnlineByPair[addedId] = online);
      });
      _otherNameSubs[addedId] = LocationService.listenDevice(otherId, (data) {
        if (!mounted) return;
        setState(() => _otherNameByPair[addedId] = (data?['name'] as String?) ?? 'Cihaz');
      });
      _zonesSubs[addedId] = LocationService.listenDeviceZones(pair.protectedDeviceId, (zones) {
        if (!mounted) return;
        setState(() => _zonesByPair[addedId] = zones);
        _checkDistance();
        _updateMap();
      });
    }

    if (!mounted) return;
    setState(() {
      _pairs = newPairs;
      if (_focusedPairId == null || !_pairs.containsKey(_focusedPairId)) {
        _focusedPairId = _pairs.keys.isNotEmpty ? _pairs.keys.first : null;
      }
    });

    if (_pairs.isNotEmpty && !_fgStarted) {
      _fgStarted = true;
      ForegroundTaskService.start(deviceId: widget.deviceId).ignore();
    } else if (_pairs.isEmpty && _fgStarted) {
      _fgStarted = false;
      ForegroundTaskService.stop().ignore();
    }

    _checkDistance();
    _updateMap();
  }

  void _checkDistance() {
    if (_pairs.isEmpty) {
      _pairStatus = {};
      if (_isAlarm || _alarmCtrl.isAnimating) {
        _alarmCtrl.stop(); _alarmCtrl.reset();
        NotificationService.stopAlarm();
      }
      _lastTier = 'safe';
      _lastRouteTier = 'safe';
      if (!mounted) return;
      setState(() {
        _isAlarm = false;
        _alarmZoneLabel = null;
        _distance = null;
        _statusText = 'Eşleştirme yok';
      });
      _updateMap();
      return;
    }
    String? alarmPairId;
    ZoneData? alarmZone;
    double? alarmDistance;
    String? alarmSoundId;
    // Üç kademeli sistem: sınırın (pair.threshold) %50'sinin altı ACİL (tam
    // alarm), %50-%80 arası KRİTİK, %80-%100 arası SINIR (yeni girildi).
    // Birden fazla eşleşme varsa en kötü (en yakın) kademe esas alınır.
    String worstTier = 'safe';
    String? worstTierPairId;
    double? worstTierDistance;
    // Rota (güzergah) bölgeleri sadece kademeli kritik/sınır uyarısı verir,
    // asla tam alarm tetiklemez — konum zaten açık olduğu için gerçekten
    // yaklaşılırsa normal eşik sistemi zaten devreye girer.
    String worstRouteTier = 'safe';
    String? worstRouteLabel;
    double? worstRouteDistance;
    String? worstRoutePairId;
    final newStatus = <String, String>{};

    for (final entry in _pairs.entries) {
      final pid = entry.key;
      final pair = entry.value;
      final otherLoc = _otherLocByPair[pid];

      ZoneData? zone;
      if (!_isProtected && _myLocation != null) {
        for (final z in (_zonesByPair[pid] ?? const <ZoneData>[])) {
          final zd = z.distanceFrom(_myLocation!.lat, _myLocation!.lon);
          if (z.type == 'route') {
            if (z.threshold <= 0) continue;
            final ratio = zd / z.threshold;
            String rTier = 'safe';
            if (ratio <= kKritikRatio) rTier = 'kritik';
            else if (ratio <= 1.0) rTier = 'sinir';
            if (rTier == 'kritik' && worstRouteTier != 'kritik') {
              worstRouteTier = 'kritik'; worstRouteLabel = z.label; worstRouteDistance = zd; worstRoutePairId = pid;
            }
            if (rTier == 'sinir' && worstRouteTier == 'safe') {
              worstRouteTier = 'sinir'; worstRouteLabel = z.label; worstRouteDistance = zd; worstRoutePairId = pid;
            }
            continue; // rota bölgeleri bu döngüde tam alarm adayı olamaz
          }
          if (zd < z.threshold) { zone = z; break; }
        }
      }

      double? d;
      bool proximityAlarm = false;
      String tier = 'safe'; // 'safe' | 'sinir' | 'kritik'
      if (_myLocation != null && otherLoc != null && pair.threshold > 0) {
        d = LocationService.calculateDistance(_myLocation!.lat, _myLocation!.lon, otherLoc.lat, otherLoc.lon);
        final ratio = d / pair.threshold;
        proximityAlarm = ratio <= kAcilRatio;
        if (!proximityAlarm) {
          if (ratio <= kKritikRatio) tier = 'kritik';
          else if (ratio <= 1.0) tier = 'sinir';
        }
      }
      if (tier == 'kritik' && worstTier != 'kritik') { worstTier = 'kritik'; worstTierPairId = pid; worstTierDistance = d; }
      if (tier == 'sinir' && worstTier == 'safe') { worstTier = 'sinir'; worstTierPairId = pid; worstTierDistance = d; }

      final isAlarm = proximityAlarm || zone != null;
      newStatus[pid] = isAlarm ? 'acil' : (tier != 'safe' ? tier : (d != null ? 'safe' : 'unknown'));

      if (isAlarm) {
        if (zone != null) {
          LocationService.writeAlarmLog(pid, widget.deviceId, 0, type: 'zone', zoneLabel: zone.label);
        } else if (d != null) {
          LocationService.writeAlarmLog(pid, widget.deviceId, d);
        }
        alarmPairId ??= pid;
        alarmZone ??= zone;
        alarmDistance ??= d;
        alarmSoundId ??= pair.alarmSound;
      }
    }

    final isAlarm = alarmPairId != null;
    final now = _fmt.format(DateTime.now());
    if (!mounted) return;
    setState(() {
      _pairStatus = newStatus;
      // Odağı sadece YENİ bir alarm başladığında (önceki tick'te alarmda
      // olan eşleşmeden farklıysa) değiştiriyoruz — aksi halde aynı
      // eşleşme dakikalarca alarmda kalırken kullanıcı başka bir
      // partnere manuel dokunduğunda odak sürekli geri sıçrıyordu. Genel
      // alarm göstergeleri (ses/animasyon/durdur çubuğu) zaten odaktan
      // bağımsız olarak çalışmaya devam ediyor, güvenlik kaybı yok.
      if (isAlarm && alarmPairId != _lastAlarmPairId) {
        _focusedPairId = alarmPairId;
      }
      _lastAlarmPairId = isAlarm ? alarmPairId : null;
      final focusedOtherLoc = _otherLocation;
      _distance = (_myLocation != null && focusedOtherLoc != null)
          ? LocationService.calculateDistance(_myLocation!.lat, _myLocation!.lon, focusedOtherLoc.lat, focusedOtherLoc.lon)
          : null;
      _isAlarm = isAlarm;
      _alarmZoneLabel = isAlarm ? alarmZone?.label : null;
      _statusText = isAlarm
          ? (alarmZone != null ? 'Yasak bölgede: ${alarmZone.label}' : 'Yaklaşma tespit edildi!')
          : worstTier == 'kritik'
              ? 'Kritik — Hızla yaklaşıyor'
              : worstTier == 'sinir'
                  ? 'Sınır içine girildi'
                  : 'Güvenli mesafede';
      if (_distance != null && (_log.isEmpty || _log.first.isAlarm != isAlarm)) {
        _log.insert(0, LogEntry(now, _distance!, isAlarm));
        if (_log.length > 100) _log.removeLast();
      }
    });

    if (isAlarm) {
      if (!_alarmCtrl.isAnimating) _alarmCtrl.repeat(reverse: true);
      NotificationService.startAlarm(alarmDistance ?? 0, soundId: alarmSoundId ?? 'siren');
      _lastTier = 'safe';
      _lastRouteTier = 'safe';
    } else {
      _alarmCtrl.stop(); _alarmCtrl.reset();
      NotificationService.stopAlarm();
      // Sadece kademe KÖTÜLEŞTİĞİNDE (daha önce görülenden daha ciddi bir
      // kademeye yeni girildiğinde) bildirim/titreşim tetiklenir — aksi
      // halde aynı kademede kalınırken her 5sn'de bir tekrar bildirim
      // gösterilirdi.
      if (worstTier != _lastTier && worstTier != 'safe') {
        HapticFeedback.mediumImpact();
        // Bu erken uyarılar sadece uzaklaştırılan tarafa gösterilir — metni
        // ("...yaklaşmaktasınız...") doğrudan ona hitap ediyor, korunan
        // tarafta anlamsız olurdu.
        if (!_isProtected) {
          if (worstTier == 'kritik') {
            NotificationService.showApproachWarning();
          } else {
            NotificationService.showBoundaryEnteredNotice();
          }
          // Kademe geçişleri de kaydedilir ki Canlı Akış'ta görünsün ve
          // yönetici hangi kademelerin acil durum kişilerine mail
          // attıracağını ayrıca seçebilsin (bkz. admin panel e-posta ayarları).
          if (worstTierPairId != null) {
            LocationService.writeAlarmLog(worstTierPairId, widget.deviceId, worstTierDistance ?? 0, type: worstTier);
          }
        }
      }
      _lastTier = worstTier;

      if (!_isProtected && worstRouteTier != _lastRouteTier && worstRouteTier != 'safe') {
        HapticFeedback.selectionClick();
        NotificationService.showRouteProximityNotice(worstRouteLabel ?? 'Yol', critical: worstRouteTier == 'kritik');
        if (worstRoutePairId != null) {
          LocationService.writeAlarmLog(worstRoutePairId, widget.deviceId, worstRouteDistance ?? 0,
              type: worstRouteTier, zoneLabel: worstRouteLabel);
        }
      }
      _lastRouteTier = worstRouteTier;
    }
    _updateMap();
  }

  Future<void> _triggerPanic() async {
    if (_pairs.isEmpty || _panicSending) return;
    setState(() => _panicSending = true);
    HapticFeedback.heavyImpact();
    try {
      final loc = _myLocation;
      final locText = loc != null ? 'https://maps.google.com/?q=${loc.lat},${loc.lon}' : 'konum alınamadı';

      for (final pid in _pairs.keys) {
        await LocationService.writeAlarmLog(pid, widget.deviceId, 0, type: 'panic');
      }

      final familyEmails = <String>{};
      final authorityEmails = <String>{};
      for (final c in _myContacts) {
        final email = c.email?.trim();
        if (email == null || email.isEmpty) continue;
        if (c.type == 'authority') { authorityEmails.add(email); } else { familyEmails.add(email); }
      }

      if (familyEmails.isNotEmpty) {
        final uri = Uri(scheme: 'mailto', path: familyEmails.join(','),
            queryParameters: {'subject': 'ACİL — UZAKDUR Panik', 'body': '${widget.name} panik butonuna bastı.\nKonum: $locText'});
        if (await canLaunchUrl(uri)) await launchUrl(uri);
      }

      if (authorityEmails.isNotEmpty) {
        final uri = Uri(scheme: 'mailto', path: authorityEmails.join(','), queryParameters: {
          'subject': 'ACİL YARDIM TALEBİ — UZAKDUR Panik Bildirimi',
          'body': 'Resmi bildirim: ${widget.name} isimli kişi, UZAKDUR uygulamasındaki acil durum butonuna basmıştır.\n\n'
              'Bildirim zamanı: ${DateTime.now()}\n'
              'Son bilinen konum: $locText\n\n'
              'Lütfen ilgili birimlerle irtibata geçerek yardım talebini değerlendiriniz.',
        });
        if (await canLaunchUrl(uri)) await launchUrl(uri);
      }
      // Bilinçli olarak ekranda görünür bir onay yok: yanında biri varken
      // panik butonunun basıldığının anlaşılmaması için sadece titreşimle bildirilir.
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) setState(() => _panicSending = false);
    }
  }

  void _updateMap() {
    if (!_mapReady || _mapCtrl == null) return;
    final markers = <Marker>{};
    final circles = <Circle>{};
    final polylines = <Polyline>{};
    final threshold = _pair?.threshold ?? 0;
    final acilRadius = threshold * kAcilRatio;
    final kritikRadius = threshold * kKritikRatio;

    if (_myLocation != null) {
      final pos = LatLng(_myLocation!.lat, _myLocation!.lon);
      markers.add(Marker(
        markerId: const MarkerId('me'), position: pos,
        icon: BitmapDescriptor.defaultMarkerWithHue(_isProtected ? BitmapDescriptor.hueAzure : BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: '${widget.name} (Ben)'), zIndex: 2,
      ));
      // Kırmızı çember: ACİL (tam alarm, eşiğin %50'si). Turuncu: KRİTİK
      // (eşiğin %80'i). Mavi: SINIR (eşiğin tamamı) — üç kademe de sınıra
      // (pair.threshold) oranlı, sabit bir mesafe yok.
      if (threshold > 0) {
        circles.add(Circle(
          circleId: const CircleId('acil'), center: pos, radius: acilRadius,
          fillColor: AppColors.danger.withOpacity(0.08),
          strokeColor: AppColors.danger.withOpacity(0.4),
          strokeWidth: 1,
        ));
        circles.add(Circle(
          circleId: const CircleId('kritik'), center: pos, radius: kritikRadius,
          fillColor: AppColors.warning.withOpacity(0.06),
          strokeColor: AppColors.warning.withOpacity(0.35),
          strokeWidth: 1,
        ));
        circles.add(Circle(
          circleId: const CircleId('sinir'), center: pos, radius: threshold,
          fillColor: AppColors.roleB.withOpacity(0.04),
          strokeColor: AppColors.roleB.withOpacity(0.3),
          strokeWidth: 1,
        ));
      }
      if (_mapFollowsMe) _mapCtrl!.animateCamera(CameraUpdate.newLatLng(pos));
    }

    // Uzaklaştırılan taraf, korunan tarafın konumunu haritada göremez —
    // yalnızca mesafe eşiği aşıldığında alarm alır. Bu, admin panelinden
    // eşleşme bazında (trackedCanSeeLocation) istisnai olarak açılabilir.
    final canSeeOtherLoc = _isProtected || (_pair?.trackedCanSeeLocation ?? false);

    if (_otherLocation != null && canSeeOtherLoc) {
      markers.add(Marker(
        markerId: const MarkerId('other'),
        position: LatLng(_otherLocation!.lat, _otherLocation!.lon),
        icon: BitmapDescriptor.defaultMarkerWithHue(_isProtected ? BitmapDescriptor.hueRed : BitmapDescriptor.hueAzure),
        infoWindow: InfoWindow(title: _otherName ?? 'Eşleşilen cihaz'), zIndex: 1,
      ));
    }

    if (_focusedPairId != null) {
      final zones = _zonesByPair[_focusedPairId] ?? const <ZoneData>[];
      for (final z in zones) {
        if (z.type == 'route') {
          if (z.points.length < 2) continue;
          // Rota koridoru sadece kademeli uyarı verdiği için (bkz.
          // _checkDistance) turuncu yerine mavi/uyarı rengiyle, kesikli
          // çizgi olarak gösteriliyor — yasak bölgelerden (tam alarm)
          // görsel olarak ayrışsın diye.
          polylines.add(Polyline(
            polylineId: PolylineId('route_${z.id}'),
            points: z.points.map((p) => LatLng(p.lat, p.lon)).toList(),
            color: AppColors.roleB.withOpacity(0.55),
            width: 5, patterns: [PatternItem.dash(14), PatternItem.gap(8)],
          ));
          final mid = z.points[z.points.length ~/ 2];
          markers.add(Marker(
            markerId: MarkerId('route_${z.id}'), position: LatLng(mid.lat, mid.lon),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
            infoWindow: InfoWindow(title: '🛣️ ${z.label}'), zIndex: 0,
          ));
          continue;
        }
        final center = LatLng(z.lat, z.lon);
        circles.add(Circle(
          circleId: CircleId('zone_${z.id}'), center: center, radius: z.radius,
          fillColor: AppColors.warning.withOpacity(0.1),
          strokeColor: AppColors.warning.withOpacity(0.6), strokeWidth: 1,
        ));
        markers.add(Marker(
          markerId: MarkerId('zone_${z.id}'), position: center,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(title: '🚫 ${z.label}'), zIndex: 0,
        ));
      }
    }

    if (_myLocation != null && _otherLocation != null && canSeeOtherLoc) {
      polylines.add(Polyline(
        polylineId: const PolylineId('line'),
        points: [LatLng(_myLocation!.lat, _myLocation!.lon), LatLng(_otherLocation!.lat, _otherLocation!.lon)],
        color: (_isAlarm ? AppColors.danger : AppColors.safe).withOpacity(0.6),
        width: 2, patterns: [PatternItem.dash(12), PatternItem.gap(6)],
      ));
      if (!_mapFollowsMe) {
        final lats = [_myLocation!.lat, _otherLocation!.lat];
        final lons = [_myLocation!.lon, _otherLocation!.lon];
        _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(lats.reduce((a, b) => a < b ? a : b) - 0.001, lons.reduce((a, b) => a < b ? a : b) - 0.001),
            northeast: LatLng(lats.reduce((a, b) => a > b ? a : b) + 0.001, lons.reduce((a, b) => a > b ? a : b) + 0.001),
          ), 60,
        ));
      }
    }
    if (!mounted) return;
    setState(() { _markers = markers; _circles = circles; _polylines = polylines; });
  }

  Future<void> _stop() async {
    _posSub?.cancel();
    _pairsSub?.cancel();
    _myContactsSub?.cancel();
    for (final s in _otherLocSubs.values) { s.cancel(); }
    for (final s in _otherOnlineSubs.values) { s.cancel(); }
    for (final s in _otherNameSubs.values) { s.cancel(); }
    for (final s in _zonesSubs.values) { s.cancel(); }
    _otherLocSubs.clear(); _otherOnlineSubs.clear(); _otherNameSubs.clear(); _zonesSubs.clear();
    _pollTimer?.cancel(); _batteryTimer?.cancel();
    _alarmCtrl.stop(); _alarmCtrl.reset();
    NotificationService.stopAlarm();
    ForegroundTaskService.stop().ignore();
    _fgStarted = false;
    LocationService.setOnline(widget.deviceId, false).ignore();
    if (!mounted) return;
    setState(() { _isRunning = false; _isAlarm = false; _statusText = 'Durduruldu'; });
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() { _errorText = msg; _isRunning = false; _statusText = 'Hata'; });
  }

  Future<void> _requestDistance() async {
    if (_focusedPairId == null || _pair == null) return;
    final pairId = _focusedPairId!;
    double value = _pair!.threshold;
    final textCtrl = TextEditingController(text: value.round().toString());
    await showModalBottomSheet(
      context: context, backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: 24 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Mesafe Talebi', style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Text('Yöneticiden yeni bir alarm eşiği talep et. Onaylanana kadar mevcut eşik geçerli kalır.',
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.textMuted, height: 1.5)),
          const SizedBox(height: 20),
          TextField(
            controller: textCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
            style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.danger),
            decoration: InputDecoration(
              suffixText: 'metre',
              suffixStyle: GoogleFonts.inter(fontSize: 13, color: AppColors.textMuted),
              filled: true, fillColor: AppColors.bg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.danger.withOpacity(0.6))),
            ),
            onChanged: (t) {
              final parsed = double.tryParse(t.replaceAll(',', '.'));
              if (parsed != null && parsed > 0) setSheet(() => value = parsed);
            },
          ),
          const SizedBox(height: 8),
          Slider(value: value.clamp(20.0, 5000.0), min: 20, max: 5000, divisions: 99,
              activeColor: AppColors.danger, inactiveColor: AppColors.border,
              onChanged: (v) => setSheet(() {
                value = v;
                textCtrl.text = v.round().toString();
                textCtrl.selection = TextSelection.collapsed(offset: textCtrl.text.length);
              })),
          const SizedBox(height: 4),
          Text('Kaydırıcı 20-5000m arası; daha büyük bir değeri kutuya elle yazabilirsin. '
              'Bu sınırın %50\'sinde acil alarm, %80\'inde kritik uyarı, tamamında sınır bildirimi çalar.',
              style: GoogleFonts.inter(fontSize: 11, color: AppColors.textDisabled)),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: GestureDetector(
            onTap: value > 0 ? () async { await LocationService.requestDistanceChange(pairId, value); if (ctx.mounted) Navigator.pop(ctx); } : null,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: Text('Talebi Gönder', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          )),
        ]),
      )),
    );
    textCtrl.dispose();
  }

  Future<void> _pickAlarmSound() async {
    if (_focusedPairId == null || _pair == null) return;
    final pairId = _focusedPairId!;
    await showModalBottomSheet(
      context: context, backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Alarm Sesi', style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 16),
          ...kAlarmSounds.entries.map((e) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(e.key == _pair!.alarmSound ? Icons.check_circle_rounded : Icons.circle_outlined,
                    color: e.key == _pair!.alarmSound ? AppColors.danger : AppColors.textDisabled),
                title: Text(e.value, style: GoogleFonts.inter(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
                onTap: () async { await LocationService.setAlarmSound(pairId, e.key); if (ctx.mounted) Navigator.pop(ctx); },
              )),
        ]),
      ),
    );
  }

  Future<void> _manageContacts() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    String contactType = 'family';
    String? info;
    await showModalBottomSheet(
      context: context, backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: 24 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Acil Durum Kişileri', style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text('Ekleme/çıkarma doğrudan yapılmaz; yönetici onayladıktan sonra listeye yansır.',
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.textMuted, height: 1.5)),
            const SizedBox(height: 16),
            if (_myContacts.isEmpty)
              Text('Henüz kayıtlı acil durum kişisi yok.', style: GoogleFonts.inter(fontSize: 13, color: AppColors.textDisabled))
            else
              ..._myContacts.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Icon(c.type == 'authority' ? Icons.local_police_rounded : Icons.person_rounded, size: 16, color: AppColors.textMuted),
                      const SizedBox(width: 8),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(c.name, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                        Text(c.email ?? c.phone ?? '—', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
                      ])),
                      GestureDetector(
                        onTap: () async {
                          await LocationService.requestRemoveContact(widget.deviceId, c.id, c.name);
                          setSheet(() => info = '"${c.name}" için kaldırma talebi gönderildi.');
                        },
                        child: Text('Kaldır', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger)),
                      ),
                    ]),
                  )),
            const Divider(height: 28),
            Text('Yeni Kişi Ekleme Talebi', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            _sheetField(nameCtrl, 'İsim'),
            const SizedBox(height: 8),
            _sheetField(phoneCtrl, 'Telefon (opsiyonel)'),
            const SizedBox(height: 8),
            _sheetField(emailCtrl, 'E-posta', keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _TypeChip(label: '👤 Yakın', selected: contactType == 'family', onTap: () => setSheet(() => contactType = 'family'))),
              const SizedBox(width: 8),
              Expanded(child: _TypeChip(label: '🚓 Yetkili', selected: contactType == 'authority', onTap: () => setSheet(() => contactType = 'authority'))),
            ]),
            if (info != null) ...[
              const SizedBox(height: 12),
              Text(info!, style: GoogleFonts.inter(fontSize: 12, color: AppColors.safe)),
            ],
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: GestureDetector(
              onTap: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) { setSheet(() => info = 'İsim gerekli.'); return; }
                await LocationService.requestAddContact(widget.deviceId,
                    name: name, phone: phoneCtrl.text.trim(), email: emailCtrl.text.trim(), type: contactType);
                nameCtrl.clear(); phoneCtrl.clear(); emailCtrl.clear();
                setSheet(() => info = 'Ekleme talebi gönderildi.');
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: Text('Talebi Gönder', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            )),
          ]),
        ),
      )),
    );
    nameCtrl.dispose(); phoneCtrl.dispose(); emailCtrl.dispose();
  }

  Widget _sheetField(TextEditingController ctrl, String hint, {TextInputType? keyboardType}) => TextField(
    controller: ctrl,
    keyboardType: keyboardType,
    style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(color: AppColors.textDisabled, fontSize: 13),
      filled: true, fillColor: AppColors.bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppColors.danger.withOpacity(0.6))),
    ),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) _stop();
    if (state == AppLifecycleState.resumed) {
      _checkNotifPermission();
      _checkBatteryOpt();
      _ensureForegroundServiceAlive();
      // Kullanıcı Ayarlar'a gidip izni açıp/kapatıp geri dönmüş olabilir.
      if (!_isProtected) _checkDeviceAdmin();
    }
  }

  // Servis OEM pil yönetimi tarafından öldürülmüşse (Honor/Huawei/Xiaomi vb.
  // "Kısıtlama yok" ayarlanmadıkça sık görülür), _fgStarted bayrağı hâlâ
  // true kalıp bir daha başlatma denemesi yapılmasını engelliyordu. Uygulama
  // her öne geldiğinde gerçek servis durumunu kontrol edip gerekirse zorla
  // yeniden başlatıyoruz — WorkManager bekçisinin ~15dk'lık aralığını
  // beklemek yerine anında toparlanma şansı.
  Future<void> _ensureForegroundServiceAlive() async {
    if (_pairs.isEmpty) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      _fgStarted = true;
      await ForegroundTaskService.start(deviceId: widget.deviceId);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _pairsSub?.cancel();
    _myContactsSub?.cancel();
    for (final s in _otherLocSubs.values) { s.cancel(); }
    for (final s in _otherOnlineSubs.values) { s.cancel(); }
    for (final s in _otherNameSubs.values) { s.cancel(); }
    for (final s in _zonesSubs.values) { s.cancel(); }
    _pollTimer?.cancel(); _batteryTimer?.cancel();
    _alarmCtrl.dispose(); _mapCtrl?.dispose();
    NotificationService.stopAlarm().ignore();
    ForegroundTaskService.stop().ignore();
    LocationService.setOnline(widget.deviceId, false).ignore();
    super.dispose();
  }

  Color get _roleColor => _isProtected ? AppColors.roleB : AppColors.roleA;
  Color get _statusColor {
    if (_isAlarm) return AppColors.danger;
    if (_distance == null || _pair == null || _pair!.threshold <= 0) return AppColors.safe;
    final ratio = _distance! / _pair!.threshold;
    if (ratio <= kKritikRatio) return AppColors.warning;
    if (ratio <= 1.0) return AppColors.roleB;
    return AppColors.safe;
  }

  Color _statusColorFor(String? status) {
    switch (status) {
      case 'acil': return AppColors.danger;
      case 'kritik': return AppColors.warning;
      case 'sinir': return AppColors.roleB;
      case 'safe': return AppColors.safe;
      default: return AppColors.textDisabled;
    }
  }

  int get _permIssueCount =>
      (_notifDenied ? 1 : 0) +
      (_batteryOptOn == true ? 1 : 0) +
      (!_isProtected && _adminProtectionActive == false ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: _showGate == null
            ? const Scaffold(backgroundColor: AppColors.bg, body: Center(child: CircularProgressIndicator(color: AppColors.danger)))
            : _showGate == true
                ? _buildHealthGate()
                : Scaffold(
                    backgroundColor: AppColors.bg,
                    body: AnimatedBuilder(
                      animation: _alarmAnim,
                      builder: (_, child) => ColoredBox(
                        color: _isAlarm ? Color.lerp(AppColors.bg, AppColors.dangerDeep, _alarmAnim.value)! : AppColors.bg,
                        child: child,
                      ),
                      child: SafeArea(child: Column(children: [
                        _buildTopBar(),
                        Expanded(child: _bottomTab == 0 ? _buildMapTab() : _buildPermissionsTab()),
                      ])),
                    ),
                    bottomNavigationBar: _buildBottomNav(),
                  ),
      ),
    );
  }

  Widget _buildHealthGate() => Scaffold(
    backgroundColor: AppColors.bg,
    body: SafeArea(child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.shield_rounded, color: _roleColor, size: 36),
          const SizedBox(height: 12),
          Text('Kurulum Kontrolü', style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Text(
            'UZAKDUR\'un güvenilir çalışması için aşağıdaki izinlerin açık olması gerekiyor. Devam etmeden önce hepsine göz at.',
            style: GoogleFonts.inter(fontSize: 13, color: AppColors.textMuted, height: 1.4),
          ),
        ]),
      ),
      Expanded(child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: _permissionCards(),
      )),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: SizedBox(width: double.infinity, child: GestureDetector(
          onTap: _onGateContinueTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: _permIssueCount > 0 ? AppColors.surface : _roleColor,
              borderRadius: BorderRadius.circular(14),
              border: _permIssueCount > 0 ? Border.all(color: AppColors.border) : null,
            ),
            alignment: Alignment.center,
            child: Text(
              _permIssueCount > 0 ? 'Devam Et ($_permIssueCount eksik izin var)' : 'Devam Et',
              style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: _permIssueCount > 0 ? AppColors.textMuted : Colors.white),
            ),
          ),
        )),
      ),
    ])),
  );

  Widget _buildMapTab() => Column(children: [
    if (_notifDenied) _buildNotifBanner(),
    if (!_isProtected && _adminProtectionActive == false) _buildAdminBanner(),
    if (_updateInfo != null) _buildUpdateBanner(),
    if (_pairs.isNotEmpty) _buildPartnerStrip(),
    Expanded(child: _errorText != null
        ? _buildErrorState()
        : _pairs.isEmpty
            ? _buildWaitingState()
            : Column(children: [_buildMap(), _buildStatusBar(), _buildBottom()])),
  ]);

  Widget _buildBottomNav() => BottomNavigationBar(
    currentIndex: _bottomTab,
    onTap: (i) => setState(() => _bottomTab = i),
    backgroundColor: AppColors.surface,
    selectedItemColor: _roleColor,
    unselectedItemColor: AppColors.textMuted,
    type: BottomNavigationBarType.fixed,
    items: [
      const BottomNavigationBarItem(icon: Icon(Icons.map_rounded), label: 'Harita'),
      BottomNavigationBarItem(
        icon: _permIssueCount > 0
            ? Badge(label: Text('$_permIssueCount'), child: const Icon(Icons.shield_rounded))
            : const Icon(Icons.shield_rounded),
        label: 'İzinler',
      ),
    ],
  );

  Widget _buildPermissionsTab() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('İzinler ve Ayarlar', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
      const SizedBox(height: 4),
      Text('Uygulamanın düzgün çalışması için gereken her şey tek yerde.', style: GoogleFonts.inter(fontSize: 12, color: AppColors.textMuted)),
      const SizedBox(height: 20),
      ..._permissionCards(),
    ],
  );

  // Hem pasif "İzinler" sekmesi hem de ilk açılış sihirbazı (bkz.
  // _buildHealthGate) aynı kart listesini kullanır — tek yerden güncellenir.
  List<Widget> _permissionCards() => [
    _permissionCard(
      icon: Icons.notifications_rounded,
      title: 'Bildirimler',
      desc: 'Kapalıysa mesaj, pil ve alarm bildirimlerini hiç görmezsin.',
      ok: !_notifDenied,
      loading: false,
      onTap: () => openAppSettings(),
    ),
    const SizedBox(height: 12),
    _permissionCard(
      icon: Icons.battery_charging_full_rounded,
      title: 'Pil Kısıtlaması',
      desc: 'Kapalı olmazsa telefon, uygulamayı arka planda öldürüp takibi durdurabilir.',
      ok: _batteryOptOn == null ? null : !_batteryOptOn!,
      loading: _batteryOptOn == null,
      onTap: () async {
        await Permission.ignoreBatteryOptimizations.request();
        await _checkBatteryOpt();
      },
    ),
    if (!_isProtected) ...[
      const SizedBox(height: 12),
      _permissionCard(
        icon: Icons.security_rounded,
        title: 'Silme Koruması',
        desc: 'Açık olursa uygulama silinmeye çalışıldığında yöneticiye anında haber verilir.',
        ok: _adminProtectionActive,
        loading: _adminProtectionActive == null,
        onTap: () async {
          await DeviceAdminService.requestActivation();
          await _checkDeviceAdmin();
        },
      ),
    ],
    const SizedBox(height: 12),
    _oemInfoCard(),
  ];

  Widget _permissionCard({
    required IconData icon,
    required String title,
    required String desc,
    required bool? ok,
    required VoidCallback onTap,
    bool loading = false,
  }) {
    final color = loading ? AppColors.textMuted : (ok == true ? AppColors.safe : AppColors.danger);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(width: 8),
            if (!loading) Icon(ok == true ? Icons.check_circle_rounded : Icons.error_rounded, color: color, size: 16),
          ]),
          const SizedBox(height: 4),
          Text(desc, style: GoogleFonts.inter(fontSize: 12, color: AppColors.textMuted, height: 1.4)),
          if (!loading && ok != true) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.4))),
                child: Text('Ayarla', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
              ),
            ),
          ],
        ])),
      ]),
    );
  }

  // OEM (Honor/Huawei/Xiaomi vb.) otomatik başlatma ayarının durumu
  // programatik olarak okunamıyor — Android'in genel API'si bunu sunmuyor.
  // Bu yüzden yeşil/kırmızı bir durum yerine sadece bilgilendirme + doğrudan
  // ayar sayfasına yönlendirme gösteriliyor.
  Widget _oemInfoCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: AppColors.warning.withOpacity(0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.warning.withOpacity(0.3))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.smartphone_rounded, color: AppColors.warning, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text('Telefon Üreticisi Ayarları', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
      ]),
      const SizedBox(height: 6),
      Text(
        'Honor/Huawei/Xiaomi gibi telefonlarda yukarıdaki izinler tek başına yetmeyebilir. Ayarlar > Pil > Uygulama başlatma (ya da "Otomatik Başlatma") bölümünden UZAKDUR için manuel yönetimi aç ve üç seçeneği de (Otomatik başlatma, İkincil başlatma, Arka planda çalışma) etkinleştir. Bu ayar işletim sistemine özel olduğu için uygulama içinden kontrol edilemez.',
        style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
      ),
      const SizedBox(height: 10),
      GestureDetector(
        onTap: () => openAppSettings(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: AppColors.warning.withOpacity(0.15), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.warning.withOpacity(0.4))),
          child: Text('Uygulama Ayarlarını Aç', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.warning)),
        ),
      ),
    ]),
  );

  Widget _buildTopBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
    child: Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: _roleColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8), border: Border.all(color: _roleColor.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_isProtected ? Icons.shield_rounded : Icons.person_pin_circle_rounded, color: _roleColor, size: 14),
          const SizedBox(width: 6),
          Text(widget.name, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _roleColor)),
        ]),
      ),
      const SizedBox(width: 8),
      // Kurulu build numarası — güncelleme/özellik sorunlarını teşhis
      // ederken hangi sürümün telefonda çalıştığını görmek için.
      Text('b${UpdateService.currentBuild}', style: GoogleFonts.inter(fontSize: 10, color: AppColors.textDisabled)),
      const Spacer(),
      if (_isProtected && _pairs.isNotEmpty) ...[
        _IconBtn(icon: Icons.rule_rounded, onTap: _requestDistance),
        const SizedBox(width: 8),
        _IconBtn(icon: Icons.music_note_rounded, onTap: _pickAlarmSound),
        const SizedBox(width: 8),
        _IconBtn(icon: Icons.contacts_rounded, onTap: _manageContacts),
        const SizedBox(width: 8),
      ],
      if (_isProtected) ...[
        _IconBtn(icon: _disguised ? Icons.visibility_off_rounded : Icons.visibility_rounded, onTap: _toggleDisguise),
        const SizedBox(width: 10),
      ],
      _OnlineDot(label: 'Ben', online: _isRunning, color: _roleColor),
    ]),
  );

  Widget _buildUpdateBanner() => GestureDetector(
    onTap: () async {
      final uri = Uri.parse(_updateInfo!.releaseUrl);
      if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
    },
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.roleB.withOpacity(0.14),
      child: Row(children: [
        Icon(Icons.system_update_rounded, color: AppColors.roleB, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text('Yeni bir güncelleme var — indirmek için dokun', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.roleB))),
        Icon(Icons.chevron_right_rounded, color: AppColors.roleB, size: 18),
      ]),
    ),
  );

  Widget _buildNotifBanner() => GestureDetector(
    onTap: () => openAppSettings(),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.danger.withOpacity(0.14),
      child: Row(children: [
        Icon(Icons.notifications_off_rounded, color: AppColors.danger, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text('Bildirimler kapalı — mesaj/pil uyarıları hiç görünmez. Açmak için dokun', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger))),
        Icon(Icons.chevron_right_rounded, color: AppColors.danger, size: 18),
      ]),
    ),
  );

  // Android'de gerçek bir "şifreyle silme engeli" yok — bu, uygulamayı
  // silmeden önce Cihaz Yöneticisi iznini elle kapatmayı zorunlu kılan tek
  // genel mekanizma. Amaç silmeyi imkansız kılmak değil, bu adımın anında
  // yakalanıp yöneticiye bildirilmesi.
  Widget _buildAdminBanner() => GestureDetector(
    onTap: () => DeviceAdminService.requestActivation(),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.warning.withOpacity(0.14),
      child: Row(children: [
        Icon(Icons.security_rounded, color: AppColors.warning, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text('Silme koruması kapalı — yanlışlıkla/bilgin dışında silinmeyi önlemek için dokun', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.warning))),
        Icon(Icons.chevron_right_rounded, color: AppColors.warning, size: 18),
      ]),
    ),
  );

  Widget _buildPartnerStrip() => Container(
    height: 46,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _pairs.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, i) {
        final pid = _pairs.keys.elementAt(i);
        final selected = pid == _focusedPairId;
        final statusColor = _statusColorFor(_pairStatus[pid]);
        // Uzaklaştırılan taraf, izin verilmedikçe korunanın kimliğini de
        // görmemeli — haritadaki konum gizleme kuralıyla aynı gerekçe.
        final canSeeOtherIdentity = _isProtected || (_pairs[pid]?.trackedCanSeeLocation ?? false);
        final name = canSeeOtherIdentity ? (_otherNameByPair[pid] ?? 'Eşleşme ${i + 1}') : 'Eşleşme ${i + 1}';
        final online = _otherOnlineByPair[pid] ?? false;
        return GestureDetector(
          onTap: () => setState(() => _focusedPairId = pid),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? statusColor.withOpacity(0.12) : AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? statusColor.withOpacity(0.5) : AppColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? statusColor : AppColors.textDisabled)),
              const SizedBox(width: 7),
              Text(name, style: GoogleFonts.inter(fontSize: 11.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? AppColors.textPrimary : AppColors.textSecondary)),
            ]),
          ),
        );
      },
    ),
  );

  Widget _buildWaitingState() => Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 72, height: 72, decoration: BoxDecoration(color: _roleColor.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
        child: Icon(Icons.hourglass_top_rounded, color: _roleColor, size: 34)),
    const SizedBox(height: 22),
    Text('Eşleştirme Bekleniyor', style: GoogleFonts.inter(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
    const SizedBox(height: 10),
    Text('${widget.name} olarak kayıtlısın. Yönetici seni web panelinden bir veya birden fazla cihazla eşleştirdiğinde izleme otomatik başlayacak.',
        textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary, height: 1.6)),
    const SizedBox(height: 20),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.safe)),
        const SizedBox(width: 8),
        Text('Cihaz çevrimiçi, konum paylaşılıyor', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
      ]),
    ),
  ])));

  Widget _buildMap() => Expanded(
    flex: 5,
    child: Stack(children: [
      GoogleMap(
        initialCameraPosition: CameraPosition(
          target: _myLocation != null ? LatLng(_myLocation!.lat, _myLocation!.lon) : const LatLng(41.0082, 28.9784),
          zoom: 16,
        ),
        markers: _markers, circles: _circles, polylines: _polylines,
        mapType: MapType.normal, myLocationEnabled: false,
        compassEnabled: false, zoomControlsEnabled: false, mapToolbarEnabled: false,
        onMapCreated: (ctrl) { _mapCtrl = ctrl; ctrl.setMapStyle(_darkMapStyle); setState(() => _mapReady = true); _updateMap(); },
        onCameraMove: (_) { if (_mapFollowsMe) setState(() => _mapFollowsMe = false); },
      ),
      Positioned(top: 12, left: 12, child: _FloatingDistanceCard(distance: _distance, threshold: _pair?.threshold, isAlarm: _isAlarm, statusColor: _statusColor)),
      Positioned(top: 12, right: 12, child: Column(children: [
        _MapBtn(icon: _mapFollowsMe ? Icons.my_location_rounded : Icons.location_searching_rounded, active: _mapFollowsMe, color: _roleColor, onTap: () { setState(() => _mapFollowsMe = !_mapFollowsMe); _updateMap(); }),
        const SizedBox(height: 8),
        _MapBtn(icon: Icons.fit_screen_rounded, active: false, color: AppColors.textSecondary, onTap: () { setState(() => _mapFollowsMe = false); _updateMap(); }),
      ])),
      if (_isProtected && _pairs.isNotEmpty) Positioned(bottom: 12, left: 12, child: _PanicButton(sending: _panicSending, onFire: _triggerPanic)),
      if (_isAlarm) Positioned(bottom: 0, left: 0, right: 0,
          child: AnimatedBuilder(animation: _alarmAnim, builder: (_, __) => Container(height: 3, color: AppColors.danger.withOpacity(0.5 + 0.5 * _alarmAnim.value)))),
    ]),
  );

  Widget _buildStatusBar() => AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: _isAlarm ? AppColors.danger.withOpacity(0.1) : AppColors.surface,
      border: Border(bottom: const BorderSide(color: AppColors.border, width: 0.5), left: BorderSide(color: _statusColor, width: 3)),
    ),
    child: Row(children: [
      Container(width: 36, height: 36,
          decoration: BoxDecoration(color: _statusColor.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(_alarmZoneLabel != null ? Icons.block_rounded : _isAlarm ? Icons.warning_rounded : Icons.check_circle_rounded, color: _statusColor, size: 18)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_statusText, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _isAlarm ? AppColors.danger : AppColors.textPrimary)),
        Text('Sınır: ${_pair?.threshold.round() ?? '—'}m  •  Acil: ${_pair != null ? (_pair!.threshold * kAcilRatio).round() : '—'}m  •  5 sn\'de bir güncelleniyor'
                '${_isProtected && _pair?.distanceRequest != null ? '  •  Talep: ${_pair!.distanceRequest!.round()}m bekleniyor' : ''}',
            style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
      ])),
      if (_isProtected) GestureDetector(
        onTap: _isRunning ? _stop : _start,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
          child: Text(_isRunning ? 'Durdur' : 'Başlat', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textMuted)),
        ),
      ),
    ]),
  );

  Widget _buildBottom() {
    if (_isAlarm) return GestureDetector(
      onTap: () { NotificationService.stopAlarm(); _alarmCtrl.stop(); _alarmCtrl.reset(); setState(() => _isAlarm = false); },
      child: AnimatedBuilder(
        animation: _alarmAnim,
        builder: (_, __) => Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 18),
          color: Color.lerp(const Color(0xFFCC0000), AppColors.danger, _alarmAnim.value),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.volume_off_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Text('ALARMI DURDUR', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
          ]),
        ),
      ),
    );

    return Container(
      height: 140, padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('OLAY GEÇMİŞİ', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
          const Spacer(),
          if (_log.isNotEmpty) Text('${_log.length} kayıt', style: GoogleFonts.inter(fontSize: 10, color: AppColors.textDisabled)),
        ]),
        const SizedBox(height: 8),
        Expanded(child: _log.isEmpty
            ? Center(child: Text('GPS bağlandıktan sonra kayıt başlar', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textDisabled)))
            : ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) {
                  final e = _log[i];
                  return Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
                    Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: e.isAlarm ? AppColors.danger : AppColors.safe)),
                    const SizedBox(width: 8),
                    Text(e.time, style: GoogleFonts.sourceCodePro(fontSize: 10, color: AppColors.textMuted)),
                    const SizedBox(width: 10),
                    Text('${e.distance.round()}m', style: GoogleFonts.sourceCodePro(fontSize: 10, fontWeight: FontWeight.w600, color: e.isAlarm ? AppColors.danger : AppColors.safe)),
                    const SizedBox(width: 8),
                    Text(e.isAlarm ? '⚠ Alarm' : '✓ Güvenli', style: GoogleFonts.inter(fontSize: 10, color: e.isAlarm ? AppColors.danger : AppColors.safe)),
                  ]));
                },
              )),
      ]),
    );
  }

  Widget _buildErrorState() => Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 64, height: 64, decoration: BoxDecoration(color: AppColors.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.location_off_rounded, color: AppColors.danger, size: 32)),
    const SizedBox(height: 20),
    Text('Konum Hatası', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
    const SizedBox(height: 8),
    Text(_errorText ?? '', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
    const SizedBox(height: 28),
    GestureDetector(onTap: _start, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      decoration: BoxDecoration(color: _roleColor.withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: _roleColor.withOpacity(0.4))),
      child: Text('Tekrar Dene', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: _roleColor)),
    )),
  ])));
}

// Alt widget'lar
class _OnlineDot extends StatelessWidget {
  final String label; final bool online; final Color color;
  const _OnlineDot({required this.label, required this.online, required this.color});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    AnimatedContainer(duration: const Duration(milliseconds: 400), width: 7, height: 7,
        decoration: BoxDecoration(shape: BoxShape.circle, color: online ? color : AppColors.textDisabled,
            boxShadow: online ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)] : [])),
    const SizedBox(width: 5),
    Text(label, style: GoogleFonts.inter(fontSize: 10, color: online ? AppColors.textSecondary : AppColors.textDisabled)),
  ]);
}

class _IconBtn extends StatelessWidget {
  final IconData icon; final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: Container(
    width: 32, height: 32,
    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(9), border: Border.all(color: AppColors.border)),
    child: Icon(icon, color: AppColors.textSecondary, size: 16),
  ));
}

class _TypeChip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _TypeChip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? AppColors.danger.withOpacity(0.12) : AppColors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: selected ? AppColors.danger.withOpacity(0.5) : AppColors.border),
      ),
      child: Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? AppColors.danger : AppColors.textSecondary)),
    ),
  );
}

class _PanicButton extends StatelessWidget {
  final bool sending; final VoidCallback onFire;
  const _PanicButton({required this.sending, required this.onFire});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPress: sending ? null : onFire,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.danger, borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: AppColors.danger.withOpacity(0.5), blurRadius: 14)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(sending ? Icons.hourglass_top_rounded : Icons.sos_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Text(sending ? 'Gönderiliyor…' : 'Basılı tut: PANİK', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
      ]),
    ),
  );
}

class _FloatingDistanceCard extends StatelessWidget {
  final double? distance, threshold; final bool isAlarm; final Color statusColor;
  const _FloatingDistanceCard({required this.distance, required this.threshold, required this.isAlarm, required this.statusColor});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.bg.withOpacity(0.92), borderRadius: BorderRadius.circular(12),
      border: Border.all(color: isAlarm ? AppColors.danger.withOpacity(0.5) : AppColors.border),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 2))],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('MESAFE', style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
      const SizedBox(height: 4),
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(distance != null ? '${distance!.round()}' : '—', style: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w800, color: statusColor, height: 1)),
        const SizedBox(width: 4),
        Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('m', style: GoogleFonts.inter(fontSize: 13, color: AppColors.textMuted))),
      ]),
      Text('Kritik: ${threshold != null ? (threshold! * kKritikRatio).round() : '—'}m  •  Acil: ${threshold != null ? (threshold! * kAcilRatio).round() : '—'}m', style: GoogleFonts.inter(fontSize: 10, color: AppColors.textMuted)),
    ]),
  );
}

class _MapBtn extends StatelessWidget {
  final IconData icon; final bool active; final Color color; final VoidCallback onTap;
  const _MapBtn({required this.icon, required this.active, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: Container(
    width: 40, height: 40,
    decoration: BoxDecoration(
      color: active ? color.withOpacity(0.15) : AppColors.bg.withOpacity(0.92),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: active ? color.withOpacity(0.5) : AppColors.border),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 8)],
    ),
    child: Icon(icon, color: active ? color : AppColors.textSecondary, size: 18),
  ));
}
