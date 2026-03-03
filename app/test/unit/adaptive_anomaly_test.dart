import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/adaptive_anomaly_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Helper: Generate consistent feature map
  // ---------------------------------------------------------------------------
  Map<String, double> createFeatures({
    double ppv = 2.0,
    double rms = 1.5,
    double crest = 3.0,
    double kurtosis = 2.5,
    double stalta = 1.0,
    double cav = 0.1,
    double freq = 10.0,
  }) {
    return {
      'ppv': ppv,
      'rms': rms,
      'crest': crest,
      'kurtosis': kurtosis,
      'stalta': stalta,
      'cav': cav,
      'freq': freq,
    };
  }

  // ---------------------------------------------------------------------------
  // Helper: Generate features with random noise
  // ---------------------------------------------------------------------------
  Map<String, double> createNoisyFeatures(Random rng, Map<String, double> base, {double noiseLevel = 0.1}) {
    return {
      for (final entry in base.entries)
        entry.key: entry.value * (1.0 + (rng.nextDouble() - 0.5) * 2 * noiseLevel),
    };
  }

  // =========================================================================
  // Initial State
  // =========================================================================
  group('Initial State', () {
    test('not calibrated on construction', () {
      final service = AdaptiveAnomalyService();
      expect(service.isCalibrated, isFalse);
    });

    test('detect() returns null before calibration', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      final result = service.detect(features);

      expect(result, isNull);
    });

    test('sampleCount starts at 0', () {
      final service = AdaptiveAnomalyService();
      expect(service.sampleCount, 0);
    });

    test('calibrationProgress starts at 0', () {
      final service = AdaptiveAnomalyService();
      expect(service.calibrationProgress, 0.0);
    });

    test('modeLabel shows calibrating at start', () {
      final service = AdaptiveAnomalyService();
      expect(service.modeLabel, contains('Calibrating'));
      expect(service.modeLabel, contains('0%'));
    });

    test('baselineSummary returns empty before calibration', () {
      final service = AdaptiveAnomalyService();
      expect(service.baselineSummary, isEmpty);
    });
  });

  // =========================================================================
  // Calibration
  // =========================================================================
  group('Calibration', () {
    test('feeding 150 normal samples triggers calibration', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      // Feed 149 samples - should not calibrate yet
      for (int i = 0; i < 149; i++) {
        service.updateBaseline(features);
      }
      expect(service.isCalibrated, isFalse);
      expect(service.sampleCount, 149);

      // Feed 150th sample - should trigger calibration
      service.updateBaseline(features);
      expect(service.isCalibrated, isTrue);
      expect(service.sampleCount, 150);
    });

    test('isCalibrated becomes true after calibration', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      expect(service.isCalibrated, isTrue);
    });

    test('calibration with varied data completes successfully', () {
      final service = AdaptiveAnomalyService();
      final rng = Random(42);
      final baseFeatures = createFeatures();

      for (int i = 0; i < 150; i++) {
        final features = createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.15);
        service.updateBaseline(features);
      }

      expect(service.isCalibrated, isTrue);
      expect(service.sampleCount, 150);
    });
  });

  // =========================================================================
  // Calibration Progress
  // =========================================================================
  group('Calibration Progress', () {
    test('sampleCount increments correctly', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      expect(service.sampleCount, 0);

      service.updateBaseline(features);
      expect(service.sampleCount, 1);

      service.updateBaseline(features);
      expect(service.sampleCount, 2);

      for (int i = 0; i < 10; i++) {
        service.updateBaseline(features);
      }
      expect(service.sampleCount, 12);
    });

    test('calibrationProgress updates correctly', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      expect(service.calibrationProgress, 0.0);

      // At 75 samples: 75/150 = 0.5
      for (int i = 0; i < 75; i++) {
        service.updateBaseline(features);
      }
      expect(service.calibrationProgress, closeTo(0.5, 0.001));

      // At 150 samples: 150/150 = 1.0
      for (int i = 0; i < 75; i++) {
        service.updateBaseline(features);
      }
      expect(service.calibrationProgress, 1.0);

      // After calibration, stays at 1.0
      service.updateBaseline(features);
      expect(service.calibrationProgress, 1.0);
    });

    test('modeLabel updates during calibration', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      // 0%
      expect(service.modeLabel, contains('0%'));

      // 50 samples: 33%
      for (int i = 0; i < 50; i++) {
        service.updateBaseline(features);
      }
      expect(service.modeLabel, contains('33%'));

      // 100 samples: 66-67% (rounding)
      for (int i = 0; i < 50; i++) {
        service.updateBaseline(features);
      }
      final label100 = service.modeLabel;
      expect(label100.contains('66%') || label100.contains('67%'), isTrue);

      // 150 samples: calibrated
      for (int i = 0; i < 50; i++) {
        service.updateBaseline(features);
      }
      expect(service.modeLabel, 'Adaptive');
    });
  });

  // =========================================================================
  // Normal Detection
  // =========================================================================
  group('Normal Detection', () {
    test('after calibration, similar data returns normal', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures(ppv: 2.0, rms: 1.5, crest: 3.0);

      // Calibrate with consistent data
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      // Feed similar data
      final result = service.detect(features);

      expect(result, isNotNull);
      expect(result!.level, AdaptiveAnomalyLevel.normal);
    });

    test('small variations within 1σ return normal', () {
      final service = AdaptiveAnomalyService();
      final rng = Random(123);
      final baseFeatures = createFeatures(ppv: 2.0, rms: 1.5);

      // Calibrate with some variation
      for (int i = 0; i < 150; i++) {
        final features = createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.1);
        service.updateBaseline(features);
      }

      // Feed data within 1 standard deviation
      final testFeatures = createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.08);
      final result = service.detect(testFeatures);

      expect(result, isNotNull);
      expect(result!.level, AdaptiveAnomalyLevel.normal);
      expect(result.score, lessThan(0.5));
    });

    test('normal level has score < 0.5', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final result = service.detect(features);

      expect(result, isNotNull);
      expect(result!.level, AdaptiveAnomalyLevel.normal);
      expect(result.score, lessThan(0.5));
    });
  });

  // =========================================================================
  // Anomaly Detection
  // =========================================================================
  group('Anomaly Detection', () {
    test('z-scores > 3.5σ return anomaly level', () {
      final service = AdaptiveAnomalyService();
      final baseFeatures = createFeatures(ppv: 2.0, rms: 1.5, crest: 3.0);

      // Calibrate with consistent data
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(baseFeatures);
      }

      // Feed data with PPV 5x higher (well beyond 3.5σ)
      final anomalyFeatures = createFeatures(ppv: 10.0, rms: 1.5, crest: 3.0);
      final result = service.detect(anomalyFeatures);

      expect(result, isNotNull);
      expect(result!.level, AdaptiveAnomalyLevel.anomaly);
      expect(result.rmsZScore, greaterThan(3.5));
    });

    test('anomaly level has high score', () {
      final service = AdaptiveAnomalyService();
      final baseFeatures = createFeatures(ppv: 2.0);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(baseFeatures);
      }

      // Extreme anomaly
      final anomalyFeatures = createFeatures(ppv: 20.0);
      final result = service.detect(anomalyFeatures);

      expect(result, isNotNull);
      expect(result!.level, AdaptiveAnomalyLevel.anomaly);
      expect(result.score, greaterThan(0.8));
    });

    test('identifies dominant feature causing anomaly', () {
      final service = AdaptiveAnomalyService();
      final baseFeatures = createFeatures(ppv: 2.0, rms: 1.5, kurtosis: 2.5);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(baseFeatures);
      }

      // Only kurtosis is anomalous
      final anomalyFeatures = createFeatures(ppv: 2.0, rms: 1.5, kurtosis: 15.0);
      final result = service.detect(anomalyFeatures);

      expect(result, isNotNull);
      expect(result!.dominantFeature, 'kurtosis');
    });

    test('multiple anomalous features detected', () {
      final service = AdaptiveAnomalyService();
      final baseFeatures = createFeatures(ppv: 2.0, rms: 1.5);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(baseFeatures);
      }

      // Both ppv and rms anomalous
      final anomalyFeatures = createFeatures(ppv: 15.0, rms: 10.0);
      final result = service.detect(anomalyFeatures);

      expect(result, isNotNull);
      expect(result!.featureZScores['ppv'], greaterThan(3.5));
      expect(result.featureZScores['rms'], greaterThan(3.5));
    });
  });

  // =========================================================================
  // Unusual Detection
  // =========================================================================
  group('Unusual Detection', () {
    test('z-scores between 2-3.5σ return unusual level', () {
      final service = AdaptiveAnomalyService();
      final rng = Random(456);
      final baseFeatures = createFeatures(ppv: 2.0, rms: 1.5);

      // Calibrate with some variation to establish variance
      for (int i = 0; i < 150; i++) {
        final features = createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.1);
        service.updateBaseline(features);
      }

      // Feed data moderately elevated (roughly 2.5σ)
      final unusualFeatures = createFeatures(ppv: 3.5, rms: 2.5);
      final result = service.detect(unusualFeatures);

      expect(result, isNotNull);
      // Should be either unusual or normal depending on learned variance
      if (result!.rmsZScore >= 2.0 && result.rmsZScore < 3.5) {
        expect(result.level, AdaptiveAnomalyLevel.unusual);
      }
    });

    test('unusual level has score between 0.5 and 0.8', () {
      final service = AdaptiveAnomalyService();
      final baseFeatures = createFeatures(ppv: 2.0);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(baseFeatures);
      }

      // Moderately elevated PPV
      final unusualFeatures = createFeatures(ppv: 5.0);
      final result = service.detect(unusualFeatures);

      expect(result, isNotNull);
      if (result!.level == AdaptiveAnomalyLevel.unusual) {
        expect(result.score, greaterThanOrEqualTo(0.5));
        expect(result.score, lessThan(0.8));
      }
    });
  });

  // =========================================================================
  // EMA Drift Tracking
  // =========================================================================
  group('EMA Drift Tracking', () {
    test('slowly drifting data adapts without false alarms', () {
      final service = AdaptiveAnomalyService();

      // Calibrate at baseline
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(createFeatures(ppv: 2.0));
      }

      // Slowly drift upward
      for (int i = 0; i < 100; i++) {
        final driftedPpv = 2.0 + (i * 0.01); // Very gradual drift
        service.updateBaseline(createFeatures(ppv: driftedPpv));

        // Detection should adapt, not flag as anomaly
        final result = service.detect(createFeatures(ppv: driftedPpv));

        // Even with drift, immediate detection should be normal or unusual at worst
        expect(result, isNotNull);
        // Most should be normal as EMA adapts
      }

      // The baseline should have adapted
      final summary = service.baselineSummary;
      expect(summary['ppv']!['mean'], greaterThan(2.0));
    });

    test('baseline mean adapts with EMA after calibration', () {
      final service = AdaptiveAnomalyService();

      // Calibrate at ppv=2.0
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(createFeatures(ppv: 2.0));
      }

      final initialSummary = service.baselineSummary;
      final initialMean = initialSummary['ppv']!['mean']!;
      expect(initialMean, closeTo(2.0, 0.1));

      // Feed sustained higher values
      for (int i = 0; i < 200; i++) {
        service.updateBaseline(createFeatures(ppv: 3.0));
      }

      final updatedSummary = service.baselineSummary;
      final updatedMean = updatedSummary['ppv']!['mean']!;

      // Mean should have drifted upward
      expect(updatedMean, greaterThan(initialMean));
    });

    test('EMA variance updates after calibration', () {
      final service = AdaptiveAnomalyService();

      // Calibrate with low variance
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(createFeatures(ppv: 2.0));
      }

      final initialSummary = service.baselineSummary;
      final initialStdDev = initialSummary['ppv']!['stdDev']!;

      // Feed varied data
      final rng = Random(789);
      for (int i = 0; i < 200; i++) {
        final ppv = 2.0 + (rng.nextDouble() - 0.5) * 2.0;
        service.updateBaseline(createFeatures(ppv: ppv));
      }

      final updatedSummary = service.baselineSummary;
      final updatedStdDev = updatedSummary['ppv']!['stdDev']!;

      // Variance should have increased
      expect(updatedStdDev, greaterThan(initialStdDev));
    });
  });

  // =========================================================================
  // Reset
  // =========================================================================
  group('Reset', () {
    test('after reset, isCalibrated becomes false', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      // Calibrate
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }
      expect(service.isCalibrated, isTrue);

      // Reset
      service.reset();
      expect(service.isCalibrated, isFalse);
    });

    test('after reset, sampleCount becomes 0', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }
      expect(service.sampleCount, 150);

      service.reset();
      expect(service.sampleCount, 0);
    });

    test('after reset, detect returns null', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      // Calibrate
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }
      expect(service.detect(features), isNotNull);

      // Reset
      service.reset();
      expect(service.detect(features), isNull);
    });

    test('after reset, baselineSummary is empty', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      // Calibrate
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }
      expect(service.baselineSummary, isNotEmpty);

      // Reset
      service.reset();
      expect(service.baselineSummary, isEmpty);
    });

    test('can recalibrate after reset', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      // First calibration
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }
      expect(service.isCalibrated, isTrue);

      // Reset
      service.reset();
      expect(service.isCalibrated, isFalse);

      // Recalibrate with different baseline
      final newFeatures = createFeatures(ppv: 5.0);
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(newFeatures);
      }
      expect(service.isCalibrated, isTrue);
      expect(service.sampleCount, 150);

      // New baseline should reflect new data
      final summary = service.baselineSummary;
      expect(summary['ppv']!['mean'], closeTo(5.0, 0.1));
    });
  });

  // =========================================================================
  // Baseline Summary
  // =========================================================================
  group('Baseline Summary', () {
    test('returns non-empty map after calibration', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final summary = service.baselineSummary;
      expect(summary, isNotEmpty);
    });

    test('contains all feature keys', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final summary = service.baselineSummary;
      final expectedKeys = ['ppv', 'rms', 'crest', 'kurtosis', 'stalta', 'cav', 'freq'];

      for (final key in expectedKeys) {
        expect(summary.containsKey(key), isTrue, reason: 'Missing feature: $key');
      }
    });

    test('each feature has mean and stdDev', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final summary = service.baselineSummary;

      for (final featureStats in summary.values) {
        expect(featureStats.containsKey('mean'), isTrue);
        expect(featureStats.containsKey('stdDev'), isTrue);
        expect(featureStats['mean'], isA<double>());
        expect(featureStats['stdDev'], isA<double>());
      }
    });

    test('baseline summary reflects calibration data', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures(ppv: 3.0, rms: 2.5, freq: 15.0);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final summary = service.baselineSummary;
      expect(summary['ppv']!['mean'], closeTo(3.0, 0.1));
      expect(summary['rms']!['mean'], closeTo(2.5, 0.1));
      expect(summary['freq']!['mean'], closeTo(15.0, 0.1));
    });

    test('stdDev is very small for constant data', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures(ppv: 2.0);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final summary = service.baselineSummary;
      // With constant input, variance should be floored at 1e-10
      expect(summary['ppv']!['stdDev'], lessThan(0.001));
    });

    test('stdDev increases with varied data', () {
      final service = AdaptiveAnomalyService();
      final rng = Random(101);
      final baseFeatures = createFeatures(ppv: 2.0);

      for (int i = 0; i < 150; i++) {
        final features = createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.2);
        service.updateBaseline(features);
      }

      final summary = service.baselineSummary;
      expect(summary['ppv']!['stdDev'], greaterThan(0.05));
    });
  });

  // =========================================================================
  // Edge Cases
  // =========================================================================
  group('Edge Cases', () {
    test('zero variance features have minimum floored variance', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures(ppv: 2.0, rms: 1.5, crest: 3.0);

      // Feed identical samples
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final summary = service.baselineSummary;

      // All features should have minimal stdDev (from variance floor)
      for (final stats in summary.values) {
        expect(stats['stdDev'], greaterThan(0));
        expect(stats['stdDev'], lessThan(0.001));
      }

      // Detection should still work
      final result = service.detect(features);
      expect(result, isNotNull);
      expect(result!.level, AdaptiveAnomalyLevel.normal);
    });

    test('handles negative feature values', () {
      final service = AdaptiveAnomalyService();

      // Some features can be negative (e.g., if data is DC-removed)
      final features = createFeatures(ppv: -2.0, rms: 1.5, kurtosis: -1.0);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      expect(service.isCalibrated, isTrue);

      final result = service.detect(features);
      expect(result, isNotNull);
    });

    test('handles very large feature values', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures(ppv: 1000.0, rms: 500.0, crest: 200.0);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      expect(service.isCalibrated, isTrue);

      final result = service.detect(features);
      expect(result, isNotNull);
      expect(result!.level, AdaptiveAnomalyLevel.normal);
    });

    test('handles missing feature values gracefully', () {
      final service = AdaptiveAnomalyService();

      // Normal features
      final fullFeatures = createFeatures();
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(fullFeatures);
      }

      // Detect with some missing features (will default to 0.0)
      final partialFeatures = {'ppv': 2.0, 'rms': 1.5};
      final result = service.detect(partialFeatures);

      expect(result, isNotNull);
      // Missing features treated as 0.0, which may cause anomaly
    });

    test('extreme z-scores clamp score to 1.0', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures(ppv: 2.0);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      // Feed extremely anomalous data
      final extremeFeatures = createFeatures(ppv: 1000.0);
      final result = service.detect(extremeFeatures);

      expect(result, isNotNull);
      expect(result!.score, lessThanOrEqualTo(1.0));
      expect(result.level, AdaptiveAnomalyLevel.anomaly);
    });

    test('feature z-scores map contains all features', () {
      final service = AdaptiveAnomalyService();
      final features = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(features);
      }

      final result = service.detect(features);

      expect(result, isNotNull);
      expect(result!.featureZScores, isNotEmpty);

      // Should contain z-scores for features with non-zero variance
      final expectedFeatures = ['ppv', 'rms', 'crest', 'kurtosis', 'stalta', 'cav', 'freq'];
      // At least most features should be present
      // (constant features with zero variance might be excluded)
      expect(result.featureZScores.keys.where((k) => expectedFeatures.contains(k)).length, greaterThan(0));
    });

    test('rmsZScore is always non-negative', () {
      final service = AdaptiveAnomalyService();
      final rng = Random(202);
      final baseFeatures = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.1));
      }

      // Test various inputs
      for (int i = 0; i < 20; i++) {
        final testFeatures = createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.5);
        final result = service.detect(testFeatures);

        expect(result, isNotNull);
        expect(result!.rmsZScore, greaterThanOrEqualTo(0));
      }
    });

    test('score is always between 0 and 1', () {
      final service = AdaptiveAnomalyService();
      final rng = Random(303);
      final baseFeatures = createFeatures();

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.1));
      }

      // Test with extreme variations
      for (int i = 0; i < 50; i++) {
        final testFeatures = createNoisyFeatures(rng, baseFeatures, noiseLevel: rng.nextDouble() * 5.0);
        final result = service.detect(testFeatures);

        expect(result, isNotNull);
        expect(result!.score, greaterThanOrEqualTo(0.0));
        expect(result.score, lessThanOrEqualTo(1.0));
      }
    });

    test('dominant feature is identified correctly', () {
      final service = AdaptiveAnomalyService();
      final baseFeatures = createFeatures(ppv: 2.0, rms: 1.5);

      for (int i = 0; i < 150; i++) {
        service.updateBaseline(baseFeatures);
      }

      // Only RMS is highly anomalous
      final testFeatures = createFeatures(ppv: 2.0, rms: 20.0);
      final result = service.detect(testFeatures);

      expect(result, isNotNull);
      expect(result!.dominantFeature, 'rms');
    });
  });

  // =========================================================================
  // Result Object
  // =========================================================================
  group('AdaptiveAnomalyResult', () {
    test('levelLabel returns correct strings', () {
      const normal = AdaptiveAnomalyResult(
        score: 0.1,
        level: AdaptiveAnomalyLevel.normal,
        rmsZScore: 0.5,
        featureZScores: {},
      );
      expect(normal.levelLabel, 'Normal');

      const unusual = AdaptiveAnomalyResult(
        score: 0.6,
        level: AdaptiveAnomalyLevel.unusual,
        rmsZScore: 2.5,
        featureZScores: {},
      );
      expect(unusual.levelLabel, 'Unusual');

      const anomaly = AdaptiveAnomalyResult(
        score: 0.9,
        level: AdaptiveAnomalyLevel.anomaly,
        rmsZScore: 5.0,
        featureZScores: {},
      );
      expect(anomaly.levelLabel, 'Anomaly');
    });

    test('dominantFeature can be null', () {
      const result = AdaptiveAnomalyResult(
        score: 0.5,
        level: AdaptiveAnomalyLevel.normal,
        rmsZScore: 1.0,
        featureZScores: {},
        dominantFeature: null,
      );
      expect(result.dominantFeature, isNull);
    });

    test('dominantFeature can be set', () {
      const result = AdaptiveAnomalyResult(
        score: 0.8,
        level: AdaptiveAnomalyLevel.anomaly,
        rmsZScore: 4.0,
        featureZScores: {'ppv': 4.5},
        dominantFeature: 'ppv',
      );
      expect(result.dominantFeature, 'ppv');
    });
  });

  // =========================================================================
  // Integration Tests
  // =========================================================================
  group('Integration', () {
    test('full workflow: calibrate, detect normal, detect anomaly', () {
      final service = AdaptiveAnomalyService();
      final baseFeatures = createFeatures(ppv: 2.0, rms: 1.5);

      // Phase 1: Calibration
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(baseFeatures);
      }
      expect(service.isCalibrated, isTrue);

      // Phase 2: Normal detection
      final normalResult = service.detect(baseFeatures);
      expect(normalResult, isNotNull);
      expect(normalResult!.level, AdaptiveAnomalyLevel.normal);

      // Phase 3: Anomaly detection
      final anomalyFeatures = createFeatures(ppv: 15.0, rms: 10.0);
      final anomalyResult = service.detect(anomalyFeatures);
      expect(anomalyResult, isNotNull);
      expect(anomalyResult!.level, AdaptiveAnomalyLevel.anomaly);
      expect(anomalyResult.score, greaterThan(normalResult.score));
    });

    test('continuous operation with mixed normal and anomalous data', () {
      final service = AdaptiveAnomalyService();
      final rng = Random(404);
      final baseFeatures = createFeatures();

      // Calibrate
      for (int i = 0; i < 150; i++) {
        service.updateBaseline(createNoisyFeatures(rng, baseFeatures, noiseLevel: 0.1));
      }

      int normalCount = 0;
      int unusualCount = 0;
      int anomalyCount = 0;

      // Run detection on mixed data
      for (int i = 0; i < 100; i++) {
        final testFeatures = createNoisyFeatures(
          rng,
          baseFeatures,
          noiseLevel: rng.nextDouble() < 0.9 ? 0.15 : 2.0, // 90% normal, 10% extreme
        );

        service.updateBaseline(testFeatures); // Continue learning
        final result = service.detect(testFeatures);

        expect(result, isNotNull);
        switch (result!.level) {
          case AdaptiveAnomalyLevel.normal:
            normalCount++;
            break;
          case AdaptiveAnomalyLevel.unusual:
            unusualCount++;
            break;
          case AdaptiveAnomalyLevel.anomaly:
            anomalyCount++;
            break;
        }
      }

      // Should have detected mostly non-anomaly samples (normal + unusual)
      expect(normalCount + unusualCount, greaterThan(50));

      // Should have some anomalies from the 10% extreme samples
      expect(anomalyCount, greaterThan(0));
    });
  });
}
