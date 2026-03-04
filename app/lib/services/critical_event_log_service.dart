import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'location_service.dart';

/// Immutable record of a single CRITICAL anomaly event with optional GPS fix.
class CriticalEvent {
  final DateTime timestamp;
  final double ppv;
  final double anomalyScore;
  final GpsLocation? location;
  final String? deviceId;

  /// Number of times this event has been updated (clustered duplicates within
  /// 30 s / ~1 km are merged into the existing event rather than added anew).
  final int count;

  const CriticalEvent({
    required this.timestamp,
    required this.ppv,
    required this.anomalyScore,
    this.location,
    this.deviceId,
    this.count = 1,
  });

  /// Returns a copy of this event with the given fields replaced.
  CriticalEvent copyWith({
    DateTime? timestamp,
    double? ppv,
    double? anomalyScore,
    GpsLocation? location,
    String? deviceId,
    int? count,
  }) =>
      CriticalEvent(
        timestamp: timestamp ?? this.timestamp,
        ppv: ppv ?? this.ppv,
        anomalyScore: anomalyScore ?? this.anomalyScore,
        location: location ?? this.location,
        deviceId: deviceId ?? this.deviceId,
        count: count ?? this.count,
      );

  factory CriticalEvent.fromJson(Map<String, dynamic> json) => CriticalEvent(
        timestamp: DateTime.parse(json['timestamp'] as String),
        ppv: (json['ppv'] as num).toDouble(),
        anomalyScore: (json['anomaly_score'] as num).toDouble(),
        location: json['location'] != null
            ? _locationFromJson(json['location'] as Map<String, dynamic>)
            : null,
        deviceId: json['device_id'] as String?,
        count: (json['count'] as num?)?.toInt() ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'ppv': ppv,
        'anomaly_score': anomalyScore,
        'location': location == null
            ? null
            : {
                'lat': location!.latitude,
                'lon': location!.longitude,
                'acc': location!.accuracy,
                'ts': location!.timestamp.toIso8601String(),
              },
        'device_id': deviceId,
        'count': count,
      };

  static GpsLocation _locationFromJson(Map<String, dynamic> m) => GpsLocation(
        latitude: (m['lat'] as num).toDouble(),
        longitude: (m['lon'] as num).toDouble(),
        accuracy: (m['acc'] as num).toDouble(),
        timestamp: DateTime.parse(m['ts'] as String),
      );
}

/// Singleton service that records CRITICAL anomaly events with GPS coordinates
/// and persists them to SharedPreferences.
///
/// Call [logEvent] whenever a CRITICAL threshold is crossed in safety_view.
/// Use [exportAsCsv] to get a CSV string, or [exportAndShareCsv] to share via
/// the OS share sheet.
class CriticalEventLogService {
  static final CriticalEventLogService instance =
      CriticalEventLogService._();
  CriticalEventLogService._();

  static const String _key = 'critical_event_log';

  /// Maximum number of events to retain in memory and on disk.
  ///
  /// When exceeded, the oldest events (tail of the newest-first list) are
  /// trimmed to keep memory bounded.  Consumers may pass a custom limit via
  /// [setMaxEvents].  Defaults to 1000.
  static const int defaultMaxEvents = 1000;

  int _maxEvents = defaultMaxEvents;

  /// Override the maximum event limit at runtime.
  ///
  /// The new limit is applied immediately — if the in-memory list already
  /// exceeds [limit], it is trimmed and the result is persisted.
  Future<void> setMaxEvents(int limit) async {
    assert(limit > 0, 'maxEvents must be positive');
    _maxEvents = limit;
    await _ensureLoaded();
    if (_events.length > _maxEvents) {
      _events.removeRange(_maxEvents, _events.length);
      await _persist();
    }
  }

  // Clustering thresholds.
  static const Duration _clusterTimeWindow = Duration(seconds: 30);
  static const double _clusterDistanceDeg = 0.01; // ~1 km

  final List<CriticalEvent> _events = [];
  bool _loaded = false;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns an unmodifiable view of in-memory events (newest first).
  ///
  /// Call [_ensureLoaded] first if you need persistence across launches.
  List<CriticalEvent> get events => List.unmodifiable(_events);

  /// Total number of stored events.
  int get totalEvents => _events.length;

  /// Number of events where [CriticalEvent.ppv] exceeds 1.0 mm/s.
  int get criticalCount => _events.where((e) => e.ppv > 1.0).length;

  /// Maximum PPV value across all stored events; 0.0 if no events.
  double get peakPpvAllTime =>
      _events.isEmpty ? 0.0 : _events.map((e) => e.ppv).reduce(math.max);

  /// Most recently added event (first element, newest first), or null.
  CriticalEvent? get mostRecentEvent => _events.isEmpty ? null : _events.first;

  /// Timestamp of the most recent event, or null if no events exist.
  DateTime? get lastEventTime => mostRecentEvent?.timestamp;

  /// Sum of ppv² across all stored events (J·s/m² proxy for cumulative damage).
  ///
  /// Useful for Arias-intensity-style damage accumulation assessment.
  double get totalPpvEnergy =>
      _events.fold(0.0, (sum, e) => sum + e.ppv * e.ppv);

  /// Ensures persisted events are loaded, then returns an unmodifiable list.
  ///
  /// Prefer this over [events] when you need the full history on app start.
  Future<List<CriticalEvent>> loadEvents() async {
    await _ensureLoaded();
    return List.unmodifiable(_events);
  }

  /// Returns events whose [CriticalEvent.timestamp] falls within [[start], [end]]
  /// (inclusive on both ends), ordered newest-first.
  ///
  /// Loads persisted data first so this is safe to call at app startup.
  Future<List<CriticalEvent>> getEventsBetween(
    DateTime start,
    DateTime end,
  ) async {
    await _ensureLoaded();
    return List.unmodifiable(
      _events.where(
        (e) =>
            !e.timestamp.isBefore(start) && !e.timestamp.isAfter(end),
      ),
    );
  }

  /// Removes all events older than [age] from now, then persists the result.
  ///
  /// Useful for routine maintenance — e.g. call with `Duration(days: 90)` on
  /// app start to keep the log from growing indefinitely beyond [_maxEvents].
  Future<void> clearEventsOlderThan(Duration age) async {
    try {
      await _ensureLoaded();
      final cutoff = DateTime.now().subtract(age);
      final before = _events.length;
      _events.removeWhere((e) => e.timestamp.isBefore(cutoff));
      if (_events.length != before) {
        await _persist();
        debugPrint(
          '[CriticalEventLogService] clearEventsOlderThan: '
          'removed ${before - _events.length} events older than $age',
        );
      }
    } catch (e) {
      debugPrint('[CriticalEventLogService] clearEventsOlderThan failed: $e');
    }
  }

  /// Explicit initialise method — loads persisted events from SharedPreferences.
  ///
  /// Calling this on app start ensures [events] is populated before the first
  /// [logEvent] call.  Subsequent calls are no-ops.
  Future<void> initialize() => _ensureLoaded();

  /// Record a CRITICAL event.  Attempts to obtain a GPS fix (up to 15 s).
  ///
  /// If an existing event within [_clusterTimeWindow] and [_clusterDistanceDeg]
  /// already exists, updates its PPV (worst case) and increments its count
  /// instead of adding a duplicate.
  ///
  /// Safe to call from any async context; never throws.
  Future<void> logEvent({
    required double ppv,
    required double anomalyScore,
    String? deviceId,
  }) async {
    try {
      await _ensureLoaded();

      // Attempt GPS — gracefully returns null if unavailable.
      final location =
          await LocationService.instance.getCurrentLocation();

      final now = DateTime.now();

      // --- Clustering check ---------------------------------------------------
      final clusterIdx = _findCluster(now, location);
      if (clusterIdx != -1) {
        final existing = _events[clusterIdx];
        _events[clusterIdx] = existing.copyWith(
          ppv: math.max(existing.ppv, ppv),
          count: existing.count + 1,
        );
        debugPrint(
          '[CriticalEventLogService] Clustered event at idx=$clusterIdx '
          'ppv=${_events[clusterIdx].ppv} count=${_events[clusterIdx].count}',
        );
        await _persist();
        return;
      }
      // ------------------------------------------------------------------------

      final event = CriticalEvent(
        timestamp: now,
        ppv: ppv,
        anomalyScore: anomalyScore,
        location: location,
        deviceId: deviceId,
      );

      _events.insert(0, event);
      // Trim to the hard limit — remove oldest (tail) entries.
      if (_events.length > _maxEvents) {
        _events.removeRange(_maxEvents, _events.length);
      }

      await _persist();

      debugPrint(
        '[CriticalEventLogService] Logged event: ppv=$ppv score=$anomalyScore '
        'gps=${location != null ? "${location.latitude},${location.longitude}" : "none"}',
      );
    } catch (e) {
      debugPrint('[CriticalEventLogService] logEvent failed: $e');
    }
  }

  /// Returns all events as a CSV string.
  ///
  /// Header: `timestamp,ppv,score,lat,lon,accuracy,count`
  String exportAsCsv() {
    final buffer = StringBuffer();
    buffer.writeln('timestamp,ppv,score,lat,lon,accuracy,count');

    for (final ev in _events) {
      final loc = ev.location;
      buffer.writeln([
        ev.timestamp.toUtc().toIso8601String(),
        ev.ppv.toStringAsFixed(4),
        ev.anomalyScore.toStringAsFixed(4),
        loc?.latitude.toStringAsFixed(7) ?? '',
        loc?.longitude.toStringAsFixed(7) ?? '',
        loc?.accuracy.toStringAsFixed(1) ?? '',
        ev.count,
      ].join(','));
    }

    return buffer.toString();
  }

  /// Export all events as a CSV file shared via the OS share sheet.
  Future<void> exportAndShareCsv() async {
    try {
      await _ensureLoaded();

      if (_events.isEmpty) return;

      final csv = exportAsCsv();

      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/critical_events_$ts.csv');
      await file.writeAsString(csv);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: 'AncientVision Critical Events $ts',
      );
    } catch (e) {
      debugPrint('[CriticalEventLogService] exportAndShareCsv failed: $e');
    }
  }

  /// Clear all persisted events.
  Future<void> clearAll() async {
    try {
      _events.clear();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      debugPrint('[CriticalEventLogService] clearAll failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Returns the index in [_events] of an event that is within the clustering
  /// window, or -1 if no such event exists.
  int _findCluster(DateTime now, GpsLocation? location) {
    for (var i = 0; i < _events.length; i++) {
      final ev = _events[i];
      final timeDiff = now.difference(ev.timestamp).abs();
      if (timeDiff > _clusterTimeWindow) continue;

      // If either event has no GPS, cluster on time alone.
      if (location == null || ev.location == null) return i;

      final dLat = (location.latitude - ev.location!.latitude).abs();
      final dLon = (location.longitude - ev.location!.longitude).abs();
      if (dLat <= _clusterDistanceDeg && dLon <= _clusterDistanceDeg) return i;
    }
    return -1;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _events.addAll(
          list
              .cast<Map<String, dynamic>>()
              .map(CriticalEvent.fromJson),
        );
      }
    } catch (e) {
      debugPrint('[CriticalEventLogService] _ensureLoaded error: $e');
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(_events.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[CriticalEventLogService] _persist failed: $e');
    }
  }
}
