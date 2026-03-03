import 'package:flutter/foundation.dart';

/// Tracks ML model calibration progress for display in the safety view.
///
/// The adaptive anomaly service needs [requiredSamples] normal readings
/// before calibration completes. This service provides a progress value
/// (0.0 to 1.0) for display in a progress bar.
class CalibrationProgressService extends ChangeNotifier {
  final int requiredSamples;
  int _samplesCollected = 0;
  bool _isCalibrated = false;

  CalibrationProgressService({this.requiredSamples = 100});

  double get progress =>
      _isCalibrated ? 1.0 : (_samplesCollected / requiredSamples).clamp(0.0, 1.0);

  bool get isCalibrated => _isCalibrated;
  int get samplesCollected => _samplesCollected;

  void addSample() {
    if (_isCalibrated) return;
    _samplesCollected++;
    if (_samplesCollected >= requiredSamples) {
      _isCalibrated = true;
      debugPrint('[CalibrationProgress] Calibration complete');
    }
    notifyListeners();
  }

  void reset() {
    _samplesCollected = 0;
    _isCalibrated = false;
    notifyListeners();
  }
}
