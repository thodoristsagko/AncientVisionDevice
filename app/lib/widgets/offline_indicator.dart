import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

// ---------------------------------------------------------------------------
// _ConnectivityType — internal enum capturing what interface is active
// ---------------------------------------------------------------------------

enum _ConnectivityType { wifi, mobile, none }

String _connectivityLabel(_ConnectivityType type) {
  switch (type) {
    case _ConnectivityType.wifi:
      return 'WiFi';
    case _ConnectivityType.mobile:
      return 'Mobile data';
    case _ConnectivityType.none:
      return 'None';
  }
}

IconData _connectivityIcon(_ConnectivityType type) {
  switch (type) {
    case _ConnectivityType.wifi:
      return Icons.wifi_off;
    case _ConnectivityType.mobile:
      return Icons.signal_cellular_off;
    case _ConnectivityType.none:
      return Icons.wifi_off;
  }
}

_ConnectivityType _resultToType(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.wifi)) return _ConnectivityType.wifi;
  if (results.contains(ConnectivityResult.mobile)) return _ConnectivityType.mobile;
  return _ConnectivityType.none;
}

bool _hasConnection(List<ConnectivityResult> results) {
  return results.any((r) =>
      r == ConnectivityResult.wifi ||
      r == ConnectivityResult.mobile ||
      r == ConnectivityResult.ethernet ||
      r == ConnectivityResult.vpn);
}

// ---------------------------------------------------------------------------
// OfflineIndicator
// ---------------------------------------------------------------------------

/// Wraps [child] and overlays a slide-in banner at the top whenever the device
/// has no network connectivity.
///
/// Enhanced features:
/// - Shows specific connectivity type (WiFi / mobile / none).
/// - Slide-in animation when going offline.
/// - "Offline — data will sync when connected" messaging.
/// - After 5 minutes offline, shows "Offline for Xm — X sessions pending sync".
/// - "Retry" button that triggers a manual connectivity re-check.
class OfflineIndicator extends StatefulWidget {
  final Widget child;
  final bool showBanner;

  /// Optional count of sessions that are pending sync.
  final int? pendingSyncCount;

  const OfflineIndicator({
    super.key,
    required this.child,
    this.showBanner = true,
    this.pendingSyncCount,
  });

  @override
  State<OfflineIndicator> createState() => _OfflineIndicatorState();
}

class _OfflineIndicatorState extends State<OfflineIndicator>
    with SingleTickerProviderStateMixin {
  // -------------------------------------------------------------------------
  // Connectivity state
  // -------------------------------------------------------------------------
  late StreamSubscription<List<ConnectivityResult>> _subscription;
  bool _isOffline = false;
  _ConnectivityType _connectivityType = _ConnectivityType.none;

  // -------------------------------------------------------------------------
  // Offline duration tracking
  // -------------------------------------------------------------------------
  DateTime? _offlineSince;
  Timer? _durationTimer;
  Duration _offlineDuration = Duration.zero;

  // -------------------------------------------------------------------------
  // Animation
  // -------------------------------------------------------------------------
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _checkConnectivity();
    _subscription =
        Connectivity().onConnectivityChanged.listen(_updateConnectionStatus);
  }

  Future<void> _checkConnectivity() async {
    try {
      final result = await Connectivity().checkConnectivity();
      _updateConnectionStatus(result);
    } catch (_) {
      // Ignore — will be updated by stream.
    }
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    final isOffline = !_hasConnection(results);
    final type = _resultToType(results);

    if (!mounted) return;

    if (isOffline && !_isOffline) {
      // Went offline — start tracking duration.
      _offlineSince = DateTime.now();
      _offlineDuration = Duration.zero;
      _durationTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted) return;
        setState(() {
          _offlineDuration = DateTime.now().difference(_offlineSince!);
        });
      });
      setState(() {
        _isOffline = true;
        _connectivityType = type;
      });
      _animationController.forward();
    } else if (!isOffline && _isOffline) {
      // Came back online.
      _durationTimer?.cancel();
      _durationTimer = null;
      _offlineSince = null;
      _offlineDuration = Duration.zero;
      setState(() {
        _isOffline = false;
        _connectivityType = type;
      });
      _animationController.reverse();
    } else if (_connectivityType != type && mounted) {
      setState(() => _connectivityType = type);
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    _animationController.dispose();
    _durationTimer?.cancel();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  bool get _hasBeenOfflineLong => _offlineDuration.inMinutes >= 5;

  int get _pendingCount => widget.pendingSyncCount ?? 0;

  String get _bannerMessage {
    if (_hasBeenOfflineLong) {
      final mins = _offlineDuration.inMinutes;
      final pending = _pendingCount;
      if (pending > 0) {
        return 'Offline for ${mins}m — '
            '$pending session${pending == 1 ? '' : 's'} pending sync';
      }
      return 'Offline for ${mins}m — data will sync when connected';
    }
    return 'Offline — data will sync when connected';
  }

  void _retry() {
    // NetworkStatusService.instance.checkNow() would go here if it existed.
    // Fall back to a manual poll via connectivity_plus.
    _checkConnectivity();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!widget.showBanner) return widget.child;

    return Stack(
      children: [
        widget.child,
        SlideTransition(
          position: _slideAnimation,
          child: AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              if (!_isOffline && _animationController.isDismissed) {
                return const SizedBox.shrink();
              }
              return child!;
            },
            child: _OfflineBanner(
              connectivityType: _connectivityType,
              message: _bannerMessage,
              onRetry: _retry,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _OfflineBanner — the visible red banner
// ---------------------------------------------------------------------------

class _OfflineBanner extends StatelessWidget {
  final _ConnectivityType connectivityType;
  final String message;
  final VoidCallback onRetry;

  const _OfflineBanner({
    required this.connectivityType,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF5722).withAlpha(230),
            const Color(0xFFE64A19).withAlpha(230),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(50),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            children: [
              Icon(
                _connectivityIcon(connectivityType),
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Connection: ${_connectivityLabel(connectivityType)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: const BorderSide(color: Colors.white38),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: const Text('Retry', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OfflineChip — small app bar indicator
// ---------------------------------------------------------------------------

/// Small offline chip indicator for app bars.
class OfflineChip extends StatefulWidget {
  const OfflineChip({super.key});

  @override
  State<OfflineChip> createState() => _OfflineChipState();
}

class _OfflineChipState extends State<OfflineChip> {
  late StreamSubscription<List<ConnectivityResult>> _subscription;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _subscription =
        Connectivity().onConnectivityChanged.listen(_updateConnectionStatus);
  }

  Future<void> _checkConnectivity() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _updateConnectionStatus(results);
    } catch (_) {}
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    final isOffline = !_hasConnection(results);
    if (isOffline != _isOffline && mounted) {
      setState(() => _isOffline = isOffline);
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isOffline) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFF5722).withAlpha(40),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF5722).withAlpha(100)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off, color: Color(0xFFFF5722), size: 14),
          SizedBox(width: 4),
          Text(
            'Offline',
            style: TextStyle(
              color: Color(0xFFFF5722),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ConnectivityHelper — backward-compat singleton
// ---------------------------------------------------------------------------

/// Connectivity status helper (singleton, backward-compatible).
class ConnectivityHelper {
  static final ConnectivityHelper _instance = ConnectivityHelper._internal();
  factory ConnectivityHelper() => _instance;
  ConnectivityHelper._internal();

  final _connectivity = Connectivity();
  final _controller = StreamController<bool>.broadcast();

  Stream<bool> get onlineStream => _controller.stream;
  bool _isOnline = true;
  bool get isOnline => _isOnline;

  Future<void> initialize() async {
    final results = await _connectivity.checkConnectivity();
    _updateStatus(results);
    _connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  void _updateStatus(List<ConnectivityResult> results) {
    final online = _hasConnection(results);
    if (online != _isOnline) {
      _isOnline = online;
      _controller.add(online);
    }
  }

  Future<bool> checkConnectivity() async {
    final results = await _connectivity.checkConnectivity();
    return _hasConnection(results);
  }

  void dispose() {
    _controller.close();
  }
}
