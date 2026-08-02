import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/location_service.dart';
import '../services/foreground_task_service.dart';
import '../services/watchdog_service.dart';
import '../services/push_service.dart';
import '../theme/app_theme.dart';

// Saat (Wear OS) girişi — telefon uygulamasının küçültülmüş bir kopyası
// değil, aynı hesaba (aynı deviceId'ye) ikinci bir giriş noktası. Yani
// "Uzaklaştırılan" kişi telefonda oluşturduğu e-posta/şifre ile saatte de
// giriş yapar; ikisi de aynı devices/{deviceId} kaydına konum yazar, hangisi
// çalışıyorsa o güncel konumu gönderir. Böylece admin panelinde/eşleştirmede
// HİÇBİR değişiklik gerekmiyor — saat, telefonun yerini alan ikinci bir uçtan
// ibaret.
class WearApp extends StatelessWidget {
  const WearApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const WearGate(),
      );
}

class WearGate extends StatefulWidget {
  const WearGate({super.key});
  @override
  State<WearGate> createState() => _WearGateState();
}

class _WearGateState extends State<WearGate> {
  bool _loading = true;
  String? _deviceId, _name, _role;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _deviceId = p.getString('device_id');
      _name = p.getString('device_name');
      _role = p.getString('device_role');
      _loading = false;
    });
  }

  void _onLoggedIn(String deviceId, String name, String role) {
    setState(() { _deviceId = deviceId; _name = name; _role = role; });
  }

  Future<void> _onLoggedOut() async {
    await ForegroundTaskService.stop();
    await LocationService.setOnline(_deviceId!, false);
    final p = await SharedPreferences.getInstance();
    await p.remove('device_id');
    await p.remove('device_name');
    await p.remove('device_role');
    if (!mounted) return;
    setState(() { _deviceId = null; _name = null; _role = null; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(backgroundColor: AppColors.bg, body: Center(child: CircularProgressIndicator(color: AppColors.danger)));
    }
    if (_deviceId == null || _name == null || _role == null) {
      return WearLoginScreen(onLoggedIn: _onLoggedIn);
    }
    return WearStatusScreen(deviceId: _deviceId!, name: _name!, role: _role!, onLogout: _onLoggedOut);
  }
}

class WearLoginScreen extends StatefulWidget {
  const WearLoginScreen({super.key, required this.onLoggedIn});
  final void Function(String deviceId, String name, String role) onLoggedIn;
  @override
  State<WearLoginScreen> createState() => _WearLoginScreenState();
}

class _WearLoginScreenState extends State<WearLoginScreen> {
  static final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _saving = false;
  bool _obscure = true;
  String? _error;

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (email.isEmpty || !_emailRegex.hasMatch(email)) { setState(() => _error = 'Geçerli bir e-posta gir.'); return; }
    if (password.isEmpty) { setState(() => _error = 'Şifre gerekli.'); return; }
    setState(() { _saving = true; _error = null; });
    try {
      final account = await LocationService.findAccountByEmail(email);
      if (account == null) { setState(() { _error = 'Hesap bulunamadı. Önce telefonda kayıt ol.'; _saving = false; }); return; }
      final hash = LocationService.hashPassword(account.email, password);
      if (hash != account.passwordHash) { setState(() { _error = 'Şifre yanlış.'; _saving = false; }); return; }
      final p = await SharedPreferences.getInstance();
      await p.setString('device_id', account.deviceId);
      await p.setString('device_name', account.name);
      await p.setString('device_role', account.role);
      PushService.init(account.deviceId).ignore();
      if (!mounted) return;
      widget.onLoggedIn(account.deviceId, account.name, account.role);
    } catch (e) {
      setState(() { _error = 'Bağlantı hatası, tekrar dene.'; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('UZAKDUR', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.danger, letterSpacing: 1.5)),
              const SizedBox(height: 4),
              Text('Hesabınla giriş yap', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textSecondary)),
              const SizedBox(height: 14),
              _WearField(controller: _emailCtrl, hint: 'E-posta', keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 8),
              _WearField(controller: _passwordCtrl, hint: 'Şifre', obscure: _obscure,
                  suffix: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 16, color: AppColors.textMuted),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  )),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 10.5, color: AppColors.danger)),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 38,
                child: ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
                  ),
                  child: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text('Giriş Yap', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _WearField extends StatelessWidget {
  const _WearField({required this.controller, required this.hint, this.obscure = false, this.keyboardType, this.suffix});
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final Widget? suffix;
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        style: GoogleFonts.inter(fontSize: 12.5, color: AppColors.textPrimary),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: GoogleFonts.inter(fontSize: 12.5, color: AppColors.textMuted),
          filled: true,
          fillColor: AppColors.surface,
          suffixIcon: suffix,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(19), borderSide: BorderSide.none),
        ),
      );
}

class WearStatusScreen extends StatefulWidget {
  const WearStatusScreen({super.key, required this.deviceId, required this.name, required this.role, required this.onLogout});
  final String deviceId, name, role;
  final Future<void> Function() onLogout;
  @override
  State<WearStatusScreen> createState() => _WearStatusScreenState();
}

class _WearStatusScreenState extends State<WearStatusScreen> {
  String _status = 'Konum izni kontrol ediliyor…';
  bool _running = false;
  bool _error = false;
  StreamSubscription? _deviceSub;
  int? _battery;
  DateTime? _lastTs;

  @override
  void initState() {
    super.initState();
    ForegroundTaskService.init();
    _start();
    _deviceSub = LocationService.listenDevice(widget.deviceId, (data) {
      if (!mounted || data == null) return;
      setState(() {
        final b = data['battery'];
        if (b is num) _battery = b.toInt();
        final ts = data['ts'];
        if (ts is num) _lastTs = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
      });
    });
  }

  Future<void> _start() async {
    final result = await LocationService.requestPermissions();
    if (!mounted) return;
    switch (result) {
      case LocationPermissionResult.serviceDisabled:
        setState(() { _status = 'GPS kapalı, açman gerekiyor.'; _error = true; }); return;
      case LocationPermissionResult.denied:
        setState(() { _status = 'Konum izni reddedildi.'; _error = true; }); return;
      case LocationPermissionResult.deniedForever:
        setState(() { _status = 'Konum izni kalıcı reddedildi, ayarlardan aç.'; _error = true; }); return;
      case LocationPermissionResult.granted:
        break;
    }
    await LocationService.setOnline(widget.deviceId, true);
    await ForegroundTaskService.start(deviceId: widget.deviceId);
    WatchdogService.register().ignore();
    if (!mounted) return;
    setState(() { _running = true; _error = false; _status = 'İzleniyor'; });
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roleLabel = widget.role == 'protected' ? 'Korunan' : 'Uzaklaştırılan';
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _error ? AppColors.dangerDeep : (_running ? AppColors.surfaceHigh : AppColors.surface),
                  border: Border.all(color: _error ? AppColors.danger : (_running ? AppColors.safe : AppColors.border), width: 2),
                ),
                child: Icon(_error ? Icons.error_outline : Icons.my_location, color: _error ? AppColors.danger : (_running ? AppColors.safe : AppColors.textMuted), size: 20),
              ),
              const SizedBox(height: 8),
              Text(widget.name, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              Text(roleLabel, style: GoogleFonts.inter(fontSize: 10, color: AppColors.textSecondary)),
              const SizedBox(height: 6),
              Text(_status, textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 10.5, color: _error ? AppColors.danger : AppColors.textSecondary)),
              if (_battery != null || _lastTs != null) ...[
                const SizedBox(height: 8),
                Wrap(alignment: WrapAlignment.center, spacing: 10, children: [
                  if (_battery != null) _WearStat(icon: Icons.battery_std, text: '%$_battery'),
                  if (_lastTs != null) _WearStat(icon: Icons.schedule, text: _formatAgo(_lastTs!)),
                ]),
              ],
              if (_error) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 30,
                  child: TextButton(
                    onPressed: _start,
                    style: TextButton.styleFrom(backgroundColor: AppColors.surfaceHigh, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                    child: Text('Tekrar Dene', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textPrimary)),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                height: 28,
                child: TextButton(
                  onPressed: widget.onLogout,
                  child: Text('Çıkış Yap', style: GoogleFonts.inter(fontSize: 10.5, color: AppColors.textMuted)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

String _formatAgo(DateTime ts) {
  final diff = DateTime.now().difference(ts);
  if (diff.inSeconds < 60) return 'şimdi';
  if (diff.inMinutes < 60) return '${diff.inMinutes}dk önce';
  return '${diff.inHours}sa önce';
}

class _WearStat extends StatelessWidget {
  const _WearStat({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: AppColors.textMuted),
        const SizedBox(width: 3),
        Text(text, style: GoogleFonts.inter(fontSize: 10.5, color: AppColors.textSecondary)),
      ]);
}
