import 'dart:math';
import 'package:flutter/foundation.dart';
import '../utils/circular_buffer.dart';

/// Adaptive statistical anomaly detector using online learning + trend analysis.
///
/// Phase 1 (calibration, first 5 minutes): Learns baseline vibration profile
/// using Welford's online algorithm for numerically stable running mean/variance.
/// During this phase, falls back to rule-based scoring.
///
/// Phase 2 (detection): Scores new samples by TWO methods:
///   1. **Instantaneous**: multivariate z-score deviation from baseline
///      (for sudden large events — actual avalanches)
///   2. **Trend**: compares short-term (2 min) vs long-term (10 min) rolling
///      averages to detect slow drift in vibration patterns
///      (for micro-vibration precursors to avalanches)
///
/// The trend detector is the KEY innovation — soil avalanche precursors
/// manifest as gradual increases in low-frequency energy, rising kurtosis
/// (micro-cracks), and slowly climbing STA/LTA over minutes, NOT as
/// sudden spikes. A spike-only detector would miss precursors entirely.
///
/// Academic basis:
/// - Welford (1962) "Note on a Method for Calculating Corrected Sums of
///   Squares and Products" — Technometrics 4(3)
/// - Helmstetter & Garambois (2010) "Seismic monitoring of Séchilienne
///   rockslide" — precursor signals build over minutes to hours
/// - Fäh et al. (2012) "Microseismic activity analysis for stability
///   assessment of soil slopes" — low-frequency drift as instability indicator
class AdaptiveAnomalyService {
  // Feature names we track (must match extractFeatures output)
  static const List<String> _featureKeys = [
    'ppv', 'rms', 'crest', 'kurtosis', 'stalta', 'cav', 'freq',
  ];

  // Features most indicative of pre-avalanche drift
  // Higher weight = more important for trend scoring
  static const Map<String, double> _trendWeights = {
    'ppv': 0.15,
    'rms': 0.10,
    'crest': 0.05,
    'kurtosis': 0.20,   // micro-cracks cause rising kurtosis
    'stalta': 0.25,     // slow STA/LTA rise = key precursor
    'cav': 0.10,
    'freq': 0.15,       // frequency shift toward low band = instability
  };

  // Calibration config
  static const int _calibrationSamples = 150; // ~5 min at 0.5Hz BLE rate
  static const double _emaAlpha = 0.005; // Very slow adaptation — don't adapt away precursors

  // Instantaneous detection thresholds (in standard deviations)
  // Raised high — only trigger on genuinely large events
  static const double _thresholdLow = 3.0;   // > 3σ = unusual
  static const double _thresholdHigh = 5.0;  // > 5σ = anomaly

  // Trend detection config
  static const int _shortWindowSize = 60;    // ~2 min of samples at 0.5Hz
  static const int _longWindowSize = 300;    // ~10 min of samples
  static const double _trendThresholdLow = 1.5;  // Short-term 1.5σ above long-term
  static const double _trendThresholdHigh = 2.5; // Short-term 2.5σ above long-term

  // Sliding window feature matrix for precursor pattern detection
  // ~20 min at 0.5Hz BLE rate
  final _featureHistory = CircularBuffer<Map<String, double>>(600);

  // Per-feature running statistics (Welford's algorithm)
  final Map<String, _WelfordStats> _stats = {};

  // Post-calibration EMA baseline
  final Map<String, double> _emaMean = {};
  final Map<String, double> _emaVariance = {};

  // Rolling windows for trend detection
  final Map<String, CircularBuffer<double>> _shortWindow = {};
  final Map<String, CircularBuffer<double>> _longWindow = {};

  // CUSUM (Cumulative Sum) change point detection
  final Map<String, double> _cusumPositive = {};
  final Map<String, double> _cusumNegative = {};
  final Map<String, int> _changePointCount = {};

  // Fukuzono inverse velocity history for time-to-failure prediction
  final _inverseVelocityHistory = CircularBuffer<double>(120); // ~4 min at 0.5 Hz
  final _inverseVelocityTimes = CircularBuffer<double>(120);
  final Stopwatch _serviceStopwatch = Stopwatch();

  // Latest PSD slope from DSP (passed through for display)
  double? _lastPsdSlope;
  double? get lastPsdSlope => _lastPsdSlope;

  int _sampleCount = 0;
  bool _isCalibrated = false;

  // Dynamic thresholds computed after calibration (defaults from model config)
  double _dynamicThresholdLow = 1.195327;
  double _dynamicThresholdHigh = 1.788009;

  bool get isCalibrated => _isCalibrated;
  double get dynamicThresholdLow => _dynamicThresholdLow;
  double get dynamicThresholdHigh => _dynamicThresholdHigh;
  int get sampleCount => _sampleCount;
  int get calibrationTarget => _calibrationSamples;
  double get calibrationProgress => (_sampleCount / _calibrationSamples).clamp(0.0, 1.0);
  String get modeLabel => _isCalibrated ? 'Adaptive' : 'Calibrating (${(_sampleCount * 100 / _calibrationSamples).round()}%)';

  AdaptiveAnomalyService() {
    _serviceStopwatch.start();
    for (final key in _featureKeys) {
      _stats[key] = _WelfordStats();
      _shortWindow[key] = CircularBuffer<double>(_shortWindowSize);
      _longWindow[key] = CircularBuffer<double>(_longWindowSize);
      _cusumPositive[key] = 0.0;
      _cusumNegative[key] = 0.0;
      _changePointCount[key] = 0;
    }
  }

  /// Feed a new sample to update the baseline model.
  /// Call this for EVERY BLE packet received, even during detection phase.
  void updateBaseline(Map<String, double> features) {
    _sampleCount++;

    for (final key in _featureKeys) {
      final value = features[key] ?? 0.0;
      _stats[key]!.update(value);

      // Maintain rolling windows for trend detection
      _shortWindow[key]!.add(value);
      _longWindow[key]!.add(value);

      // CUSUM change point detection (only during calibrated phase)
      if (_isCalibrated) {
        final mean = _emaMean[key]!;
        final stdDev = sqrt(_emaVariance[key]!);
        final drift = 0.5 * stdDev; // allowable drift (half sigma)
        final threshold = 5.0 * stdDev; // detection threshold

        // Update CUSUM statistics
        final cusumPos = max(0.0, _cusumPositive[key]! + (value - mean - drift));
        final cusumNeg = max(0.0, _cusumNegative[key]! + (mean - drift - value));

        // Detect change point
        if (cusumPos > threshold || cusumNeg > threshold) {
          _changePointCount[key] = (_changePointCount[key] ?? 0) + 1;
          // Reset CUSUM after change point detected
          _cusumPositive[key] = 0.0;
          _cusumNegative[key] = 0.0;
          if (kDebugMode) {
            debugPrint('CUSUM change point detected in $key: '
                'cusumPos=${cusumPos.toStringAsFixed(3)} '
                'cusumNeg=${cusumNeg.toStringAsFixed(3)} '
                'count=${_changePointCount[key]}');
          }
        } else {
          _cusumPositive[key] = cusumPos;
          _cusumNegative[key] = cusumNeg;
        }
      }
    }

    // Transition from calibration to detection
    if (!_isCalibrated && _sampleCount >= _calibrationSamples) {
      _isCalibrated = true;
      // Initialize EMA with calibration statistics
      for (final key in _featureKeys) {
        _emaMean[key] = _stats[key]!.mean;
        _emaVariance[key] = _stats[key]!.variance;
      }

      // Compute adaptive thresholds from calibration data.
      // Use the mean of per-feature RMS z-scores as calibration baseline.
      // During calibration, z-scores track how spread the data is around zero
      // (Welford mean); a combined calibration score proxy is the average stdDev.
      // We compute a composite "calibration norm" = RMS of per-feature stdDevs,
      // then set 2-sigma and 4-sigma bands above the calibration mean (0).
      double sumVariance = 0.0;
      for (final key in _featureKeys) {
        sumVariance += _stats[key]!.variance;
      }
      final _calibStd = sqrt(sumVariance / _featureKeys.length);
      final _calibMean = 0.0; // z-score baseline is always 0
      _dynamicThresholdLow = _calibMean + 2.0 * _calibStd;
      _dynamicThresholdHigh = _calibMean + 4.0 * _calibStd;
      // Guard: never let dynamic thresholds fall below sensible minimums
      if (_dynamicThresholdLow < 0.1) _dynamicThresholdLow = 1.195327;
      if (_dynamicThresholdHigh < 0.2) _dynamicThresholdHigh = 1.788009;

      if (kDebugMode) {
        debugPrint('AdaptiveAnomalyService: Calibration complete after $_sampleCount samples');
        debugPrint('  Baseline: ${_featureKeys.map((k) => "$k: μ=${_emaMean[k]!.toStringAsFixed(3)} σ=${sqrt(_emaVariance[k]!).toStringAsFixed(3)}").join(", ")}');
        debugPrint('  Dynamic thresholds: low=${_dynamicThresholdLow.toStringAsFixed(4)} high=${_dynamicThresholdHigh.toStringAsFixed(4)}');
      }
    }

    _featureHistory.add(Map.of(features));

    // Update EMA baseline (very slow drift tracking)
    if (_isCalibrated) {
      for (final key in _featureKeys) {
        final value = features[key] ?? 0.0;
        final oldMean = _emaMean[key]!;
        _emaMean[key] = oldMean + _emaAlpha * (value - oldMean);
        final diff = value - _emaMean[key]!;
        _emaVariance[key] = _emaVariance[key]! + _emaAlpha * (diff * diff - _emaVariance[key]!);
        // Floor variance to prevent division by near-zero
        if (_emaVariance[key]! < 1e-20) _emaVariance[key] = 1e-20;
      }
    }
  }

  /// Score a sample for anomaly detection.
  /// Returns null if not yet calibrated (caller should use rule-based fallback).
  ///
  /// Uses the HIGHER of instantaneous score and trend score.
  /// This means:
  /// - A sudden massive event (actual avalanche) triggers via instantaneous
  /// - A slow buildup of micro-vibrations triggers via trend
  AdaptiveAnomalyResult? detect(Map<String, double> features) {
    if (!_isCalibrated) return null;

    // --- Instantaneous z-score detection ---
    double sumZSq = 0.0;
    int featureCount = 0;
    final Map<String, double> zScores = {};

    for (final key in _featureKeys) {
      final value = features[key] ?? 0.0;
      final mean = _emaMean[key]!;
      final stdDev = sqrt(_emaVariance[key]!);

      if (stdDev > 1e-12) {
        final z = (value - mean).abs() / stdDev;
        zScores[key] = z;
        sumZSq += z * z;
      } else {
        // Near-zero variance: no deviation possible, treat as z=0
        zScores[key] = 0.0;
      }
      featureCount++;
    }

    if (featureCount == 0) return null;

    final rmsZ = sqrt(sumZSq / featureCount);

    // Use adaptive (calibration-derived) thresholds if available, else static defaults
    final effectiveLow = _isCalibrated ? _dynamicThresholdLow : _thresholdLow;
    final effectiveHigh = _isCalibrated ? _dynamicThresholdHigh : _thresholdHigh;

    // Instantaneous classification
    double instantScore;
    if (rmsZ < effectiveLow) {
      instantScore = rmsZ / effectiveLow * 0.3; // 0-0.3 range for normal
    } else if (rmsZ < effectiveHigh) {
      instantScore = 0.3 + 0.4 * (rmsZ - effectiveLow) / (effectiveHigh - effectiveLow);
    } else {
      instantScore = min(1.0, 0.7 + 0.3 * (rmsZ - effectiveHigh) / effectiveHigh);
    }

    // --- Trend detection (short-term vs long-term) ---
    double trendScore = 0.0;
    String? trendFeature;
    double maxTrendZ = 0.0;

    // Only compute trend if we have enough long-window data
    if (_longWindow[_featureKeys.first]!.length >= _longWindowSize ~/ 2) {
      double weightedTrendSum = 0.0;
      double weightSum = 0.0;

      for (final key in _featureKeys) {
        final shortAvg = _windowMean(_shortWindow[key]!);
        final longAvg = _windowMean(_longWindow[key]!);
        final longStd = _windowStdDev(_longWindow[key]!, longAvg);

        if (longStd > 1e-8) {
          // How many σ is the short-term average ABOVE the long-term average?
          // Positive = rising trend, negative = falling trend
          // For precursors, we care about RISING trends in most features
          // but FALLING frequency (shift to lower frequencies = instability)
          double trendZ;
          if (key == 'freq') {
            // Frequency dropping = bad sign (shift to low-freq seismic band)
            trendZ = (longAvg - shortAvg) / longStd;
          } else {
            // Everything else rising = bad sign
            trendZ = (shortAvg - longAvg) / longStd;
          }

          // Only count positive trends (rising risk)
          if (trendZ > 0) {
            final weight = _trendWeights[key] ?? 0.1;
            weightedTrendSum += trendZ * weight;
            weightSum += weight;

            if (trendZ > maxTrendZ) {
              maxTrendZ = trendZ;
              trendFeature = key;
            }
          }
        }
      }

      if (weightSum > 0) {
        final weightedTrendZ = weightedTrendSum / weightSum;

        if (weightedTrendZ < _trendThresholdLow) {
          trendScore = weightedTrendZ / _trendThresholdLow * 0.3;
        } else if (weightedTrendZ < _trendThresholdHigh) {
          trendScore = 0.3 + 0.4 * (weightedTrendZ - _trendThresholdLow) /
              (_trendThresholdHigh - _trendThresholdLow);
        } else {
          trendScore = min(1.0, 0.7 + 0.3 * (weightedTrendZ - _trendThresholdHigh) /
              _trendThresholdHigh);
        }
      }
    }

    // --- Change point detection contribution ---
    // Count recent change points across all features (last 10 samples)
    double changePointScore = 0.0;
    int totalChangePoints = 0;
    for (final key in _featureKeys) {
      totalChangePoints += _changePointCount[key] ?? 0;
    }
    // Normalize: 0 change points = 0.0, 5+ change points = 0.5
    if (totalChangePoints > 0) {
      changePointScore = min(0.5, totalChangePoints / 10.0);
    }

    // --- Physics-informed precursor pattern detection ---
    double precursorScore = 0.0;
    String? precursorPattern;

    if (_featureHistory.length >= 300) { // Need ~10 min of data
      const windowSamples = 150; // ~5 min window

      final ppvDeriv = _computeDerivative('ppv', windowSamples);
      final freqDeriv = _computeDerivative('freq', windowSamples);
      final kurtDeriv = _computeDerivative('kurtosis', windowSamples);
      final staltaDeriv = _computeDerivative('stalta', windowSamples);
      final ppvAccel = _computeAcceleration('ppv', windowSamples);

      // Pattern A: Soil creep — slow PPV rise + frequency drop + kurtosis spikes
      // Physics: soil grains rearranging under load, friction decreasing
      double patternA = 0.0;
      if (ppvDeriv > 0 && freqDeriv < 0 && kurtDeriv > 0) {
        patternA = (ppvDeriv.abs() * 100).clamp(0.0, 1.0) * 0.3 +
                   (freqDeriv.abs() * 50).clamp(0.0, 1.0) * 0.4 +
                   (kurtDeriv.abs() * 20).clamp(0.0, 1.0) * 0.3;
      }

      // Pattern B: Crack propagation — intermittent kurtosis bursts + STA/LTA ratcheting
      // Physics: discrete crack events with increasing frequency
      double patternB = 0.0;
      if (kurtDeriv > 0 && staltaDeriv > 0) {
        patternB = (kurtDeriv.abs() * 30).clamp(0.0, 1.0) * 0.5 +
                   (staltaDeriv.abs() * 20).clamp(0.0, 1.0) * 0.5;
      }

      // Pattern C: Imminent failure — all features rising, frequency collapsed to <5Hz
      // Physics: large-scale mass movement beginning
      double patternC = 0.0;
      final recentFreq = _rangeAverage('freq', _featureHistory.length - 30, _featureHistory.length);
      if (ppvDeriv > 0 && kurtDeriv > 0 && staltaDeriv > 0 && recentFreq > 0 && recentFreq < 5.0) {
        patternC = min(1.0, ppvAccel.abs() * 500 + 0.5); // Accelerating = very bad
      }

      // Boost Pattern C with Fukuzono prediction
      final fukuzono = computeFukuzono();
      if (fukuzono != null && fukuzono.ttfSeconds < 600 && fukuzono.r2 > 0.7) {
        // Fukuzono predicts failure within 10 minutes with good fit
        patternC = max(patternC, 0.7 + 0.3 * (1.0 - fukuzono.ttfSeconds / 600.0));
      }

      // Take the max pattern match
      precursorScore = max(patternA, max(patternB, patternC));
      if (patternC >= patternA && patternC >= patternB && patternC > 0.3) {
        precursorPattern = 'imminent_failure';
      } else if (patternB >= patternA && patternB > 0.3) {
        precursorPattern = 'crack_propagation';
      } else if (patternA > 0.3) {
        precursorPattern = 'soil_creep';
      }

      // Cross-feature correlation bonus: kurtosis rising WHILE frequency dropping
      if (kurtDeriv > 0 && freqDeriv < 0) {
        precursorScore = min(1.0, precursorScore * 1.3); // 30% confidence bonus
      }

      if (precursorScore > 0.2) {
        if (kDebugMode) {
          debugPrint('Precursor: score=${precursorScore.toStringAsFixed(3)} '
              'pattern=$precursorPattern A=${patternA.toStringAsFixed(2)} '
              'B=${patternB.toStringAsFixed(2)} C=${patternC.toStringAsFixed(2)}');
        }
      }
    }

    // Final score = max of instantaneous, trend, precursor, and change point
    // This way EITHER a sudden event OR a slow buildup OR a physics pattern OR change points triggers
    final finalScore = max(instantScore, max(trendScore, max(precursorScore, changePointScore))).clamp(0.0, 1.0);
    final isTrendDriven = trendScore > instantScore && trendScore >= precursorScore;
    final isPrecursorDriven = precursorScore > instantScore && precursorScore > trendScore;

    // Classify
    AdaptiveAnomalyLevel level;
    if (finalScore < 0.35) {
      level = AdaptiveAnomalyLevel.normal;
    } else if (finalScore < 0.7) {
      level = AdaptiveAnomalyLevel.unusual;
    } else {
      level = AdaptiveAnomalyLevel.anomaly;
    }

    // Find dominant contributing feature
    String? dominantFeature;
    if (isTrendDriven && trendFeature != null) {
      dominantFeature = '$trendFeature (trend↑)';
    } else {
      double maxZ = 0;
      for (final entry in zScores.entries) {
        if (entry.value > maxZ) {
          maxZ = entry.value;
          dominantFeature = entry.key;
        }
      }
    }

    if (isPrecursorDriven && precursorPattern != null) {
      dominantFeature = 'precursor: $precursorPattern';
    }

    if (level != AdaptiveAnomalyLevel.normal) {
      if (kDebugMode) {
        debugPrint('AdaptiveAnomaly: ${level.name} score=${finalScore.toStringAsFixed(3)} '
            '${isPrecursorDriven ? "PRECURSOR($precursorPattern)" : isTrendDriven ? "TREND" : "INSTANT"} '
            'dominant=$dominantFeature '
            'instantZ=${rmsZ.toStringAsFixed(2)} trendScore=${trendScore.toStringAsFixed(3)} '
            'precursorScore=${precursorScore.toStringAsFixed(3)} '
            'changePointScore=${changePointScore.toStringAsFixed(3)} changePoints=$totalChangePoints');
      }
    }

    return AdaptiveAnomalyResult(
      score: finalScore,
      level: level,
      rmsZScore: rmsZ,
      featureZScores: zScores,
      dominantFeature: dominantFeature,
      isTrendDriven: isTrendDriven,
      trendScore: trendScore,
      isPrecursorDriven: isPrecursorDriven,
      precursorScore: precursorScore,
      precursorPattern: precursorPattern,
    );
  }

  /// Feed PSD slope from DSP service for passthrough to results.
  void updatePsdSlope(double slope) {
    _lastPsdSlope = slope;
  }

  /// Compute Fukuzono inverse velocity time-to-failure prediction.
  ///
  /// Based on Fukuzono (1985) — plots 1/velocity vs time; when the
  /// linear fit extrapolates to zero, that's the predicted failure time.
  /// Returns null if insufficient data or no accelerating trend.
  ///
  /// Academic basis:
  /// - Fukuzono (1985) "A new method for predicting the failure time of a slope"
  /// - Voight (1989) "A relation to describe rate-dependent material failure"
  FukuzonoResult? computeFukuzono() {
    if (_featureHistory.length < 3) return null;

    final now = _serviceStopwatch.elapsedMilliseconds / 1000.0;

    // Compute pseudo-velocity as PPV derivative (change rate).
    // NOTE: This is a heuristic proxy for displacement rate, not true
    // Fukuzono inverse velocity. True Fukuzono requires direct displacement
    // measurements (extensometer/inclinometer). We use PPV trend rate as a
    // surrogate — valid for relative comparison, not absolute TTF values.
    final pseudoVelocity = _computeDerivative('ppv', min(150, _featureHistory.length - 1).toInt());
    if (pseudoVelocity.abs() < 1e-8) return null; // No significant velocity

    // Use pseudoVelocity as velocity proxy; compute inverse velocity
    final velocity = pseudoVelocity.abs();
    if (velocity < 1e-6) return null;

    final invV = 1.0 / velocity;
    _inverseVelocityHistory.add(invV);
    _inverseVelocityTimes.add(now);

    // Need at least 20 points for meaningful regression
    if (_inverseVelocityHistory.length < 20) return null;

    // Linear regression: 1/v = a + b*t
    final times = _inverseVelocityTimes.toList();
    final invVels = _inverseVelocityHistory.toList();
    final n = times.length;

    double sumT = 0, sumIV = 0, sumTT = 0, sumTIV = 0;
    for (int i = 0; i < n; i++) {
      sumT += times[i];
      sumIV += invVels[i];
      sumTT += times[i] * times[i];
      sumTIV += times[i] * invVels[i];
    }

    final denom = n * sumTT - sumT * sumT;
    if (denom.abs() < 1e-12) return null;

    final b = (n * sumTIV - sumT * sumIV) / denom; // slope
    final a = (sumIV - b * sumT) / n; // intercept

    // Only valid if slope is negative (inverse velocity decreasing toward zero)
    if (b >= 0) return null;

    // Compute R²
    final meanIV = sumIV / n;
    double ssTot = 0, ssRes = 0;
    for (int i = 0; i < n; i++) {
      final predicted = a + b * times[i];
      ssRes += (invVels[i] - predicted) * (invVels[i] - predicted);
      ssTot += (invVels[i] - meanIV) * (invVels[i] - meanIV);
    }
    final r2 = ssTot > 1e-12 ? 1.0 - (ssRes / ssTot) : 0.0;

    if (r2 < 0.7) return null; // Poor fit — don't predict

    // t_failure = -a/b (time when 1/v = 0)
    final tFailure = -a / b;
    final ttf = tFailure - now; // seconds until failure

    if (ttf <= 0 || ttf > 7200) return null; // Already past or too far out (>2h)

    // Estimate Voight α from log(dΩ/dt) vs log(Ω)
    // For soil: expect α ≈ 1.9-2.1
    double? alpha;
    if (_featureHistory.length >= 60) {
      // Simple α estimation from PPV acceleration vs PPV
      final ppvAccel = _computeAcceleration('ppv', min(150, _featureHistory.length ~/ 2).clamp(10, 150));
      final recentPpv = _rangeAverage('ppv', _featureHistory.length - 10, _featureHistory.length);
      if (ppvAccel.abs() > 1e-10 && recentPpv > 1e-6) {
        final logAccel = log(ppvAccel.abs()) / ln10;
        final logPpv = log(recentPpv) / ln10;
        if (logPpv.abs() > 1e-6) {
          alpha = logAccel / logPpv;
        }
      }
    }

    return FukuzonoResult(
      ttfSeconds: ttf,
      r2: r2,
      alpha: alpha,
      psdSlope: _lastPsdSlope,
    );
  }

  /// Reset the baseline — call on BLE reconnect or site change.
  ///
  /// Clears all calibration state so the service re-learns the baseline
  /// from scratch. Forces rule-based fallback until recalibration completes.
  void reset() {
    _sampleCount = 0;
    _isCalibrated = false;
    _dynamicThresholdLow = 1.195327;
    _dynamicThresholdHigh = 1.788009;
    _emaMean.clear();
    _emaVariance.clear();
    for (final key in _featureKeys) {
      _stats[key] = _WelfordStats();
      _shortWindow[key]!.clear();
      _longWindow[key]!.clear();
      _cusumPositive[key] = 0.0;
      _cusumNegative[key] = 0.0;
      _changePointCount[key] = 0;
    }
    _featureHistory.clear();
    _inverseVelocityHistory.clear();
    _inverseVelocityTimes.clear();
    _lastPsdSlope = null;
    if (kDebugMode) {
      debugPrint('AdaptiveAnomalyService: Baseline reset (forces recalibration)');
    }
  }

  /// Clean up resources
  void dispose() {
    _serviceStopwatch.stop();
    _featureHistory.clear();
    _inverseVelocityHistory.clear();
    _inverseVelocityTimes.clear();
    for (final key in _featureKeys) {
      _shortWindow[key]?.clear();
      _longWindow[key]?.clear();
    }
    _emaMean.clear();
    _emaVariance.clear();
    _cusumPositive.clear();
    _cusumNegative.clear();
    _changePointCount.clear();
  }

  /// Get baseline summary for display
  Map<String, Map<String, double>> get baselineSummary {
    if (!_isCalibrated) return {};
    return {
      for (final key in _featureKeys)
        key: {
          'mean': _emaMean[key] ?? 0,
          'stdDev': sqrt(_emaVariance[key] ?? 0),
        },
    };
  }

  /// Get current trend features for precursor classifier input.
  Map<String, double> getTrendFeatures() {
    if (!_isCalibrated) {
      return {
        'ppv_trend': 1.0, 'freq_trend': 1.0, 'kurtosis_trend': 1.0,
        'stalta_trend': 1.0, 'cusum_max': 0.0, 'autoencoder_score': 0.0,
      };
    }
    double shortLongRatio(String key) {
      final short = _shortWindow[key];
      final long = _longWindow[key];
      if (short == null || long == null || short.isEmpty || long.isEmpty) return 1.0;
      final shortList = short.toList();
      final longList = long.toList();
      final shortMean = shortList.reduce((a, b) => a + b) / shortList.length;
      final longMean = longList.reduce((a, b) => a + b) / longList.length;
      return longMean != 0 ? shortMean / longMean : 1.0;
    }
    double maxCusum() {
      double m = 0;
      for (final key in _featureKeys) {
        final pos = _cusumPositive[key] ?? 0;
        final neg = _cusumNegative[key] ?? 0;
        if (pos > m) m = pos;
        if (neg > m) m = neg;
      }
      return m;
    }
    return {
      'ppv_trend': shortLongRatio('ppv'),
      'freq_trend': shortLongRatio('freq'),
      'kurtosis_trend': shortLongRatio('kurtosis'),
      'stalta_trend': shortLongRatio('stalta'),
      'cusum_max': maxCusum(),
      'autoencoder_score': 0.0, // filled by caller
    };
  }

  // --- Temporal derivative helpers for precursor detection ---

  /// Compute rate of change (derivative) of a feature over a window.
  /// Returns change per sample. Positive = rising.
  double _computeDerivative(String feature, int windowSamples) {
    if (_featureHistory.length < windowSamples + 1) return 0.0;
    final start = _featureHistory.length - windowSamples;
    final oldAvg = _rangeAverage(feature, start, start + windowSamples ~/ 3);
    final newAvg = _rangeAverage(feature, _featureHistory.length - windowSamples ~/ 3, _featureHistory.length);
    return (newAvg - oldAvg) / windowSamples;
  }

  /// Compute acceleration (2nd derivative) — is the trend speeding up?
  double _computeAcceleration(String feature, int windowSamples) {
    if (_featureHistory.length < windowSamples * 2) return 0.0;
    final d1 = _computeDerivative(feature, windowSamples);
    // Compute derivative from the earlier half
    final historyList = _featureHistory.toList();
    final halfLen = historyList.length ~/ 2;
    final oldHistory = historyList.sublist(0, halfLen);
    double oldD = 0.0;
    if (oldHistory.length >= windowSamples + 1) {
      final start = oldHistory.length - windowSamples;
      double oldSum = 0.0, newSum = 0.0;
      int oldCount = 0, newCount = 0;
      for (int i = start; i < start + windowSamples ~/ 3; i++) {
        oldSum += oldHistory[i][feature] ?? 0.0;
        oldCount++;
      }
      for (int i = oldHistory.length - windowSamples ~/ 3; i < oldHistory.length; i++) {
        newSum += oldHistory[i][feature] ?? 0.0;
        newCount++;
      }
      if (oldCount > 0 && newCount > 0) {
        oldD = (newSum / newCount - oldSum / oldCount) / windowSamples;
      }
    }
    return d1 - oldD; // Positive = accelerating upward
  }

  double _rangeAverage(String feature, int from, int to) {
    if (from >= to || from < 0) return 0.0;
    final historyList = _featureHistory.toList();
    final end = to.clamp(0, historyList.length);
    final start = from.clamp(0, end);
    if (start >= end) return 0.0;
    double sum = 0.0;
    for (int i = start; i < end; i++) {
      sum += historyList[i][feature] ?? 0.0;
    }
    return sum / (end - start);
  }

  // --- Utility functions ---

  double _windowMean(CircularBuffer<double> window) {
    if (window.isEmpty) return 0.0;
    double sum = 0.0;
    for (final v in window.iter) {
      sum += v;
    }
    return sum / window.length;
  }

  double _windowStdDev(CircularBuffer<double> window, double mean) {
    if (window.length < 2) return 0.0;
    double sumSq = 0.0;
    for (final v in window.iter) {
      final d = v - mean;
      sumSq += d * d;
    }
    return sqrt(sumSq / (window.length - 1));
  }
}

/// Welford's online algorithm for numerically stable running mean/variance.
class _WelfordStats {
  int _count = 0;
  double _mean = 0.0;
  double _m2 = 0.0;

  double get mean => _mean;
  double get variance => _count > 1 ? _m2 / (_count - 1) : 0.0;
  int get count => _count;

  void update(double value) {
    _count++;
    final delta = value - _mean;
    _mean += delta / _count;
    final delta2 = value - _mean;
    _m2 += delta * delta2;
  }
}

enum AdaptiveAnomalyLevel { normal, unusual, anomaly }

class AdaptiveAnomalyResult {
  final double score; // 0.0 (normal) to 1.0 (severe)
  final AdaptiveAnomalyLevel level;
  final double rmsZScore; // Root mean squared z-score
  final Map<String, double> featureZScores; // Per-feature z-scores
  final String? dominantFeature; // Feature contributing most to anomaly
  final bool isTrendDriven; // True if trend detection triggered (not instantaneous)
  final double trendScore; // Trend-specific score
  final bool isPrecursorDriven; // True if precursor pattern detection triggered
  final double precursorScore; // Precursor-specific score
  final String? precursorPattern; // Detected precursor pattern name

  const AdaptiveAnomalyResult({
    required this.score,
    required this.level,
    required this.rmsZScore,
    required this.featureZScores,
    this.dominantFeature,
    this.isTrendDriven = false,
    this.trendScore = 0.0,
    this.isPrecursorDriven = false,
    this.precursorScore = 0.0,
    this.precursorPattern,
  });

  String get levelLabel {
    switch (level) {
      case AdaptiveAnomalyLevel.normal:
        return 'Normal';
      case AdaptiveAnomalyLevel.unusual:
        return 'Unusual';
      case AdaptiveAnomalyLevel.anomaly:
        return 'Anomaly';
    }
  }
}

/// Result of Fukuzono inverse velocity time-to-failure prediction.
class FukuzonoResult {
  final double ttfSeconds; // Estimated seconds to failure
  final double r2; // Linear fit quality (0-1)
  final double? alpha; // Voight α value (soil ≈ 1.9-2.1)
  final double? psdSlope; // PSD log-log slope from DSP

  const FukuzonoResult({
    required this.ttfSeconds,
    required this.r2,
    this.alpha,
    this.psdSlope,
  });

  /// Classify PSD slope: earthquake ~-0.5, landslide ~-3 to -9, noise < -9
  String get psdClassification {
    if (psdSlope == null) return 'unknown';
    final s = psdSlope!;
    if (s > -1.5) return 'earthquake';
    if (s > -9.0) return 'landslide';
    return 'noise';
  }
}
