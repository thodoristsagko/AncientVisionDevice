import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:ancient_vision/services/wavelet_service.dart';

void main() {
  const double sqrt2 = 1.4142135623730951;

  group('WaveletService.decompose', () {
    test('decomposes [1, 2, 3, 4] correctly at 1 level', () {
      // Haar DWT of [1, 2, 3, 4] at level 1:
      //   approx = [(1+2)/sqrt2, (3+4)/sqrt2] = [3/sqrt2, 7/sqrt2]
      //   detail = [(1-2)/sqrt2, (3-4)/sqrt2] = [-1/sqrt2, -1/sqrt2]
      final result = WaveletService.decompose([1, 2, 3, 4], levels: 1);

      expect(result.levels, 1);
      expect(result.details.length, 1);
      expect(result.approximation.length, 2);
      expect(result.details[0].length, 2);

      expect(result.approximation[0], closeTo(3 / sqrt2, 1e-10));
      expect(result.approximation[1], closeTo(7 / sqrt2, 1e-10));
      expect(result.details[0][0], closeTo(-1 / sqrt2, 1e-10));
      expect(result.details[0][1], closeTo(-1 / sqrt2, 1e-10));
    });

    test('decomposes [1, 2, 3, 4] correctly at 2 levels', () {
      final result = WaveletService.decompose([1, 2, 3, 4], levels: 2);

      expect(result.levels, 2);
      expect(result.details.length, 2);
      // Level 1 detail same as above.
      expect(result.details[0][0], closeTo(-1 / sqrt2, 1e-10));
      expect(result.details[0][1], closeTo(-1 / sqrt2, 1e-10));

      // Level 2: DWT of [3/sqrt2, 7/sqrt2]
      //   approx = [(3/sqrt2 + 7/sqrt2) / sqrt2] = [10/2] = [5]
      //   detail = [(3/sqrt2 - 7/sqrt2) / sqrt2] = [-4/2] = [-2]
      expect(result.approximation.length, 1);
      expect(result.approximation[0], closeTo(5.0, 1e-10));
      expect(result.details[1].length, 1);
      expect(result.details[1][0], closeTo(-2.0, 1e-10));
    });

    test('handles non-power-of-two lengths by zero-padding', () {
      // Signal of length 3 -> zero-padded to 4.
      final result = WaveletService.decompose([1, 2, 3], levels: 1);
      expect(result.levels, 1);
      // Padded signal is [1, 2, 3, 0]
      //   approx = [(1+2)/sqrt2, (3+0)/sqrt2]
      //   detail = [(1-2)/sqrt2, (3-0)/sqrt2]
      expect(result.approximation[0], closeTo(3 / sqrt2, 1e-10));
      expect(result.approximation[1], closeTo(3 / sqrt2, 1e-10));
      expect(result.details[0][0], closeTo(-1 / sqrt2, 1e-10));
      expect(result.details[0][1], closeTo(3 / sqrt2, 1e-10));
    });
  });

  group('WaveletService.reconstruct (round-trip)', () {
    test('round-trip on [1, 2, 3, 4]', () {
      final signal = [1.0, 2.0, 3.0, 4.0];
      final result = WaveletService.decompose(signal, levels: 2);
      final reconstructed = WaveletService.reconstruct(result);

      for (int i = 0; i < signal.length; i++) {
        expect(reconstructed[i], closeTo(signal[i], 1e-10));
      }
    });

    test('round-trip on longer signal', () {
      final rng = Random(42);
      final signal = List<double>.generate(256, (_) => rng.nextDouble() * 10);
      final result = WaveletService.decompose(signal, levels: 3);
      final reconstructed = WaveletService.reconstruct(result);

      for (int i = 0; i < signal.length; i++) {
        expect(reconstructed[i], closeTo(signal[i], 1e-10));
      }
    });

    test('round-trip on constant signal', () {
      final signal = List<double>.filled(16, 5.0);
      final result = WaveletService.decompose(signal, levels: 3);
      final reconstructed = WaveletService.reconstruct(result);

      for (int i = 0; i < signal.length; i++) {
        expect(reconstructed[i], closeTo(5.0, 1e-10));
      }
    });

    test('round-trip on non-power-of-two length (padded)', () {
      final signal = [1.0, 2.0, 3.0, 4.0, 5.0];
      final result = WaveletService.decompose(signal, levels: 2);
      final reconstructed = WaveletService.reconstruct(result);

      // First 5 values should match; indices 5-7 are from zero-padding.
      for (int i = 0; i < signal.length; i++) {
        expect(reconstructed[i], closeTo(signal[i], 1e-10));
      }
    });
  });

  group('WaveletService.denoise', () {
    test('denoising reduces noise on a noisy sine wave', () {
      final rng = Random(123);
      const int n = 256;
      const double freq = 5.0;
      const double sampleRate = 256.0;

      // Pure sine wave.
      final clean = List<double>.generate(
          n, (i) => sin(2 * pi * freq * i / sampleRate));

      // Add Gaussian-ish noise (Box-Muller).
      final noisy = List<double>.generate(n, (i) {
        final u1 = rng.nextDouble();
        final u2 = rng.nextDouble();
        final noise = sqrt(-2 * log(u1)) * cos(2 * pi * u2) * 0.5;
        return clean[i] + noise;
      });

      final denoised = WaveletService.denoise(noisy, levels: 3);

      // Compute MSE of noisy vs clean and denoised vs clean.
      double noisyMse = 0.0;
      double denoisedMse = 0.0;
      for (int i = 0; i < n; i++) {
        noisyMse += (noisy[i] - clean[i]) * (noisy[i] - clean[i]);
        denoisedMse += (denoised[i] - clean[i]) * (denoised[i] - clean[i]);
      }
      noisyMse /= n;
      denoisedMse /= n;

      // Denoised signal should have lower MSE than the noisy signal.
      expect(denoisedMse, lessThan(noisyMse),
          reason: 'Denoising should reduce MSE. '
              'Noisy MSE=$noisyMse, Denoised MSE=$denoisedMse');
    });

    test('denoising a clean signal preserves it approximately', () {
      final clean = List<double>.generate(
          64, (i) => sin(2 * pi * 3 * i / 64.0));
      final denoised = WaveletService.denoise(clean, levels: 2);

      double mse = 0.0;
      for (int i = 0; i < clean.length; i++) {
        mse += (denoised[i] - clean[i]) * (denoised[i] - clean[i]);
      }
      mse /= clean.length;

      // MSE should be very small for a clean signal.
      expect(mse, lessThan(0.1),
          reason: 'Denoising a clean signal should not distort it much');
    });
  });

  group('WaveletService.detectTransients', () {
    test('detects an impulse in a quiet signal', () {
      // Quiet background with a large impulse near the center.
      final signal = List<double>.filled(256, 0.0);
      signal[128] = 10.0; // impulse

      final events = WaveletService.detectTransients(
        signal,
        sensitivity: 3.0,
        sampleRate: 200.0,
      );

      expect(events, isNotEmpty,
          reason: 'Transient detector should find the impulse');

      // At least one event should be near the impulse location.
      final bool anyNearImpulse = events.any(
          (e) => (e.timestamp - 128 / 200.0).abs() < 1.0);
      expect(anyNearImpulse, isTrue,
          reason: 'At least one transient should be near t=0.64s');
    });

    test('does not flag a constant signal', () {
      final signal = List<double>.filled(256, 3.0);
      final events = WaveletService.detectTransients(signal);

      expect(events, isEmpty,
          reason: 'A constant signal should have no transients');
    });

    test('returns empty for very short signals', () {
      expect(WaveletService.detectTransients([1.0]), isEmpty);
      expect(WaveletService.detectTransients([1.0, 2.0]), isEmpty);
      expect(WaveletService.detectTransients([]), isEmpty);
    });
  });

  group('WaveletService.bandEnergy', () {
    test('band energies sum to total signal energy (Parseval)', () {
      final rng = Random(77);
      final signal = List<double>.generate(128, (_) => rng.nextDouble() * 5);

      // Total energy in the time domain.
      // Note: We must compare against the zero-padded signal's energy because
      // 128 is already a power of two, so no padding occurs.
      double signalEnergy = 0.0;
      for (final v in signal) {
        signalEnergy += v * v;
      }

      final bands = WaveletService.bandEnergy(signal, levels: 3);
      double bandEnergySum = 0.0;
      for (final e in bands.values) {
        bandEnergySum += e;
      }

      // Parseval's theorem: sum of squared coefficients == sum of squared
      // samples. The wavelet coefficients are orthonormal so energies match.
      expect(bandEnergySum, closeTo(signalEnergy, 1e-6),
          reason: 'Band energies should sum to total signal energy');
    });

    test('returns expected number of bands', () {
      final signal = List<double>.generate(64, (i) => i.toDouble());
      final bands = WaveletService.bandEnergy(signal, levels: 3, sampleRate: 200.0);

      // 3 detail bands + 1 approximation band = 4 entries.
      expect(bands.length, 4);
      expect(bands.keys.where((k) => k.startsWith('D')).length, 3);
      expect(bands.keys.where((k) => k.startsWith('A')).length, 1);
    });

    test('returns empty for empty signal', () {
      expect(WaveletService.bandEnergy([]), isEmpty);
    });

    test('band labels contain correct frequency ranges for 200 Hz', () {
      final signal = List<double>.filled(128, 1.0);
      final bands = WaveletService.bandEnergy(
        signal,
        levels: 3,
        sampleRate: 200.0,
      );

      // Nyquist = 100 Hz.
      // D1: 50-100 Hz, D2: 25-50 Hz, D3: 12.5-25 Hz, A3: 0-12.5 Hz.
      expect(bands.containsKey('D1: 50.0-100.0 Hz'), isTrue);
      expect(bands.containsKey('D2: 25.0-50.0 Hz'), isTrue);
      expect(bands.containsKey('D3: 12.5-25.0 Hz'), isTrue);
      expect(bands.containsKey('A3: 0.0-12.5 Hz'), isTrue);
    });
  });

  group('Edge cases', () {
    test('empty signal decompose returns empty result', () {
      final result = WaveletService.decompose([]);
      expect(result.approximation, isEmpty);
      expect(result.details, isEmpty);
      expect(result.levels, 0);
    });

    test('single-element signal decompose returns it unchanged', () {
      final result = WaveletService.decompose([42.0]);
      expect(result.approximation, [42.0]);
      expect(result.details, isEmpty);
      expect(result.levels, 0);
    });

    test('reconstruct of empty result gives empty list', () {
      const result = WaveletResult(
        approximation: [],
        details: [],
        levels: 0,
      );
      expect(WaveletService.reconstruct(result), isEmpty);
    });

    test('reconstruct of single-element result gives that element', () {
      const result = WaveletResult(
        approximation: [7.0],
        details: [],
        levels: 0,
      );
      expect(WaveletService.reconstruct(result), [7.0]);
    });

    test('denoise of single element returns it unchanged', () {
      expect(WaveletService.denoise([3.14]), [3.14]);
    });

    test('denoise of empty signal returns empty', () {
      expect(WaveletService.denoise([]), isEmpty);
    });

    test('two-element signal decomposes and round-trips', () {
      final signal = [3.0, 7.0];
      final result = WaveletService.decompose(signal, levels: 1);
      expect(result.levels, 1);
      expect(result.approximation.length, 1);
      expect(result.approximation[0], closeTo(10 / sqrt2, 1e-10));
      expect(result.details[0][0], closeTo(-4 / sqrt2, 1e-10));

      final reconstructed = WaveletService.reconstruct(result);
      expect(reconstructed[0], closeTo(3.0, 1e-10));
      expect(reconstructed[1], closeTo(7.0, 1e-10));
    });
  });
}
