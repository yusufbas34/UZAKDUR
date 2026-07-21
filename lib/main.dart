import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'screens/onboarding_screen.dart';
import 'screens/monitor_screen.dart';
import 'services/notification_service.dart';
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

class _StartupGateState extends State<_StartupGate> {
  bool _loading = true;
  String? _deviceId, _name, _role;

  @override
  void initState() { super.initState(); _load(); }

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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(backgroundColor: AppColors.bg, body: Center(child: CircularProgressIndicator(color: AppColors.danger)));
    }
    if (_deviceId == null || _name == null || _role == null) return const OnboardingScreen();
    return MonitorScreen(deviceId: _deviceId!, name: _name!, role: _role!);
  }
}
