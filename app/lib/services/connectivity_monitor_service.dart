import 'package:flutter/foundation.dart';

import 'network_status_service.dart';

// ---------------------------------------------------------------------------
// CombinedHealthStatus
// ---------------------------------------------------------------------------

/// Combined connectivity health for the app.
enum CombinedHealthStatus {
  /// Both BLE sensor and network are connected.
  fullyConnected,

  /// BLE connected but no network (can still collect data, cannot sync).
  bleOnlyConnected,

  /// Network connected but BLE disconnected (cannot collect data).
  networkOnlyConnected,

  /// Neither BLE nor network are connected.
  fullyDisconnected,

  /// Status not yet determined.
  unknown,
}

// ---------------------------------------------------------------------------
// ConnectivityMonitorService
// ---------------------------------------------------------------------------

/// Singleton service that monitors both BLE device connectivity AND network
/// connectivity and exposes a combined [CombinedHealthStatus].
///
/// BLE status must be pushed manually via [updateBleStatus].
/// Network status is subscribed to automatically from [NetworkStatusService].
///
/// Usage:
/// ```dart
/// // In main.dart / app init:
/// await ConnectivityMonitorService.instance.initialize();
///
/// // Whenever BLE connects / disconnects:
/// ConnectivityMonitorService.instance.updateBleStatus(connected: true);
///
/// // Listen for changes:
/// ConnectivityMonitorService.instance.addListener(() {
///   print(ConnectivityMonitorService.instance.healthStatus);
/// });
/// ```
class ConnectivityMonitorService extends ChangeNotifier {
  // -------------------------------------------------------------------------
  // Singleton
  // -------------------------------------------------------------------------

  static final ConnectivityMonitorService instance =
      ConnectivityMonitorService._();
  ConnectivityMonitorService._();

  // -------------------------------------------------------------------------
  // Internal state
  // -------------------------------------------------------------------------

  bool _bleConnected = false;
  bool _networkConnected = false;

  DateTime? _lastBleConnectTime;
  DateTime? _bleDisconnectTime;

  DateTime? _lastNetworkConnectTime;

  // -------------------------------------------------------------------------
  // Public getters
  // -------------------------------------------------------------------------

  /// True when both BLE device and network are connected.
  bool get isFullyConnected => _bleConnected && _networkConnected;

  /// True when the BLE device is connected.
  bool get isBleConnected => _bleConnected;

  /// True when the device has network connectivity.
  bool get isNetworkConnected => _networkConnected;

  /// The last time BLE connected successfully (null if never connected).
  DateTime? get lastBleConnectTime => _lastBleConnectTime;

  /// The last time network connectivity was confirmed (null if never connected).
  DateTime? get lastNetworkConnectTime => _lastNetworkConnectTime;

  /// How long BLE has been offline.  Returns [Duration.zero] when BLE is
  /// currently connected or has never been connected.
  Duration get bleOfflineDuration {
    if (_bleConnected || _bleDisconnectTime == null) return Duration.zero;
    return DateTime.now().difference(_bleDisconnectTime!);
  }

  /// Combined health status derived from individual connection states.
  CombinedHealthStatus get healthStatus {
    if (_networkConnected == false && _bleConnected == false) {
      // If we've never had an update yet, report unknown.
      if (_lastBleConnectTime == null && _lastNetworkConnectTime == null) {
        return CombinedHealthStatus.unknown;
      }
      return CombinedHealthStatus.fullyDisconnected;
    }
    if (_bleConnected && _networkConnected) {
      return CombinedHealthStatus.fullyConnected;
    }
    if (_bleConnected) return CombinedHealthStatus.bleOnlyConnected;
    return CombinedHealthStatus.networkOnlyConnected;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Start monitoring.  Safe to call multiple times.
  void initialize() {
    // Subscribe to network status changes.
    NetworkStatusService.instance.addListener(_onNetworkStatusChanged);

    // Sync current network state immediately.
    final networkConnected = NetworkStatusService.instance.isConnected;
    _setNetworkConnected(networkConnected);

    debugPrint(
      '[ConnectivityMonitorService] Initialized. '
      'BLE=$_bleConnected Network=$_networkConnected',
    );
  }

  @override
  void dispose() {
    NetworkStatusService.instance.removeListener(_onNetworkStatusChanged);
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Call whenever the BLE connection state changes.
  ///
  /// Pass [connected] = true when a device connects successfully, false when
  /// it disconnects.  Optionally supply the last known [rssi] for diagnostics.
  void updateBleStatus({required bool connected, int? rssi}) {
    if (_bleConnected == connected) return;
    _bleConnected = connected;

    if (connected) {
      _lastBleConnectTime = DateTime.now();
      _bleDisconnectTime = null;
      debugPrint(
        '[ConnectivityMonitorService] BLE connected'
        '${rssi != null ? " (RSSI $rssi dBm)" : ""}.',
      );
    } else {
      _bleDisconnectTime = DateTime.now();
      debugPrint(
        '[ConnectivityMonitorService] BLE disconnected. '
        'Was connected for '
        '${_lastBleConnectTime != null ? DateTime.now().difference(_lastBleConnectTime!).inSeconds : 0}s.',
      );
    }

    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  void _onNetworkStatusChanged() {
    final connected = NetworkStatusService.instance.isConnected;
    _setNetworkConnected(connected);
  }

  void _setNetworkConnected(bool connected) {
    if (_networkConnected == connected) return;
    _networkConnected = connected;
    if (connected) {
      _lastNetworkConnectTime = DateTime.now();
      debugPrint('[ConnectivityMonitorService] Network connected.');
    } else {
      debugPrint('[ConnectivityMonitorService] Network disconnected.');
    }
    notifyListeners();
  }
}
