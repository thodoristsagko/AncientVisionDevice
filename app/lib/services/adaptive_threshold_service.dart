import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'vibration_anomaly_service.dart';

/// AdaptiveThresholdService
/// Implements P71: adaptive threshold tuning after calibration
///
/// After calibration, adjusts the anomaly detection thresholds based on:
/// - Ambient noise level (from AdaptiveAnomalyService baseline)
/// - Site-specific PPV patterns
/// - Time of day (construction hours: 7am-6pm have higher ambient noise)
class AdaptiveThresholdService {
  static final AdaptiveThresholdService instance = AdaptiveThresholdService._();
  AdaptiveThresholdService._();

  double _lowThreshold = 1.0;   // reconstruction error
  double _highThreshold = 2.5;
  double _ppvThreshold = 0.3;   // mm/s

  bool _hasBeenTuned = false;
  DateTime? _lastTuneTime;

  static const String _prefKeyLow = 'adaptive_threshold_low';
  static const String _prefKeyHigh = 'adaptive_threshold_high';
  static const String _prefKeyPpv = 'adaptive_threshold_ppv';
  static const String _prefKeyTuned = 'adaptive_threshold_tuned';
  static const String _prefKeyTuneTime = 'adaptive_threshold_tune_time';

  double get lowThreshold => _lowThreshold;
  double get highThreshold => _highThreshold;
  double get ppvThreshold => _ppvThreshold;
  bool get hasBeenTuned => _hasBeenTuned;

  /// Returns true if the current hour falls within construction hours (7:00–18:00).
  ///
  /// During construction hours ambient background vibration is typically higher
  /// due to nearby machinery and vehicle traffic near archaeological sites.
  bool get _isConstructionHours {
    final hour = DateTime.now().hour;
    return hour >= 7 && hour < 18;
  }

  /// Tune thresholds based on calibration noise floor.
  ///
  /// Higher ambient noise → higher thresholds (to reduce false positives).
  /// [noiseFloor] is ambient RMS acceleration in g.
  ///
  /// An additional construction-hours factor is applied during 7am–6pm to
  /// account for elevated daytime site activity (machinery, vehicles).
  void tuneFromCalibration(double noiseFloor) {
    // 0.005 g = baseline quiet site; noiseFactor scales thresholds proportionally
    final double noiseFactor =
        (noiseFloor / 0.005).clamp(0.5, 3.0);

    // During construction hours (7am–6pm) apply a modest upward bias
    // (×1.25) so machinery noise doesn't trigger false positives.
    final double hourFactor = _isConstructionHours ? 1.25 : 1.0;

    final double combinedFactor = (noiseFactor * hourFactor).clamp(0.5, 3.75);

    _lowThreshold = (1.0 * combinedFactor).clamp(0.5, 3.0);
    _highThreshold = (2.5 * combinedFactor).clamp(1.5, 7.5);
    _ppvThreshold = (0.3 * combinedFactor).clamp(0.1, 1.0);
    _hasBeenTuned = true;
    _lastTuneTime = DateTime.now();

    // Propagate the PPV threshold to the anomaly detection service
    VibrationAnomalyService.instance.setAlertThreshold(_ppvThreshold);

    if (kDebugMode) {
      debugPrint(
        'AdaptiveThresholdService: tuned — '
        'low=$_lowThreshold high=$_highThreshold ppv=$_ppvThreshold '
        '(noise=$noiseFloor noiseFactor=$noiseFactor '
        'constructionHours=$_isConstructionHours)',
      );
    }
  }

  /// Reset all thresholds to factory defaults and clear the tuned flag.
  ///
  /// This should be called when the user changes sites or when a new
  /// calibration session is started from scratch.
  void reset() {
    _lowThreshold = 1.0;
    _highThreshold = 2.5;
    _ppvThreshold = 0.3;
    _hasBeenTuned = false;
    _lastTuneTime = null;
    if (kDebugMode) {
      debugPrint('AdaptiveThresholdService: reset to defaults');
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Persist the current threshold values to SharedPreferences.
  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefKeyLow, _lowThreshold);
      await prefs.setDouble(_prefKeyHigh, _highThreshold);
      await prefs.setDouble(_prefKeyPpv, _ppvThreshold);
      await prefs.setBool(_prefKeyTuned, _hasBeenTuned);
      if (_lastTuneTime != null) {
        await prefs.setString(
          _prefKeyTuneTime,
          _lastTuneTime!.toIso8601String(),
        );
      }
      if (kDebugMode) {
        debugPrint('AdaptiveThresholdService: saved to SharedPreferences');
      }
    } catch (e) {
      debugPrint('AdaptiveThresholdService: save failed — $e');
    }
  }

  /// Restore threshold values from SharedPreferences.
  ///
  /// If no persisted values are found the service remains at its defaults.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lowThreshold = prefs.getDouble(_prefKeyLow) ?? 1.0;
      _highThreshold = prefs.getDouble(_prefKeyHigh) ?? 2.5;
      _ppvThreshold = prefs.getDouble(_prefKeyPpv) ?? 0.3;
      _hasBeenTuned = prefs.getBool(_prefKeyTuned) ?? false;
      final tuneTimeStr = prefs.getString(_prefKeyTuneTime);
      if (tuneTimeStr != null) {
        _lastTuneTime = DateTime.tryParse(tuneTimeStr);
      }
      if (_hasBeenTuned) {
        // Re-apply the restored PPV threshold so VibrationAnomalyService
        // uses the same value that was active in the previous session.
        VibrationAnomalyService.instance.setAlertThreshold(_ppvThreshold);
      }
      if (kDebugMode) {
        debugPrint(
          'AdaptiveThresholdService: loaded — '
          'low=$_lowThreshold high=$_highThreshold ppv=$_ppvThreshold '
          'tuned=$_hasBeenTuned',
        );
      }
    } catch (e) {
      debugPrint('AdaptiveThresholdService: load failed — $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Diagnostics
  // ---------------------------------------------------------------------------

  /// Human-readable summary of the current threshold state.
  String get summary {
    if (!_hasBeenTuned) {
      return 'Default thresholds (not yet tuned)';
    }
    final tuneTimeStr = _lastTuneTime != null
        ? ' @ ${_lastTuneTime!.toLocal().toString().substring(0, 16)}'
        : '';
    return 'Tuned$tuneTimeStr: '
        'low=${_lowThreshold.toStringAsFixed(2)} '
        'high=${_highThreshold.toStringAsFixed(2)} '
        'ppv=${_ppvThreshold.toStringAsFixed(3)} mm/s';
  }
}
