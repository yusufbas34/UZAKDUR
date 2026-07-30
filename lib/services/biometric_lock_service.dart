import 'package:local_auth/local_auth.dart';

class BiometricLockService {
  static final _auth = LocalAuthentication();

  /// Cihazda biyometri veya ekran kilidi (PIN/desen) kurulu değilse ya da
  /// donanım desteklemiyorsa true döner — bu durumda kilit ekranı hiç
  /// gösterilmemeli (kullanıcıyı uygulamadan kilitli tutmamak için).
  static Future<bool> isAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final canCheck = await _auth.canCheckBiometrics;
      if (canCheck) return true;
      // Biyometri yok ama cihaz desteklendiği bildiriliyorsa (ör. sadece
      // PIN/desen kurulu) yine de authenticate() cihaz kimlik bilgisiyle
      // devam edebilir.
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Devam etmek için kimliğini doğrula',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }
}
