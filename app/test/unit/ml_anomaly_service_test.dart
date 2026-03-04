import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/ml_anomaly_service.dart';

/// Tests for [MlAnomalyService] that do NOT require a TFLite model file or
/// any platform channel (path_provider, rootBundle, etc.).
///
/// We test only the properties and methods that are pure Dart and do not
/// call [initialize()] (which loads the .tflite asset and invokes platform
/// channels). If the test environment cannot resolve the asset bundle,
/// calling initialize() would throw; we avoid that by testing initial state
/// and the pure-math methods.
void main() {
  group('MlAnomalyService — initial state (no model loaded)', () {
    late MlAnomalyService svc;

    setUp(() {
      svc = MlAnomalyService();
    });

    // -------------------------------------------------------------------------
    // 1. isHealthy is true initially
    // -------------------------------------------------------------------------
    test('isHealthy is true initially', () {
      expect(svc.isHealthy, isTrue);
    });

    // -------------------------------------------------------------------------
    // 2. smoothedScore starts at 0.0
    // -------------------------------------------------------------------------
    test('smoothedScore starts at 0.0', () {
      expect(svc.smoothedScore, closeTo(0.0, 1e-12));
    });

    // -------------------------------------------------------------------------
    // 3. consecutiveAnomalyFrames starts at 0
    // -------------------------------------------------------------------------
    test('consecutiveAnomalyFrames starts at 0', () {
      expect(svc.consecutiveAnomalyFrames, equals(0));
    });

    // -------------------------------------------------------------------------
    // 4. scoreHistory is empty initially
    // -------------------------------------------------------------------------
    test('scoreHistory is empty initially', () {
      expect(svc.scoreHistory, isEmpty);
    });

    // -------------------------------------------------------------------------
    // 5. scoreVariance returns 0.0 when history is empty
    // -------------------------------------------------------------------------
    test('scoreVariance returns 0.0 for empty history', () {
      expect(svc.scoreVariance, closeTo(0.0, 1e-12));
    });

    // -------------------------------------------------------------------------
    // 6. isLoaded is false before initialize()
    // -------------------------------------------------------------------------
    test('isLoaded is false before initialize()', () {
      expect(svc.isLoaded, isFalse);
    });

    // -------------------------------------------------------------------------
    // 7. isCalibrating is false initially
    // -------------------------------------------------------------------------
    test('isCalibrating is false initially', () {
      expect(svc.isCalibrating, isFalse);
    });

    // -------------------------------------------------------------------------
    // 8. isCalibrated is false initially (no site profile)
    // -------------------------------------------------------------------------
    test('isCalibrated is false initially', () {
      expect(svc.isCalibrated, isFalse);
    });

    // -------------------------------------------------------------------------
    // 9. calibrationSampleCount is 0 initially
    // -------------------------------------------------------------------------
    test('calibrationSampleCount is 0 initially', () {
      expect(svc.calibrationSampleCount, equals(0));
    });

    // -------------------------------------------------------------------------
    // 10. calibrationProgress is 0.0 initially
    // -------------------------------------------------------------------------
    test('calibrationProgress is 0.0 initially', () {
      expect(svc.calibrationProgress, closeTo(0.0, 1e-12));
    });

    // -------------------------------------------------------------------------
    // 11. infer returns null when model is not loaded
    // -------------------------------------------------------------------------
    test('infer returns null when model is not loaded', () {
      final result = svc.infer({
        'rms': 1.0, 'ppv': 0.5, 'freq': 10.0, 'crest': 3.0,
        'centroid': 15.0, 'kurtosis': 2.5, 'stalta': 1.2,
        'arias': 0.01, 'cav': 0.1, 'temp': 25.0, 'psdSlope': -2.0,
      });
      expect(result, isNull);
    });

    // -------------------------------------------------------------------------
    // 12. dispose does not throw
    // -------------------------------------------------------------------------
    test('dispose does not throw', () {
      expect(() => svc.dispose(), returnsNormally);
    });
  });

  group('MlAnomalyService — calibrateThresholds (pure Dart)', () {
    late MlAnomalyService svc;

    setUp(() {
      svc = MlAnomalyService();
    });

    // -------------------------------------------------------------------------
    // 13. calibrateThresholds sets thresholds > 0 from a score list
    //     We cannot inspect _thresholdLow / _thresholdHigh directly (private),
    //     but the method is async and must complete without throwing.
    // -------------------------------------------------------------------------
    test('calibrateThresholds completes without throwing for valid input', () async {
      // 100 scores linearly spaced 0.1 … 10.0
      final scores = List<double>.generate(100, (i) => 0.1 + i * 0.099);
      await expectLater(svc.calibrateThresholds(scores), completes);
    });

    // -------------------------------------------------------------------------
    // 14. calibrateThresholds throws ArgumentError for empty list
    // -------------------------------------------------------------------------
    test('calibrateThresholds throws ArgumentError for empty list', () async {
      await expectLater(
        svc.calibrateThresholds([]),
        throwsA(isA<ArgumentError>()),
      );
    });

    // -------------------------------------------------------------------------
    // 15. startCalibration / cancelCalibration round-trip
    // -------------------------------------------------------------------------
    test('startCalibration sets isCalibrating = true, cancelCalibration resets it', () {
      svc.startCalibration();
      expect(svc.isCalibrating, isTrue);
      svc.cancelCalibration();
      expect(svc.isCalibrating, isFalse);
      expect(svc.calibrationSampleCount, equals(0));
    });

    // -------------------------------------------------------------------------
    // 16. feedCalibrationSample accumulates samples during calibration
    // -------------------------------------------------------------------------
    test('feedCalibrationSample accumulates samples while calibrating', () {
      svc.startCalibration();
      final feature = {
        'rms': 1.0, 'ppv': 0.5, 'freq': 10.0, 'crest': 3.0,
        'centroid': 15.0, 'kurtosis': 2.5, 'stalta': 1.2,
        'arias': 0.01, 'cav': 0.1, 'temp': 25.0, 'psdSlope': -2.0,
      };
      for (int i = 0; i < 5; i++) {
        svc.feedCalibrationSample(feature);
      }
      expect(svc.calibrationSampleCount, equals(5));
      svc.cancelCalibration();
    });

    // -------------------------------------------------------------------------
    // 17. feedCalibrationSample is a no-op when not calibrating
    // -------------------------------------------------------------------------
    test('feedCalibrationSample is a no-op when not calibrating', () {
      expect(svc.isCalibrating, isFalse);
      svc.feedCalibrationSample({'rms': 1.0});
      expect(svc.calibrationSampleCount, equals(0));
    });
  });
}
