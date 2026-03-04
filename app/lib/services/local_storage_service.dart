import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Local storage service for offline support and auto-save
/// Ensures no data is lost even without internet connection
class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._internal();
  factory LocalStorageService() => _instance;
  LocalStorageService._internal();

  SharedPreferences? _prefs;
  bool _initialized = false;

  /// Initialize the service
  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  /// Auto-save form data (prevents data loss)
  Future<void> saveFormDraft({
    required String formId,
    required Map<String, dynamic> data,
  }) async {
    await initialize();
    final key = 'draft_$formId';
    await _prefs!.setString(key, jsonEncode(data));
  }

  /// Get saved form draft
  Map<String, dynamic>? getFormDraft(String formId) {
    if (!_initialized || _prefs == null) return null;
    final key = 'draft_$formId';
    final jsonStr = _prefs!.getString(key);
    if (jsonStr == null) return null;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// Clear form draft after successful save
  Future<void> clearFormDraft(String formId) async {
    await initialize();
    final key = 'draft_$formId';
    await _prefs!.remove(key);
  }

  /// Cache finding locally (for offline access)
  Future<void> cacheFinding({
    required String findingId,
    required Map<String, dynamic> data,
  }) async {
    await initialize();

    // Save individual finding
    final key = 'finding_$findingId';
    await _prefs!.setString(key, jsonEncode(data));

    // Update cached findings list
    final cachedIds = getCachedFindingIds();
    if (!cachedIds.contains(findingId)) {
      cachedIds.add(findingId);
      await _prefs!.setStringList('cached_findings', cachedIds);
    }
  }

  /// Get cached finding
  Map<String, dynamic>? getCachedFinding(String findingId) {
    if (!_initialized || _prefs == null) return null;
    final key = 'finding_$findingId';
    final jsonStr = _prefs!.getString(key);
    if (jsonStr == null) return null;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// Get all cached finding IDs
  List<String> getCachedFindingIds() {
    if (!_initialized || _prefs == null) return [];
    return _prefs!.getStringList('cached_findings') ?? [];
  }

  /// Get all cached findings
  List<Map<String, dynamic>> getAllCachedFindings() {
    final ids = getCachedFindingIds();
    final findings = <Map<String, dynamic>>[];
    for (final id in ids) {
      final finding = getCachedFinding(id);
      if (finding != null) {
        finding['id'] = id;
        findings.add(finding);
      }
    }
    return findings;
  }

  /// Queue finding for upload (offline mode)
  Future<void> queueForUpload({
    required String findingId,
    required Map<String, dynamic> data,
  }) async {
    await initialize();

    // Save to pending uploads
    final key = 'pending_$findingId';
    await _prefs!.setString(key, jsonEncode(data));

    // Update pending list
    final pending = getPendingUploads();
    if (!pending.contains(findingId)) {
      pending.add(findingId);
      await _prefs!.setStringList('pending_uploads', pending);
    }
  }

  /// Get pending upload IDs
  List<String> getPendingUploads() {
    if (!_initialized || _prefs == null) return [];
    return _prefs!.getStringList('pending_uploads') ?? [];
  }

  /// Get pending upload data
  Map<String, dynamic>? getPendingUpload(String findingId) {
    if (!_initialized || _prefs == null) return null;
    final key = 'pending_$findingId';
    final jsonStr = _prefs!.getString(key);
    if (jsonStr == null) return null;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// Sync pending uploads to Firebase
  Future<int> syncPendingUploads() async {
    await initialize();
    final pending = getPendingUploads();
    int synced = 0;

    for (final id in pending) {
      try {
        final data = getPendingUpload(id);
        if (data != null) {
          // Upload to Firebase
          await FirebaseFirestore.instance
              .collection('findings')
              .doc(id)
              .set(data);

          // Remove from pending
          await _prefs!.remove('pending_$id');
          synced++;
        }
      } catch (e) {
        // Keep in pending queue for retry
        // Silent fail - will retry on next sync
      }
    }

    // Update pending list
    final remaining = getPendingUploads();
    remaining.removeWhere((id) => !_prefs!.containsKey('pending_$id'));
    await _prefs!.setStringList('pending_uploads', remaining);

    return synced;
  }

  /// Check if offline mode (has pending uploads)
  bool get hasOfflineData => getPendingUploads().isNotEmpty;

  /// Get offline data count
  int get offlineDataCount => getPendingUploads().length;

  /// Save app settings
  Future<void> saveSetting(String key, dynamic value) async {
    await initialize();
    if (value is String) {
      await _prefs!.setString(key, value);
    } else if (value is int) {
      await _prefs!.setInt(key, value);
    } else if (value is double) {
      await _prefs!.setDouble(key, value);
    } else if (value is bool) {
      await _prefs!.setBool(key, value);
    }
  }

  /// Get app setting
  T? getSetting<T>(String key, {T? defaultValue}) {
    if (!_initialized || _prefs == null) return defaultValue;

    if (T == String) {
      return (_prefs!.getString(key) ?? defaultValue) as T?;
    } else if (T == int) {
      return (_prefs!.getInt(key) ?? defaultValue) as T?;
    } else if (T == double) {
      return (_prefs!.getDouble(key) ?? defaultValue) as T?;
    } else if (T == bool) {
      return (_prefs!.getBool(key) ?? defaultValue) as T?;
    }
    return defaultValue;
  }

  /// Clear all cached data (use with caution)
  Future<void> clearAllCache() async {
    await initialize();
    await _prefs!.clear();
  }

  /// Serializes all keys currently stored in SharedPreferences to a JSON
  /// string.  Useful for diagnostics, bug reports, and local backups.
  ///
  /// Values are represented as-is (String/int/double/bool/List<String>).
  /// The map is sorted by key for deterministic output.
  Future<String> exportAllPreferencesToJson() async {
    await initialize();
    final keys = _prefs!.getKeys().toList()..sort();
    final result = <String, dynamic>{};
    for (final key in keys) {
      result[key] = _prefs!.get(key);
    }
    return const JsonEncoder.withIndent('  ').convert(result);
  }
}
