import 'dart:async';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_database/firebase_database.dart';

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

class ZoneData {
  final String id;
  final String label;
  final double lat;
  final double lon;
  final double radius;
  const ZoneData({required this.id, required this.label, required this.lat, required this.lon, required this.radius});

  factory ZoneData.fromMap(String id, Map<dynamic, dynamic> map) => ZoneData(
        id: id,
        label: (map['label'] as String?) ?? 'Bölge',
        lat: (map['lat'] as num).toDouble(),
        lon: (map['lon'] as num).toDouble(),
        radius: ((map['radius'] as num?) ?? 100).toDouble(),
      );
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
  final List<ZoneData> zones;
  final List<EmergencyContact> emergencyContacts;
  const PairData({
    required this.id,
    required this.protectedDeviceId,
    required this.trackedDeviceId,
    required this.threshold,
    required this.alarmSound,
    this.distanceRequest,
    this.zones = const [],
    this.emergencyContacts = const [],
  });

  factory PairData.fromMap(String id, Map<dynamic, dynamic> map) => PairData(
        id: id,
        protectedDeviceId: map['protectedDeviceId'] as String,
        trackedDeviceId: map['trackedDeviceId'] as String,
        threshold: ((map['threshold'] as num?) ?? 100).toDouble(),
        alarmSound: (map['alarmSound'] as String?) ?? 'siren',
        distanceRequest: (map['distanceRequest'] as Map?)?['value'] != null
            ? ((map['distanceRequest']['value'] as num).toDouble())
            : null,
        zones: (map['zones'] as Map?)
                ?.entries
                .map((e) {
                  try { return ZoneData.fromMap(e.key as String, e.value as Map); } catch (_) { return null; }
                })
                .whereType<ZoneData>()
                .toList() ??
            const [],
        emergencyContacts: (map['emergencyContacts'] as Map?)
                ?.entries
                .map((e) {
                  try { return EmergencyContact.fromMap(e.key as String, e.value as Map); } catch (_) { return null; }
                })
                .whereType<EmergencyContact>()
                .toList() ??
            const [],
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
  static Future<void> registerDevice(String deviceId, String name, String role) =>
      _db.child('devices/$deviceId').update({
        'name': name,
        'role': role,
        'online': false,
        'createdAt': ServerValue.timestamp,
      });

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

  static Stream<Position> startLocationStream() => Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 3));

  static double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
