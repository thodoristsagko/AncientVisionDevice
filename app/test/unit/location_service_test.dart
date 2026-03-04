import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/location_service.dart';

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

GpsLocation _loc(double lat, double lon, {double acc = 5.0}) => GpsLocation(
      latitude: lat,
      longitude: lon,
      accuracy: acc,
      timestamp: DateTime.now(),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  group('GpsLocation.distanceMeters', () {
    test('returns 0 for same point', () {
      final a = _loc(37.9755, 23.7348);
      final d = GpsLocation.distanceMeters(a, a);
      expect(d, closeTo(0.0, 1e-9));
    });

    test('computes known distance — Athens to Piraeus', () {
      // Athens city centre (approx): 37.9755, 23.7348
      // Piraeus port (approx):       37.9481, 23.6412
      // Straight-line Haversine distance ≈ 8.75 km.
      final athens = _loc(37.9755, 23.7348);
      final piraeus = _loc(37.9481, 23.6412);
      final d = GpsLocation.distanceMeters(athens, piraeus);
      expect(d, greaterThan(8000));
      expect(d, lessThan(11000));
    });

    test('is symmetric — dist(A,B) == dist(B,A)', () {
      final a = _loc(37.9755, 23.7348);
      final b = _loc(37.9481, 23.6412);
      final dAB = GpsLocation.distanceMeters(a, b);
      final dBA = GpsLocation.distanceMeters(b, a);
      expect(dAB, closeTo(dBA, 1e-6));
    });
  });

  // -------------------------------------------------------------------------
  group('GpsLocation.bearingDeg', () {
    test('returns approximately 180 for due south', () {
      // Moving south means decreasing latitude, same longitude.
      final from = _loc(10.0, 0.0);
      final to = _loc(9.0, 0.0); // 1 degree south
      final bearing = GpsLocation.bearingDeg(from, to);
      expect(bearing, closeTo(180.0, 1.0)); // ±1°
    });

    test('returns approximately 90 for due east', () {
      // Moving east means increasing longitude, same latitude.
      // At lat=0 the bearing formula gives exactly 90°.
      final from = _loc(0.0, 0.0);
      final to = _loc(0.0, 1.0); // 1 degree east
      final bearing = GpsLocation.bearingDeg(from, to);
      expect(bearing, closeTo(90.0, 1.0)); // ±1°
    });
  });

  // -------------------------------------------------------------------------
  group('GpsLocation.accuracyTier', () {
    test('returns excellent for 3m accuracy', () {
      expect(_loc(0, 0, acc: 3.0).accuracyTier, LocationAccuracyTier.excellent);
    });

    test('returns good for 10m accuracy', () {
      expect(_loc(0, 0, acc: 10.0).accuracyTier, LocationAccuracyTier.good);
    });

    test('returns fair for 30m accuracy', () {
      expect(_loc(0, 0, acc: 30.0).accuracyTier, LocationAccuracyTier.fair);
    });

    test('returns poor for 100m accuracy', () {
      expect(_loc(0, 0, acc: 100.0).accuracyTier, LocationAccuracyTier.poor);
    });
  });

  // -------------------------------------------------------------------------
  group('GpsLocation.accuracyLabel', () {
    test('contains ± symbol', () {
      final label = _loc(0, 0, acc: 10.0).accuracyLabel;
      expect(label, contains('±'));
    });

    test('contains ✓ for excellent tier', () {
      // accuracy < 5 → excellent tier → label ends with ✓
      final label = _loc(0, 0, acc: 3.0).accuracyLabel;
      expect(label, contains('✓'));
    });
  });
}
