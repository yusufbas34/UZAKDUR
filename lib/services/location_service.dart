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

enum LocationPermissionResult { granted, denied, deniedForever, serviceDisabled }

class LocationService {
  static final _db = FirebaseDatabase.instance.ref();

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

  static Future<void> writeLocation(String role, double lat, double lon) =>
      _db.child('locations/$role').set({'lat': lat, 'lon': lon, 'ts': DateTime.now().millisecondsSinceEpoch});

  static Future<void> setOnline(String role, bool online) =>
      _db.child('status/$role').set({'online': online, 'ts': DateTime.now().millisecondsSinceEpoch});

  static Future<void> writeAlarmLog(String role, double distance) =>
      _db.child('alarm_log').push().set({'role': role, 'distance': distance.round(), 'ts': DateTime.now().millisecondsSinceEpoch});

  static StreamSubscription<DatabaseEvent> listenOtherLocation(String role, void Function(LocationData) onData) =>
      _db.child('locations/$role').onValue.listen((e) {
        final v = e.snapshot.value;
        if (v == null) return;
        try { onData(LocationData.fromMap(v as Map)); } catch (_) {}
      });

  static StreamSubscription<DatabaseEvent> listenOtherStatus(String role, void Function(bool) onData) =>
      _db.child('status/$role').onValue.listen((e) {
        final v = e.snapshot.value;
        if (v == null) { onData(false); return; }
        try { onData((v as Map)['online'] == true); } catch (_) { onData(false); }
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
