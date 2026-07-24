import 'package:flutter/services.dart';

// Android'de gerçek, şifreyle korunan bir "silme engeli" yok — bu servis,
// uygulamayı silmeden önce Cihaz Yöneticisi iznini elle kapatmayı zorunlu
// kılan tek genel mekanizmayı kullanıyor. Asıl koruma silmeyi engellemek
// değil (mümkün değil), bu adımın anında yakalanıp yöneticiye bildirilmesi
// (bkz. android/.../UzakdurDeviceAdminReceiver.java, onDisabled).
class DeviceAdminService {
  static const _channel = MethodChannel('uzakdur/device_admin');

  static Future<bool> isActive() async {
    try {
      return await _channel.invokeMethod<bool>('isActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestActivation() async {
    try {
      await _channel.invokeMethod('requestActivation');
    } catch (_) {}
  }
}
