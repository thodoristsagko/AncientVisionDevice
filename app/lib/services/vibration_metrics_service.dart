import 'dart:math';

/// Accumulated vibration metrics for a monitoring session.
///
/// Tracks running totals of Arias Intensity, Cumulative Absolute Velocity,
/// Palmgren-Miner damage index, and Housner Spectral Intensity. Call
/// [updateWithSample] for each new acceleration sample, or [updateWithWindow]
/// for a buffered window. Call [resetSession] to start a new monitoring period.
class VibrationMetrics {
  /// Arias Intensity in m/s. Cumulative energy measure of ground motion.
  double ariasIntensity = 0;

  /// Cumulative Absolute Velocity in g-s. EPRI threshold: 0.16 g-s.
  double cav = 0;

  /// Palmgren-Miner cumulative damage index. D >= 1.0 => theoretical failure.
  double damageIndex = 0;

  /// Housner Spectral Intensity (most recent window), in mm/s-s.
  double housnerSI = 0;

  /// Update running metrics with a single acceleration sample.
  ///
  /// [accelG] is acceleration in units of g. [dt] is the time step in seconds
  /// (i.e. 1 / sampleRate).
  void updateWithSample(double accelG, double dt) {
    // Arias Intensity: Ia += (pi / (2g)) * a^2 * dt
    ariasIntensity += (pi / (2 * 9.81)) * accelG * accelG * dt;

    // CAV: integral of |a(t)| dt
    cav += accelG.abs() * dt;
  }

  /// Update metrics from a complete acceleration window.
  ///
  /// Also updates the damage index based on the window's PPV and dominant
  /// frequency, and computes Housner SI if FFT data is provided.
  void updateWithWindow(
    List<double> accelG,
    double sampleRate, {
    double? ppv,
    double? dominantFreq,
    List<double>? fftMagnitudes,
    List<double>? frequencies,
  }) {
    if (accelG.isEmpty) return;

    final dt = 1.0 / sampleRate;

    for (final a in accelG) {
      updateWithSample(a, dt);
    }

    // Update damage index if PPV is provided
    if (ppv != null && dominantFreq != null) {
      final duration = accelG.length / sampleRate;
      damageIndex = VibrationMetricsService.updateDamageIndex(
        damageIndex,
        ppv,
        duration,
        dominantFreq,
      );
    }

    // Update Housner SI if FFT data is provided
    if (fftMagnitudes != null && frequencies != null) {
      housnerSI = VibrationMetricsService.computeHousnerSI(
        fftMagnitudes,
        frequencies,
      );
    }
  }

  /// Reset all accumulated metrics to zero for a new monitoring session.
  void resetSession() {
    ariasIntensity = 0;
    cav = 0;
    damageIndex = 0;
    housnerSI = 0;
  }

  /// Serialize current metrics to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'ariasIntensity': ariasIntensity,
        'cav': cav,
        'damageIndex': damageIndex,
        'housnerSI': housnerSI,
        'cavExceedsEPRI': cav > 0.16,
        'damageStatus': damageIndex < 0.5
            ? 'safe'
            : damageIndex < 1.0
                ? 'warning'
                : 'critical',
      };
}

/// Vibration standard identifier for multi-standard classification.
enum VibrationStandard { din4150, bs7385, fhwa, sn640312a }

/// Result of classifying a PPV measurement against a single standard.
class StandardClassification {
  final VibrationStandard standard;

  /// One of 'safe', 'warning', 'critical'.
  final String level;

  /// The applicable PPV limit in mm/s for the given frequency.
  final double limit;

  /// Human-readable description of the standard and its verdict.
  final String description;

  const StandardClassification({
    required this.standard,
    required this.level,
    required this.limit,
    required this.description,
  });

  @override
  String toString() =>
      'StandardClassification($standard, $level, limit=${limit}mm/s)';
}

// ---------------------------------------------------------------------------
// Thresholds used for exceedance tracking
// ---------------------------------------------------------------------------

/// PPV threshold for exceedance tracking (mm/s). Uses FHWA ruins/ancient
/// monuments limit — the strictest applicable to archaeological sites.
const double _kPpvThreshold = 2.0;

/// RMS acceleration threshold for exceedance tracking (g).
const double _kRmsThreshold = 0.05;

/// STA/LTA ratio threshold for exceedance tracking (dimensionless).
const double _kStaLtaThreshold = 3.0;

/// Pure-Dart computations for advanced vibration analysis.
///
/// All methods are static and have no Flutter dependencies so they can run
/// in an isolate or in unit tests without a widget binding.
///
/// In addition to the static analysis helpers, this class maintains a small
/// stateful layer that is used by the live monitoring path:
///
/// - **Trending** — 10-sample rolling average per metric; [trends] returns
///   "up", "down", or "stable" based on whether the current value has changed
///   by more than 5 % relative to that average.
/// - **PPV trend slope** — [ppvTrend] is the least-squares slope of PPV over
///   the last 20 samples (mm/s per second). Positive = increasing.
/// - **Sustained exceedance** — [exceedanceDurations] tracks how long each
///   metric has *continuously* exceeded its threshold.
/// - **Rate of change** — [ppvRateOfChange] is the least-squares slope of PPV
///   over the last 10 samples (mm/s per second).
/// - **Session statistics** — [sessionStats] map with min/max/mean/std/total;
///   also [sessionPeakPpv], [sessionMeanPpv], [exceedanceCount]; reset with
///   [resetSession] / [resetSessionStats].
/// - **Peak detection** — [latestPeak] is the most recently detected local
///   maximum in the PPV time series.
/// - **Export summary** — [summary] bundles all key metrics into one map.
///
/// Call [recordSample] once per incoming BLE/DSP update to advance the
/// stateful layer.
class VibrationMetricsService {
  // ---------------------------------------------------------------------------
  // Stateful monitoring layer
  // ---------------------------------------------------------------------------

  // Rolling window size for trend and rate-of-change computations.
  static const int _kWindowSize = 10;

  // Window size for the dedicated PPV trend buffer (linear regression slope).
  static const int _kTrendWindowSize = 20;

  // Per-metric circular history buffers (capacity = _kWindowSize).
  final List<double> _ppvHistory = [];
  final List<double> _rmsHistory = [];
  final List<double> _staLtaHistory = [];

  // Timestamps (seconds since epoch, fractional) corresponding to each PPV
  // sample in _ppvHistory. Used for slope computation.
  final List<double> _ppvTimestamps = [];

  // 20-sample PPV trend buffer (with matching timestamps) for [ppvTrend].
  final List<double> _ppvTrendHistory = [];
  final List<double> _ppvTrendTimestamps = [];

  // Exceedance-start timestamps; null means metric is currently within limits.
  DateTime? _ppvExceedanceStart;
  DateTime? _rmsExceedanceStart;
  DateTime? _staLtaExceedanceStart;

  // Session statistics.
  double _sessionPeakPpv = 0;
  double _sessionMinPpv = double.infinity;
  double _sessionSumPpv = 0;
  double _sessionSumSqPpv = 0; // for std_ppv computation
  int _sessionSampleCount = 0;
  int _exceedanceCount = 0;
  bool _ppvWasExceeded = false; // edge detector for exceedanceCount

  // Most recently detected local-maximum PPV value (peak detection).
  double? _latestPeak;

  // ---------------------------------------------------------------------------
  // Public API — stateful layer
  // ---------------------------------------------------------------------------

  /// Record a new monitoring sample to advance all stateful computations.
  ///
  /// [ppv] is Peak Particle Velocity in mm/s. [rms] is RMS acceleration in g.
  /// [staLta] is the STA/LTA ratio (dimensionless). [timestamp] defaults to
  /// [DateTime.now] and is used for slope and exceedance-duration computations.
  void recordSample({
    required double ppv,
    double rms = 0,
    double staLta = 0,
    DateTime? timestamp,
  }) {
    final now = timestamp ?? DateTime.now();
    final nowSec = now.millisecondsSinceEpoch / 1000.0;

    // --- Rolling history ---
    _addToWindow(_ppvHistory, ppv);
    _addToWindow(_rmsHistory, rms);
    _addToWindow(_staLtaHistory, staLta);
    _addToWindow(_ppvTimestamps, nowSec);

    // --- 20-sample PPV trend buffer ---
    _ppvTrendHistory.add(ppv);
    _ppvTrendTimestamps.add(nowSec);
    if (_ppvTrendHistory.length > _kTrendWindowSize) {
      _ppvTrendHistory.removeAt(0);
      _ppvTrendTimestamps.removeAt(0);
    }

    // --- Session statistics ---
    if (ppv > _sessionPeakPpv) _sessionPeakPpv = ppv;
    if (ppv < _sessionMinPpv) _sessionMinPpv = ppv;
    _sessionSumPpv += ppv;
    _sessionSumSqPpv += ppv * ppv;
    _sessionSampleCount++;

    // --- Local maximum (peak) detection ---
    // A value is a peak if it exceeds both its predecessor and the new value.
    // We detect peaks one step late (when current < prev and prev > preprev).
    if (_ppvHistory.length >= 3) {
      final prev2 = _ppvHistory[_ppvHistory.length - 3];
      final prevVal = _ppvHistory[_ppvHistory.length - 2];
      final currVal = _ppvHistory[_ppvHistory.length - 1];
      if (prevVal > prev2 && prevVal > currVal) {
        _latestPeak = prevVal;
      }
    }
    // PPV exceedance edge detection (count each new exceedance episode).
    final ppvExceeded = ppv >= _kPpvThreshold;
    if (ppvExceeded && !_ppvWasExceeded) _exceedanceCount++;
    _ppvWasExceeded = ppvExceeded;

    // --- Sustained exceedance start/clear ---
    _updateExceedanceStart(
      exceeded: ppvExceeded,
      startRef: _ppvExceedanceStart,
      onSet: (t) => _ppvExceedanceStart = t,
      onClear: () => _ppvExceedanceStart = null,
    );
    _updateExceedanceStart(
      exceeded: rms >= _kRmsThreshold,
      startRef: _rmsExceedanceStart,
      onSet: (t) => _rmsExceedanceStart = t,
      onClear: () => _rmsExceedanceStart = null,
    );
    _updateExceedanceStart(
      exceeded: staLta >= _kStaLtaThreshold,
      startRef: _staLtaExceedanceStart,
      onSet: (t) => _staLtaExceedanceStart = t,
      onClear: () => _staLtaExceedanceStart = null,
    );
  }

  /// Trend direction for each metric relative to its 10-sample rolling mean.
  ///
  /// Returns a map with keys "ppv", "rms", "staLta". Each value is one of:
  /// - "up"     — current value is more than 5 % above the rolling mean.
  /// - "down"   — current value is more than 5 % below the rolling mean.
  /// - "stable" — within ±5 % of the rolling mean, or fewer than 2 samples.
  Map<String, String> get trends => {
        'ppv': _trend(_ppvHistory),
        'rms': _trend(_rmsHistory),
        'staLta': _trend(_staLtaHistory),
      };

  /// How long each metric has *continuously* exceeded its threshold.
  ///
  /// Returns a map with keys "ppv", "rms", "staLta". Duration is [Duration.zero]
  /// when the metric is currently within its threshold.
  Map<String, Duration> get exceedanceDurations {
    final now = DateTime.now();
    return {
      'ppv': _exceedanceDuration(_ppvExceedanceStart, now),
      'rms': _exceedanceDuration(_rmsExceedanceStart, now),
      'staLta': _exceedanceDuration(_staLtaExceedanceStart, now),
    };
  }

  /// Least-squares slope of PPV over the last 10 samples in mm/s per second.
  ///
  /// Positive means PPV is increasing; negative means decreasing.
  /// Returns 0.0 if fewer than 2 samples have been recorded.
  double get ppvRateOfChange {
    if (_ppvHistory.length < 2) return 0.0;
    return _leastSquaresSlope(_ppvTimestamps, _ppvHistory);
  }

  /// Least-squares slope of PPV over the last 20 samples in mm/s per second.
  ///
  /// Uses a larger window than [ppvRateOfChange] to capture slower trends.
  /// Positive = PPV is trending upward; negative = trending downward.
  /// Returns 0.0 if fewer than 2 samples have been recorded.
  double get ppvTrend {
    if (_ppvTrendHistory.length < 2) return 0.0;
    return _leastSquaresSlope(_ppvTrendTimestamps, _ppvTrendHistory);
  }

  // --- Session statistics ---

  /// Maximum PPV seen since the last [resetSessionStats] call, in mm/s.
  double get sessionPeakPpv => _sessionPeakPpv;

  /// Rolling mean of all PPV samples since the last [resetSessionStats] call.
  double get sessionMeanPpv =>
      _sessionSampleCount == 0 ? 0.0 : _sessionSumPpv / _sessionSampleCount;

  /// Number of times PPV has crossed above [_kPpvThreshold] (rising edge only)
  /// since the last [resetSessionStats] call.
  int get exceedanceCount => _exceedanceCount;

  /// Comprehensive session statistics as a map.
  ///
  /// Keys:
  /// - `min_ppv`      — minimum PPV recorded in this session (mm/s).
  /// - `max_ppv`      — maximum PPV recorded in this session (mm/s).
  /// - `mean_ppv`     — arithmetic mean PPV (mm/s).
  /// - `std_ppv`      — sample standard deviation of PPV (mm/s).
  /// - `total_readings` — total number of [recordSample] calls this session.
  ///
  /// All values are 0.0 if no samples have been recorded yet.
  Map<String, double> get sessionStats {
    if (_sessionSampleCount == 0) {
      return {
        'min_ppv': 0.0,
        'max_ppv': 0.0,
        'mean_ppv': 0.0,
        'std_ppv': 0.0,
        'total_readings': 0.0,
      };
    }
    final mean = _sessionSumPpv / _sessionSampleCount;
    // Sample variance: (sum(x^2) - n*mean^2) / (n-1)
    double variance = 0.0;
    if (_sessionSampleCount > 1) {
      variance = (_sessionSumSqPpv - _sessionSampleCount * mean * mean) /
          (_sessionSampleCount - 1);
      if (variance < 0.0) variance = 0.0; // guard floating-point rounding
    }
    return {
      'min_ppv': _sessionMinPpv.isInfinite ? 0.0 : _sessionMinPpv,
      'max_ppv': _sessionPeakPpv,
      'mean_ppv': mean,
      'std_ppv': sqrt(variance),
      'total_readings': _sessionSampleCount.toDouble(),
    };
  }

  /// The most recently detected local maximum (peak) PPV value in mm/s.
  ///
  /// A value is considered a peak if it exceeds both its predecessor and the
  /// subsequent sample in the rolling PPV history. Returns null until at least
  /// one peak has been detected since the last [resetSessionStats] call.
  double? get latestPeak => _latestPeak;

  /// Reset session statistics (peak, min, mean, std, exceedance count, peak
  /// detection state).
  ///
  /// Does NOT clear the rolling history windows used for trending and slope.
  /// Alias: [resetSession] delegates to this method.
  void resetSessionStats() {
    _sessionPeakPpv = 0;
    _sessionMinPpv = double.infinity;
    _sessionSumPpv = 0;
    _sessionSumSqPpv = 0;
    _sessionSampleCount = 0;
    _exceedanceCount = 0;
    _ppvWasExceeded = false;
    _latestPeak = null;
  }

  /// Reset session statistics. Delegates to [resetSessionStats].
  ///
  /// Provided as a convenience alias so callers do not need to know which
  /// reset method to call.
  void resetSession() => resetSessionStats();

  /// Export all key metrics as a JSON-compatible map for logging or upload.
  ///
  /// Includes trending, exceedance durations (in seconds), rate of change, and
  /// session statistics.
  Map<String, dynamic> get summary {
    final exc = exceedanceDurations;
    final tr = trends;
    final stats = sessionStats;
    return {
      'ppv': _ppvHistory.isNotEmpty ? _ppvHistory.last : 0.0,
      'rms': _rmsHistory.isNotEmpty ? _rmsHistory.last : 0.0,
      'staLta': _staLtaHistory.isNotEmpty ? _staLtaHistory.last : 0.0,
      'ppvTrend': tr['ppv'],
      'rmsTrend': tr['rms'],
      'staLtaTrend': tr['staLta'],
      'ppvTrendSlope': ppvTrend,
      'ppvExceedanceSec': exc['ppv']!.inSeconds,
      'rmsExceedanceSec': exc['rms']!.inSeconds,
      'staLtaExceedanceSec': exc['staLta']!.inSeconds,
      'ppvRateOfChange': ppvRateOfChange,
      'sessionPeakPpv': _sessionPeakPpv,
      'sessionMinPpv': stats['min_ppv'],
      'sessionMeanPpv': stats['mean_ppv'],
      'sessionStdPpv': stats['std_ppv'],
      'latestPeak': _latestPeak,
      'exceedanceCount': _exceedanceCount,
      'sampleCount': _sessionSampleCount,
      'ppvThreshold': _kPpvThreshold,
      'rmsThreshold': _kRmsThreshold,
      'staLtaThreshold': _kStaLtaThreshold,
    };
  }

  // ---------------------------------------------------------------------------
  // Internal helpers — stateful layer
  // ---------------------------------------------------------------------------

  static void _addToWindow(List<double> buf, double value) {
    buf.add(value);
    if (buf.length > _kWindowSize) buf.removeAt(0);
  }

  static String _trend(List<double> buf) {
    if (buf.length < 2) return 'stable';
    final current = buf.last;
    // Rolling mean excluding the current sample to measure change against.
    final history = buf.sublist(0, buf.length - 1);
    final mean = history.fold(0.0, (s, v) => s + v) / history.length;
    if (mean == 0) return 'stable';
    final delta = (current - mean) / mean;
    if (delta > 0.05) return 'up';
    if (delta < -0.05) return 'down';
    return 'stable';
  }

  static Duration _exceedanceDuration(DateTime? start, DateTime now) {
    if (start == null) return Duration.zero;
    return now.difference(start);
  }

  static void _updateExceedanceStart({
    required bool exceeded,
    required DateTime? startRef,
    required void Function(DateTime) onSet,
    required void Function() onClear,
  }) {
    if (exceeded) {
      if (startRef == null) onSet(DateTime.now());
    } else {
      onClear();
    }
  }

  /// Ordinary least-squares slope: dy/dx.
  static double _leastSquaresSlope(List<double> xs, List<double> ys) {
    assert(xs.length == ys.length);
    final n = xs.length;
    if (n < 2) return 0.0;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (int i = 0; i < n; i++) {
      sumX += xs[i];
      sumY += ys[i];
      sumXY += xs[i] * ys[i];
      sumX2 += xs[i] * xs[i];
    }
    final denom = n * sumX2 - sumX * sumX;
    if (denom.abs() < 1e-30) return 0.0;
    return (n * sumXY - sumX * sumY) / denom;
  }

  // ---------------------------------------------------------------------------
  // Arias Intensity
  // ---------------------------------------------------------------------------

  /// Compute Arias Intensity for a complete acceleration time series.
  ///
  /// Returns Ia in m/s. [accelG] values are in units of g.
  static double computeAriasIntensity(List<double> accelG, double sampleRate) {
    if (accelG.isEmpty) return 0;
    final dt = 1.0 / sampleRate;
    const scale = pi / (2 * 9.81);
    double ia = 0;
    for (final a in accelG) {
      ia += scale * a * a * dt;
    }
    return ia;
  }

  // ---------------------------------------------------------------------------
  // Cumulative Absolute Velocity
  // ---------------------------------------------------------------------------

  /// Compute CAV for a complete acceleration time series.
  ///
  /// Returns CAV in g-s. EPRI damage threshold is 0.16 g-s.
  static double computeCAV(List<double> accelG, double sampleRate) {
    if (accelG.isEmpty) return 0;
    final dt = 1.0 / sampleRate;
    double cav = 0;
    for (final a in accelG) {
      cav += a.abs() * dt;
    }
    return cav;
  }

  // ---------------------------------------------------------------------------
  // Housner Spectral Intensity (simplified)
  // ---------------------------------------------------------------------------

  /// Compute a simplified Housner Spectral Intensity from FFT output.
  ///
  /// The true Housner SI integrates the pseudo-velocity response spectrum
  /// (5% damping) from T = 0.1 s to T = 2.5 s. Here we approximate PSV
  /// from the FFT magnitudes using the relation PSV(T) ~ (2*pi/T) * SD(T)
  /// where SD is approximated from the displacement spectrum (FFT magnitude
  /// divided by omega^2). We integrate over the corresponding frequency
  /// range (0.4 Hz to 10 Hz) using the trapezoidal rule.
  ///
  /// Returns SI in mm/s-s (velocity dimension times period dimension).
  static double computeHousnerSI(
    List<double> fftMagnitudes,
    List<double> frequencies,
  ) {
    if (fftMagnitudes.isEmpty || frequencies.isEmpty) return 0;
    if (fftMagnitudes.length != frequencies.length) return 0;

    // Integration limits in frequency: f = 1/T
    // T = 0.1s => f = 10 Hz, T = 2.5s => f = 0.4 Hz
    const fLow = 0.4;
    const fHigh = 10.0;

    // Collect (period, PSV) pairs within range, sorted by period.
    final List<double> periods = [];
    final List<double> psvValues = [];

    for (int i = 0; i < frequencies.length; i++) {
      final f = frequencies[i];
      if (f < fLow || f > fHigh) continue;

      final omega = 2 * pi * f;
      // Approximate spectral displacement from FFT magnitude / omega^2
      // Then PSV = omega * SD = magnitude / omega
      final psv = fftMagnitudes[i] / omega;
      final period = 1.0 / f;
      periods.add(period);
      psvValues.add(psv);
    }

    if (periods.length < 2) {
      // Not enough frequency bins in range; return single-point estimate
      if (periods.length == 1) return psvValues[0] * (2.5 - 0.1);
      return 0;
    }

    // Sort by ascending period for trapezoidal integration
    final indices = List<int>.generate(periods.length, (i) => i);
    indices.sort((a, b) => periods[a].compareTo(periods[b]));

    double si = 0;
    for (int k = 1; k < indices.length; k++) {
      final dt = periods[indices[k]] - periods[indices[k - 1]];
      final avgPsv = (psvValues[indices[k]] + psvValues[indices[k - 1]]) / 2;
      si += avgPsv * dt;
    }

    return si.abs();
  }

  // ---------------------------------------------------------------------------
  // Spectral Kurtosis
  // ---------------------------------------------------------------------------

  /// Compute spectral kurtosis using short-time Fourier transform (STFT).
  ///
  /// Returns a list of SK values, one per frequency bin (windowSize / 2 + 1).
  /// For Gaussian noise SK ~ 0; positive values indicate impulsive content.
  ///
  /// [windowSize] is the FFT window length. [hopSize] is the stride between
  /// successive windows.
  static List<double> computeSpectralKurtosis(
    List<double> signal, {
    int windowSize = 64,
    int hopSize = 32,
    double sampleRate = 200.0,
  }) {
    if (signal.length < windowSize) {
      return List.filled(windowSize ~/ 2 + 1, 0);
    }

    final nBins = windowSize ~/ 2 + 1;
    // Accumulate <|X|^2> and <|X|^4> across windows
    final sumMag2 = List<double>.filled(nBins, 0);
    final sumMag4 = List<double>.filled(nBins, 0);
    int windowCount = 0;

    for (int start = 0; start + windowSize <= signal.length; start += hopSize) {
      final window = signal.sublist(start, start + windowSize);
      final fftResult = _realFFT(window);

      for (int k = 0; k < nBins; k++) {
        final mag2 = fftResult[k] * fftResult[k]; // |X|^2
        sumMag2[k] += mag2;
        sumMag4[k] += mag2 * mag2; // |X|^4
      }
      windowCount++;
    }

    if (windowCount == 0) return List.filled(nBins, 0);

    // SK(f) = <|X|^4> / <|X|^2>^2 - 2
    final sk = List.filled(nBins, 0.0);
    for (int k = 0; k < nBins; k++) {
      final mean2 = sumMag2[k] / windowCount;
      final mean4 = sumMag4[k] / windowCount;
      if (mean2 > 1e-30) {
        sk[k] = mean4 / (mean2 * mean2) - 2;
      }
    }

    return sk;
  }

  // ---------------------------------------------------------------------------
  // Zero-Crossing Rate
  // ---------------------------------------------------------------------------

  /// Compute zero-crossing rate of a signal.
  ///
  /// ZCR = (1 / 2N) * sum(|sign(x[n]) - sign(x[n-1])|)
  ///
  /// For a sine wave at frequency f sampled at rate fs, ZCR ~ f / fs,
  /// so estimated frequency = ZCR * sampleRate.
  static double computeZeroCrossingRate(List<double> signal) {
    if (signal.length < 2) return 0;
    int crossings = 0;
    for (int i = 1; i < signal.length; i++) {
      if ((signal[i] >= 0 && signal[i - 1] < 0) ||
          (signal[i] < 0 && signal[i - 1] >= 0)) {
        crossings++;
      }
    }
    // ZCR = crossings / (2 * N) where each crossing contributes 2 to the
    // |sign| difference sum, so we count actual crossings and divide by N.
    // Frequency estimate: crossings / (2 * (N-1)) * sampleRate
    // But the formula given uses 2N in denominator with |sign diff| = 0 or 2,
    // which simplifies to crossings / N.
    return crossings / signal.length;
  }

  // ---------------------------------------------------------------------------
  // Multi-Standard Classification
  // ---------------------------------------------------------------------------

  /// Classify a PPV reading against all supported international standards.
  ///
  /// [ppv] is Peak Particle Velocity in mm/s. [dominantFreq] is the dominant
  /// vibration frequency in Hz.
  static List<StandardClassification> classifyAllStandards(
    double ppv,
    double dominantFreq,
  ) {
    return [
      _classifyDIN4150(ppv, dominantFreq),
      _classifyBS7385(ppv, dominantFreq),
      _classifyFHWA(ppv, dominantFreq),
      _classifySN640312a(ppv, dominantFreq),
    ];
  }

  /// DIN 4150-3 heritage limits.
  static StandardClassification _classifyDIN4150(double ppv, double freq) {
    double limit;
    if (freq <= 10) {
      limit = 3.0;
    } else if (freq <= 50) {
      // Linear interpolation from 3.0 at 10 Hz to 8.0 at 50 Hz
      limit = 3.0 + (freq - 10) / (50 - 10) * (8.0 - 3.0);
    } else {
      // Linear interpolation from 8.0 at 50 Hz to 10.0 at 100 Hz
      limit = 8.0 + (freq - 50) / (100 - 50) * (10.0 - 8.0);
    }

    // Also check continuous limit of 2.5 mm/s
    const continuousLimit = 2.5;
    final effectiveLimit = min(limit, continuousLimit);
    final level = ppv >= effectiveLimit
        ? 'critical'
        : ppv >= effectiveLimit * 0.7
            ? 'warning'
            : 'safe';

    return StandardClassification(
      standard: VibrationStandard.din4150,
      level: level,
      limit: effectiveLimit,
      description:
          'DIN 4150-3 heritage: ${effectiveLimit.toStringAsFixed(1)} mm/s '
          '@ ${freq.toStringAsFixed(0)} Hz '
          '(continuous limit: $continuousLimit mm/s)',
    );
  }

  /// BS 7385-2 heritage limits.
  static StandardClassification _classifyBS7385(double ppv, double freq) {
    double limit;
    if (freq <= 10) {
      limit = 6.0;
    } else if (freq <= 50) {
      limit = 6.0 + (freq - 10) / (50 - 10) * (12.0 - 6.0);
    } else {
      limit = 12.0 + (freq - 50) / (100 - 50) * (15.0 - 12.0);
    }

    final level = ppv >= limit
        ? 'critical'
        : ppv >= limit * 0.7
            ? 'warning'
            : 'safe';

    return StandardClassification(
      standard: VibrationStandard.bs7385,
      level: level,
      limit: limit,
      description:
          'BS 7385-2 heritage: ${limit.toStringAsFixed(1)} mm/s '
          '@ ${freq.toStringAsFixed(0)} Hz',
    );
  }

  /// FHWA heritage/ruins limits (flat 2.0 mm/s across all frequencies).
  static StandardClassification _classifyFHWA(double ppv, double freq) {
    const limit = 2.0;
    final level = ppv >= limit
        ? 'critical'
        : ppv >= limit * 0.7
            ? 'warning'
            : 'safe';

    return StandardClassification(
      standard: VibrationStandard.fhwa,
      level: level,
      limit: limit,
      description: 'FHWA ruins/ancient monuments: $limit mm/s (all freq)',
    );
  }

  /// Swiss SN 640 312a heritage limits.
  static StandardClassification _classifySN640312a(double ppv, double freq) {
    double limit;
    if (freq <= 10) {
      limit = 3.0;
    } else if (freq <= 50) {
      limit = 3.0 + (freq - 10) / (50 - 10) * (8.0 - 3.0);
    } else {
      limit = 8.0;
    }

    const continuousLimit = 2.5;
    final effectiveLimit = min(limit, continuousLimit);
    final level = ppv >= effectiveLimit
        ? 'critical'
        : ppv >= effectiveLimit * 0.7
            ? 'warning'
            : 'safe';

    return StandardClassification(
      standard: VibrationStandard.sn640312a,
      level: level,
      limit: effectiveLimit,
      description:
          'SN 640 312a heritage: ${limit.toStringAsFixed(1)} mm/s '
          '@ ${freq.toStringAsFixed(0)} Hz '
          '(continuous limit: $continuousLimit mm/s)',
    );
  }

  // ---------------------------------------------------------------------------
  // Palmgren-Miner Damage Index
  // ---------------------------------------------------------------------------

  /// Update cumulative damage index based on PPV exposure.
  ///
  /// Uses DIN 4150-3 heritage limit at [dominantFreq] as the reference fatigue
  /// life Ni. The damage increment is proportional to (ppv / limit)^2 * duration,
  /// applying a quadratic stress-life relationship typical of fatigue analysis.
  ///
  /// [currentIndex] is the existing accumulated damage.
  /// [ppv] is in mm/s, [duration] in seconds, [dominantFreq] in Hz.
  /// Returns the updated damage index.
  static double updateDamageIndex(
    double currentIndex,
    double ppv,
    double duration,
    double dominantFreq,
  ) {
    // Get DIN 4150-3 limit as reference fatigue life
    final classification = _classifyDIN4150(ppv, dominantFreq);
    final limit = classification.limit;

    if (limit <= 0) return currentIndex;

    // Damage increment: (ppv / limit)^2 * duration / referenceTime
    // Reference time: 1 hour (3600s) of continuous exposure at limit = D of 1.0
    const referenceTime = 3600.0;
    final ratio = ppv / limit;
    final increment = ratio * ratio * duration / referenceTime;

    return currentIndex + increment;
  }

  // ---------------------------------------------------------------------------
  // Internal FFT helper
  // ---------------------------------------------------------------------------

  /// Compute magnitudes of a real-valued FFT using the Cooley-Tukey algorithm.
  ///
  /// Input length is zero-padded to the next power of 2 if needed.
  /// Returns magnitudes for bins 0 .. N/2 (N/2 + 1 values).
  static List<double> _realFFT(List<double> input) {
    // Zero-pad to next power of 2
    int n = 1;
    while (n < input.length) {
      n <<= 1;
    }

    // Separate real and imaginary parts
    final re = List<double>.filled(n, 0);
    final im = List<double>.filled(n, 0);
    for (int i = 0; i < input.length; i++) {
      re[i] = input[i];
    }

    // Bit-reversal permutation
    int j = 0;
    for (int i = 0; i < n; i++) {
      if (i < j) {
        final tmpR = re[i];
        re[i] = re[j];
        re[j] = tmpR;
        final tmpI = im[i];
        im[i] = im[j];
        im[j] = tmpI;
      }
      int m = n >> 1;
      while (m >= 1 && j >= m) {
        j -= m;
        m >>= 1;
      }
      j += m;
    }

    // Cooley-Tukey iterative FFT
    for (int size = 2; size <= n; size <<= 1) {
      final halfSize = size >> 1;
      final angle = -2.0 * pi / size;
      final wRe = cos(angle);
      final wIm = sin(angle);

      for (int start = 0; start < n; start += size) {
        double curRe = 1.0;
        double curIm = 0.0;

        for (int k = 0; k < halfSize; k++) {
          final evenIdx = start + k;
          final oddIdx = start + k + halfSize;

          final tRe = curRe * re[oddIdx] - curIm * im[oddIdx];
          final tIm = curRe * im[oddIdx] + curIm * re[oddIdx];

          re[oddIdx] = re[evenIdx] - tRe;
          im[oddIdx] = im[evenIdx] - tIm;
          re[evenIdx] = re[evenIdx] + tRe;
          im[evenIdx] = im[evenIdx] + tIm;

          final newRe = curRe * wRe - curIm * wIm;
          final newIm = curRe * wIm + curIm * wRe;
          curRe = newRe;
          curIm = newIm;
        }
      }
    }

    // Return magnitudes for positive frequencies
    final nBins = n ~/ 2 + 1;
    final mags = List<double>.filled(nBins, 0);
    for (int i = 0; i < nBins; i++) {
      mags[i] = sqrt(re[i] * re[i] + im[i] * im[i]);
    }
    return mags;
  }
}
