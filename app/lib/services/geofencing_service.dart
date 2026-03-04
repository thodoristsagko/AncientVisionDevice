import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_service.dart';
import 'local_notification_service.dart';

// --------------------------------------------------------------------------
// Data classes
// --------------------------------------------------------------------------

/// Categories of archaeological hazard zones.
enum ArchaeologicalZoneType {
  excavation, // active dig area
  unstableSoil, // soil creep risk
  cliffEdge, // fall hazard
  structuralRuin, // collapse risk
  access, // safe access corridor
}

/// A circular geofence zone.
class GeofenceZone {
  final String id;
  final String name;
  final GpsLocation center;
  final double radiusMeters;
  final GeofenceSeverity severity;
  final bool isActive;
  final ArchaeologicalZoneType zoneType;

  const GeofenceZone({
    required this.id,
    required this.name,
    required this.center,
    required this.radiusMeters,
    this.severity = GeofenceSeverity.warning,
    this.isActive = true,
    this.zoneType = ArchaeologicalZoneType.excavation,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': center.latitude,
        'lon': center.longitude,
        'radius': radiusMeters,
        'severity': severity.name,
        'active': isActive,
        'zoneType': zoneType.name,
      };

  factory GeofenceZone.fromJson(Map<String, dynamic> json) {
    return GeofenceZone(
      id: json['id'] as String,
      name: json['name'] as String,
      center: GpsLocation(
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lon'] as num).toDouble(),
        accuracy: 1.0,
        timestamp: DateTime.now(),
      ),
      radiusMeters: (json['radius'] as num).toDouble(),
      severity: GeofenceSeverity.values.firstWhere(
        (s) => s.name == json['severity'],
        orElse: () => GeofenceSeverity.warning,
      ),
      isActive: json['active'] as bool? ?? true,
      zoneType: ArchaeologicalZoneType.values.firstWhere(
        (t) => t.name == json['zoneType'],
        orElse: () => ArchaeologicalZoneType.excavation,
      ),
    );
  }
}

enum GeofenceSeverity { info, warning, danger, critical }

/// Status of a device relative to a geofence zone.
enum GeofenceStatus { inside, outside, approaching }

/// Event fired when geofence status changes.
class GeofenceEvent {
  final GeofenceZone zone;
  final GeofenceStatus status;
  final double distanceMeters;
  final DateTime timestamp;

  const GeofenceEvent({
    required this.zone,
    required this.status,
    required this.distanceMeters,
    required this.timestamp,
  });
}

// --------------------------------------------------------------------------
// Service
// --------------------------------------------------------------------------

/// Singleton service for archaeological site geofencing.
///
/// Monitors proximity to registered hazard zones and fires OS notifications
/// when approaching or entering a danger area.
///
/// Usage:
/// ```dart
/// await GeofencingService.instance.initialize();
/// GeofencingService.instance.addZone(GeofenceZone(
///   id: 'trench-1',
///   name: 'Trench 1 Collapse Risk',
///   center: GpsLocation(latitude: 37.975, longitude: 23.735, accuracy: 5, timestamp: DateTime.now()),
///   radiusMeters: 50,
///   severity: GeofenceSeverity.danger,
/// ));
/// GeofencingService.instance.events.listen((e) { ... });
/// ```
class GeofencingService {
  static final GeofencingService instance = GeofencingService._();
  GeofencingService._();

  // -------------------------------------------------------------------------
  // Zone registry
  // -------------------------------------------------------------------------

  /// All registered geofence zones, keyed by their ID.
  final Map<String, GeofenceZone> _zones = {};

  /// Returns an unmodifiable snapshot of all registered zones.
  List<GeofenceZone> get zones => List.unmodifiable(_zones.values);

  /// Register or update a geofence zone.
  ///
  /// If a zone with the same [id] already exists it is replaced.
  void addZone(GeofenceZone zone) {
    _zones[zone.id] = zone;
    // Reset cached status so the next check re-evaluates from scratch.
    _lastStatuses.remove(zone.id);
    debugPrint('[GeofencingService] Zone added: ${zone.id} '
        '(${zone.name}, r=${zone.radiusMeters}m, ${zone.severity.name})');
  }

  /// Remove a registered zone by its [id].
  ///
  /// No-op if the zone is not found.
  void removeZone(String id) {
    _zones.remove(id);
    _lastStatuses.remove(id);
    debugPrint('[GeofencingService] Zone removed: $id');
  }

  // -------------------------------------------------------------------------
  // Periodic check
  // -------------------------------------------------------------------------

  /// Fires a geofence evaluation every 10 seconds.
  Timer? _checkTimer;

  static const Duration _checkInterval = Duration(seconds: 10);

  // -------------------------------------------------------------------------
  // Status tracking — previous status per zone for transition detection
  // -------------------------------------------------------------------------

  final Map<String, GeofenceStatus> _lastStatuses = {};

  // -------------------------------------------------------------------------
  // Event stream
  // -------------------------------------------------------------------------

  final StreamController<GeofenceEvent> _controller =
      StreamController<GeofenceEvent>.broadcast();

  /// Broadcast stream of [GeofenceEvent]s emitted on status transitions.
  Stream<GeofenceEvent> get events => _controller.stream;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Initialise the service and start the periodic proximity check.
  ///
  /// Safe to call multiple times — additional calls are no-ops.
  Future<void> initialize() async {
    if (_checkTimer != null) return; // already running

    _checkTimer = Timer.periodic(_checkInterval, (_) => _checkZones());
    debugPrint('[GeofencingService] Initialized — checking every '
        '${_checkInterval.inSeconds}s');
  }

  /// Stop the periodic check and close the event stream.
  ///
  /// After calling [dispose] the service must be re-[initialize]d before use.
  void dispose() {
    _checkTimer?.cancel();
    _checkTimer = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
    debugPrint('[GeofencingService] Disposed.');
  }

  // -------------------------------------------------------------------------
  // Core check loop
  // -------------------------------------------------------------------------

  /// Evaluate all active zones against the current GPS fix.
  ///
  /// Called automatically on the [_checkTimer].  Can also be triggered
  /// manually (useful in tests).
  void _checkZones() {
    final location = LocationService.instance.lastLocation;
    if (location == null) {
      debugPrint('[GeofencingService] No GPS fix — skipping zone check.');
      return;
    }

    for (final zone in _zones.values) {
      if (!zone.isActive) continue;

      final dist = _distanceMeters(location, zone.center);
      final status = _statusFor(dist, zone.radiusMeters);
      final prev = _lastStatuses[zone.id];

      if (prev != status) {
        // Status changed — emit an event and (optionally) a notification.
        _lastStatuses[zone.id] = status;
        final event = GeofenceEvent(
          zone: zone,
          status: status,
          distanceMeters: dist,
          timestamp: DateTime.now(),
        );
        if (!_controller.isClosed) {
          _controller.add(event);
        }
        _handleTransition(prev, status, zone, dist);
      }
    }
  }

  /// Map a distance to a [GeofenceStatus].
  ///
  /// "Approaching" means the device is within [radius * 2.0] metres but still
  /// outside the zone boundary.
  GeofenceStatus _statusFor(double distanceMeters, double radiusMeters) {
    if (distanceMeters <= radiusMeters) return GeofenceStatus.inside;
    if (distanceMeters <= radiusMeters * 2.0) return GeofenceStatus.approaching;
    return GeofenceStatus.outside;
  }

  // -------------------------------------------------------------------------
  // Notification helpers
  // -------------------------------------------------------------------------

  /// Fire an OS notification when the status transition warrants it.
  Future<void> _handleTransition(
    GeofenceStatus? prev,
    GeofenceStatus next,
    GeofenceZone zone,
    double dist,
  ) async {
    final distStr = dist.toStringAsFixed(0);

    if (next == GeofenceStatus.approaching) {
      // Any transition to "approaching" (inside is already handled below).
      await LocalNotificationService.instance.showAnomalyAlert(
        title: 'Approaching hazard zone',
        body: '${zone.name}: ${distStr}m away — exercise caution.',
      );
    } else if (next == GeofenceStatus.inside) {
      // Entering a danger or critical zone — high-priority alert.
      if (zone.severity == GeofenceSeverity.danger ||
          zone.severity == GeofenceSeverity.critical) {
        await LocalNotificationService.instance.showAnomalyAlert(
          title: 'ENTERED hazard zone',
          body: '${zone.name} [${zone.severity.name.toUpperCase()}] — '
              'stop work and retreat immediately.',
        );
      }
    } else if (next == GeofenceStatus.outside &&
        (prev == GeofenceStatus.inside ||
            prev == GeofenceStatus.approaching)) {
      // Left the zone or approach corridor.
      await LocalNotificationService.instance.showAnomalyAlert(
        title: 'Zone cleared',
        body: 'You have left ${zone.name} (${distStr}m from boundary).',
      );
    }

    debugPrint('[GeofencingService] Transition '
        '${prev?.name ?? "none"} -> ${next.name} '
        'for zone "${zone.id}" dist=${distStr}m');
  }

  // -------------------------------------------------------------------------
  // Haversine distance
  // -------------------------------------------------------------------------

  /// Haversine great-circle distance between two GPS locations in metres.
  double _distanceMeters(GpsLocation a, GpsLocation b) {
    const r = 6371000.0; // Earth mean radius in metres
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final sinDlat = sin(dLat / 2);
    final sinDlon = sin(dLon / 2);
    final x = sinDlat * sinDlat + cos(lat1) * cos(lat2) * sinDlon * sinDlon;
    return 2 * r * asin(sqrt(x));
  }

  // -------------------------------------------------------------------------
  // Query helpers
  // -------------------------------------------------------------------------

  /// Returns the nearest active zone and its current distance (in metres), or
  /// null if there are no active zones or no GPS fix.
  ({GeofenceZone zone, double distanceMeters})? getNearestZone() {
    final location = LocationService.instance.lastLocation;
    if (location == null || _zones.isEmpty) return null;

    GeofenceZone? nearest;
    double nearestDist = double.infinity;

    for (final zone in _zones.values) {
      if (!zone.isActive) continue;
      final d = _distanceMeters(location, zone.center);
      if (d < nearestDist) {
        nearestDist = d;
        nearest = zone;
      }
    }

    if (nearest == null) return null;
    return (zone: nearest, distanceMeters: nearestDist);
  }

  /// Returns true if the current GPS fix is inside any zone whose severity is
  /// [GeofenceSeverity.danger] or [GeofenceSeverity.critical].
  bool isInsideAnyDangerZone() {
    final location = LocationService.instance.lastLocation;
    if (location == null) return false;

    for (final zone in _zones.values) {
      if (!zone.isActive) continue;
      if (zone.severity != GeofenceSeverity.danger &&
          zone.severity != GeofenceSeverity.critical) {
        continue;
      }
      final dist = _distanceMeters(location, zone.center);
      if (dist <= zone.radiusMeters) return true;
    }
    return false;
  }

  /// Returns the distance in metres to the nearest active zone whose severity
  /// is [GeofenceSeverity.danger] or [GeofenceSeverity.critical].
  ///
  /// Returns null if no danger/critical zones exist.
  double? distanceToNearestDangerZone(GpsLocation position) {
    double? nearest;

    for (final zone in _zones.values) {
      if (!zone.isActive) continue;
      if (zone.severity != GeofenceSeverity.danger &&
          zone.severity != GeofenceSeverity.critical) {
        continue;
      }
      final d = _distanceMeters(position, zone.center);
      if (nearest == null || d < nearest) nearest = d;
    }

    return nearest;
  }

  /// Returns true if [position] is within any active zone of type
  /// [ArchaeologicalZoneType.access].
  bool isInSafeCorridor(GpsLocation position) {
    for (final zone in _zones.values) {
      if (!zone.isActive) continue;
      if (zone.zoneType != ArchaeologicalZoneType.access) continue;
      if (_distanceMeters(position, zone.center) <= zone.radiusMeters) {
        return true;
      }
    }
    return false;
  }

  /// Returns a map of each [GeofenceSeverity] level to the count of active
  /// zones at that severity.
  Map<GeofenceSeverity, int> get zoneSummary {
    final summary = <GeofenceSeverity, int>{
      for (final s in GeofenceSeverity.values) s: 0,
    };
    for (final zone in _zones.values) {
      if (!zone.isActive) continue;
      summary[zone.severity] = (summary[zone.severity] ?? 0) + 1;
    }
    return summary;
  }

  // -------------------------------------------------------------------------
  // Zone persistence
  // -------------------------------------------------------------------------

  static const String _prefKey = 'geofencing_zones_v1';

  /// Serialize all registered zones to [SharedPreferences].
  Future<void> saveZones() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _zones.values.map((z) => z.toJson()).toList();
      await prefs.setString(_prefKey, jsonEncode(list));
      debugPrint('[GeofencingService] Saved ${list.length} zone(s).');
    } catch (e) {
      debugPrint('[GeofencingService] saveZones failed: $e');
    }
  }

  /// Deserialize zones previously saved via [saveZones] and register them.
  ///
  /// Existing zones with matching IDs will be replaced.
  Future<void> loadZones() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return;

      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        addZone(GeofenceZone.fromJson(item as Map<String, dynamic>));
      }
      debugPrint('[GeofencingService] Loaded ${list.length} zone(s).');
    } catch (e) {
      debugPrint('[GeofencingService] loadZones failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Convenience factory
  // -------------------------------------------------------------------------

  /// Register a 30-metre [GeofenceSeverity.danger] zone at the coordinates of
  /// a critical seismic/anomaly event.
  ///
  /// The zone ID is auto-generated as
  /// `'critical-<Unix-milliseconds>'` to ensure uniqueness.
  void addCriticalEventZone(
    double lat,
    double lon, {
    double radiusMeters = 30,
  }) {
    final id = 'critical-${DateTime.now().millisecondsSinceEpoch}';
    addZone(GeofenceZone(
      id: id,
      name: 'Critical Event Zone',
      center: GpsLocation(
        latitude: lat,
        longitude: lon,
        accuracy: 1.0,
        timestamp: DateTime.now(),
      ),
      radiusMeters: radiusMeters,
      severity: GeofenceSeverity.danger,
    ));
    debugPrint('[GeofencingService] Critical event zone created: $id '
        '($lat, $lon, r=${radiusMeters}m)');
  }
}
