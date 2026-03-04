import 'package:flutter/services.dart';

/// Haptic feedback patterns for the AncientVision safety system.
///
/// Each pattern is tuned to convey the urgency and character of the
/// corresponding seismic precursor type so that field users can receive
/// safety information even without looking at the screen.
///
/// Pattern design rationale:
///   - soil_creep      : slow, building threat → 2 light pulses, 200 ms apart
///   - crack_propagation: urgent, repeated      → 3 medium pulses, 100 ms apart
///   - imminent_failure : CRITICAL              → 3 heavy pulses, 50 ms apart
///   - levelUp          : hazard level raised   → single medium impact
///   - allClear         : safe again            → single light impact
class HapticService {
  // Private constructor — static-only class.
  HapticService._();

  // -------------------------------------------------------------------------
  // Precursor-specific patterns
  // -------------------------------------------------------------------------

  /// Soil creep alert: 2 light pulses separated by 200 ms.
  ///
  /// Conveys a slow, building threat that still needs attention.
  static Future<void> soilCreepAlert() async {
    await HapticFeedback.lightImpact();
    await Future.delayed(const Duration(milliseconds: 200));
    await HapticFeedback.lightImpact();
  }

  /// Crack propagation alert: 3 medium pulses separated by 100 ms.
  ///
  /// Conveys an urgent, repeating structural event that demands action.
  static Future<void> crackPropagationAlert() async {
    for (int i = 0; i < 3; i++) {
      await HapticFeedback.mediumImpact();
      if (i < 2) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Imminent failure alert: 3 heavy pulses separated by 50 ms.
  ///
  /// Maximum urgency — EVACUATE AREA.
  static Future<void> imminentFailureAlert() async {
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 50));
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 50));
    await HapticFeedback.heavyImpact();
  }

  // -------------------------------------------------------------------------
  // General-purpose patterns
  // -------------------------------------------------------------------------

  /// Fired when the anomaly level escalates (e.g. normal → unusual).
  static Future<void> levelUp() async {
    await HapticFeedback.mediumImpact();
  }

  /// Fired when conditions return to normal after an alert period.
  static Future<void> allClear() async {
    await HapticFeedback.lightImpact();
  }

  // -------------------------------------------------------------------------
  // Helper: dispatch by precursor pattern name
  // -------------------------------------------------------------------------

  /// Fire the pattern that matches [patternName].
  ///
  /// [patternName] is the raw string from [AnomalyResult.precursorPattern],
  /// e.g. `'soil_creep'`, `'crack_propagation'`, `'imminent_failure'`.
  /// Falls back to [imminentFailureAlert] for unknown critical patterns.
  static Future<void> forPrecursorPattern(String? patternName) async {
    switch (patternName) {
      case 'soil_creep':
        await soilCreepAlert();
        break;
      case 'crack_propagation':
        await crackPropagationAlert();
        break;
      case 'imminent_failure':
        await imminentFailureAlert();
        break;
      default:
        // Unknown critical pattern — use the strongest signal
        await imminentFailureAlert();
    }
  }
}
