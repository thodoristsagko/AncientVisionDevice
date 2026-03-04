import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';

/// Manages BLE reconnection attempts with exponential (stepped) backoff.
///
/// Usage:
/// ```dart
/// final manager = BleReconnectManager();
///
/// manager.startReconnect(
///   onAttempt: () => _connectToDevice(),
///   onGiveUp: () => _showPermanentDisconnectUI(),
/// );
///
/// // User taps "Retry Now" button:
/// manager.retryNow(onAttempt: () => _connectToDevice(), onGiveUp: () {});
///
/// // BLE connected successfully:
/// manager.reset();
/// ```
class BleReconnectManager {
  // -----------------------------------------------------------------------
  // Constants
  // -----------------------------------------------------------------------

  static const int maxAttempts = 5;

  /// Backoff delays (seconds) indexed by attempt number (0-based).
  /// After attempt 0 wait 3 s, after attempt 1 wait 5 s, etc.
  static const List<int> retryDelays = [3, 5, 10, 30, 60];

  // -----------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------

  int _attempts = 0;
  Timer? _retryTimer;
  int _secondsUntilRetry = 0;
  Timer? _countdownTimer;

  /// Callback invoked when the countdown is updated (for UI refresh).
  VoidCallback? onCountdownTick;

  // -----------------------------------------------------------------------
  // Public API
  // -----------------------------------------------------------------------

  /// Number of reconnect attempts made so far (1-based when first attempt fires).
  int get currentAttempt => _attempts;

  /// Seconds remaining until the next scheduled retry.
  int get secondsUntilRetry => _secondsUntilRetry;

  /// Whether the manager has given up (all attempts exhausted).
  bool get hasGivenUp => _attempts >= maxAttempts && _retryTimer == null;

  /// Delay in seconds before the *next* attempt fires.
  int get nextRetrySeconds =>
      retryDelays[min(_attempts, retryDelays.length - 1)];

  /// Start the reconnect sequence.
  ///
  /// [onAttempt] is called once per reconnect attempt.
  /// [onGiveUp] is called when [maxAttempts] have been exhausted without
  /// a successful connection (the caller must have invoked [reset] to signal
  /// success).
  void startReconnect({
    required void Function() onAttempt,
    required void Function() onGiveUp,
  }) {
    cancel(); // clear any previous run
    _attempts = 0;
    _scheduleNextAttempt(onAttempt: onAttempt, onGiveUp: onGiveUp);
  }

  /// Force an immediate retry, resetting the countdown.
  void retryNow({
    required void Function() onAttempt,
    required void Function() onGiveUp,
  }) {
    _cancelTimers();
    _fireAttempt(onAttempt: onAttempt, onGiveUp: onGiveUp);
  }

  /// Cancel all pending timers. Call when BLE connects successfully or the
  /// user explicitly cancels.
  void cancel() {
    _cancelTimers();
  }

  /// Reset attempt counter. Call after a successful connection.
  void reset() {
    _cancelTimers();
    _attempts = 0;
    _secondsUntilRetry = 0;
  }

  // -----------------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------------

  void _scheduleNextAttempt({
    required void Function() onAttempt,
    required void Function() onGiveUp,
  }) {
    if (_attempts >= maxAttempts) {
      onGiveUp();
      return;
    }

    final delaySecs = retryDelays[min(_attempts, retryDelays.length - 1)];
    _secondsUntilRetry = delaySecs;
    onCountdownTick?.call();

    // Tick every second so the UI can show a live countdown
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _secondsUntilRetry = (_secondsUntilRetry - 1).clamp(0, delaySecs);
      onCountdownTick?.call();
    });

    _retryTimer = Timer(Duration(seconds: delaySecs), () {
      _cancelCountdown();
      _fireAttempt(onAttempt: onAttempt, onGiveUp: onGiveUp);
    });
  }

  void _fireAttempt({
    required void Function() onAttempt,
    required void Function() onGiveUp,
  }) {
    _attempts++;
    onAttempt();
    _scheduleNextAttempt(onAttempt: onAttempt, onGiveUp: onGiveUp);
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelCountdown();
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _secondsUntilRetry = 0;
  }
}
