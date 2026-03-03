import 'dart:math';

/// Result of a multi-level Haar Discrete Wavelet Transform decomposition.
class WaveletResult {
  /// Approximation coefficients at the coarsest level.
  final List<double> approximation;

  /// Detail coefficients at each level. [details[0]] is level 1 (finest),
  /// [details[levels-1]] is the coarsest detail level.
  final List<List<double>> details;

  /// Number of decomposition levels performed.
  final int levels;

  const WaveletResult({
    required this.approximation,
    required this.details,
    required this.levels,
  });
}

/// A transient event detected via wavelet detail coefficient energy analysis.
class TransientEvent {
  /// Timestamp in seconds from the start of the signal.
  final double timestamp;

  /// Energy of the transient.
  final double energy;

  /// Wavelet decomposition level where the transient was detected.
  final int level;

  const TransientEvent({
    required this.timestamp,
    required this.energy,
    required this.level,
  });

  @override
  String toString() =>
      'TransientEvent(t=${timestamp.toStringAsFixed(4)}s, '
      'energy=${energy.toStringAsFixed(4)}, level=$level)';
}

/// Pure-Dart Haar Discrete Wavelet Transform service.
///
/// Provides decomposition, reconstruction, denoising, transient detection,
/// and wavelet packet energy distribution -- all with O(N) complexity and
/// zero external dependencies.
class WaveletService {
  static final double _sqrt2 = sqrt(2.0);

  // ---------------------------------------------------------------------------
  // Core DWT
  // ---------------------------------------------------------------------------

  /// Performs a multi-level Haar DWT decomposition of [signal].
  ///
  /// The signal length must be at least 2^[levels]. If it is not a power of
  /// two the signal is zero-padded to the next power of two before
  /// decomposition.
  static WaveletResult decompose(List<double> signal, {int levels = 3}) {
    if (signal.isEmpty) {
      return const WaveletResult(
        approximation: [],
        details: [],
        levels: 0,
      );
    }
    if (signal.length == 1) {
      return WaveletResult(
        approximation: List<double>.from(signal),
        details: const [],
        levels: 0,
      );
    }

    // Zero-pad to the next power of two if needed.
    final int padLen = _nextPowerOfTwo(signal.length);
    List<double> current = List<double>.filled(padLen, 0.0);
    for (int i = 0; i < signal.length; i++) {
      current[i] = signal[i];
    }

    // Ensure we don't request more levels than the signal supports.
    final int maxLevels = (log(padLen) / ln2).floor();
    final int actualLevels = levels.clamp(1, maxLevels);

    final List<List<double>> details = [];

    for (int l = 0; l < actualLevels; l++) {
      final int halfLen = current.length ~/ 2;
      final List<double> approx = List<double>.filled(halfLen, 0.0);
      final List<double> detail = List<double>.filled(halfLen, 0.0);

      for (int k = 0; k < halfLen; k++) {
        approx[k] = (current[2 * k] + current[2 * k + 1]) / _sqrt2;
        detail[k] = (current[2 * k] - current[2 * k + 1]) / _sqrt2;
      }

      details.add(detail);
      current = approx;
    }

    return WaveletResult(
      approximation: current,
      details: details,
      levels: actualLevels,
    );
  }

  /// Reconstructs the original signal from a [WaveletResult].
  ///
  /// This is the inverse Haar DWT. For a result produced by [decompose], the
  /// round-trip `reconstruct(decompose(signal))` recovers the (possibly
  /// zero-padded) original signal within floating-point precision.
  static List<double> reconstruct(WaveletResult result) {
    if (result.levels == 0) {
      return List<double>.from(result.approximation);
    }

    List<double> current = List<double>.from(result.approximation);

    // Walk from the coarsest detail level back to the finest.
    for (int l = result.levels - 1; l >= 0; l--) {
      final List<double> detail = result.details[l];
      final int outLen = current.length * 2;
      final List<double> output = List<double>.filled(outLen, 0.0);

      for (int k = 0; k < current.length; k++) {
        output[2 * k] = (current[k] + detail[k]) / _sqrt2;
        output[2 * k + 1] = (current[k] - detail[k]) / _sqrt2;
      }

      current = output;
    }

    return current;
  }

  // ---------------------------------------------------------------------------
  // Denoising
  // ---------------------------------------------------------------------------

  /// Denoises [signal] using Haar DWT soft thresholding with BayesShrink.
  ///
  /// BayesShrink provides per-level adaptive thresholding instead of a
  /// universal threshold. For each detail level, the threshold is computed as:
  ///   threshold = sigma² / sigma_signal
  /// where sigma is the noise standard deviation (estimated from finest detail
  /// using MAD) and sigma_signal = sqrt(max(0, var(detail) - sigma²)).
  ///
  /// This is more conservative than universal thresholding and better preserves
  /// signal features while removing noise. An explicit [threshold] can still be
  /// supplied to override the automatic estimate and use universal thresholding.
  static List<double> denoise(
    List<double> signal, {
    int levels = 3,
    double? threshold,
  }) {
    if (signal.length < 2) return List<double>.from(signal);

    final WaveletResult result = decompose(signal, levels: levels);

    // Estimate noise standard deviation from finest detail coefficients.
    final double sigma = _estimateSigma(result.details[0]);

    // If explicit threshold provided, use universal thresholding
    if (threshold != null) {
      final List<List<double>> thresholdedDetails = result.details
          .map((d) => d.map((v) => _softThreshold(v, threshold)).toList())
          .toList();

      final WaveletResult denoised = WaveletResult(
        approximation: result.approximation,
        details: thresholdedDetails,
        levels: result.levels,
      );

      final List<double> reconstructed = reconstruct(denoised);
      return reconstructed.sublist(0, signal.length);
    }

    // BayesShrink: compute per-level adaptive thresholds
    final List<List<double>> thresholdedDetails = [];
    for (final detail in result.details) {
      // Compute variance of this detail level
      double mean = 0.0;
      for (final v in detail) {
        mean += v;
      }
      mean /= detail.length;

      double variance = 0.0;
      for (final v in detail) {
        final d = v - mean;
        variance += d * d;
      }
      variance /= detail.length;

      // Estimate signal variance: var_signal = max(0, var(detail) - sigma²)
      final sigmaSignalSq = max(0.0, variance - sigma * sigma);
      final sigmaSignal = sqrt(sigmaSignalSq);

      // BayesShrink threshold: sigma² / sigma_signal
      // If sigma_signal ≈ 0 (pure noise), threshold → infinity (suppress all)
      // Add small epsilon to prevent division by zero
      final thr = sigmaSignal > 1e-10 ? (sigma * sigma) / sigmaSignal : sigma * 100.0;

      // Apply soft thresholding with this level's threshold
      final thresholdedDetail = detail.map((v) => _softThreshold(v, thr)).toList();
      thresholdedDetails.add(thresholdedDetail);
    }

    final WaveletResult denoised = WaveletResult(
      approximation: result.approximation,
      details: thresholdedDetails,
      levels: result.levels,
    );

    final List<double> reconstructed = reconstruct(denoised);

    // Trim back to original length (undo zero-padding).
    return reconstructed.sublist(0, signal.length);
  }

  // ---------------------------------------------------------------------------
  // Transient Detection
  // ---------------------------------------------------------------------------

  /// Detects transient events by monitoring detail coefficient energy.
  ///
  /// At each decomposition level the detail coefficients are split into
  /// non-overlapping windows. If the energy in a window exceeds [sensitivity]
  /// times the running average energy, a [TransientEvent] is emitted.
  static List<TransientEvent> detectTransients(
    List<double> signal, {
    double sensitivity = 3.0,
    double sampleRate = 200.0,
  }) {
    if (signal.length < 4) return const [];

    final WaveletResult result = decompose(signal, levels: 3);
    final List<TransientEvent> events = [];

    for (int level = 0; level < result.details.length; level++) {
      final List<double> detail = result.details[level];
      if (detail.length < 2) continue;

      // Window size: at least 2 coefficients, up to 1/8 of the detail length.
      final int windowSize = max(2, detail.length ~/ 8);
      final int stride = windowSize; // non-overlapping

      // Pre-compute the overall mean energy per window for this level.
      // This serves as a fallback when the running average is near zero
      // (e.g. an impulse in an otherwise silent signal).
      double totalEnergy = 0.0;
      for (final double v in detail) {
        totalEnergy += v * v;
      }
      final int numWindows =
          (detail.length - windowSize) ~/ stride + 1;
      final double meanWindowEnergy =
          numWindows > 0 ? totalEnergy / numWindows : 0.0;

      double runningSum = 0.0;
      int runningCount = 0;

      for (int start = 0; start + windowSize <= detail.length; start += stride) {
        double windowEnergy = 0.0;
        for (int j = start; j < start + windowSize; j++) {
          windowEnergy += detail[j] * detail[j];
        }

        if (runningCount > 0) {
          final double runningAvg = runningSum / runningCount;
          // Use the larger of the running average and a fraction of the
          // overall mean energy as the baseline. This ensures isolated
          // impulses in otherwise silent signals are still detected.
          final double baseline = max(runningAvg, meanWindowEnergy * 0.1);
          if (baseline > 0 && windowEnergy > sensitivity * baseline) {
            // Map the coefficient index back to the time domain.
            // Each coefficient at `level` corresponds to 2^(level+1) samples.
            final int sampleIndex = start * (1 << (level + 1));
            final double timestamp = sampleIndex / sampleRate;

            events.add(TransientEvent(
              timestamp: timestamp,
              energy: windowEnergy,
              level: level + 1, // 1-indexed level
            ));
          }
        }

        runningSum += windowEnergy;
        runningCount++;
      }
    }

    // Sort by timestamp.
    events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return events;
  }

  // ---------------------------------------------------------------------------
  // Band Energy Distribution
  // ---------------------------------------------------------------------------

  /// Computes the wavelet packet energy distribution across frequency bands.
  ///
  /// Returns a map from human-readable band labels (e.g. "D1: 50-100 Hz") to
  /// the energy (sum of squared coefficients) in that band.
  static Map<String, double> bandEnergy(
    List<double> signal, {
    int levels = 3,
    double sampleRate = 200.0,
  }) {
    if (signal.length < 2) return {};

    final WaveletResult result = decompose(signal, levels: levels);
    final double nyquist = sampleRate / 2.0;
    final Map<String, double> energies = {};

    for (int level = 0; level < result.details.length; level++) {
      // Detail at level l captures frequencies in [nyquist/2^(l+1), nyquist/2^l].
      final double fHigh = nyquist / pow(2, level);
      final double fLow = nyquist / pow(2, level + 1);
      final String label =
          'D${level + 1}: ${fLow.toStringAsFixed(1)}-${fHigh.toStringAsFixed(1)} Hz';

      double energy = 0.0;
      for (final double v in result.details[level]) {
        energy += v * v;
      }
      energies[label] = energy;
    }

    // Approximation band: 0 to nyquist/2^levels.
    final double approxHigh = nyquist / pow(2, result.levels);
    final String approxLabel = 'A${result.levels}: 0.0-${approxHigh.toStringAsFixed(1)} Hz';
    double approxEnergy = 0.0;
    for (final double v in result.approximation) {
      approxEnergy += v * v;
    }
    energies[approxLabel] = approxEnergy;

    return energies;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Returns the smallest power of two >= [n].
  static int _nextPowerOfTwo(int n) {
    if (n <= 1) return 1;
    int p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }

  /// Estimates noise standard deviation via MAD (Median Absolute Deviation).
  static double _estimateSigma(List<double> coefficients) {
    if (coefficients.isEmpty) return 0.0;
    final List<double> absCoeffs =
        coefficients.map((c) => c.abs()).toList()..sort();
    final double median = _median(absCoeffs);
    return median / 0.6745;
  }

  /// Computes the median of a sorted list of non-negative values.
  static double _median(List<double> sorted) {
    if (sorted.isEmpty) return 0.0;
    final int mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  /// Soft thresholding operator: sign(x) * max(|x| - threshold, 0).
  static double _softThreshold(double x, double threshold) {
    if (x.abs() <= threshold) return 0.0;
    return x.sign * (x.abs() - threshold);
  }
}
