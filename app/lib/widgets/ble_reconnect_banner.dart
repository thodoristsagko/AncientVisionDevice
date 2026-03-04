import 'package:flutter/material.dart';
import '../utils/app_styles.dart';

/// An animated banner displayed when BLE connectivity is lost.
///
/// Shows:
///   - The current reconnect attempt number and max
///   - A live countdown until the next automatic retry
///   - A "Retry Now" button to trigger an immediate attempt
///   - A "Cancel" button to stop all retries
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
///     onRetryNow: () => _manager.retryNow(...),
///     onCancel: () { _manager.cancel(); setState(() => _isDisconnected = false); },
///   ),
/// ```
class BleReconnectBanner extends StatefulWidget {
  final int attemptNumber;
  final int maxAttempts;
  final int secondsUntilRetry;
  final VoidCallback onRetryNow;
  final VoidCallback onCancel;

  const BleReconnectBanner({
    super.key,
    required this.attemptNumber,
    required this.maxAttempts,
    required this.secondsUntilRetry,
    required this.onRetryNow,
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

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFB71C1C), Color(0xFFE65100)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
        ),
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
    final String attemptLabel = widget.attemptNumber == 0
        ? 'Connection lost'
        : 'Connection lost — attempt ${widget.attemptNumber}/${widget.maxAttempts}';

    final String countdownLabel = widget.secondsUntilRetry > 0
        ? 'Retrying in ${widget.secondsUntilRetry}s'
        : 'Connecting...';

    return Row(
      children: [
        const Icon(Icons.bluetooth_disabled, color: Colors.white, size: 20),
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
              Text(
                countdownLabel,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        // Mini countdown progress
        if (widget.secondsUntilRetry > 0)
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              value: null, // indeterminate while counting down
              strokeWidth: 3,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
      ],
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
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
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: widget.onRetryNow,
            icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFB71C1C)),
            label: const Text(
              'Retry Now',
              style: TextStyle(color: Color(0xFFB71C1C), fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact inline chip variant for use inside card views.
///
/// Shows a pulsing red dot + "Reconnecting..." text.
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
