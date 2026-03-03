import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AlertHistoryService {
  static const _key = 'alert_history';
  static const _maxEntries = 100;

  Future<List<Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadFromPrefs(prefs);
  }

  List<Map<String, dynamic>> _loadFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> add({
    required String level,
    required String type,
    required double ppv,
    required String message,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _loadFromPrefs(prefs);
    entries.add({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': type,
      'ppv': ppv,
      'message': message,
    });
    final trimmed = entries.length > _maxEntries
        ? entries.sublist(entries.length - _maxEntries)
        : entries;
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
