import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';

const kAlarmSounds = {
  'siren': 'Siren',
  'beep': 'Hızlı Bip',
  'classic': 'Klasik',
};

String alarmSoundAsset(String soundId) => 'sounds/alarm_$soundId.wav';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static final _player = AudioPlayer();
  static bool _alarming = false;

  static Future<void> init() async {
    await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    // Android 13+ (API 33) bildirim gösterebilmek için açık kullanıcı izni
    // istiyor; manifest'teki POST_NOTIFICATIONS izni tek başına yeterli
    // değil. Bu istenmeden alarm/pil/mesaj bildirimleri sessizce hiç
    // gösterilmez (alarmın sesi/titreşimi bu izne bağlı değil, o yüzden
    // "alarm çalışıyor ama bildirim hiç gelmiyor" hissi verir).
    //
    // Bu çağrı bir Activity'ye ihtiyaç duyuyor — arka plan servisinin kendi
    // isolate'inde (ekran/Activity yok) çağrıldığında eklenti null Context
    // üzerinden checkPermission çağırmaya çalışıp PlatformException
    // fırlatıyordu. İzin isteme zaten sadece ön planda (main.dart'ın ilk
    // çağrısında) anlamlı, o yüzden burada sessizce yutuluyor — kanal
    // oluşturma (aşağıda) buna bağımlı değil, o her isolate'te çalışmalı.
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'uzakdur_alarm', 'UZAKDUR Alarm',
          description: 'Yaklaşma uyarısı', importance: Importance.max, enableVibration: true,
        ));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'uzakdur_status', 'UZAKDUR Servis',
          description: 'Arka plan servisi', importance: Importance.low,
        ));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'uzakdur_battery', 'UZAKDUR Pil Uyarısı',
          description: 'Pil seviyesi düşük olduğunda uyarır', importance: Importance.high,
        ));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'uzakdur_admin_msg', 'UZAKDUR Admin Mesajı',
          description: 'Admin panelinden gönderilen mesajlar', importance: Importance.high,
        ));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'uzakdur_caution', 'UZAKDUR Yaklaşma Uyarısı',
          description: 'Tam alarm eşiğinden önceki erken titreşimli uyarı', importance: Importance.high,
        ));
    await _player.setReleaseMode(ReleaseMode.loop);
  }

  static Future<void> showAdminMessage(String text) async {
    await _plugin.show(
      104,
      '📨 Admin Mesajı',
      text,
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_admin_msg', 'UZAKDUR Admin Mesajı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
  }

  // Konum isteği sessizce karşılanmasın — kullanıcı bunu görebilsin diye
  // (uygulamanın "gizlice takip eden" değil, şeffaf/bilgilendiren bir araç
  // olması ilkesiyle tutarlı).
  static Future<void> showLocationRequestNotice() async {
    await _plugin.show(
      105,
      '📍 Konum İstendi',
      'Yönetici konumunu talep etti, anlık konumun paylaşıldı.',
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_admin_msg', 'UZAKDUR Admin Mesajı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
  }

  // Üç kademeli yaklaşma sistemi: mesafe sınırın (pair.threshold) %50'sinin
  // altına inince tam alarm (siren, startAlarm) çalar; %50-%80 arası KRİTİK
  // (bu metod — daha güçlü uyarı); %80-%100 arası SINIR (aşağıdaki
  // showBoundaryEnteredNotice — en hafif, ilk uyarı). Uzaklaştırılan taraf
  // için, tam alarma dönüşmeden önce kademeli olarak uzaklaşma şansı verir.
  static Future<void> showApproachWarning() async {
    await _plugin.show(
      106,
      '⚠️ KRİTİK — Yaklaşma Uyarısı',
      'Koruma altındaki kişiye hızla yaklaşmaktasınız. Lütfen ilgili birimlere haber verilmeden bulunduğunuz konumu değiştiriniz.',
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_caution', 'UZAKDUR Yaklaşma Uyarısı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 250, 150, 250]);
    }
  }

  // En hafif/ilk kademe — sınırın (eşiğin) içine yeni girildiğinde.
  static Future<void> showBoundaryEnteredNotice() async {
    await _plugin.show(
      108,
      '🔶 Sınır İçine Girildi',
      'Koruma altındaki kişiye yaklaşıyorsunuz. Mesafenizi kontrol edin.',
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_caution', 'UZAKDUR Yaklaşma Uyarısı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 150]);
    }
  }

  // Korunan kişinin düzenli kullandığı bir güzergaha (rota bölgesi)
  // yaklaşılıyor ama henüz içine girilmedi — tek seferlik uyarı, kademe
  // kötüleşmedikçe tekrar etmez. Her iki taraf da bilgilendirilir: uzaklaştırılana
  // kendi konumu, korunana ise uzaklaştırılanın kendi güzergahına yaklaştığı
  // söylenir.
  static Future<void> showRouteApproachNotice(String routeLabel, {required bool isProtectedSide}) async {
    final title = isProtectedSide ? '🟠 Uzaklaştırılan Yaklaşıyor' : '⚠️ Güzergaha Hızla Yaklaşılıyor';
    final body = isProtectedSide
        ? 'Uzaklaştırılan kişi "$routeLabel" güzergahınıza yaklaşıyor.'
        : '"$routeLabel" güzergahına hızla yaklaşıyorsunuz.';
    await _plugin.show(
      109,
      title,
      body,
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_caution', 'UZAKDUR Yaklaşma Uyarısı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 250, 150, 250]);
    }
  }

  // Güzergahın (koridorun) içine girildi — en ciddi rota kademesi, asla tam
  // alarm değil ama girişte bir kez ve içeride kalındığı sürece 30sn'de bir
  // tekrarlanır (bkz. monitor_screen.dart / foreground_task_service.dart).
  static Future<void> showRouteInsideNotice(String routeLabel, {required bool isProtectedSide}) async {
    final title = isProtectedSide ? '🔵 Uzaklaştırılan Güzergahınızda' : '🔴 Korumalı Güzergah İçindesiniz';
    final body = isProtectedSide
        ? 'Uzaklaştırılan kişi "$routeLabel" güzergahınızın içinde.'
        : '"$routeLabel" korumalı güzergahı içindesiniz. Lütfen güzergahınızı değiştirin.';
    await _plugin.show(
      110,
      title,
      body,
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_caution', 'UZAKDUR Yaklaşma Uyarısı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 150]);
    }
  }

  // Yasak bölgeye (daire) girildiğinde artık tam alarm ÇALMAZ — sadece
  // girişte bir kez bildirim + titreşim verir (bkz. monitor_screen.dart'ta
  // zone artık isAlarm hesabına dahil değil).
  static Future<void> showZoneEnteredNotice(String zoneLabel) async {
    await _plugin.show(
      111,
      '🚫 Yasak Bölgeye Girildi',
      '"$zoneLabel" bölgesine girdiniz.',
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_caution', 'UZAKDUR Yaklaşma Uyarısı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 300, 150, 300]);
    }
  }

  // Uzaklaştırılan tarafın pili bitmesi, takibin tamamen kesilmesi anlamına
  // gelir (güvenlik mekanizmasının kendisi çalışamaz olur) — bu yüzden o
  // taraf için metin daha vurgulu/acil.
  static Future<void> showBatteryWarning(int level, {required bool critical, bool isTracked = false}) async {
    final title = critical ? '🔴 Pil Kritik Seviyede (%$level)' : '🟠 Pil Azalıyor (%$level)';
    final body = critical
        ? (isTracked ? 'Takip kesilebilir — LÜTFEN HEMEN telefonu şarja tak!' : 'Takip kesilebilir — telefonu en kısa sürede şarja tak.')
        : (isTracked ? 'Pilin biterse takip kesilir. Şarja takmayı unutma.' : 'Konum paylaşımının kesilmemesi için telefonu şarja takmayı unutma.');
    await _plugin.show(
      critical ? 103 : 102,
      title,
      body,
      const NotificationDetails(android: AndroidNotificationDetails(
        'uzakdur_battery', 'UZAKDUR Pil Uyarısı',
        importance: Importance.high, priority: Priority.high,
      )),
    );
  }

  static Future<void> startAlarm(double distance, {String soundId = 'siren'}) async {
    if (_alarming) return;
    _alarming = true;
    await _plugin.show(101, '⚠️  YAKLAŞMA ALGILANDI',
        'Mesafe: ${distance.round()} metre — Uzaklaşın!',
        const NotificationDetails(
            android: AndroidNotificationDetails('uzakdur_alarm', 'UZAKDUR Alarm',
                importance: Importance.max, priority: Priority.max,
                fullScreenIntent: true, ongoing: true, autoCancel: false,
                color: Color(0xFFFF3B30), category: AndroidNotificationCategory.alarm)));
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 600, 150, 600, 150, 900], repeat: 2);
    }
    try {
      await _player.play(AssetSource(alarmSoundAsset(soundId)), volume: 1.0);
    } catch (_) {}
  }

  static Future<void> stopAlarm() async {
    if (!_alarming) return;
    _alarming = false;
    await _plugin.cancel(101);
    Vibration.cancel();
    try { await _player.stop(); } catch (_) {}
  }

  static bool get isAlarming => _alarming;
}
