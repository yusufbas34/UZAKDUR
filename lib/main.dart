import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'screens/onboarding_screen.dart';
import 'screens/monitor_screen.dart';
import 'services/biometric_lock_service.dart';
import 'services/notification_service.dart';
import 'services/watchdog_service.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.init();
  await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  await WatchdogService.init();
  await PushService.registerBackgroundHandler();
  runApp(const UzakDurApp());
}

class UzakDurApp extends StatelessWidget {
  const UzakDurApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'UZAKDUR',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const _StartupGate(),
      );
}

class _StartupGate extends StatefulWidget {
  const _StartupGate();
  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> with WidgetsBindingObserver {
  bool _loading = true;
  String? _deviceId, _name, _role;
  bool _locked = false;
  bool _authChecking = false;
  bool _wasBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Uygulama arka plana atılıp geri döndüğünde de (sadece soğuk açılışta
  // değil) kilidi tekrar devreye sokuyoruz — bir yabancı telefonu ele
  // geçirip uygulamayı arka plandan öne getirerek kilidi atlayamasın.
  // Not: "inactive" durumunu saymıyoruz — biyometrik istem ekranı da bu
  // durumu tetikliyor ve onu saysaydık kimlik doğrulama kendi kendini
  // sürekli yeniden tetikleyen bir döngüye girerdi. Gerçekten arka plana
  // atılma her zaman "paused" ile sonuçlanıyor.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasBackgrounded = true;
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      if (!_loading && _deviceId != null && mounted) {
        setState(() => _locked = true);
        _attemptAuth();
      }
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    final deviceId = p.getString('device_id');
    setState(() {
      _deviceId = deviceId;
      _name = p.getString('device_name');
      _role = p.getString('device_role');
      _loading = false;
    });
    if (deviceId != null) {
      PushService.init(deviceId).ignore();
      final available = await BiometricLockService.isAvailable();
      if (available && mounted) {
        setState(() => _locked = true);
        _attemptAuth();
      }
    }
  }

  Future<void> _attemptAuth() async {
    if (_authChecking) return;
    _authChecking = true;
    final ok = await BiometricLockService.authenticate();
    _authChecking = false;
    if (!mounted) return;
    if (ok) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(backgroundColor: AppColors.bg, body: Center(child: CircularProgressIndicator(color: AppColors.danger)));
    }
    if (_deviceId == null || _name == null || _role == null) return const OnboardingScreen();
    if (_locked) return _LockScreen(onRetry: _attemptAuth);
    return MonitorScreen(deviceId: _deviceId!, name: _name!, role: _role!);
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(color: AppColors.surface, shape: BoxShape.circle, border: Border.all(color: AppColors.border)),
                child: const Icon(Icons.lock_rounded, color: AppColors.textSecondary, size: 32),
              ),
              const SizedBox(height: 20),
              Text('UZAKDUR kilitli', style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              Text('Devam etmek için kimliğini doğrula.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onRetry,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.surfaceHigh,
                    foregroundColor: AppColors.textPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('Kilidi Aç', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
