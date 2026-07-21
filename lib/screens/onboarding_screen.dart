import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/roles.dart';
import '../services/location_service.dart';
import '../services/disguise_service.dart';
import '../theme/app_theme.dart';
import 'monitor_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  String? _role;
  bool _saving = false;
  bool _disguise = false;
  bool _obscurePassword = true;
  String? _error;

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (email.isEmpty || !_emailRegex.hasMatch(email)) { setState(() => _error = 'Geçerli bir e-posta gerekli.'); return; }
    if (password.length < 4) { setState(() => _error = 'Şifre en az 4 karakter olmalı.'); return; }
    setState(() { _saving = true; _error = null; });
    try {
      // Bu e-posta ile daha önce kayıt olunmuşsa (ör. uygulama silinip
      // tekrar kurulduğunda) yeni bir cihaz oluşturmak yerine mevcut hesaba
      // giriş yapılır — böylece admin panelinde kopya kayıt oluşmaz. Her
      // e-posta yalnızca bir cihaza bağlı olabilir.
      final account = await LocationService.findAccountByEmail(email);

      if (account != null) {
        final hash = LocationService.hashPassword(account.email, password);
        if (hash != account.passwordHash) {
          setState(() { _error = 'Bu e-posta zaten kayıtlı ama şifre yanlış. Şifreni mi unuttun?'; _saving = false; });
          return;
        }
        final p = await SharedPreferences.getInstance();
        await p.setString('device_id', account.deviceId);
        await p.setString('device_name', account.name);
        await p.setString('device_role', account.role);
        if (!mounted) return;
        Navigator.pushReplacement(context, PageRouteBuilder(
          pageBuilder: (_, a, __) => MonitorScreen(deviceId: account.deviceId, name: account.name, role: account.role),
          transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ));
        return;
      }

      if (name.isEmpty) { setState(() { _error = 'İsim gerekli.'; _saving = false; }); return; }
      if (_role == null) { setState(() { _error = 'Rol seçmelisin.'; _saving = false; }); return; }

      final deviceId = LocationService.generateDeviceId();
      final passwordHash = LocationService.hashPassword(email, password);
      await LocationService.registerDevice(deviceId, name, _role!, email: email, passwordHash: passwordHash);
      final p = await SharedPreferences.getInstance();
      await p.setString('device_id', deviceId);
      await p.setString('device_name', name);
      await p.setString('device_role', _role!);
      if (_role == kRoleProtected && _disguise) {
        await DisguiseService.apply();
        await p.setBool('app_disguised', true);
      }
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

  Future<void> _showForgotPassword() async {
    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final newPassCtrl = TextEditingController();
    String? error;
    bool sending = false;
    bool sent = false;
    await showModalBottomSheet(
      context: context, backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: 24 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Şifremi Unuttum', style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Text('Gerçek zamanlı e-posta gönderimi yok; talebin yöneticiye iletilir, o onaylayınca yeni şifrenle giriş yapabilirsin.',
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.textMuted, height: 1.5)),
          const SizedBox(height: 20),
          if (sent) ...[
            Text('Talep gönderildi. Yönetici onayladıktan sonra yeni şifrenle giriş yapabilirsin.',
                style: GoogleFonts.inter(fontSize: 13, color: AppColors.safe, height: 1.5)),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: Text('Kapat', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ),
            )),
          ] else ...[
            _buildField(emailCtrl, 'Kayıtlı e-postan', keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 12),
            _buildField(newPassCtrl, 'Yeni şifre (en az 4 karakter)', obscure: true),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!, style: GoogleFonts.inter(fontSize: 12, color: AppColors.danger)),
            ],
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: GestureDetector(
              onTap: sending ? null : () async {
                final e = emailCtrl.text.trim();
                final np = newPassCtrl.text;
                if (e.isEmpty || !_emailRegex.hasMatch(e)) { setSheet(() => error = 'Geçerli bir e-posta gir.'); return; }
                if (np.length < 4) { setSheet(() => error = 'Yeni şifre en az 4 karakter olmalı.'); return; }
                setSheet(() { sending = true; error = null; });
                final ok = await LocationService.requestPasswordReset(e, np);
                if (!ok) { setSheet(() { sending = false; error = 'Bu e-postayla kayıtlı bir hesap bulunamadı.'; }); return; }
                setSheet(() { sending = false; sent = true; });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(color: sending ? AppColors.surfaceHigh : AppColors.danger, borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: Text(sending ? 'Gönderiliyor…' : 'Sıfırlama Talebi Gönder', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            )),
          ],
        ]),
      )),
    );
    emailCtrl.dispose();
    newPassCtrl.dispose();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Widget _buildField(TextEditingController ctrl, String hint, {bool obscure = false, TextInputType? keyboardType, Widget? suffix}) => TextField(
    controller: ctrl,
    obscureText: obscure,
    keyboardType: keyboardType,
    style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(color: AppColors.textDisabled),
      filled: true, fillColor: AppColors.surface,
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppColors.roleA.withOpacity(0.6))),
    ),
  );

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
        const SizedBox(height: 10),
        Text('Uygulamayı silip tekrar kurarsan, aynı e-posta ve şifreyle giriş yaparak eski cihazına devam edebilirsin — yeni kayıt oluşmaz. Her e-posta yalnızca bir cihaza ait olabilir.',
            style: GoogleFonts.inter(fontSize: 12, color: AppColors.textMuted, height: 1.5)),
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
        const SizedBox(height: 24),
        Text('E-POSTA', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
        const SizedBox(height: 12),
        _buildField(_emailCtrl, 'ornek@mail.com', keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 20),
        Text('ŞİFRE', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textMuted, letterSpacing: 2)),
        const SizedBox(height: 12),
        _buildField(_passwordCtrl, 'En az 4 karakter', obscure: _obscurePassword, suffix: IconButton(
          icon: Icon(_obscurePassword ? Icons.visibility_rounded : Icons.visibility_off_rounded, color: AppColors.textMuted, size: 20),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        )),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _showForgotPassword,
          child: Text('Şifremi unuttum', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.roleB)),
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
        const SizedBox(height: 8),
        Text('Not: Girdiğin kullanıcı adı/e-posta zaten kayıtlıysa ve şifre doğruysa, rol seçimi dikkate alınmadan doğrudan mevcut hesabına giriş yapılır.',
            style: GoogleFonts.inter(fontSize: 11, color: AppColors.textDisabled, height: 1.4)),
        if (_role == kRoleProtected) ...[
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _disguise = !_disguise),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _disguise ? AppColors.roleB.withOpacity(0.1) : AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _disguise ? AppColors.roleB.withOpacity(0.5) : AppColors.border),
              ),
              child: Row(children: [
                Icon(_disguise ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    color: _disguise ? AppColors.roleB : AppColors.textDisabled, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Uygulama simgesini gizle', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text('Ana ekranda "Notlarım" adıyla, farklı bir simgeyle görünür. Daha sonra ayarlardan kapatabilirsin.',
                      style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted, height: 1.4)),
                ])),
              ]),
            ),
          ),
        ],
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
