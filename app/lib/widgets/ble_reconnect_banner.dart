import 'package:flutter/material.dart';
import '../utils/app_styles.dart';

// ---------------------------------------------------------------------------
// RSSI helper
// ---------------------------------------------------------------------------

/// Converts an RSSI value (dBm) to a 0–5 bar count.
///
/// Thresholds follow common BLE RSSI conventions:
///   ≥ -55 dBm → 5 bars (excellent)
///   ≥ -65 dBm → 4 bars (good)
///   ≥ -75 dBm → 3 bars (fair)
///   ≥ -85 dBm → 2 bars (weak)
///   ≥ -95 dBm → 1 bar  (very weak)
///   <  -95 dBm → 0 bars (no signal)
int _rssiToBars(int rssi) {
  if (rssi >= -55) return 5;
  if (rssi >= -65) return 4;
  if (rssi >= -75) return 3;
  if (rssi >= -85) return 2;
  if (rssi >= -95) return 1;
  return 0;
}

// ---------------------------------------------------------------------------
// _SignalStrengthDots — "●●●○○" style widget
// ---------------------------------------------------------------------------

class _SignalStrengthDots extends StatelessWidget {
  final int bars; // 0–5
  static const int _maxBars = 5;

  const _SignalStrengthDots({required this.bars});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_maxBars, (i) {
        final filled = i < bars;
        return Padding(
          padding: const EdgeInsets.only(right: 2),
          child: Text(
            '●',
            style: TextStyle(
              fontSize: 10,
              color: filled ? Colors.white : Colors.white38,
            ),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// BleReconnectBanner
// ---------------------------------------------------------------------------

/// An animated banner displayed when BLE connectivity is lost.
///
/// Shows:
///   - The current reconnect attempt number and max.
///   - A live countdown until the next automatic retry.
///   - Last known RSSI as a "Signal: ●●●○○" indicator.
///   - A "Retry Now" button to trigger an immediate attempt.
///   - A "Scan for devices" button to pop back to device scanning mode.
///   - A "Cancel" button to stop all retries.
///   - Color: orange while attempting, red when all attempts have failed.
///
/// Wrap in an [AnimatedSwitcher] or a [Visibility] widget to slide it in/out.
///
/// Example:
/// ```dart
/// if (_isDisconnected)
///   BleReconnectBanner(
///     attemptNumber: _manager.currentAttempt,
///     maxAttempts: BleReconnectManager.maxAttempts,
///     secondsUntilRetry: _manager.secondsUntilRetry,
///     lastRssi: _lastKnownRssi,
///     onRetryNow: () => _manager.retryNow(...),
///     onScan: () => Navigator.of(context).pop(),
///     onCancel: () { _manager.cancel(); setState(() => _isDisconnected = false); },
///   ),
/// ```
class BleReconnectBanner extends StatefulWidget {
  final int attemptNumber;
  final int maxAttempts;
  final int secondsUntilRetry;

  /// Last known RSSI in dBm.  Pass null if unavailable.
  final int? lastRssi;

  final VoidCallback onRetryNow;

  /// Called when the user taps "Scan for devices".  Typically pops back to
  /// the device-scanning screen.  Pass null to hide the button.
  final VoidCallback? onScan;

  final VoidCallback onCancel;

  const BleReconnectBanner({
    super.key,
    required this.attemptNumber,
    required this.maxAttempts,
    required this.secondsUntilRetry,
    this.lastRssi,
    required this.onRetryNow,
    this.onScan,
    required this.onCancel,
  });

  @override
  State<BleReconnectBanner> createState() => _BleReconnectBannerState();
}

class _BleReconnectBannerState extends State<BleReconnectBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // State-derived helpers
  // -------------------------------------------------------------------------

  /// True when all retry attempts have been exhausted.
  bool get _hasFailed =>
      widget.attemptNumber >= widget.maxAttempts &&
      widget.secondsUntilRetry == 0;

  /// Background gradient: orange while retrying, red when failed.
  LinearGradient get _gradient {
    if (_hasFailed) {
      return const LinearGradient(
        colors: [Color(0xFFB71C1C), Color(0xFFE53935)],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      );
    }
    return const LinearGradient(
      colors: [Color(0xFFE65100), Color(0xFFF57C00)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Container(
        decoration: BoxDecoration(gradient: _gradient),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildStatusRow(),
                const SizedBox(height: 8),
                _buildActionRow(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusRow() {
    final String attemptLabel;
    if (_hasFailed) {
      attemptLabel = 'Connection failed after ${widget.maxAttempts} attempts';
    } else if (widget.attemptNumber == 0) {
      attemptLabel = 'Connection lost';
    } else {
      attemptLabel =
          'Reconnect attempt ${widget.attemptNumber}/${widget.maxAttempts}';
    }

    final String countdownLabel = widget.secondsUntilRetry > 0
        ? 'Retrying in ${widget.secondsUntilRetry}s'
        : (_hasFailed ? 'No further retries' : 'Connecting...');

    return Row(
      children: [
        Icon(
          _hasFailed ? Icons.bluetooth_disabled : Icons.bluetooth_searching,
          color: Colors.white,
          size: 20,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                attemptLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    countdownLabel,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  if (widget.lastRssi != null) ...[
                    const SizedBox(width: 10),
                    _buildSignalIndicator(widget.lastRssi!),
                  ],
                ],
              ),
            ],
          ),
        ),
        // Mini countdown spinner
        if (widget.secondsUntilRetry > 0)
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
      ],
    );
  }

  Widget _buildSignalIndicator(int rssi) {
    final bars = _rssiToBars(rssi);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Signal: ',
          style: TextStyle(color: Colors.white70, fontSize: 11),
        ),
        _SignalStrengthDots(bars: bars),
        const SizedBox(width: 4),
        Text(
          '($rssi dBm)',
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        // Cancel button
        Expanded(
          child: OutlinedButton(
            onPressed: widget.onCancel,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white38),
              padding: const EdgeInsets.symmetric(vertical: 8),
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Cancel', style: TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(width: 8),
        // Scan button (optional)
        if (widget.onScan != null) ...[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: widget.onScan,
              icon: const Icon(Icons.search, size: 15, color: Colors.white),
              label: const Text(
                'Scan',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
                padding: const EdgeInsets.symmetric(vertical: 8),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        // Retry Now button
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: _hasFailed ? null : widget.onRetryNow,
            icon: Icon(
              Icons.refresh,
              size: 16,
              color: _hasFailed ? Colors.grey : const Color(0xFFB71C1C),
            ),
            label: Text(
              'Retry Now',
              style: TextStyle(
                color: _hasFailed ? Colors.grey : const Color(0xFFB71C1C),
                fontSize: 13,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              disabledBackgroundColor: Colors.white38,
              padding: const EdgeInsets.symmetric(vertical: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// BleReconnectingChip — compact inline chip variant
// ---------------------------------------------------------------------------

/// Compact inline chip variant for use inside card views.
///
/// Shows a pulsing dot + "Reconnecting…" text.
class BleReconnectingChip extends StatefulWidget {
  final int secondsUntilRetry;

  const BleReconnectingChip({super.key, required this.secondsUntilRetry});

  @override
  State<BleReconnectingChip> createState() => _BleReconnectingChipState();
}

class _BleReconnectingChipState extends State<BleReconnectingChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.withAlpha(30),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.withAlpha(80)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(
                  ((_pulse.value * 200) + 55).round(),
                ),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              widget.secondsUntilRetry > 0
                  ? 'Reconnecting in ${widget.secondsUntilRetry}s'
                  : 'Reconnecting...',
              style: AppTextStyles.caption.copyWith(color: Colors.red[300]),
            ),
          ],
        ),
      ),
    );
  }
}
