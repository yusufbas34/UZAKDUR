import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import 'monitor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  double _threshold = 100;
  String? _lastRole;
  late AnimationController _radarCtrl;
  late Animation<double> _radarScale, _radarOpacity;

  @override
  void initState() {
    super.initState();
    _radarCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _radarScale = Tween<double>(begin: 0.3, end: 1.5).animate(CurvedAnimation(parent: _radarCtrl, curve: Curves.easeOut));
    _radarOpacity = Tween<double>(begin: 0.6, end: 0.0).animate(CurvedAnimation(parent: _radarCtrl, curve: Curves.easeOut));
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() { _threshold = p.getDouble('threshold') ?? 100; _lastRole = p.getString('last_role'); });
  }

  Future<void> _navigate(String role) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('threshold', _threshold);
    await p.setString('last_role', role);
    if (!mounted) return;
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, a, __) => MonitorScreen(role: role, threshold: _threshold),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      transitionDuration: const Duration(milliseconds: 400),
    ));
  }

  @override
  void dispose() { _radarCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(children: [
        // Radar animasyonu
        Positioned(
          top: size.height * 0.1, right: -80,
          child: AnimatedBuilder(animation: _radarCtrl, builder: (_, __) => Container(
            width: 300 * _radarScale.value, height: 300 * _radarScale.value,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(
              color: AppColors.danger.withOpacity(_radarOpacity.value * 0.25), width: 1.5)),
          )),
        ),
        SafeArea(child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 32),
            // Logo
            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: AppColors.danger.withOpacity(0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.danger.withOpacity(0.3))),
                child: const Icon(Icons.radar, color: AppColors.danger, size: 22),
              ),
              const SizedBox(width: 12),
              Text('UZAKDUR', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: 3)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppColors.border)),
                child: Text('v2.0', style: GoogleFonts.sourceCodePro(fontSize: 10, color: AppColors.textMuted)),
              ),
            ]),
            const SizedBox(height: 36),
            Text('Yaklaşma\nEngel Sistemi', style: GoogleFonts.inter(fontSize: 36, fontWeight: FontWeight.w800, color: AppColors.textPrimary, height: 1.15)),
            const SizedBox(height: 12),
            Text('İki telefon arasındaki mesafeyi gerçek zamanlı\nölçer. Belirlenen sınır aşılınca alarm verir.',
                style: GoogleFonts.inter(fontSize: 14, color: AppColors.textSecondary, height: 1.6)),
            const SizedBox(height: 48),
            // Rol seçimi
            Text('CİHAZ ROLÜNÜ SEÇ', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _RoleCard(role: 'A', title: 'Cihaz A', subtitle: 'Uzaklaştırma kişisi', description: 'Takip edilen kişinin telefonu', icon: Icons.person_pin_circle_rounded, color: AppColors.roleA, isLast: _lastRole == 'A', onTap: () => _navigate('A'))),
              const SizedBox(width: 12),
              Expanded(child: _RoleCard(role: 'B', title: 'Cihaz B', subtitle: 'Korunan kişi', description: 'Alarm alan kişinin telefonu', icon: Icons.shield_rounded, color: AppColors.roleB, isLast: _lastRole == 'B', onTap: () => _navigate('B'))),
            ]),
            const SizedBox(height: 40),
            // Eşik
            Row(children: [
              Text('ALARM EŞİĞİ', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: AppColors.danger.withOpacity(0.12), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.danger.withOpacity(0.3))),
                child: Text('${_threshold.round()} metre', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.danger)),
              ),
            ]),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
              child: Column(children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4, activeTrackColor: AppColors.danger, inactiveTrackColor: AppColors.border,
                    thumbColor: AppColors.danger, overlayColor: AppColors.dangerGlow,
                  ),
                  child: Slider(value: _threshold, min: 50, max: 500, divisions: 45, onChanged: (v) => setState(() => _threshold = v)),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('50m', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
                  Text(_threshold <= 100 ? 'Yakın mesafe' : _threshold <= 250 ? 'Orta mesafe' : 'Uzak mesafe',
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600,
                          color: _threshold <= 100 ? AppColors.danger : _threshold <= 250 ? AppColors.warning : AppColors.safe)),
                  Text('500m', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
                ]),
              ]),
            ),
            const SizedBox(height: 40),
            // Nasıl çalışır
            Text('NASIL KULLANILIR', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
              child: Column(children: [
                _StepTile(step: '01', icon: Icons.install_mobile_rounded, title: 'İki telefona kur', subtitle: 'Her iki cihaza da uygulamayı yükle', isLast: false),
                _StepTile(step: '02', icon: Icons.people_alt_rounded, title: 'Rol seç', subtitle: 'A uzaklaştırma, B korunan kişi', isLast: false),
                _StepTile(step: '03', icon: Icons.wifi_rounded, title: 'İnternete bağlan', subtitle: 'Konum Firebase üzerinden paylaşılır', isLast: false),
                _StepTile(step: '04', icon: Icons.notifications_active_rounded, title: 'İzinleri ver', subtitle: 'GPS, bildirim ve pil optimizasyonu', isLast: true),
              ]),
            ),
            const SizedBox(height: 48),
          ]),
        )),
      ]),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final String role, title, subtitle, description;
  final IconData icon;
  final Color color;
  final bool isLast;
  final VoidCallback onTap;
  const _RoleCard({required this.role, required this.title, required this.subtitle, required this.description, required this.icon, required this.color, required this.isLast, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isLast ? color.withOpacity(0.07) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isLast ? color.withOpacity(0.5) : AppColors.border, width: isLast ? 1.5 : 1),
        boxShadow: isLast ? [BoxShadow(color: color.withOpacity(0.15), blurRadius: 20)] : [],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 22)),
        const SizedBox(height: 14),
        Text(title, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        Text(subtitle, style: GoogleFonts.inter(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(description, style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted, height: 1.5)),
        if (isLast) ...[
          const SizedBox(height: 12),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
              child: Text('Son kullanılan', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: color))),
        ],
      ]),
    ),
  );
}

class _StepTile extends StatelessWidget {
  final String step, title, subtitle;
  final IconData icon;
  final bool isLast;
  const _StepTile({required this.step, required this.icon, required this.title, required this.subtitle, required this.isLast});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: BoxDecoration(border: isLast ? null : const Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
    child: Row(children: [
      Text(step, style: GoogleFonts.sourceCodePro(fontSize: 11, color: AppColors.textDisabled, fontWeight: FontWeight.w600)),
      const SizedBox(width: 14),
      Container(width: 36, height: 36, decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: AppColors.textSecondary, size: 18)),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        const SizedBox(height: 2),
        Text(subtitle, style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted, height: 1.4)),
      ])),
    ]),
  );
}
