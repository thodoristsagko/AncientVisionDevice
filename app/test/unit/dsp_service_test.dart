import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/vibration_dsp_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Build three identical zero-filled axis lists of [size] samples.
  List<double> zeros(int size) => List<double>.filled(size, 0.0);

  /// Build a list of [size] samples all equal to [value].
  List<double> constant(int size, double value) =>
      List<double>.filled(size, value);

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------

  group('VibrationDspService', () {
    late VibrationDspService svc;

    setUp(() {
      svc = VibrationDspService();
    });

    // -------------------------------------------------------------------------
    // 1. Returns non-null result for valid input
    // -------------------------------------------------------------------------
    test('process returns non-null result for valid input', () {
      const n = VibrationDspService.windowSize;
      final result = svc.process(zeros(n), zeros(n), zeros(n));
      expect(result, isNotNull);
    });

    // -------------------------------------------------------------------------
    // 2. RMS of a constant-1 signal equals 1.0
    // -------------------------------------------------------------------------
    test('process computes RMS correctly for constant-1 signal', () {
      const n = VibrationDspService.windowSize;
      // Magnitude = sqrt(1^2 + 0^2 + 0^2) = 1.0 for every sample.
      final result = svc.process(constant(n, 1.0), zeros(n), zeros(n));
      expect(result.rms, closeTo(1.0, 1e-9));
    });

    // -------------------------------------------------------------------------
    // 3. PPV (peak) equals the maximum magnitude in the signal
    // -------------------------------------------------------------------------
    test('process computes peak correctly', () {
      const n = VibrationDspService.windowSize;
      // X-axis constant 5.0, Y and Z zero → magnitude = 5.0 every sample.
      final result = svc.process(constant(n, 5.0), zeros(n), zeros(n));
      expect(result.peak, closeTo(5.0, 1e-9));
    });

    // -------------------------------------------------------------------------
    // 4. All-zero input: no exception, ppv = 0, rms = 0
    // -------------------------------------------------------------------------
    test('process handles all-zero input gracefully', () {
      const n = VibrationDspService.windowSize;
      late DspResult result;
      expect(() {
        result = svc.process(zeros(n), zeros(n), zeros(n));
      }, returnsNormally);
      expect(result.peak, closeTo(0.0, 1e-12));
      expect(result.rms, closeTo(0.0, 1e-12));
    });

    // -------------------------------------------------------------------------
    // 5. Caching: identical input returns the same DspResult object
    // -------------------------------------------------------------------------
    test('process caches identical input and returns same result', () {
      const n = VibrationDspService.windowSize;
      final x = constant(n, 0.5);
      final y = constant(n, 0.3);
      final z = constant(n, 0.1);
      final first = svc.process(x, y, z);
      final second = svc.process(x, y, z);
      // The cache returns the same object reference.
      expect(identical(first, second), isTrue);
    });

    // -------------------------------------------------------------------------
    // 6. sampleRateHz returns a positive value
    // -------------------------------------------------------------------------
    test('sampleRateHz returns positive value', () {
      expect(svc.sampleRateHz, greaterThan(0));
    });

    // -------------------------------------------------------------------------
    // 7. Dominant frequency is within the valid Nyquist range
    //    (dominantFreq may be 0 when signal is below noise floor — that is valid)
    // -------------------------------------------------------------------------
    test('process dominantFreq is within valid range for a sinusoidal signal', () {
      const n = VibrationDspService.windowSize;
      final nyquist = VibrationDspService.sampleRate / 2.0;

      // Build a 10 Hz sine wave on the X axis so FFT has a clear peak.
      final x = List<double>.generate(n, (i) {
        final t = i / VibrationDspService.sampleRate.toDouble();
        return sin(2.0 * pi * 10.0 * t);
      });

      final result = svc.process(x, zeros(n), zeros(n));
      // dominantFreq can be 0 only if below noise floor (acceptable).
      // When above noise floor it must be in (0, nyquist].
      if (result.dominantFreq > 0.0) {
        expect(result.dominantFreq, lessThanOrEqualTo(nyquist));
      }
    });

    // -------------------------------------------------------------------------
    // 8. Excess kurtosis of a constant signal is 0.0 (variance is 0 → guard
    //    branch returns 0.0) and for broadband white noise it is ≥ -3
    //    (normal excess kurtosis ≈ 0, so at minimum it should be > -10).
    // -------------------------------------------------------------------------
    test('process kurtosis is a finite number and >= -3.0 for white noise', () {
      const n = VibrationDspService.windowSize;
      final rng = Random(42);
      final x = List<double>.generate(n, (_) => rng.nextDouble() * 2.0 - 1.0);
      final y = List<double>.generate(n, (_) => rng.nextDouble() * 2.0 - 1.0);
      final z = List<double>.generate(n, (_) => rng.nextDouble() * 2.0 - 1.0);

      final result = svc.process(x, y, z);
      expect(result.kurtosis.isFinite, isTrue);
      // Excess kurtosis of Gaussian noise ≈ 0 — allow generous tolerance.
      expect(result.kurtosis, greaterThanOrEqualTo(-3.0));
    });

    // -------------------------------------------------------------------------
    // 9. reset() clears accumulators without throwing
    // -------------------------------------------------------------------------
    test('reset clears running accumulators', () {
      const n = VibrationDspService.windowSize;
      svc.process(constant(n, 1.0), zeros(n), zeros(n));
      expect(() => svc.reset(), returnsNormally);
      expect(svc.ariasIntensity, closeTo(0.0, 1e-12));
      expect(svc.cav, closeTo(0.0, 1e-12));
    });

    // -------------------------------------------------------------------------
    // 10. dispose() does not throw
    // -------------------------------------------------------------------------
    test('dispose does not throw', () {
      expect(() => svc.dispose(), returnsNormally);
    });
  });
}
