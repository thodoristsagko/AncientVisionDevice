// shared_preferences: ^2.2.2 — already present in pubspec.yaml
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last connected BLE device so the app can auto-reconnect on
/// startup, and tracks per-device metadata (last PPV, first-seen timestamp).
class DeviceMemoryService {
  static const String _kLastDeviceId = 'ble_last_device_id';
  static const String _kLastDeviceName = 'ble_last_device_name';
  // ISO-8601 string of the last successful connection time.
  static const String _kLastSeenAt = 'ble_last_seen_at';

  // Per-device metadata is stored as a JSON-encoded map under this key.
  // Schema: { "<deviceId>": { "firstSeenAt": "<iso>", "lastPpv": <double> } }
  static const String _kDeviceMetaKey = 'ble_device_meta';

  DeviceMemoryService._();
  static final DeviceMemoryService instance = DeviceMemoryService._();

  // ---------------------------------------------------------------------------
  // Existing API (unchanged)
  // ---------------------------------------------------------------------------

  /// Save the last successfully connected device and record the current time.
  Future<void> saveDevice({required String id, required String name}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastDeviceId, id);
    await prefs.setString(_kLastDeviceName, name);
    await prefs.setString(_kLastSeenAt, DateTime.now().toIso8601String());
    // Ensure the device appears in the per-device metadata map (first-seen).
    await _ensureDeviceRegistered(prefs, id);
  }

  /// Get the last known device ID, or null if never connected.
  Future<String?> getLastDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastDeviceId);
  }

  /// Get the last known device name, or null if never connected.
  Future<String?> getLastDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastDeviceName);
  }

  /// Get the DateTime when the device was last successfully connected,
  /// or null if never connected.
  Future<DateTime?> getLastSeenAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastSeenAt);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  /// Clear saved device (on explicit disconnect/forget).
  Future<void> clearDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLastDeviceId);
    await prefs.remove(_kLastDeviceName);
    await prefs.remove(_kLastSeenAt);
  }

  // ---------------------------------------------------------------------------
  // Multi-device tracking
  // ---------------------------------------------------------------------------

  /// All device IDs that have ever been seen by this app instance.
  Future<List<String>> get allKnownDevices async {
    final meta = await _loadMeta();
    return List.unmodifiable(meta.keys.toList());
  }

  /// Record a PPV measurement for [deviceId].
  ///
  /// Called from the BLE data path whenever a new IMU packet arrives.
  /// Also registers the device as known if it is not yet in the metadata map.
  Future<void> recordPpv(String deviceId, double ppv) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final meta = _loadMetaFromPrefs(prefs);
      final entry = _entryFor(meta, deviceId);
      entry['lastPpv'] = ppv;
      meta[deviceId] = entry;
      await _saveMeta(prefs, meta);
    } catch (e) {
      debugPrint('[DeviceMemoryService] recordPpv failed: $e');
    }
  }

  /// Returns the last PPV value recorded for [deviceId], or null if no PPV
  /// has been recorded yet.
  Future<double?> getLastKnownPpv(String deviceId) async {
    final meta = await _loadMeta();
    final entry = meta[deviceId];
    if (entry == null) return null;
    final raw = entry['lastPpv'];
    if (raw == null) return null;
    return (raw as num).toDouble();
  }

  /// Returns the [Duration] since [deviceId] was first seen (registered via
  /// [saveDevice] or [recordPpv]).  Returns null if the device is unknown.
  Future<Duration?> getDeviceUptime(String deviceId) async {
    final meta = await _loadMeta();
    final entry = meta[deviceId];
    if (entry == null) return null;
    final firstSeenRaw = entry['firstSeenAt'] as String?;
    if (firstSeenRaw == null) return null;
    final firstSeen = DateTime.tryParse(firstSeenRaw);
    if (firstSeen == null) return null;
    return DateTime.now().difference(firstSeen);
  }

  /// Remove all metadata for a specific device.  Does not affect the
  /// "last connected device" keys cleared by [clearDevice].
  Future<void> forgetDevice(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final meta = _loadMetaFromPrefs(prefs);
      meta.remove(deviceId);
      await _saveMeta(prefs, meta);
    } catch (e) {
      debugPrint('[DeviceMemoryService] forgetDevice failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<Map<String, Map<String, dynamic>>> _loadMeta() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadMetaFromPrefs(prefs);
  }

  Map<String, Map<String, dynamic>> _loadMetaFromPrefs(
    SharedPreferences prefs,
  ) {
    try {
      final raw = prefs.getString(_kDeviceMetaKey);
      if (raw == null) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)),
      );
    } catch (e) {
      debugPrint('[DeviceMemoryService] _loadMetaFromPrefs error: $e');
      return {};
    }
  }

  Future<void> _saveMeta(
    SharedPreferences prefs,
    Map<String, Map<String, dynamic>> meta,
  ) async {
    await prefs.setString(_kDeviceMetaKey, jsonEncode(meta));
  }

  /// Returns the entry for [deviceId], creating it with a firstSeenAt timestamp
  /// if it does not already exist.
  Map<String, dynamic> _entryFor(
    Map<String, Map<String, dynamic>> meta,
    String deviceId,
  ) {
    return meta.putIfAbsent(
      deviceId,
      () => {'firstSeenAt': DateTime.now().toIso8601String()},
    );
  }

  Future<void> _ensureDeviceRegistered(
    SharedPreferences prefs,
    String deviceId,
  ) async {
    final meta = _loadMetaFromPrefs(prefs);
    if (!meta.containsKey(deviceId)) {
      _entryFor(meta, deviceId);
      await _saveMeta(prefs, meta);
    }
  }
}
