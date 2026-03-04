import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Typed representation of a single alert history entry.
class AlertData {
  final DateTime timestamp;
  final String level;
  final String type;
  final double ppv;
  final String message;
  final String? deviceId;

  const AlertData({
    required this.timestamp,
    required this.level,
    required this.type,
    required this.ppv,
    required this.message,
    this.deviceId,
  });

  factory AlertData.fromMap(Map<String, dynamic> m) => AlertData(
        timestamp: DateTime.parse(m['timestamp'] as String),
        level: m['level'] as String? ?? '',
        type: m['type'] as String? ?? '',
        ppv: (m['ppv'] as num?)?.toDouble() ?? 0.0,
        message: m['message'] as String? ?? '',
        deviceId: m['device_id'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'timestamp': timestamp.toIso8601String(),
        'level': level,
        'type': type,
        'ppv': ppv,
        'message': message,
        if (deviceId != null) 'device_id': deviceId,
      };
}

class AlertHistoryService {
  static const _key = 'alert_history';

  /// Maximum entries kept in SharedPreferences across restarts.
  static const _maxEntries = 200;

  // ---------------------------------------------------------------------------
  // Persistence helpers
  // ---------------------------------------------------------------------------

  /// Load all alert entries from SharedPreferences.
  Future<List<AlertData>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadFromPrefs(prefs);
  }

  List<AlertData> _loadFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => AlertData.fromMap(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Persist [entries] to SharedPreferences, keeping at most [_maxEntries].
  Future<void> save(List<AlertData> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = entries.length > _maxEntries
        ? entries.sublist(entries.length - _maxEntries)
        : entries;
    await prefs.setString(_key, jsonEncode(trimmed.map((e) => e.toMap()).toList()));
  }

  // ---------------------------------------------------------------------------
  // Mutation
  // ---------------------------------------------------------------------------

  Future<void> add({
    required String level,
    required String type,
    required double ppv,
    required String message,
    String? deviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _loadFromPrefs(prefs);
    entries.add(AlertData(
      timestamp: DateTime.now(),
      level: level,
      type: type,
      ppv: ppv,
      message: message,
      deviceId: deviceId,
    ));
    final trimmed = entries.length > _maxEntries
        ? entries.sublist(entries.length - _maxEntries)
        : entries;
    await prefs.setString(
      _key,
      jsonEncode(trimmed.map((e) => e.toMap()).toList()),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  // ---------------------------------------------------------------------------
  // Statistics
  // ---------------------------------------------------------------------------

  /// Total number of alerts in history (synchronous after [load]).
  Future<int> get totalCount async => (await load()).length;

  /// Number of CRITICAL-level alerts in history.
  Future<int> get criticalCount async =>
      (await load()).where((e) => e.level == 'CRITICAL').length;

  /// Fraction of alerts that are CRITICAL (0.0 if history is empty).
  Future<double> get criticalRate async {
    final entries = await load();
    if (entries.isEmpty) return 0.0;
    final critical = entries.where((e) => e.level == 'CRITICAL').length;
    return critical / entries.length;
  }

  /// Timestamp of the most recent CRITICAL alert, or null if none.
  Future<DateTime?> get lastCriticalTime async {
    final criticals = (await load())
        .where((e) => e.level == 'CRITICAL')
        .toList();
    if (criticals.isEmpty) return null;
    criticals.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return criticals.first.timestamp;
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  /// Returns all alerts whose [AlertData.level] equals [level].
  Future<List<AlertData>> getByLevel(String level) async =>
      (await load()).where((e) => e.level == level).toList();

  /// Returns all alerts that occurred within [duration] before now.
  Future<List<AlertData>> getRecent(Duration duration) async {
    final cutoff = DateTime.now().subtract(duration);
    return (await load()).where((e) => e.timestamp.isAfter(cutoff)).toList();
  }

  // ---------------------------------------------------------------------------
  // Pagination
  // ---------------------------------------------------------------------------

  /// Returns a page of alerts sorted newest-first.
  ///
  /// [page] is zero-indexed. Returns an empty list when [page] is out of range.
  Future<List<AlertData>> getPage(int page, {int pageSize = 20}) async {
    final all = await load();
    // newest first
    final sorted = List<AlertData>.from(all)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final start = page * pageSize;
    if (start >= sorted.length) return [];
    final end = (start + pageSize).clamp(0, sorted.length);
    return sorted.sublist(start, end);
  }

  // ---------------------------------------------------------------------------
  // CSV export
  // ---------------------------------------------------------------------------

  /// Returns a CSV string of all history entries.
  ///
  /// Columns: timestamp, level, ppv, message, device_id
  Future<String> exportAsCsv() async {
    final entries = await load();
    final buf = StringBuffer();
    buf.writeln('timestamp,level,ppv,message,device_id');
    for (final e in entries) {
      final ts = e.timestamp.toIso8601String();
      final msg = _csvEscape(e.message);
      final dev = _csvEscape(e.deviceId ?? '');
      buf.writeln('$ts,${e.level},${e.ppv.toStringAsFixed(4)},$msg,$dev');
    }
    return buf.toString();
  }

  /// Wraps [value] in double-quotes and escapes internal quotes for CSV.
  String _csvEscape(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }
}
