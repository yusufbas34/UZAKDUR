import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../services/foreground_task_service.dart';
import '../theme/app_theme.dart';

class LogEntry {
  final String time;
  final double distance;
  final bool isAlarm;
  LogEntry(this.time, this.distance, this.isAlarm);
}

class MonitorScreen extends StatefulWidget {
  final String role;
  final double threshold;
  const MonitorScreen({super.key, required this.role, required this.threshold});
  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final String _role, _otherRole;
  late final double _threshold;
  LocationData? _myLocation, _otherLocation;
  double? _distance;
  bool _isAlarm = false, _isRunning = false, _otherOnline = false;
  String _statusText = 'GPS bekleniyor…';
  String? _errorText;
  final List<LogEntry> _log = [];
  final _fmt = DateFormat('HH:mm:ss');

  StreamSubscription<Position>? _posSub;
  StreamSubscription? _otherLocSub, _otherStatusSub;
  Timer? _pollTimer;

  late AnimationController _alarmCtrl;
  late Animation<double> _alarmAnim;

  GoogleMapController? _mapCtrl;
  Set<Marker> _markers = {};
  Set<Circle> _circles = {};
  Set<Polyline> _polylines = {};
  bool _mapReady = false, _mapFollowsMe = true;

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

  @override
  void initState() {
    super.initState();
    _role = widget.role;
    _otherRole = _role == 'A' ? 'B' : 'A';
    _threshold = widget.threshold;
    _alarmCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _alarmAnim = CurvedAnimation(parent: _alarmCtrl, curve: Curves.easeInOut);
    WidgetsBinding.instance.addObserver(this);
    ForegroundTaskService.init();
    _start();
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
    await ForegroundTaskService.start(role: _role, threshold: _threshold);
    await LocationService.setOnline(_role, true);

    _posSub = LocationService.startLocationStream().listen((pos) async {
      final loc = LocationData(lat: pos.latitude, lon: pos.longitude, timestamp: DateTime.now());
      if (!mounted) return;
      setState(() => _myLocation = loc);
      await LocationService.writeLocation(_role, pos.latitude, pos.longitude);
      _updateMap();
      _checkDistance();
    }, onError: (e) => _setError('GPS hatası: $e'));

    _otherLocSub = LocationService.listenOtherLocation(_otherRole, (loc) {
      if (!mounted) return;
      setState(() => _otherLocation = loc);
      _updateMap();
      _checkDistance();
    });

    _otherStatusSub = LocationService.listenOtherStatus(_otherRole, (online) {
      if (!mounted) return;
      setState(() => _otherOnline = online);
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkDistance());
  }

  void _checkDistance() {
    if (_myLocation == null || _otherLocation == null) return;
    final d = LocationService.calculateDistance(_myLocation!.lat, _myLocation!.lon, _otherLocation!.lat, _otherLocation!.lon);
    final isAlarm = d < _threshold;
    final now = _fmt.format(DateTime.now());
    if (!mounted) return;
    setState(() {
      _distance = d;
      _isAlarm = isAlarm;
      _statusText = isAlarm ? 'Yaklaşma tespit edildi!' : d < _threshold * 1.5 ? 'Dikkat — Sınıra yaklaşıyor' : 'Güvenli mesafede';
      if (_log.isEmpty || _log.first.isAlarm != isAlarm) {
        _log.insert(0, LogEntry(now, d, isAlarm));
        if (_log.length > 100) _log.removeLast();
      }
    });
    if (isAlarm) {
      if (!_alarmCtrl.isAnimating) _alarmCtrl.repeat(reverse: true);
      NotificationService.startAlarm(d);
      LocationService.writeAlarmLog(_role, d);
    } else {
      _alarmCtrl.stop(); _alarmCtrl.reset();
      NotificationService.stopAlarm();
    }
  }

  void _updateMap() {
    if (!_mapReady || _mapCtrl == null) return;
    final markers = <Marker>{};
    final circles = <Circle>{};
    final polylines = <Polyline>{};

    if (_myLocation != null) {
      final pos = LatLng(_myLocation!.lat, _myLocation!.lon);
      markers.add(Marker(
        markerId: const MarkerId('me'), position: pos,
        icon: BitmapDescriptor.defaultMarkerWithHue(_role == 'A' ? BitmapDescriptor.hueRed : BitmapDescriptor.hueAzure),
        infoWindow: InfoWindow(title: 'Cihaz $_role (Ben)'), zIndex: 2,
      ));
      circles.add(Circle(
        circleId: const CircleId('threshold'), center: pos, radius: _threshold,
        fillColor: (_isAlarm ? AppColors.danger : AppColors.safe).withOpacity(0.08),
        strokeColor: (_isAlarm ? AppColors.danger : AppColors.safe).withOpacity(0.4),
        strokeWidth: 1,
      ));
      if (_mapFollowsMe) _mapCtrl!.animateCamera(CameraUpdate.newLatLng(pos));
    }

    if (_otherLocation != null) {
      markers.add(Marker(
        markerId: const MarkerId('other'),
        position: LatLng(_otherLocation!.lat, _otherLocation!.lon),
        icon: BitmapDescriptor.defaultMarkerWithHue(_role == 'A' ? BitmapDescriptor.hueAzure : BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: 'Cihaz $_otherRole'), zIndex: 1,
      ));
    }

    if (_myLocation != null && _otherLocation != null) {
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
    _posSub?.cancel(); _otherLocSub?.cancel(); _otherStatusSub?.cancel(); _pollTimer?.cancel();
    _alarmCtrl.stop(); _alarmCtrl.reset();
    NotificationService.stopAlarm();
    ForegroundTaskService.stop().ignore();
    LocationService.setOnline(_role, false).ignore();
    if (!mounted) return;
    setState(() { _isRunning = false; _isAlarm = false; _statusText = 'Durduruldu'; });
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() { _errorText = msg; _isRunning = false; _statusText = 'Hata'; });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) _stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel(); _otherLocSub?.cancel(); _otherStatusSub?.cancel(); _pollTimer?.cancel();
    _alarmCtrl.dispose(); _mapCtrl?.dispose();
    NotificationService.stopAlarm().ignore();
    ForegroundTaskService.stop().ignore();
    LocationService.setOnline(_role, false).ignore();
    super.dispose();
  }

  Color get _roleColor => _role == 'A' ? AppColors.roleA : AppColors.roleB;
  Color get _statusColor => _isAlarm ? AppColors.danger : _distance != null && _distance! < _threshold * 1.5 ? AppColors.warning : AppColors.safe;

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: AppColors.bg,
          body: AnimatedBuilder(
            animation: _alarmAnim,
            builder: (_, child) => ColoredBox(
              color: _isAlarm ? Color.lerp(AppColors.bg, AppColors.dangerDeep, _alarmAnim.value)! : AppColors.bg,
              child: child,
            ),
            child: SafeArea(child: Column(children: [
              _buildTopBar(),
              Expanded(child: _errorText != null ? _buildErrorState() : Column(children: [
                _buildMap(),
                _buildStatusBar(),
                _buildBottom(),
              ])),
            ])),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
    child: Row(children: [
      GestureDetector(
        onTap: () async { await _stop(); if (mounted) Navigator.pop(context); },
        child: Container(width: 36, height: 36,
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            child: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.textSecondary, size: 16)),
      ),
      const SizedBox(width: 14),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: _roleColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8), border: Border.all(color: _roleColor.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_role == 'A' ? Icons.person_pin_circle_rounded : Icons.shield_rounded, color: _roleColor, size: 14),
          const SizedBox(width: 6),
          Text(_role == 'A' ? 'Uzaklaştırma — A' : 'Korunan — B', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _roleColor)),
        ]),
      ),
      const Spacer(),
      _OnlineDot(label: 'Ben', online: _isRunning, color: _roleColor),
      const SizedBox(width: 10),
      _OnlineDot(label: 'Cihaz $_otherRole', online: _otherOnline, color: _role == 'A' ? AppColors.roleB : AppColors.roleA),
    ]),
  );

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
      // Mesafe kartı
      Positioned(top: 12, left: 12, child: _FloatingDistanceCard(distance: _distance, threshold: _threshold, isAlarm: _isAlarm, statusColor: _statusColor)),
      // Harita kontrolleri
      Positioned(top: 12, right: 12, child: Column(children: [
        _MapBtn(icon: _mapFollowsMe ? Icons.my_location_rounded : Icons.location_searching_rounded, active: _mapFollowsMe, color: _roleColor, onTap: () { setState(() => _mapFollowsMe = !_mapFollowsMe); _updateMap(); }),
        const SizedBox(height: 8),
        _MapBtn(icon: Icons.fit_screen_rounded, active: false, color: AppColors.textSecondary, onTap: () { setState(() => _mapFollowsMe = false); _updateMap(); }),
      ])),
      // Alarm çizgisi
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
          child: Icon(_isAlarm ? Icons.warning_rounded : Icons.check_circle_rounded, color: _statusColor, size: 18)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_statusText, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _isAlarm ? AppColors.danger : AppColors.textPrimary)),
        Text('Eşik: ${_threshold.round()}m  •  5 sn\'de bir güncelleniyor', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
      ])),
      GestureDetector(
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
      Text('Eşik: ${threshold?.round()}m', style: GoogleFonts.inter(fontSize: 10, color: AppColors.textMuted)),
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
