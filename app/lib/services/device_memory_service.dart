// shared_preferences: ^2.2.2 — already present in pubspec.yaml
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last connected BLE device so the app can auto-reconnect on startup.
class DeviceMemoryService {
  static const String _kLastDeviceId = 'ble_last_device_id';
  static const String _kLastDeviceName = 'ble_last_device_name';

  DeviceMemoryService._();
  static final DeviceMemoryService instance = DeviceMemoryService._();

  /// Save the last successfully connected device.
  Future<void> saveDevice({required String id, required String name}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastDeviceId, id);
    await prefs.setString(_kLastDeviceName, name);
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

  /// Clear saved device (on explicit disconnect/forget).
  Future<void> clearDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLastDeviceId);
    await prefs.remove(_kLastDeviceName);
  }
}
