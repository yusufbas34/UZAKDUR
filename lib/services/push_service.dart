import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_service.dart';

// Sunucu (Apps Script), bir cihazın konumu ~30 dakikadır güncellenmemişse
// bu "type: request_location" veri mesajını FCM ile gönderir. Bu, garantili
// bir mekanizma değil — sadece ek bir güvenlik katmanı; asıl güvence
// foreground service ve WorkManager bekçisidir. OEM pil yönetimleri veya
// derin Doze modu bu mesajın ulaşmasını engelleyebilir.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await _handleLocationRequest(message);
}

Future<void> _handleLocationRequest(RemoteMessage message) async {
  if (message.data['type'] != 'request_location') return;
  final prefs = await SharedPreferences.getInstance();
  final deviceId = prefs.getString('device_id');
  if (deviceId == null) return;
  try {
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.medium,
      timeLimit: const Duration(seconds: 15),
    );
    await LocationService.writeLocation(deviceId, pos.latitude, pos.longitude);
  } catch (_) {
    // Sessiz başarısızlık: pencere kapanmış, konum servisi kapalı ya da
    // izin yoksa burada yapabileceğimiz bir şey yok — bir sonraki normal
    // arka plan döngüsü ya da WorkManager bekçisi devam edecek.
  }
}

class PushService {
  static Future<void> registerBackgroundHandler() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  static Future<void> init(String deviceId) async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: false, badge: false, sound: false);
      FirebaseMessaging.onMessage.listen(_handleLocationRequest);
      final token = await messaging.getToken();
      if (token != null) await LocationService.saveFcmToken(deviceId, token);
      messaging.onTokenRefresh.listen((t) => LocationService.saveFcmToken(deviceId, t));
    } catch (_) {
      // Google Play Services olmayan cihazlarda FCM kurulamayabilir;
      // bu durumda uygulama diğer takip mekanizmalarıyla çalışmaya devam eder.
    }
  }
}
