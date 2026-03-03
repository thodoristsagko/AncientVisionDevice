import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

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

  /// Most recently obtained location, or null if none yet.
  GpsLocation? get lastLocation => _lastLocation;

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
          _lastLocation = _fromPosition(position);
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
