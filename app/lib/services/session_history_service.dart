import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Immutable data class representing a completed monitoring session.
class SessionRecord {
  final String id;
  final DateTime start;
  final DateTime end;
  final double peakPpv;
  final double peakScore;
  final int sampleCount;
  final int anomalyEvents;
  final String deviceName;

  const SessionRecord({
    required this.id,
    required this.start,
    required this.end,
    required this.peakPpv,
    required this.peakScore,
    required this.sampleCount,
    required this.anomalyEvents,
    required this.deviceName,
  });

  factory SessionRecord.fromJson(Map<String, dynamic> json) => SessionRecord(
        id: json['id'] as String? ?? '',
        start: DateTime.parse(json['start'] as String),
        end: DateTime.parse(json['end'] as String),
        peakPpv: (json['peak_ppv'] as num?)?.toDouble() ?? 0.0,
        peakScore: (json['peak_score'] as num?)?.toDouble() ?? 0.0,
        sampleCount: (json['sample_count'] as num?)?.toInt() ?? 0,
        anomalyEvents: (json['anomaly_events'] as num?)?.toInt() ?? 0,
        deviceName: json['device_name'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'peak_ppv': peakPpv,
        'peak_score': peakScore,
        'sample_count': sampleCount,
        'anomaly_events': anomalyEvents,
        'device_name': deviceName,
      };

  /// Duration of the session.
  Duration get duration => end.difference(start);
}

/// Singleton service that persists session history to SharedPreferences.
///
/// Keeps the last [_maxEntries] sessions.  Newest sessions are stored first.
class SessionHistoryService {
  static final SessionHistoryService instance = SessionHistoryService._();
  SessionHistoryService._();

  static const String _key = 'session_history';
  static const int _maxEntries = 50;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Persist a completed [record].  Prepends to the list; trims to [_maxEntries].
  Future<void> saveSession(SessionRecord record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessions = _loadFromPrefs(prefs);
      sessions.insert(0, record);
      final trimmed = sessions.length > _maxEntries
          ? sessions.sublist(0, _maxEntries)
          : sessions;
      await prefs.setString(
        _key,
        jsonEncode(trimmed.map((s) => s.toJson()).toList()),
      );
    } catch (e) {
      // Non-fatal — do not crash the caller.
    }
  }

  /// Returns all stored sessions, newest first.
  Future<List<SessionRecord>> getSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _loadFromPrefs(prefs);
    } catch (e) {
      return [];
    }
  }

  /// Wipe all stored sessions.
  Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      // Non-fatal.
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  List<SessionRecord> _loadFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .cast<Map<String, dynamic>>()
          .map(SessionRecord.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
