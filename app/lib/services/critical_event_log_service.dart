import 'dart:convert';
import 'dart:io';
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

  const CriticalEvent({
    required this.timestamp,
    required this.ppv,
    required this.anomalyScore,
    this.location,
    this.deviceId,
  });

  factory CriticalEvent.fromJson(Map<String, dynamic> json) => CriticalEvent(
        timestamp: DateTime.parse(json['timestamp'] as String),
        ppv: (json['ppv'] as num).toDouble(),
        anomalyScore: (json['anomaly_score'] as num).toDouble(),
        location: json['location'] != null
            ? _locationFromJson(json['location'] as Map<String, dynamic>)
            : null,
        deviceId: json['device_id'] as String?,
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
/// Use [exportAsCsv] to share a CSV of all events via the OS share sheet.
class CriticalEventLogService {
  static final CriticalEventLogService instance =
      CriticalEventLogService._();
  CriticalEventLogService._();

  static const String _key = 'critical_event_log';
  static const int _maxEvents = 200;

  final List<CriticalEvent> _events = [];
  bool _loaded = false;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns an unmodifiable view of in-memory events (newest first).
  ///
  /// Call [_ensureLoaded] first if you need persistence across launches.
  List<CriticalEvent> get events => List.unmodifiable(_events);

  /// Record a CRITICAL event.  Attempts to obtain a GPS fix (up to 15 s).
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

      final event = CriticalEvent(
        timestamp: DateTime.now(),
        ppv: ppv,
        anomalyScore: anomalyScore,
        location: location,
        deviceId: deviceId,
      );

      _events.insert(0, event);
      // Trim in-memory list.
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

  /// Export all events as a CSV file shared via the OS share sheet.
  Future<void> exportAsCsv() async {
    try {
      await _ensureLoaded();

      if (_events.isEmpty) return;

      final buffer = StringBuffer();
      buffer.writeln(
        'timestamp,ppv_mm_s,anomaly_score,latitude,longitude,gps_accuracy_m,device_id',
      );

      for (final ev in _events) {
        final loc = ev.location;
        buffer.writeln([
          ev.timestamp.toIso8601String(),
          ev.ppv.toStringAsFixed(4),
          ev.anomalyScore.toStringAsFixed(4),
          loc?.latitude.toStringAsFixed(7) ?? '',
          loc?.longitude.toStringAsFixed(7) ?? '',
          loc?.accuracy.toStringAsFixed(1) ?? '',
          ev.deviceId ?? '',
        ].join(','));
      }

      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/critical_events_$ts.csv');
      await file.writeAsString(buffer.toString());

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: 'AncientVision Critical Events $ts',
      );
    } catch (e) {
      debugPrint('[CriticalEventLogService] exportAsCsv failed: $e');
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
