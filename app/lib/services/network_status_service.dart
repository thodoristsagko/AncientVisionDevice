import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Coarse network reachability states.
enum NetworkStatus {
  /// At least one viable network interface is up (WiFi, mobile, ethernet…).
  connected,

  /// No network interface is available.
  disconnected,

  /// Status has not yet been determined (before [initialize] completes).
  unknown,
}

/// Singleton service that monitors device network connectivity.
///
/// Backed by the `connectivity_plus` package.  Extends [ChangeNotifier] so
/// that widgets/providers can `addListener` and rebuild on status changes.
///
/// Usage:
/// ```dart
/// await NetworkStatusService.instance.initialize();
/// print(NetworkStatusService.instance.isConnected); // true / false
/// ```
class NetworkStatusService extends ChangeNotifier {
  static final NetworkStatusService instance = NetworkStatusService._();
  NetworkStatusService._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  NetworkStatus _status = NetworkStatus.unknown;

  /// Current network status.
  NetworkStatus get status => _status;

  /// Convenience getter — true when at least one network interface is up.
  bool get isConnected => _status == NetworkStatus.connected;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Start listening to connectivity changes.
  ///
  /// Performs an immediate check and then subscribes to the stream.
  /// Safe to call multiple times (subsequent calls are no-ops).
  Future<void> initialize() async {
    if (_subscription != null) return; // Already initialised.

    try {
      // Perform an initial check.
      final results = await _connectivity.checkConnectivity();
      _updateStatus(results);
    } catch (e) {
      debugPrint('[NetworkStatusService] Initial check failed: $e');
      _setStatus(NetworkStatus.unknown);
    }

    // Subscribe to ongoing connectivity changes.
    try {
      _subscription = _connectivity.onConnectivityChanged.listen(
        _updateStatus,
        onError: (Object e) {
          debugPrint('[NetworkStatusService] Stream error: $e');
          _setStatus(NetworkStatus.unknown);
        },
        cancelOnError: false,
      );
      debugPrint('[NetworkStatusService] Initialized. Status: $_status');
    } catch (e) {
      debugPrint('[NetworkStatusService] Failed to subscribe to stream: $e');
    }
  }

  @override
  void dispose() {
    try {
      _subscription?.cancel();
      _subscription = null;
    } catch (e) {
      debugPrint('[NetworkStatusService] dispose error: $e');
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _updateStatus(List<ConnectivityResult> results) {
    final connected = results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn);
    _setStatus(
      connected ? NetworkStatus.connected : NetworkStatus.disconnected,
    );
  }

  void _setStatus(NetworkStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    debugPrint('[NetworkStatusService] Status changed → $_status');
    notifyListeners();
  }
}
