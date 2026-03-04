import 'package:flutter/foundation.dart';

/// A single escalation or de-escalation event recorded in the session history.
class EscalationEvent {
  /// Wall-clock time the transition occurred.
  final DateTime timestamp;

  /// Alert level before the transition (e.g. 'normal', 'caution', 'anomaly',
  /// 'critical').
  final String fromLevel;

  /// Alert level after the transition.
  final String toLevel;

  const EscalationEvent({
    required this.timestamp,
    required this.fromLevel,
    required this.toLevel,
  });

  @override
  String toString() =>
      'EscalationEvent(${timestamp.toIso8601String()}: $fromLevel→$toLevel)';
}

/// Manages alert escalation with hysteresis, history, and frequency detection.
///
/// Escalation logic (unchanged from v1):
///   If [isAnomaly] has been true for [escalationSeconds] (default 15) without
///   interruption, the service promotes to CRITICAL mode.
///
/// De-escalation hysteresis (new in v2):
///   When the anomaly clears and CRITICAL was active, de-escalation is
///   confirmed only after [deEscalationSeconds] (default 30) of sustained
///   non-anomaly readings. This prevents a brief dip from clearing an alert
///   that was triggered by a genuine, sustained event.
///
/// Escalation history:
///   Every confirmed level transition is appended to [escalationHistory].
///   Use [escalationCount] and [isFrequentlyEscalating] for session-level
///   assessment, and [reset] to start a new session.
class AlertEscalationService {
  AlertEscalationService._();
  static final AlertEscalationService instance = AlertEscalationService._();

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  /// Seconds of continuous anomaly required before escalating to CRITICAL.
  static const int escalationSeconds = 15;

  /// Seconds of sustained non-anomaly required before de-escalating from
  /// CRITICAL (hysteresis window).
  static const int deEscalationSeconds = 30;

  /// Rolling window (seconds) used for the frequent-escalation check.
  static const int _frequentEscalationWindowSec = 300; // 5 minutes

  /// Escalation count threshold within [_frequentEscalationWindowSec] that
  /// triggers the [isFrequentlyEscalating] flag.
  static const int _frequentEscalationThreshold = 3;

  // ---------------------------------------------------------------------------
  // Private state
  // ---------------------------------------------------------------------------

  DateTime? _anomalySince;
  bool _criticalActive = false;

  // De-escalation hysteresis: when anomaly clears while critical is active,
  // we start a pending de-escalation timer instead of clearing immediately.
  DateTime? _deEscalationPendingSince;

  // Escalation history (all events, new session starts after reset()).
  final List<EscalationEvent> _history = [];

  // Tracks the "last known" level string so we can record from→to transitions.
  String _currentLevel = 'normal';

  // ---------------------------------------------------------------------------
  // Rate limiting
  // ---------------------------------------------------------------------------

  /// Maximum one [update] call processed per second to prevent notification spam.
  static const Duration _minUpdateInterval = Duration(seconds: 1);

  /// Wall-clock time of the most recent [update] call that was processed.
  DateTime? _lastUpdateTime;

  // ---------------------------------------------------------------------------
  // Same-level repeat escalation
  // ---------------------------------------------------------------------------

  /// Escalation level at the start of the current rapid-repeat window.
  String? _repeatLevel;

  /// Time at which the current rapid-repeat window started.
  DateTime? _repeatWindowStart;

  /// How many times the same alert level has fired in [_repeatWindowDuration].
  int _repeatCount = 0;

  /// Duration of the rapid-repeat escalation detection window.
  static const Duration _repeatWindowDuration = Duration(seconds: 30);

  /// Number of same-level fires within [_repeatWindowDuration] that auto-escalates
  /// the alert to the next severity level.
  static const int _repeatEscalationThreshold = 3;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Call each time a new anomaly level is detected.
  ///
  /// [isAnomaly] should be true when the current reading is classified as
  /// anomalous (what was previously passed straight to update()).
  ///
  /// Rate-limited to at most 1 processed call per [_minUpdateInterval] to
  /// prevent notification spam.  Calls within the cooldown are silently dropped
  /// (returning the current [isCritical] state unchanged).
  ///
  /// Same-level repeat escalation: if the same alert level fires
  /// [_repeatEscalationThreshold] times within [_repeatWindowDuration], the
  /// service auto-escalates to the next severity level.
  ///
  /// Returns true if the system should display CRITICAL escalation.
  bool update(bool isAnomaly) {
    final now = DateTime.now();

    // Rate limiting: drop calls that arrive faster than once per second.
    if (_lastUpdateTime != null &&
        now.difference(_lastUpdateTime!) < _minUpdateInterval) {
      return _criticalActive;
    }
    _lastUpdateTime = now;

    // Same-level repeat escalation check.
    final currentInputLevel = isAnomaly ? 'anomaly' : 'normal';
    if (currentInputLevel == _repeatLevel) {
      if (_repeatWindowStart != null &&
          now.difference(_repeatWindowStart!) <= _repeatWindowDuration) {
        _repeatCount++;
        if (_repeatCount >= _repeatEscalationThreshold && !_criticalActive) {
          // Same level fired >= threshold times in the window; force critical.
          _criticalActive = true;
          _recordTransition(_currentLevel, 'critical', now);
          debugPrint(
            '[EscalationService] CRITICAL forced by  rapid repeats '
            'of level ',
          );
        }
      } else {
        // Window expired -- start a fresh window.
        _repeatWindowStart = now;
        _repeatCount = 1;
      }
    } else {
      // Level changed -- reset repeat tracking.
      _repeatLevel = currentInputLevel;
      _repeatWindowStart = now;
      _repeatCount = 1;
    }

    if (isAnomaly) {
      // Cancel any pending de-escalation — anomaly is back.
      _deEscalationPendingSince = null;

      _anomalySince ??= now;
      final elapsed = now.difference(_anomalySince!).inSeconds;

      if (elapsed >= escalationSeconds && !_criticalActive) {
        _criticalActive = true;
        _recordTransition('anomaly', 'critical', now);
        debugPrint(
          '[EscalationService] CRITICAL activated after ${elapsed}s of anomaly',
        );
      } else if (!_criticalActive && _currentLevel != 'anomaly') {
        _recordTransition(_currentLevel, 'anomaly', now);
      }
    } else {
      if (_criticalActive) {
        // Start or continue the de-escalation hysteresis window.
        _deEscalationPendingSince ??= now;
        final pendingElapsed =
            now.difference(_deEscalationPendingSince!).inSeconds;

        if (pendingElapsed >= deEscalationSeconds) {
          // De-escalation confirmed after sustained non-anomaly period.
          debugPrint(
            '[EscalationService] CRITICAL cleared after '
            '${pendingElapsed}s non-anomaly',
          );
          _recordTransition('critical', 'normal', now);
          _anomalySince = null;
          _criticalActive = false;
          _deEscalationPendingSince = null;
        }
        // While pending, keep _criticalActive = true.
      } else {
        // No critical active — clear immediately (same as v1 behaviour for
        // the non-critical anomaly→normal path).
        if (_anomalySince != null) {
          debugPrint('[EscalationService] Alert cleared');
          if (_currentLevel != 'normal') {
            _recordTransition(_currentLevel, 'normal', now);
          }
        }
        _anomalySince = null;
        _deEscalationPendingSince = null;
      }
    }

    return _criticalActive;
  }

  // ---------------------------------------------------------------------------
  // Read-only status
  // ---------------------------------------------------------------------------

  /// True when CRITICAL escalation is active.
  bool get isCritical => _criticalActive;

  /// Seconds the system has been continuously in anomaly state.
  /// Returns 0 when no anomaly is active.
  int get anomalyDurationSeconds =>
      _anomalySince != null
          ? DateTime.now().difference(_anomalySince!).inSeconds
          : 0;

  /// True when a de-escalation is pending (hysteresis window is counting down).
  bool get isDeEscalationPending => _deEscalationPendingSince != null;

  /// Seconds remaining in the de-escalation hysteresis window.
  /// Returns 0 when no de-escalation is pending.
  int get deEscalationRemainingSeconds {
    if (_deEscalationPendingSince == null) return 0;
    final elapsed =
        DateTime.now().difference(_deEscalationPendingSince!).inSeconds;
    final remaining = deEscalationSeconds - elapsed;
    return remaining > 0 ? remaining : 0;
  }

  // ---------------------------------------------------------------------------
  // Escalation history
  // ---------------------------------------------------------------------------

  /// Unmodifiable view of all escalation/de-escalation events this session.
  List<EscalationEvent> get escalationHistory =>
      List.unmodifiable(_history);

  /// Number of upward escalations (transitions to a more-severe level) recorded
  /// since the last [reset] call.
  int get escalationCount =>
      _history.where((e) => _isSeverityIncrease(e.fromLevel, e.toLevel)).length;

  /// True when there have been [_frequentEscalationThreshold] or more
  /// escalations within the last [_frequentEscalationWindowSec] seconds.
  bool get isFrequentlyEscalating {
    final cutoff = DateTime.now().subtract(
      const Duration(seconds: _frequentEscalationWindowSec),
    );
    final recentEscalations = _history.where(
      (e) =>
          e.timestamp.isAfter(cutoff) &&
          _isSeverityIncrease(e.fromLevel, e.toLevel),
    );
    return recentEscalations.length >= _frequentEscalationThreshold;
  }

  // ---------------------------------------------------------------------------
  // Session management
  // ---------------------------------------------------------------------------

  /// Reset all state — clears history, counters, and active escalation.
  ///
  /// Call this when starting a new monitoring session (e.g. on BLE reconnect).
  void reset() {
    _anomalySince = null;
    _criticalActive = false;
    _deEscalationPendingSince = null;
    _history.clear();
    _currentLevel = 'normal';
    _lastUpdateTime = null;
    _repeatLevel = null;
    _repeatWindowStart = null;
    _repeatCount = 0;
    debugPrint('[EscalationService] Session reset');
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _recordTransition(String from, String to, DateTime at) {
    _history.add(EscalationEvent(timestamp: at, fromLevel: from, toLevel: to));
    _currentLevel = to;
  }

  /// Returns true when [to] represents a higher severity than [from].
  static bool _isSeverityIncrease(String from, String to) {
    const order = {'normal': 0, 'caution': 1, 'anomaly': 2, 'critical': 3};
    return (order[to] ?? 0) > (order[from] ?? 0);
  }
}
