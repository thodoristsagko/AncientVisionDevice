import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/vibration_metrics_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Helper: generate a sine wave
  // ---------------------------------------------------------------------------
  List<double> sineWave(double freq, double sampleRate, int numSamples,
      {double amplitude = 1.0}) {
    return List<double>.generate(
      numSamples,
      (i) => amplitude * sin(2 * pi * freq * i / sampleRate),
    );
  }

  // ---------------------------------------------------------------------------
  // Helper: generate Gaussian noise
  // ---------------------------------------------------------------------------
  List<double> gaussianNoise(int length, {int seed = 42}) {
    final rng = Random(seed);
    // Box-Muller transform
    return List<double>.generate(length, (i) {
      final u1 = rng.nextDouble();
      final u2 = rng.nextDouble();
      return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
    });
  }

  // =========================================================================
  // Arias Intensity
  // =========================================================================
  group('Arias Intensity', () {
    test('known sine wave matches analytical solution', () {
      // For a sine wave a(t) = A*sin(2*pi*f*t) of duration T,
      // Ia = (pi / (2g)) * integral[A^2*sin^2(wt)] dt
      //    = (pi / (2g)) * A^2 * T/2    (for integer number of cycles)
      const amplitude = 0.5; // g
      const freq = 10.0; // Hz
      const sampleRate = 1000.0;
      const duration = 1.0; // exactly 10 cycles
      final numSamples = (duration * sampleRate).toInt();
      final signal =
          sineWave(freq, sampleRate, numSamples, amplitude: amplitude);

      final ia = VibrationMetricsService.computeAriasIntensity(
        signal,
        sampleRate,
      );

      // Analytical: (pi / (2 * 9.81)) * 0.5^2 * 1.0 / 2
      const expected =
          (pi / (2 * 9.81)) * amplitude * amplitude * duration / 2;
      expect(ia, closeTo(expected, expected * 0.01)); // 1% tolerance
    });

    test('returns 0 for empty input', () {
      expect(VibrationMetricsService.computeAriasIntensity([], 200), 0);
    });

    test('single sample produces small positive value', () {
      final ia = VibrationMetricsService.computeAriasIntensity([1.0], 200);
      expect(ia, greaterThan(0));
    });

    test('scales quadratically with amplitude', () {
      const sampleRate = 200.0;
      final signal1 = sineWave(5, sampleRate, 200, amplitude: 1.0);
      final signal2 = sineWave(5, sampleRate, 200, amplitude: 2.0);

      final ia1 =
          VibrationMetricsService.computeAriasIntensity(signal1, sampleRate);
      final ia2 =
          VibrationMetricsService.computeAriasIntensity(signal2, sampleRate);

      // ia2 should be 4x ia1 (quadratic)
      expect(ia2 / ia1, closeTo(4.0, 0.1));
    });
  });

  // =========================================================================
  // Cumulative Absolute Velocity
  // =========================================================================
  group('CAV', () {
    test('accumulates correctly over time', () {
      // Constant acceleration of 0.1 g for 1 second at 100 Hz
      const sampleRate = 100.0;
      final signal = List<double>.filled(100, 0.1);

      final cav = VibrationMetricsService.computeCAV(signal, sampleRate);

      // Expected: 0.1 * 100 * (1/100) = 0.1 g-s
      expect(cav, closeTo(0.1, 0.001));
    });

    test('returns 0 for empty input', () {
      expect(VibrationMetricsService.computeCAV([], 200), 0);
    });

    test('handles negative accelerations (absolute value)', () {
      const sampleRate = 100.0;
      final signal = List<double>.filled(100, -0.2);

      final cav = VibrationMetricsService.computeCAV(signal, sampleRate);

      // Expected: 0.2 * 100 * (1/100) = 0.2 g-s
      expect(cav, closeTo(0.2, 0.001));
    });

    test('grows linearly with duration', () {
      const sampleRate = 200.0;
      final signal1 = List<double>.filled(200, 0.1); // 1 second
      final signal2 = List<double>.filled(400, 0.1); // 2 seconds

      final cav1 = VibrationMetricsService.computeCAV(signal1, sampleRate);
      final cav2 = VibrationMetricsService.computeCAV(signal2, sampleRate);

      expect(cav2 / cav1, closeTo(2.0, 0.01));
    });
  });

  // =========================================================================
  // Zero-Crossing Rate
  // =========================================================================
  group('Zero-Crossing Rate', () {
    test('of known-frequency sine equals that frequency (normalized)', () {
      const freq = 25.0;
      const sampleRate = 1000.0;
      const numSamples = 10000; // 10 seconds, 250 cycles
      final signal = sineWave(freq, sampleRate, numSamples);

      final zcr = VibrationMetricsService.computeZeroCrossingRate(signal);

      // Each cycle crosses zero twice.
      // ZCR = crossings / N
      // Estimated frequency = ZCR * sampleRate / 2
      final estimatedFreq = zcr * sampleRate / 2;
      expect(estimatedFreq, closeTo(freq, 1.0));
    });

    test('higher frequency produces higher ZCR', () {
      const sampleRate = 1000.0;
      const n = 2000;
      final low = sineWave(10, sampleRate, n);
      final high = sineWave(50, sampleRate, n);

      final zcrLow = VibrationMetricsService.computeZeroCrossingRate(low);
      final zcrHigh = VibrationMetricsService.computeZeroCrossingRate(high);

      expect(zcrHigh, greaterThan(zcrLow));
    });

    test('returns 0 for empty or single-sample input', () {
      expect(VibrationMetricsService.computeZeroCrossingRate([]), 0);
      expect(VibrationMetricsService.computeZeroCrossingRate([1.0]), 0);
    });

    test('DC signal has zero crossings = 0', () {
      final dc = List<double>.filled(100, 5.0);
      expect(VibrationMetricsService.computeZeroCrossingRate(dc), 0);
    });
  });

  // =========================================================================
  // Multi-Standard Classification
  // =========================================================================
  group('Multi-Standard Classification', () {
    test('5 mm/s at 5 Hz: DIN critical, BS safe', () {
      final results =
          VibrationMetricsService.classifyAllStandards(5.0, 5.0);

      // DIN 4150-3: transient limit is 3.0 mm/s at 5 Hz, but continuous
      // limit of 2.5 mm/s is lower, so effective limit = 2.5 mm/s
      final din = results
          .firstWhere((c) => c.standard == VibrationStandard.din4150);
      expect(din.level, 'critical');
      expect(din.limit, closeTo(2.5, 0.01));

      // BS 7385-2: limit is 6.0 mm/s at 5 Hz => 5.0 < 6.0
      // 5.0 >= 6.0 * 0.7 = 4.2 => warning
      final bs = results
          .firstWhere((c) => c.standard == VibrationStandard.bs7385);
      expect(bs.level, isNot('critical'));
      expect(bs.limit, closeTo(6.0, 0.01));
    });

    test('1 mm/s at 5 Hz is safe for all standards', () {
      final results =
          VibrationMetricsService.classifyAllStandards(1.0, 5.0);

      for (final r in results) {
        expect(r.level, 'safe', reason: '${r.standard} should be safe');
      }
    });

    test('20 mm/s at 5 Hz is critical for all standards', () {
      final results =
          VibrationMetricsService.classifyAllStandards(20.0, 5.0);

      for (final r in results) {
        expect(r.level, 'critical', reason: '${r.standard} should be critical');
      }
    });

    test('FHWA has flat 2.0 mm/s limit regardless of frequency', () {
      for (final freq in [1.0, 25.0, 50.0, 80.0]) {
        final results =
            VibrationMetricsService.classifyAllStandards(2.5, freq);
        final fhwa = results
            .firstWhere((c) => c.standard == VibrationStandard.fhwa);
        expect(fhwa.limit, 2.0);
        expect(fhwa.level, 'critical');
      }
    });

    test('returns exactly 4 classifications', () {
      final results =
          VibrationMetricsService.classifyAllStandards(3.0, 10.0);
      expect(results.length, 4);
    });

    test('DIN limit interpolates between frequency bands', () {
      // At 30 Hz (midpoint 10-50), transient limit interpolates between 3 and 8
      // = 3.0 + (30-10)/(50-10) * 5.0 = 5.5, but continuous limit of 2.5 mm/s
      // is lower, so effective limit = 2.5 mm/s
      final results =
          VibrationMetricsService.classifyAllStandards(0.1, 30.0);
      final din = results
          .firstWhere((c) => c.standard == VibrationStandard.din4150);
      expect(din.limit, closeTo(2.5, 0.01));
    });
  });

  // =========================================================================
  // Damage Index
  // =========================================================================
  group('Damage Index', () {
    test('increases monotonically with exposure', () {
      double index = 0;
      final values = <double>[];

      for (int i = 0; i < 10; i++) {
        index = VibrationMetricsService.updateDamageIndex(
          index,
          5.0, // mm/s PPV
          1.0, // 1 second
          10.0, // Hz
        );
        values.add(index);
      }

      // Each value should be greater than the previous
      for (int i = 1; i < values.length; i++) {
        expect(values[i], greaterThan(values[i - 1]));
      }
    });

    test('zero PPV produces zero increment', () {
      final index = VibrationMetricsService.updateDamageIndex(
        0.5,
        0.0,
        1.0,
        10.0,
      );
      expect(index, 0.5);
    });

    test('higher PPV produces larger damage increment', () {
      final lowDamage = VibrationMetricsService.updateDamageIndex(
        0,
        2.0,
        1.0,
        10.0,
      );
      final highDamage = VibrationMetricsService.updateDamageIndex(
        0,
        6.0,
        1.0,
        10.0,
      );
      expect(highDamage, greaterThan(lowDamage));
    });

    test('scales quadratically with PPV ratio', () {
      final d1 = VibrationMetricsService.updateDamageIndex(0, 3.0, 1.0, 5.0);
      final d2 = VibrationMetricsService.updateDamageIndex(0, 6.0, 1.0, 5.0);

      // At 5 Hz, DIN limit = 3.0, so ratios are 1.0 and 2.0
      // Quadratic: d2/d1 should be 4.0
      expect(d2 / d1, closeTo(4.0, 0.1));
    });
  });

  // =========================================================================
  // Spectral Kurtosis
  // =========================================================================
  group('Spectral Kurtosis', () {
    test('of pure Gaussian noise is approximately 0', () {
      final noise = gaussianNoise(4096);

      final sk = VibrationMetricsService.computeSpectralKurtosis(
        noise,
        windowSize: 64,
        hopSize: 32,
      );

      // Average SK across bins should be near 0 for Gaussian noise
      final avgSK = sk.reduce((a, b) => a + b) / sk.length;
      expect(avgSK, closeTo(0, 0.5)); // generous tolerance for finite data
    });

    test('returns correct number of frequency bins', () {
      final signal = List<double>.filled(256, 0);
      const windowSize = 64;

      final sk = VibrationMetricsService.computeSpectralKurtosis(
        signal,
        windowSize: windowSize,
      );

      expect(sk.length, windowSize ~/ 2 + 1);
    });

    test('returns zeros for signal shorter than window', () {
      final signal = List<double>.filled(10, 1.0);
      final sk = VibrationMetricsService.computeSpectralKurtosis(
        signal,
        windowSize: 64,
      );
      expect(sk.every((v) => v == 0), isTrue);
    });

    test('detects impulsive content (positive SK)', () {
      // Create mostly-zero signal with a sharp impulse
      final signal = List<double>.filled(2048, 0.0);
      signal[512] = 10.0; // sharp impulse
      signal[513] = -8.0;

      final sk = VibrationMetricsService.computeSpectralKurtosis(
        signal,
        windowSize: 64,
        hopSize: 32,
      );

      // At least some bins should show positive SK (transient content)
      final maxSK = sk.reduce(max);
      expect(maxSK, greaterThan(0));
    });
  });

  // =========================================================================
  // Housner Spectral Intensity
  // =========================================================================
  group('Housner Spectral Intensity', () {
    test('is positive for non-zero input', () {
      // Create simple FFT-like data with energy in the 0.4-10 Hz range
      final frequencies = List<double>.generate(100, (i) => i * 0.5);
      final magnitudes = List<double>.generate(
        100,
        (i) => frequencies[i] > 0.3 && frequencies[i] < 11 ? 1.0 : 0.0,
      );

      final si = VibrationMetricsService.computeHousnerSI(
        magnitudes,
        frequencies,
      );

      expect(si, greaterThan(0));
    });

    test('returns 0 for empty input', () {
      expect(VibrationMetricsService.computeHousnerSI([], []), 0);
    });

    test('returns 0 for mismatched array lengths', () {
      expect(VibrationMetricsService.computeHousnerSI([1, 2], [1]), 0);
    });

    test('returns 0 when no frequencies are in the integration range', () {
      // All frequencies outside 0.4-10 Hz
      final frequencies = [0.1, 0.2, 15.0, 20.0];
      final magnitudes = [1.0, 1.0, 1.0, 1.0];

      final si = VibrationMetricsService.computeHousnerSI(
        magnitudes,
        frequencies,
      );

      expect(si, 0);
    });

    test('larger magnitudes produce larger SI', () {
      final frequencies = List<double>.generate(50, (i) => i * 0.5);
      final small = List<double>.generate(50, (i) => 1.0);
      final large = List<double>.generate(50, (i) => 5.0);

      final siSmall =
          VibrationMetricsService.computeHousnerSI(small, frequencies);
      final siLarge =
          VibrationMetricsService.computeHousnerSI(large, frequencies);

      expect(siLarge, greaterThan(siSmall));
    });
  });

  // =========================================================================
  // VibrationMetrics (stateful accumulator)
  // =========================================================================
  group('VibrationMetrics', () {
    test('updateWithSample accumulates Ia and CAV', () {
      final metrics = VibrationMetrics();
      const dt = 1.0 / 200;

      for (int i = 0; i < 200; i++) {
        metrics.updateWithSample(0.1, dt);
      }

      expect(metrics.ariasIntensity, greaterThan(0));
      expect(metrics.cav, closeTo(0.1, 0.001));
    });

    test('resetSession zeros everything', () {
      final metrics = VibrationMetrics();
      metrics.ariasIntensity = 1.5;
      metrics.cav = 0.3;
      metrics.damageIndex = 0.7;
      metrics.housnerSI = 2.0;

      metrics.resetSession();

      expect(metrics.ariasIntensity, 0);
      expect(metrics.cav, 0);
      expect(metrics.damageIndex, 0);
      expect(metrics.housnerSI, 0);
    });

    test('toJson contains all expected keys', () {
      final metrics = VibrationMetrics();
      final json = metrics.toJson();

      expect(json.containsKey('ariasIntensity'), isTrue);
      expect(json.containsKey('cav'), isTrue);
      expect(json.containsKey('damageIndex'), isTrue);
      expect(json.containsKey('housnerSI'), isTrue);
      expect(json.containsKey('cavExceedsEPRI'), isTrue);
      expect(json.containsKey('damageStatus'), isTrue);
    });

    test('damage status reflects index thresholds', () {
      final metrics = VibrationMetrics();

      metrics.damageIndex = 0.3;
      expect(metrics.toJson()['damageStatus'], 'safe');

      metrics.damageIndex = 0.7;
      expect(metrics.toJson()['damageStatus'], 'warning');

      metrics.damageIndex = 1.5;
      expect(metrics.toJson()['damageStatus'], 'critical');
    });

    test('updateWithWindow processes complete window', () {
      final metrics = VibrationMetrics();
      final signal = sineWave(10, 200, 400, amplitude: 0.5);

      metrics.updateWithWindow(signal, 200);

      expect(metrics.ariasIntensity, greaterThan(0));
      expect(metrics.cav, greaterThan(0));
    });

    test('updateWithWindow handles empty input gracefully', () {
      final metrics = VibrationMetrics();
      metrics.updateWithWindow([], 200);
      expect(metrics.ariasIntensity, 0);
      expect(metrics.cav, 0);
    });
  });

  // =========================================================================
  // Edge cases
  // =========================================================================
  group('Edge cases', () {
    test('all metrics handle single-sample input', () {
      expect(
        VibrationMetricsService.computeAriasIntensity([1.0], 200),
        greaterThan(0),
      );
      expect(
        VibrationMetricsService.computeCAV([1.0], 200),
        greaterThan(0),
      );
      expect(
        VibrationMetricsService.computeZeroCrossingRate([1.0]),
        0,
      );
    });

    test('all metrics handle all-zero input', () {
      final zeros = List<double>.filled(256, 0);
      expect(
        VibrationMetricsService.computeAriasIntensity(zeros, 200),
        0,
      );
      expect(
        VibrationMetricsService.computeCAV(zeros, 200),
        0,
      );
      expect(
        VibrationMetricsService.computeZeroCrossingRate(zeros),
        0,
      );
    });

    test('classification handles extreme frequencies', () {
      // Very low frequency
      final low = VibrationMetricsService.classifyAllStandards(5.0, 0.1);
      expect(low.length, 4);

      // Very high frequency
      final high = VibrationMetricsService.classifyAllStandards(5.0, 200.0);
      expect(high.length, 4);
    });
  });
}
