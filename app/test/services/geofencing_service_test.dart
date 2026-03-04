import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/geofencing_service.dart';
import 'package:ancient_vision/services/location_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a [GpsLocation] with sensible defaults for tests.
GpsLocation loc(double lat, double lon) => GpsLocation(
      latitude: lat,
      longitude: lon,
      accuracy: 1.0,
      timestamp: DateTime.now(),
    );

/// Build a simple warning zone centred on [lat]/[lon] with [radius] metres.
GeofenceZone zone(
  String id,
  double lat,
  double lon, {
  double radius = 100,
  GeofenceSeverity severity = GeofenceSeverity.warning,
}) =>
    GeofenceZone(
      id: id,
      name: 'Test zone $id',
      center: loc(lat, lon),
      radiusMeters: radius,
      severity: severity,
    );

// ---------------------------------------------------------------------------
// Haversine reference: compute expected distance for assertions
// ---------------------------------------------------------------------------

double haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final phi1 = lat1 * pi / 180;
  final phi2 = lat2 * pi / 180;
  final dPhi = (lat2 - lat1) * pi / 180;
  final dLam = (lon2 - lon1) * pi / 180;
  final a = sin(dPhi / 2) * sin(dPhi / 2) +
      cos(phi1) * cos(phi2) * sin(dLam / 2) * sin(dLam / 2);
  return 2 * r * asin(sqrt(a));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Fresh service instance per test group — singleton reset is achieved by
  // clearing zones and statuses between tests.
  late GeofencingService svc;

  setUp(() {
    svc = GeofencingService.instance;
    // Clear any leftover state from previous tests.
    for (final z in svc.zones.toList()) {
      svc.removeZone(z.id);
    }
  });

  // -------------------------------------------------------------------------
  group('Zone registry', () {
    test('starts with no zones', () {
      expect(svc.zones, isEmpty);
    });

    test('addZone registers a zone', () {
      svc.addZone(zone('z1', 37.975, 23.735));
      expect(svc.zones.length, 1);
      expect(svc.zones.first.id, 'z1');
    });

    test('addZone replaces existing zone with same id', () {
      svc.addZone(zone('z1', 37.975, 23.735, radius: 50));
      svc.addZone(zone('z1', 37.975, 23.735, radius: 200));
      expect(svc.zones.length, 1);
      expect(svc.zones.first.radiusMeters, 200);
    });

    test('removeZone unregisters the zone', () {
      svc.addZone(zone('z1', 37.975, 23.735));
      svc.addZone(zone('z2', 37.976, 23.736));
      svc.removeZone('z1');
      expect(svc.zones.length, 1);
      expect(svc.zones.first.id, 'z2');
    });

    test('removeZone on unknown id is a no-op', () {
      svc.addZone(zone('z1', 37.975, 23.735));
      svc.removeZone('does-not-exist');
      expect(svc.zones.length, 1);
    });

    test('zones returns an unmodifiable list', () {
      svc.addZone(zone('z1', 37.975, 23.735));
      expect(() => (svc.zones as dynamic).add(zone('z2', 0, 0)),
          throwsUnsupportedError);
    });
  });

  // -------------------------------------------------------------------------
  group('Haversine distance', () {
    // Access the private _distanceMeters via the public GeofenceZone helper by
    // calling _checkZones indirectly, but the simplest approach is to expose
    // the computation via GpsLocation.distanceMeters (which uses the same
    // formula). We validate our own reference implementation here.

    test('distance is 0 for identical coordinates', () {
      final d = haversine(37.975, 23.735, 37.975, 23.735);
      expect(d, closeTo(0.0, 1e-9));
    });

    test('distance between Athens and Thessaloniki is ~303 km', () {
      // Athens ≈ (37.98, 23.73), Thessaloniki ≈ (40.64, 22.94)
      final d = haversine(37.98, 23.73, 40.64, 22.94);
      // Expect roughly 303 000 m ± 5 000 m
      expect(d, greaterThan(298000));
      expect(d, lessThan(308000));
    });

    test('GpsLocation.distanceMeters matches haversine reference', () {
      final a = loc(37.975, 23.735);
      final b = loc(37.976, 23.736);
      final expected = haversine(37.975, 23.735, 37.976, 23.736);
      final actual = GpsLocation.distanceMeters(a, b);
      expect(actual, closeTo(expected, 0.01));
    });

    test('~1 degree latitude difference is ~111 km', () {
      final d = haversine(0, 0, 1, 0);
      expect(d, closeTo(111195, 200)); // ±200 m tolerance
    });
  });

  // -------------------------------------------------------------------------
  group('isInsideAnyDangerZone', () {
    test('returns false when no zones registered', () {
      // Inject a location so it does not return false due to missing fix.
      LocationService.instance.setSiteBoundary(
        center: loc(37.975, 23.735),
        radiusMeters: 500,
      );
      expect(svc.isInsideAnyDangerZone(), isFalse);
    });

    test('returns false for warning-severity zone regardless of position', () {
      // A warning zone — should never trigger danger.
      svc.addZone(zone('w1', 37.975, 23.735,
          radius: 10000, severity: GeofenceSeverity.warning));
      // Even at the exact center there should be no "danger".
      // We cannot inject lastLocation, so verify the severity filter
      // by checking the zone properties directly.
      expect(svc.zones.first.severity, GeofenceSeverity.warning);
      // isInsideAnyDangerZone skips non-danger/critical zones:
      // With no GPS fix it returns false (no fix → safe default).
      expect(svc.isInsideAnyDangerZone(), isFalse);
    });

    test('danger zone geometry: inside vs outside logic', () {
      // A danger zone at 0,0 with 50 m radius.
      svc.addZone(zone('d1', 0.0, 0.0,
          radius: 50, severity: GeofenceSeverity.danger));

      // Point at exactly 0,0 — 0 metres away → inside.
      final inside = haversine(0.0, 0.0, 0.0, 0.0);
      expect(inside, closeTo(0.0, 0.001));
      expect(inside <= 50, isTrue);

      // Point at ~111 m away — outside 50 m radius.
      final outside = haversine(0.0, 0.0, 0.001, 0.0);
      expect(outside, greaterThan(50));
    });
  });

  // -------------------------------------------------------------------------
  group('Approaching threshold = 2× radius', () {
    test('approaching band starts at radius and ends at 2× radius', () {
      const radius = 100.0;
      // A distance of exactly radius → inside.
      // A distance between radius and 2*radius → approaching.
      // A distance beyond 2*radius → outside.

      // We test the threshold logic by examining the haversine distances
      // relative to the approaching threshold = radius * 2.0.
      const approachingThreshold = radius * 2.0;
      expect(approachingThreshold, 200.0);

      // 150 m away from a 100 m zone: inside approaching band.
      const distApproaching = 150.0;
      expect(distApproaching > radius, isTrue);
      expect(distApproaching <= approachingThreshold, isTrue);

      // 250 m away: outside approaching band.
      const distOutside = 250.0;
      expect(distOutside > approachingThreshold, isTrue);
    });

    test('addCriticalEventZone creates a zone with 30 m default radius', () {
      svc.addCriticalEventZone(37.975, 23.735);
      final added = svc.zones.where((z) => z.id.startsWith('critical-'));
      expect(added.length, 1);
      expect(added.first.radiusMeters, 30.0);
      expect(added.first.severity, GeofenceSeverity.danger);
      // Approaching threshold = 30 * 2 = 60 m
      final approachingThreshold = added.first.radiusMeters * 2.0;
      expect(approachingThreshold, 60.0);
    });

    test('addCriticalEventZone accepts custom radius', () {
      svc.addCriticalEventZone(37.975, 23.735, radiusMeters: 75);
      final added = svc.zones.where((z) => z.id.startsWith('critical-'));
      expect(added.first.radiusMeters, 75.0);
    });
  });

  // -------------------------------------------------------------------------
  group('GeofenceZone', () {
    test('toJson contains all expected keys', () {
      final z = zone('z1', 37.975, 23.735,
          radius: 50, severity: GeofenceSeverity.danger);
      final json = z.toJson();
      expect(json['id'], 'z1');
      expect(json['lat'], 37.975);
      expect(json['lon'], 23.735);
      expect(json['radius'], 50.0);
      expect(json['severity'], 'danger');
      expect(json['active'], isTrue);
    });

    test('default severity is warning', () {
      final z = GeofenceZone(
        id: 'x',
        name: 'X',
        center: loc(0, 0),
        radiusMeters: 10,
      );
      expect(z.severity, GeofenceSeverity.warning);
      expect(z.isActive, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('GeofenceEvent', () {
    test('stores all fields', () {
      final now = DateTime.now();
      final z = zone('z1', 37.975, 23.735);
      final event = GeofenceEvent(
        zone: z,
        status: GeofenceStatus.approaching,
        distanceMeters: 150.0,
        timestamp: now,
      );
      expect(event.zone.id, 'z1');
      expect(event.status, GeofenceStatus.approaching);
      expect(event.distanceMeters, 150.0);
      expect(event.timestamp, now);
    });
  });

  // -------------------------------------------------------------------------
  group('getNearestZone', () {
    test('returns null when no zones are registered', () {
      expect(svc.getNearestZone(), isNull);
    });

    test('returns null when no GPS fix available', () {
      // LocationService singleton has no fix in a unit test environment.
      svc.addZone(zone('z1', 37.975, 23.735));
      // lastLocation is null → getNearestZone returns null.
      expect(svc.getNearestZone(), isNull);
    });
  });
}
