import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_database/firebase_database.dart';

// Üç kademeli yaklaşma sistemi — pair.threshold'a (admin/telefon tarafından
// ayarlanan "sınır") oranla: mesafe sınırın %50'sinin altındaysa ACİL (tam
// alarm/siren), %50-%80 arasıysa KRİTİK, %80-%100 arasıysa SINIR (yeni
// girildi, en hafif uyarı). Sabit bir mesafe (ör. 1000m) yok — tamamen
// eşiğe oranla belirleniyor.
const kAcilRatio = 0.5;
const kKritikRatio = 0.8;

class DeviceAccount {
  final String deviceId;
  final String name;
  final String role;
  final String email;
  final String passwordHash;
  const DeviceAccount({
    required this.deviceId,
    required this.name,
    required this.role,
    required this.email,
    required this.passwordHash,
  });
}

class LocationData {
  final double lat;
  final double lon;
  final DateTime timestamp;
  const LocationData({required this.lat, required this.lon, required this.timestamp});
  factory LocationData.fromMap(Map<dynamic, dynamic> map) => LocationData(
        lat: (map['lat'] as num).toDouble(),
        lon: (map['lon'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch((map['ts'] as num).toInt()),
      );
}

class RoutePoint {
  final double lat;
  final double lon;
  const RoutePoint(this.lat, this.lon);
}

// Yasak bölgeler iki şekilde olabilir: 'circle' (nokta + yarıçap, mevcut —
// tam alarm tetikler) ya da 'route' (korunan kişinin düzenli kullandığı bir
// güzergah, çoklu nokta + koridor genişliği — sadece kademeli kritik/sınır
// uyarısı verir, asla tam alarm tetiklemez; bkz. monitor_screen.dart).
class ZoneData {
  final String id;
  final String label;
  final String type; // 'circle' | 'route'
  final double lat;
  final double lon;
  final double radius;
  final List<RoutePoint> points;
  final double width;
  const ZoneData({
    required this.id,
    required this.label,
    this.type = 'circle',
    this.lat = 0,
    this.lon = 0,
    this.radius = 0,
    this.points = const [],
    this.width = 0,
  });

  factory ZoneData.fromMap(String id, Map<dynamic, dynamic> map) {
    final type = (map['type'] as String?) ?? 'circle';
    if (type == 'route') {
      final rawPoints = map['points'];
      final points = <RoutePoint>[];
      if (rawPoints is List) {
        for (final p in rawPoints) {
          if (p is Map) {
            try {
              points.add(RoutePoint((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()));
            } catch (_) {}
          }
        }
      }
      return ZoneData(
        id: id,
        label: (map['label'] as String?) ?? 'Yol',
        type: 'route',
        points: points,
        width: ((map['width'] as num?) ?? 80).toDouble(),
      );
    }
    return ZoneData(
      id: id,
      label: (map['label'] as String?) ?? 'Bölge',
      lat: (map['lat'] as num).toDouble(),
      lon: (map['lon'] as num).toDouble(),
      radius: ((map['radius'] as num?) ?? 100).toDouble(),
    );
  }

  // Bir konumun bu bölgeye olan mesafesi: daire için merkeze, rota için en
  // yakın segmente olan dik mesafedir.
  double distanceFrom(double lat2, double lon2) {
    if (type == 'route') return _minDistanceToRoute(lat2, lon2, points);
    return LocationService.calculateDistance(lat2, lon2, lat, lon);
  }

  // Daire için yarıçap, rota için koridor genişliği — ikisi de "bu mesafenin
  // altına girilince bölgeye girilmiş sayılır" eşiğidir.
  double get threshold => type == 'route' ? width : radius;
}

double _minDistanceToRoute(double lat, double lon, List<RoutePoint> points) {
  if (points.isEmpty) return double.infinity;
  if (points.length == 1) return LocationService.calculateDistance(lat, lon, points[0].lat, points[0].lon);
  double best = double.infinity;
  for (var i = 0; i < points.length - 1; i++) {
    final d = _distanceToSegment(lat, lon, points[i], points[i + 1]);
    if (d < best) best = d;
  }
  return best;
}

// Koridor genişliği ölçeğinde (onlarca-yüzlerce metre) haversine yerine
// basit yerel düzlemsel izdüşüm kullanılıyor — bu mesafede fark ihmal
// edilebilir düzeyde ama hesap çok daha basit (nokta-segment dik mesafe
// formülü küresel koordinatlarda yok).
double _distanceToSegment(double lat, double lon, RoutePoint a, RoutePoint b) {
  final mPerDegLat = 110540.0;
  final mPerDegLon = 111320.0 * cos(a.lat * pi / 180);
  final ax = 0.0, ay = 0.0;
  final bx = (b.lon - a.lon) * mPerDegLon, by = (b.lat - a.lat) * mPerDegLat;
  final px = (lon - a.lon) * mPerDegLon, py = (lat - a.lat) * mPerDegLat;
  final abx = bx - ax, aby = by - ay;
  final len2 = abx * abx + aby * aby;
  var t = len2 > 0 ? ((px - ax) * abx + (py - ay) * aby) / len2 : 0.0;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * abx, cy = ay + t * aby;
  final dx = px - cx, dy = py - cy;
  return sqrt(dx * dx + dy * dy);
}

class EmergencyContact {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String type; // 'family' (yakın) veya 'authority' (yetkili/polis)
  const EmergencyContact({required this.id, required this.name, this.phone, this.email, this.type = 'family'});

  factory EmergencyContact.fromMap(String id, Map<dynamic, dynamic> map) => EmergencyContact(
        id: id,
        name: (map['name'] as String?) ?? '',
        phone: map['phone'] as String?,
        email: map['email'] as String?,
        type: (map['type'] as String?) ?? 'family',
      );
}

class PairData {
  final String id;
  final String protectedDeviceId;
  final String trackedDeviceId;
  final double threshold;
  final String alarmSound;
  final double? distanceRequest;
  // Varsayılan olarak kapalı: uzaklaştırılan taraf, korunan tarafın
  // konumunu haritada GÖRMEZ — yalnızca mesafe eşiği aşıldığında alarm
  // alır. Bu, admin panelinden istisnai olarak (ör. mahkeme kararı
  // gerektiriyorsa) açılabilecek bir izin bayrağıdır.
  final bool trackedCanSeeLocation;
  const PairData({
    required this.id,
    required this.protectedDeviceId,
    required this.trackedDeviceId,
    required this.threshold,
    required this.alarmSound,
    this.distanceRequest,
    this.trackedCanSeeLocation = false,
  });

  // Not: yasak bölgeler ve acil durum kişileri artık pair'e değil, korunan
  // cihaza (devices/{protectedDeviceId}/zones ve /emergencyContacts) bağlı
  // tutulur. Böylece bir eşleşme kaldırılıp aynı ikili arasında yeniden
  // kurulduğunda (ya da korunan başka bir uzaklaştırılanla eşleştiğinde) bu
  // bilgiler kaybolmaz — LocationService.listenDeviceZones /
  // listenDeviceContacts ile ayrıca dinlenir.
  factory PairData.fromMap(String id, Map<dynamic, dynamic> map) => PairData(
        id: id,
        protectedDeviceId: map['protectedDeviceId'] as String,
        trackedDeviceId: map['trackedDeviceId'] as String,
        threshold: ((map['threshold'] as num?) ?? 100).toDouble(),
        alarmSound: (map['alarmSound'] as String?) ?? 'siren',
        distanceRequest: (map['distanceRequest'] as Map?)?['value'] != null
            ? ((map['distanceRequest']['value'] as num).toDouble())
            : null,
        trackedCanSeeLocation: (map['trackedCanSeeLocation'] as bool?) ?? false,
      );

  String otherDeviceId(String myDeviceId) =>
      myDeviceId == protectedDeviceId ? trackedDeviceId : protectedDeviceId;
}

enum LocationPermissionResult { granted, denied, deniedForever, serviceDisabled }

class LocationService {
  static final _db = FirebaseDatabase.instance.ref();

  static String generateDeviceId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(12, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  static Future<LocationPermissionResult> requestPermissions() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationPermissionResult.serviceDisabled;
    LocationPermission p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied) return LocationPermissionResult.denied;
    }
    if (p == LocationPermission.deniedForever) return LocationPermissionResult.deniedForever;
    return LocationPermissionResult.granted;
  }

  // --- Device registry ---
  // Şifre asla düz metin tutulmaz; e-postaya bağlı basit bir tuzla (salt)
  // hash'lenir. Firebase kuralları herkese açık okuma izni verdiği için bu,
  // kurumsal düzeyde değil ama en azından düz metin şifre sızıntısını ve
  // basit hash eşleşmesini önleyen asgari bir korumadır.
  static String hashPassword(String email, String password) {
    final salted = '${email.trim().toLowerCase()}::$password::uzakdur-v2';
    return sha256.convert(utf8.encode(salted)).toString();
  }

  static Future<void> registerDevice(
    String deviceId,
    String name,
    String role, {
    required String email,
    required String passwordHash,
    bool kvkkAccepted = false,
    String? phone,
  }) =>
      _db.child('devices/$deviceId').update({
        'name': name,
        'role': role,
        'email': email,
        'passwordHash': passwordHash,
        'online': false,
        'createdAt': ServerValue.timestamp,
        if (kvkkAccepted) 'kvkkAcceptedAt': ServerValue.timestamp,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      });

  // Her e-posta yalnızca bir cihaza ait olabilir; cihaz silinip yeniden
  // kurulduğunda aynı e-posta + şifre ile tekrar kayıt yerine mevcut hesaba
  // giriş yapılabilsin diye tüm devices koleksiyonu taranır (küçük ölçek
  // için pahalı değil).
  static Future<DeviceAccount?> findAccountByEmail(String email) async {
    final needle = email.trim().toLowerCase();
    if (needle.isEmpty) return null;
    final snap = await _db.child('devices').get();
    if (!snap.exists || snap.value == null) return null;
    final v = snap.value;
    if (v is! Map) return null;
    for (final entry in v.entries) {
      final data = entry.value;
      if (data is! Map) continue;
      final accountEmail = (data['email'] as String?)?.trim().toLowerCase();
      final hash = data['passwordHash'] as String?;
      if (hash == null || accountEmail == null || accountEmail.isEmpty) continue;
      if (accountEmail == needle) {
        return DeviceAccount(
          deviceId: entry.key as String,
          name: (data['name'] as String?) ?? '',
          role: (data['role'] as String?) ?? '',
          email: accountEmail,
          passwordHash: hash,
        );
      }
    }
    return null;
  }

  // --- Şifremi unuttum: admin onaylı sıfırlama ---
  // Gerçek bir e-posta sunucusu olmadığı için (ücretsiz/sunucusuz kurulum),
  // kullanıcı yeni şifresini kendi seçer ve bir talep oluşturur; yönetici
  // web panelinden onaylayınca yeni şifre devreye girer. Talep onaylanana
  // kadar eski şifre geçerli kalır.
  static Future<bool> requestPasswordReset(String email, String newPassword) async {
    final account = await findAccountByEmail(email);
    if (account == null) return false;
    final newHash = hashPassword(account.email, newPassword);
    await _db.child('devices/${account.deviceId}/passwordResetRequest').set({
      'passwordHash': newHash,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    return true;
  }

  static Future<void> setOnline(String deviceId, bool online) =>
      _db.child('devices/$deviceId').update({'online': online, 'ts': DateTime.now().millisecondsSinceEpoch});

  static Future<void> heartbeat(String deviceId) =>
      _db.child('devices/$deviceId').update({'ts': DateTime.now().millisecondsSinceEpoch});

  static Future<void> writeBattery(String deviceId, int level) =>
      _db.child('devices/$deviceId/battery').set(level);

  static StreamSubscription<DatabaseEvent> listenDevice(String deviceId, void Function(Map<dynamic, dynamic>?) onData) =>
      _db.child('devices/$deviceId').onValue.listen((e) => onData(e.snapshot.value as Map<dynamic, dynamic>?));

  static StreamSubscription<DatabaseEvent> listenOtherOnline(String otherDeviceId, void Function(bool) onData) =>
      _db.child('devices/$otherDeviceId/online').onValue.listen((e) => onData(e.snapshot.value == true));

  // --- Pairing ---
  // Bir cihazın eşleşmeleri devices altında ayrı bir alanda tutulmaz; her
  // zaman pairs koleksiyonunun tamamından süzülür, böylece kopya bir referans
  // asla senkron dışı kalamaz. Bir cihaz aynı anda birden fazla eşleşmede
  // (ör. 1 korunan – 2..4 uzaklaştırılan) yer alabilir.
  static StreamSubscription<DatabaseEvent> listenPairsForDevice(
          String deviceId, void Function(Map<String, PairData>) onData) =>
      _db.child('pairs').onValue.listen((e) {
        final v = e.snapshot.value;
        final result = <String, PairData>{};
        if (v is Map) {
          v.forEach((key, value) {
            try {
              final pd = PairData.fromMap(key as String, value as Map);
              if (pd.protectedDeviceId == deviceId || pd.trackedDeviceId == deviceId) {
                result[pd.id] = pd;
              }
            } catch (_) {}
          });
        }
        onData(result);
      });

  static Future<void> requestDistanceChange(String pairId, double meters) =>
      _db.child('pairs/$pairId/distanceRequest').set({'value': meters, 'ts': DateTime.now().millisecondsSinceEpoch});

  static Future<void> setAlarmSound(String pairId, String soundId) =>
      _db.child('pairs/$pairId/alarmSound').set(soundId);

  // Yasak bölgeler ve acil durum kişileri korunan cihaza bağlıdır (pair'e
  // değil) ki eşleşme kaldırılıp yeniden kurulduğunda kaybolmasın.
  static StreamSubscription<DatabaseEvent> listenDeviceZones(
          String protectedDeviceId, void Function(List<ZoneData>) onData) =>
      _db.child('devices/$protectedDeviceId/zones').onValue.listen((e) {
        final v = e.snapshot.value;
        final result = <ZoneData>[];
        if (v is Map) {
          v.forEach((key, value) {
            try { result.add(ZoneData.fromMap(key as String, value as Map)); } catch (_) {}
          });
        }
        onData(result);
      });

  static StreamSubscription<DatabaseEvent> listenDeviceContacts(
          String protectedDeviceId, void Function(List<EmergencyContact>) onData) =>
      _db.child('devices/$protectedDeviceId/emergencyContacts').onValue.listen((e) {
        final v = e.snapshot.value;
        final result = <EmergencyContact>[];
        if (v is Map) {
          v.forEach((key, value) {
            try { result.add(EmergencyContact.fromMap(key as String, value as Map)); } catch (_) {}
          });
        }
        onData(result);
      });

  // Korunan, acil durum kişisi ekleme/çıkarma işlemini doğrudan yapamaz;
  // yöneticinin web panelinden onaylaması gereken bir talep oluşturur.
  // protectedDeviceId, talebi gönderen korunan kişinin kendi deviceId'sidir.
  // Sunucu tarafı (Apps Script), bir cihaz 30 dakikadır konum göndermemişse
  // bu token'a FCM ile sessiz bir "konum iste" mesajı gönderir.
  static Future<void> saveFcmToken(String deviceId, String token) =>
      _db.child('devices/$deviceId').update({'fcmToken': token});

  static Future<void> requestAddContact(String protectedDeviceId, {required String name, String? phone, String? email, String type = 'family'}) =>
      _db.child('devices/$protectedDeviceId/contactRequests').push().set({
        'type': 'add',
        'name': name,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (email != null && email.isNotEmpty) 'email': email,
        'contactType': type,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

  static Future<void> requestRemoveContact(String protectedDeviceId, String contactId, String contactName) =>
      _db.child('devices/$protectedDeviceId/contactRequests').push().set({
        'type': 'remove',
        'targetContactId': contactId,
        'targetName': contactName,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

  // --- Location ---
  static Future<void> writeLocation(String deviceId, double lat, double lon) =>
      _db.child('locations/$deviceId').set({'lat': lat, 'lon': lon, 'ts': DateTime.now().millisecondsSinceEpoch});

  static Future<LocationData?> getLocationOnce(String deviceId) async {
    final snap = await _db.child('locations/$deviceId').get();
    if (!snap.exists || snap.value == null) return null;
    try { return LocationData.fromMap(snap.value as Map); } catch (_) { return null; }
  }

  static StreamSubscription<DatabaseEvent> listenOtherLocation(String otherDeviceId, void Function(LocationData) onData) =>
      _db.child('locations/$otherDeviceId').onValue.listen((e) {
        final v = e.snapshot.value;
        if (v == null) return;
        try { onData(LocationData.fromMap(v as Map)); } catch (_) {}
      });

  static Future<void> writeAlarmLog(String pairId, String deviceId, double distance, {String type = 'proximity', String? zoneLabel}) =>
      _db.child('alarm_log/$pairId').push().set({
        'byDeviceId': deviceId,
        'distance': distance.round(),
        'type': type,
        if (zoneLabel != null) 'zoneLabel': zoneLabel,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

  // bestForNavigation, sürekli en yüksek frekanslı GPS+sensör füzyonunu
  // zorlayıp pili gereksiz yere hızlı tüketir (yol tarifi gibi kullanımlar
  // için tasarlanmış); bir yaklaşma alarmı için "high" yeterli hassasiyeti
  // çok daha az güç harcayarak verir. distanceFilter'ın 3m'den 8m'ye
  // çıkarılması da her küçük kıpırdanışta konum yazıp radyoyu uyandırmak
  // yerine, gerçek harekette güncelleme yapılmasını sağlar.
  static Stream<Position> startLocationStream() => Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 8));

  static double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
