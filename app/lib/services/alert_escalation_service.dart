import 'package:flutter/foundation.dart';

/// Manages alert escalation: if AnomalyLevel.anomaly persists for
/// [escalationSeconds] (default 15), escalates to "critical" mode.
class AlertEscalationService {
  AlertEscalationService._();
  static final AlertEscalationService instance = AlertEscalationService._();

  static const int escalationSeconds = 15;

  DateTime? _anomalySince;
  bool _criticalActive = false;

  /// Call each time a new anomaly level is detected.
  /// Returns true if the system should display CRITICAL escalation.
  bool update(bool isAnomaly) {
    if (isAnomaly) {
      _anomalySince ??= DateTime.now();
      final elapsed = DateTime.now().difference(_anomalySince!).inSeconds;
      if (elapsed >= escalationSeconds && !_criticalActive) {
        _criticalActive = true;
        debugPrint('[EscalationService] CRITICAL activated after ${elapsed}s of anomaly');
      }
    } else {
      if (_anomalySince != null || _criticalActive) {
        debugPrint('[EscalationService] Alert cleared');
      }
      _anomalySince = null;
      _criticalActive = false;
    }
    return _criticalActive;
  }

  bool get isCritical => _criticalActive;
  int get anomalyDurationSeconds =>
      _anomalySince != null ? DateTime.now().difference(_anomalySince!).inSeconds : 0;

  void reset() {
    _anomalySince = null;
    _criticalActive = false;
  }
}
