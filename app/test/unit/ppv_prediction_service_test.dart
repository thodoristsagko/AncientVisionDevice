import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/ppv_prediction_service.dart';

void main() {
  group('KalmanFilter', () {
    test('smooths a noisy signal closer to the true value', () {
      // True value is 1.0; add samples with noise ±0.5
      final filter = KalmanFilter(
        processNoise: 0.01,
        measurementNoise: 0.1,
      );
      const trueValue = 1.0;
      final noisySamples = [1.4, 0.6, 1.3, 0.7, 1.1, 0.9, 1.2, 0.8, 1.05, 0.95];

      // Average absolute raw error
      final rawError = noisySamples
              .map((s) => (s - trueValue).abs())
              .reduce((a, b) => a + b) /
          noisySamples.length;

      double lastFiltered = 0.0;
      for (final s in noisySamples) {
        lastFiltered = filter.update(s);
      }

      // The filtered estimate should be closer to 1.0 than the mean raw error
      expect((lastFiltered - trueValue).abs(), lessThan(rawError),
          reason: 'Kalman output should be closer to true value than raw mean error');
    });

    test('reset clears state', () {
      final filter = KalmanFilter();
      filter.update(5.0);
      filter.update(5.0);
      filter.reset();
      expect(filter.estimate, equals(0.0));
    });
  });

  group('PPVPredictionService', () {
    late PPVPredictionService service;

    setUp(() {
      // Create a fresh instance for each test to avoid shared state
      service = PPVPredictionService.instance;
      service.reset();
    });

    tearDown(() {
      service.reset();
    });

    test('peakPpv returns 0.0 when history is empty', () {
      expect(service.peakPpv, equals(0.0));
    });

    test('peakPpv returns the maximum observed value', () {
      for (final v in [0.5, 1.2, 3.7, 0.8, 2.1]) {
        service.addSample(v);
      }
      expect(service.peakPpv, closeTo(3.7, 1e-9));
    });

    test('OLS regression gives positive slope for strictly rising data', () {
      // Feed 10 rising samples: 0.1, 0.2, ..., 1.0
      for (int i = 1; i <= 10; i++) {
        service.addSample(i * 0.1);
      }
      final p = service.prediction;
      expect(p, isNotNull);
      expect(p!.slope, greaterThan(0.0),
          reason: 'Slope must be positive for rising data');
    });

    test('prediction returns null when fewer than 5 samples collected', () {
      service.addSample(0.5);
      service.addSample(0.6);
      service.addSample(0.7);
      expect(service.prediction, isNull);
    });

    test('samplesUntilExceedance returns null for flat trend', () {
      // Pre-warm the Kalman filter with many samples so it fully converges
      // to 0.5 before the regression window is considered.  Using 60
      // identical samples fills the whole history with near-identical
      // Kalman outputs, giving slope ≈ 0 and isTrendingUp = false.
      for (int i = 0; i < 60; i++) {
        service.addSample(0.5);
      }
      // After full convergence the slope is effectively 0 → null result.
      final result = service.samplesUntilExceedance(2.0);
      expect(result, isNull,
          reason: 'Should return null when trend is flat after Kalman convergence');
    });

    test('samplesUntilExceedance returns null for falling trend', () {
      // Strictly falling data: 2.0, 1.9, ..., 1.1 (10 samples)
      for (int i = 0; i < 10; i++) {
        service.addSample(2.0 - i * 0.1);
      }
      final result = service.samplesUntilExceedance(3.0);
      expect(result, isNull,
          reason: 'Should return null when trend is falling');
    });

    test('samplesUntilExceedance returns 0 when already exceeded', () {
      for (int i = 1; i <= 10; i++) {
        service.addSample(i * 0.5); // last sample = 5.0
      }
      final result = service.samplesUntilExceedance(2.0);
      expect(result, equals(0),
          reason: 'Should return 0 when current PPV already >= threshold');
    });

    test('exceedanceCount counts samples at or above threshold', () {
      for (final v in [0.5, 1.0, 2.0, 3.0, 1.5, 4.0]) {
        service.addSample(v);
      }
      // Threshold 2.0: values 2.0, 3.0, 4.0 qualify
      expect(service.exceedanceCount(2.0), equals(3));
    });

    test('kalmanHistory has same length as rawHistory after addSample', () {
      for (int i = 0; i < 20; i++) {
        service.addSample(i * 0.1);
      }
      expect(service.kalmanHistory.length, equals(service.rawHistory.length));
    });

    test('rolling window caps history at 60 samples', () {
      for (int i = 0; i < 80; i++) {
        service.addSample(i * 0.01);
      }
      expect(service.rawHistory.length, equals(60));
      expect(service.kalmanHistory.length, equals(60));
    });

    test('reset clears all history and Kalman state', () {
      for (int i = 0; i < 10; i++) {
        service.addSample(1.0);
      }
      service.reset();
      expect(service.rawHistory, isEmpty);
      expect(service.kalmanHistory, isEmpty);
      expect(service.peakPpv, equals(0.0));
      expect(service.prediction, isNull);
    });
  });
}
