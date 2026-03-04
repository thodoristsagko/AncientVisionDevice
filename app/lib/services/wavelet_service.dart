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

  /// Ratio of high-frequency (finest detail, D1) energy to total signal energy.
  ///
  /// A high ratio indicates percussive or impulsive events dominated by
  /// high-frequency content. Returns 0.0 if there are no detail coefficients
  /// or total energy is zero.
  double get highFreqEnergyRatio {
    if (details.isEmpty) return 0.0;

    // High-frequency energy: D1 (finest detail level, index 0).
    double highFreqEnergy = 0.0;
    for (final v in details[0]) {
      highFreqEnergy += v * v;
    }

    // Total energy: all detail levels + approximation.
    double totalEnergy = highFreqEnergy;
    for (int i = 1; i < details.length; i++) {
      for (final v in details[i]) {
        totalEnergy += v * v;
      }
    }
    for (final v in approximation) {
      totalEnergy += v * v;
    }

    if (totalEnergy == 0.0) return 0.0;
    return highFreqEnergy / totalEnergy;
  }

  /// Name of the decomposition sub-band with the highest energy.
  ///
  /// Returns one of "D1", "D2", ..., "D[levels]", or "A[levels]" for the
  /// approximation band. Useful for identifying which frequency range
  /// dominates the signal. Returns "none" if the result is empty.
  String get dominantSubBand {
    if (levels == 0 && approximation.isEmpty) return 'none';

    double bestEnergy = -1.0;
    String bestLabel = 'none';

    // Check each detail level (D1 = index 0 = finest).
    for (int i = 0; i < details.length; i++) {
      double energy = 0.0;
      for (final v in details[i]) {
        energy += v * v;
      }
      if (energy > bestEnergy) {
        bestEnergy = energy;
        bestLabel = 'D${i + 1}';
      }
    }

    // Check approximation band.
    double approxEnergy = 0.0;
    for (final v in approximation) {
      approxEnergy += v * v;
    }
    if (approxEnergy > bestEnergy) {
      bestLabel = 'A$levels';
    }

    return bestLabel;
  }
}

/// Summary produced by [WaveletService.analyze].
///
/// Bundles the raw decomposition together with derived metrics — band energy
/// ratios, transient flag, frequency-band labels, and per-band energy trends
/// relative to the previous [analyze] call.
class WaveletAnalysisResult {
  /// Raw DWT decomposition.
  final WaveletResult wavelet;

  /// Absolute energy per band (sum of squared coefficients).
  /// Keys match [WaveletService.bandFrequencyLabels].
  final Map<String, double> bandEnergies;

  /// Energy of each band expressed as a fraction of the total signal energy.
  /// Values are in [0, 1] and sum to 1 (within floating-point rounding).
  final Map<String, double> bandEnergyRatios;

  /// True if any single sample in the analysed signal exceeds 3× the RMS
  /// of the signal (impulsive transient criterion).
  final bool hasTransient;

  /// Fractional change in band energy compared to the previous [analyze] call.
  /// Positive values indicate increasing energy; negative values indicate
  /// decreasing energy. Empty on the very first call (no baseline yet).
  final Map<String, double> bandEnergyTrend;

  const WaveletAnalysisResult({
    required this.wavelet,
    required this.bandEnergies,
    required this.bandEnergyRatios,
    required this.hasTransient,
    required this.bandEnergyTrend,
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
///
/// The stateful [analyze] method additionally computes band energy ratios,
/// a simple transient flag, and per-band energy trends relative to the
/// previous call.  Use [reset] to clear the trending baseline.
class WaveletService {
  static final double _sqrt2 = sqrt(2.0);

  // ---------------------------------------------------------------------------
  // Instance state for trending and caching
  // ---------------------------------------------------------------------------

  /// Band energies from the most recent [analyze] call.  Used as the baseline
  /// for computing [WaveletAnalysisResult.bandEnergyTrend].
  Map<String, double>? _previousBandEnergies;

  /// Latest band energy ratios (fraction of total energy per band).
  Map<String, double> get lastBandRatios => _lastBandRatios;
  Map<String, double> _lastBandRatios = {};

  /// Whether the most recent [analyze] call detected a transient.
  bool get hasTransient => _hasTransient;
  bool _hasTransient = false;

  // --- Result cache ---

  /// Cached result from the last [analyze] call.  Re-used when the input
  /// length and checksum match, avoiding redundant decomposition work.
  WaveletAnalysisResult? _lastResult;

  /// Input length used to produce [_lastResult].
  int _lastInputLength = -1;

  /// Simple checksum (sum of first 10 values) used to detect input changes.
  double _lastInputChecksum = double.nan;

  /// Clear the trending baseline so the next [analyze] call starts fresh.
  void reset() {
    _previousBandEnergies = null;
    _lastBandRatios = {};
    _hasTransient = false;
    _lastResult = null;
    _lastInputLength = -1;
    _lastInputChecksum = double.nan;
  }

  /// Release all cached state and internal buffers.
  ///
  /// Call this when the service is no longer needed (e.g., in a widget's
  /// dispose() lifecycle method) to free memory held by cached decomposition
  /// results and band energy history.
  void dispose() {
    _previousBandEnergies = null;
    _lastBandRatios = {};
    _hasTransient = false;
    _lastResult = null;
    _lastInputLength = -1;
    _lastInputChecksum = double.nan;
  }

  // ---------------------------------------------------------------------------
  // High-level stateful analysis
  // ---------------------------------------------------------------------------

  /// Perform a full wavelet analysis of [signal] and return a [WaveletAnalysisResult].
  ///
  /// Internally calls [decompose] and [bandEnergy], then:
  ///   1. Computes per-band energy ratios (fraction of total energy).
  ///   2. Detects a transient: any sample whose absolute value exceeds 3× the
  ///      signal RMS is considered impulsive.
  ///   3. Computes energy trends relative to the previous call (fractional
  ///      change; positive = increasing, negative = decreasing).
  ///   4. Updates [lastBandRatios] and [hasTransient] instance properties.
  ///
  /// Results are cached: if called again with the same input length and
  /// checksum (sum of first 10 values), the cached result is returned
  /// immediately without recomputing the decomposition.
  WaveletAnalysisResult analyze(
    List<double> signal, {
    int levels = 3,
    double sampleRate = 200.0,
  }) {
    // --- Cache check ---
    // Compute a lightweight checksum over the first 10 values.
    final int checkLen = signal.length < 10 ? signal.length : 10;
    double checksum = 0.0;
    for (int i = 0; i < checkLen; i++) {
      checksum += signal[i];
    }

    if (_lastResult != null &&
        signal.length == _lastInputLength &&
        checksum == _lastInputChecksum) {
      return _lastResult!;
    }

    _lastInputLength = signal.length;
    _lastInputChecksum = checksum;

    final WaveletResult decomposition =
        WaveletService.decompose(signal, levels: levels);

    // Compute absolute band energies using the existing static method.
    final Map<String, double> energies = WaveletService.bandEnergy(
      signal,
      levels: levels,
      sampleRate: sampleRate,
    );

    // --- Band energy ratios ---
    double totalEnergy = 0.0;
    for (final e in energies.values) {
      totalEnergy += e;
    }
    final Map<String, double> ratios = {};
    for (final entry in energies.entries) {
      ratios[entry.key] =
          totalEnergy > 0.0 ? entry.value / totalEnergy : 0.0;
    }
    _lastBandRatios = Map.unmodifiable(ratios);

    // --- Transient detection (sample-domain) ---
    _hasTransient = _signalHasTransient(signal);

    // --- Band energy trending ---
    final Map<String, double> trend = {};
    final prev = _previousBandEnergies;
    if (prev != null) {
      for (final entry in energies.entries) {
        final double prevEnergy = prev[entry.key] ?? 0.0;
        if (prevEnergy > 0.0) {
          trend[entry.key] = (entry.value - prevEnergy) / prevEnergy;
        } else if (entry.value > 0.0) {
          trend[entry.key] = 1.0; // rose from zero → 100 % increase
        } else {
          trend[entry.key] = 0.0;
        }
      }
    }
    _previousBandEnergies = Map.unmodifiable(energies);

    _lastResult = WaveletAnalysisResult(
      wavelet: decomposition,
      bandEnergies: energies,
      bandEnergyRatios: ratios,
      hasTransient: _hasTransient,
      bandEnergyTrend: trend,
    );
    return _lastResult!;
  }

  // ---------------------------------------------------------------------------
  // Static utilities
  // ---------------------------------------------------------------------------

  /// Returns true when any sample in [signal] exceeds 3× the signal RMS,
  /// indicating an impulsive transient event.
  static bool _signalHasTransient(List<double> signal) {
    if (signal.length < 2) return false;
    double sumSq = 0.0;
    for (final v in signal) {
      sumSq += v * v;
    }
    final double rms = sqrt(sumSq / signal.length);
    final double threshold = 3.0 * rms;
    for (final v in signal) {
      if (v.abs() > threshold) return true;
    }
    return false;
  }

  /// Maps decomposition level indices to human-readable frequency band labels.
  ///
  /// Level indices follow the [WaveletResult.details] ordering:
  ///   - Index 0 … levels-1 → detail bands D1 … D[levels] (finest→coarsest)
  ///   - Index [levels]       → approximation band A[levels]
  ///
  /// [sampleRate] is in Hz; [windowSize] is the number of samples analysed
  /// (used only to derive the theoretical finest resolution but does not
  /// affect the frequency bounds, which depend solely on [sampleRate]).
  ///
  /// Example for sampleRate=200, levels=3:
  ///   {0: 'D1: 50.0–100.0 Hz', 1: 'D2: 25.0–50.0 Hz',
  ///    2: 'D3: 12.5–25.0 Hz', 3: 'A3: 0.0–12.5 Hz'}
  static Map<int, String> bandFrequencyLabels(
    int sampleRate,
    int windowSize, {
    int levels = 3,
  }) {
    final double nyquist = sampleRate / 2.0;
    final int maxLevels =
        windowSize > 1 ? (log(windowSize) / ln2).floor() : 1;
    final int actualLevels = levels.clamp(1, maxLevels);

    final Map<int, String> labels = {};
    for (int l = 0; l < actualLevels; l++) {
      final double fHigh = nyquist / pow(2, l);
      final double fLow = nyquist / pow(2, l + 1);
      labels[l] =
          'D${l + 1}: ${fLow.toStringAsFixed(1)}–${fHigh.toStringAsFixed(1)} Hz';
    }
    // Approximation band
    final double approxHigh = nyquist / pow(2, actualLevels);
    labels[actualLevels] =
        'A$actualLevels: 0.0–${approxHigh.toStringAsFixed(1)} Hz';

    return labels;
  }

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
      final thr =
          sigmaSignal > 1e-10 ? (sigma * sigma) / sigmaSignal : sigma * 100.0;

      // Apply soft thresholding with this level's threshold
      final thresholdedDetail =
          detail.map((v) => _softThreshold(v, thr)).toList();
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
      final int numWindows = (detail.length - windowSize) ~/ stride + 1;
      final double meanWindowEnergy =
          numWindows > 0 ? totalEnergy / numWindows : 0.0;

      double runningSum = 0.0;
      int runningCount = 0;

      for (int start = 0;
          start + windowSize <= detail.length;
          start += stride) {
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
    final String approxLabel =
        'A${result.levels}: 0.0-${approxHigh.toStringAsFixed(1)} Hz';
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
