import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/roles.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import 'monitor_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nameCtrl = TextEditingController();
  String? _role;
  bool _saving = false;
  String? _error;

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) { setState(() => _error = 'İsim gerekli.'); return; }
    if (_role == null) { setState(() => _error = 'Rol seçmelisin.'); return; }
    setState(() { _saving = true; _error = null; });
    try {
      final deviceId = LocationService.generateDeviceId();
      await LocationService.registerDevice(deviceId, name, _role!);
      final p = await SharedPreferences.getInstance();
      await p.setString('device_id', deviceId);
      await p.setString('device_name', name);
      await p.setString('device_role', _role!);
      if (!mounted) return;
      Navigator.pushReplacement(context, PageRouteBuilder(
        pageBuilder: (_, a, __) => MonitorScreen(deviceId: deviceId, name: name, role: _role!),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Kayıt başarısız: $e'; _saving = false; });
    }
  }

  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.bg,
    body: SafeArea(child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 40),
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: AppColors.danger.withOpacity(0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.danger.withOpacity(0.3))),
            child: const Icon(Icons.radar, color: AppColors.danger, size: 22),
          ),
          const SizedBox(width: 12),
          Text('UZAKDUR', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: 3)),
        ]),
        const SizedBox(height: 36),
        Text('Cihazı Tanıt', style: GoogleFonts.inter(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        const SizedBox(height: 12),
        Text('Bu bilgiler bir kez girilir. Cihaz eşleştirmesi ve mesafe\nayarları yönetici tarafından web panelinden yapılır.',
            style: GoogleFonts.inter(fontSize: 14, color: AppColors.textSecondary, height: 1.6)),
        const SizedBox(height: 36),
        Text('İSİM', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
        const SizedBox(height: 12),
        TextField(
          controller: _nameCtrl,
          style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
          decoration: InputDecoration(
            hintText: 'Örn. Ahmet',
            hintStyle: GoogleFonts.inter(color: AppColors.textDisabled),
            filled: true, fillColor: AppColors.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppColors.roleA.withOpacity(0.6))),
          ),
        ),
        const SizedBox(height: 32),
        Text('ROLÜNÜ SEÇ', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
        const SizedBox(height: 12),
        _RoleTile(
          selected: _role == kRoleProtected, color: AppColors.roleB,
          icon: Icons.shield_rounded, title: 'Korunan',
          subtitle: 'Alarmı alan kişi. Mesafe talebinde bulunabilir ve alarm sesini değiştirebilir.',
          onTap: () => setState(() => _role = kRoleProtected),
        ),
        const SizedBox(height: 12),
        _RoleTile(
          selected: _role == kRoleTracked, color: AppColors.roleA,
          icon: Icons.person_pin_circle_rounded, title: 'Uzaklaştırılan',
          subtitle: 'Takip edilen kişi. Ayar değiştiremez.',
          onTap: () => setState(() => _role = kRoleTracked),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: GoogleFonts.inter(fontSize: 12, color: AppColors.danger)),
        ],
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: GestureDetector(
            onTap: _saving ? null : _submit,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: _saving ? AppColors.surfaceHigh : AppColors.danger,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('Kaydol ve Başla', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ),
        const SizedBox(height: 40),
      ]),
    )),
  );
}

class _RoleTile extends StatelessWidget {
  final bool selected; final Color color; final IconData icon; final String title, subtitle;
  final VoidCallback onTap;
  const _RoleTile({required this.selected, required this.color, required this.icon, required this.title, required this.subtitle, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: selected ? color.withOpacity(0.1) : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: selected ? color.withOpacity(0.6) : AppColors.border, width: selected ? 1.5 : 1),
      ),
      child: Row(children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 22)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 3),
          Text(subtitle, style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted, height: 1.4)),
        ])),
        Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined, color: selected ? color : AppColors.textDisabled, size: 20),
      ]),
    ),
  );
}
