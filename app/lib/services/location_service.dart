import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

// ---------------------------------------------------------------------------
// Accuracy tier
// ---------------------------------------------------------------------------

enum LocationAccuracyTier { excellent, good, fair, poor }

/// Immutable value object holding a single GPS fix.
class GpsLocation {
  final double latitude;
  final double longitude;
  final double accuracy; // metres
  final DateTime timestamp;

  const GpsLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  // -------------------------------------------------------------------------
  // Distance / bearing
  // -------------------------------------------------------------------------

  /// Haversine distance in metres between two GPS fixes.
  static double distanceMeters(GpsLocation a, GpsLocation b) {
    const r = 6371000.0; // Earth radius in metres
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final sinDlat = sin(dLat / 2);
    final sinDlon = sin(dLon / 2);
    final x = sinDlat * sinDlat + cos(lat1) * cos(lat2) * sinDlon * sinDlon;
    return 2 * r * asin(sqrt(x));
  }

  /// True bearing from [from] to [to] in degrees (0–360).
  static double bearingDeg(GpsLocation from, GpsLocation to) {
    final dLon = (to.longitude - from.longitude) * pi / 180;
    final lat1 = from.latitude * pi / 180;
    final lat2 = to.latitude * pi / 180;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  // -------------------------------------------------------------------------
  // Accuracy tier
  // -------------------------------------------------------------------------

  LocationAccuracyTier get accuracyTier {
    if (accuracy < 5) return LocationAccuracyTier.excellent;
    if (accuracy < 15) return LocationAccuracyTier.good;
    if (accuracy < 50) return LocationAccuracyTier.fair;
    return LocationAccuracyTier.poor;
  }

  String get accuracyLabel {
    switch (accuracyTier) {
      case LocationAccuracyTier.excellent:
        return '±${accuracy.round()}m ✓';
      case LocationAccuracyTier.good:
        return '±${accuracy.round()}m';
      case LocationAccuracyTier.fair:
        return '±${accuracy.round()}m (fair)';
      case LocationAccuracyTier.poor:
        return '±${accuracy.round()}m (poor)';
    }
  }

  // -------------------------------------------------------------------------
  // Serialisation / display
  // -------------------------------------------------------------------------

  /// Compact JSON representation suitable for embedding in Firestore docs.
  String toJson() =>
      '{"lat":$latitude,"lon":$longitude,"acc":$accuracy,'
      '"ts":"${timestamp.toIso8601String()}"}';

  @override
  String toString() =>
      'GpsLocation(lat=$latitude, lon=$longitude, acc=${accuracy}m)';
}

/// Singleton GPS/location service with graceful degradation.
///
/// Uses the `geolocator` package.  If permissions are denied or the platform
/// does not support location, returns a fixed placeholder location and logs a
/// warning rather than throwing.
class LocationService {
  static final LocationService instance = LocationService._();
  LocationService._();

  GpsLocation? _lastLocation;
  StreamSubscription<Position>? _trackingSubscription;

  // Site boundary (center + radius)
  GpsLocation? _siteCenter;
  double _siteRadiusMeters = 500.0;

  // Distance tracking
  double _totalDistanceMeters = 0.0;
  GpsLocation? _lastTrackedLocation;

  /// Most recently obtained location, or null if none yet.
  GpsLocation? get lastLocation => _lastLocation;

  /// Total distance moved since tracking started (metres).
  double get totalDistanceMeters => _totalDistanceMeters;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Attempt to get the current GPS fix.
  ///
  /// Returns null if permissions are denied or an error occurs.
  Future<GpsLocation?> getCurrentLocation() async {
    try {
      final permitted = await _ensurePermission();
      if (!permitted) {
        debugPrint('[LocationService] Permission denied — returning null.');
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );

      _lastLocation = _fromPosition(position);
      debugPrint('[LocationService] Fix obtained: $_lastLocation');
      return _lastLocation;
    } catch (e) {
      debugPrint('[LocationService] getCurrentLocation failed: $e');
      return null;
    }
  }

  /// Start continuous location tracking.  Updates [lastLocation] on each fix.
  Future<void> startTracking() async {
    try {
      final permitted = await _ensurePermission();
      if (!permitted) {
        debugPrint('[LocationService] Cannot start tracking — permission denied.');
        return;
      }

      if (_trackingSubscription != null) {
        debugPrint('[LocationService] Tracking already active.');
        return;
      }

      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // metres — only emit when moved ≥5 m
      );

      _trackingSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (position) {
          final newLocation = _fromPosition(position);
          // Accumulate distance
          if (_lastTrackedLocation != null) {
            _totalDistanceMeters +=
                GpsLocation.distanceMeters(_lastTrackedLocation!, newLocation);
          }
          _lastTrackedLocation = newLocation;
          _lastLocation = newLocation;
          debugPrint('[LocationService] Track update: $_lastLocation');
        },
        onError: (Object e) {
          debugPrint('[LocationService] Tracking stream error: $e');
        },
        cancelOnError: false,
      );
      debugPrint('[LocationService] Tracking started.');
    } catch (e) {
      debugPrint('[LocationService] startTracking failed: $e');
    }
  }

  /// Stop continuous location tracking.
  void stopTracking() {
    try {
      _trackingSubscription?.cancel();
      _trackingSubscription = null;
      debugPrint('[LocationService] Tracking stopped.');
    } catch (e) {
      debugPrint('[LocationService] stopTracking failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Geofencing
  // ---------------------------------------------------------------------------

  /// Set the active archaeological site boundary.
  void setSiteBoundary({
    required GpsLocation center,
    double radiusMeters = 500.0,
  }) {
    _siteCenter = center;
    _siteRadiusMeters = radiusMeters;
  }

  /// Returns true if [location] (or the last known location) is within the
  /// site boundary.
  bool isWithinSite([GpsLocation? location]) {
    final loc = location ?? _lastLocation;
    if (loc == null || _siteCenter == null) return true; // assume in-site if unknown
    return GpsLocation.distanceMeters(loc, _siteCenter!) <= _siteRadiusMeters;
  }

  /// Distance to site center in metres, or null if no fix/boundary.
  double? get distanceToSiteCenterMeters {
    if (_lastLocation == null || _siteCenter == null) return null;
    return GpsLocation.distanceMeters(_lastLocation!, _siteCenter!);
  }

  // ---------------------------------------------------------------------------
  // Distance tracking
  // ---------------------------------------------------------------------------

  /// Reset distance tracking.
  void resetDistanceTracking() {
    _totalDistanceMeters = 0.0;
    _lastTrackedLocation = null;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<bool> _ensurePermission() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[LocationService] Location services disabled on device.');
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[LocationService] _ensurePermission error: $e');
      return false;
    }
  }

  GpsLocation _fromPosition(Position position) => GpsLocation(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        timestamp: position.timestamp,
      );
}
