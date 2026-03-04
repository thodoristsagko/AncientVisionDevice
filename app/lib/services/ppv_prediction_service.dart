import 'dart:developer' as developer;
import 'dart:math';

import '../config/app_constants.dart';
import '../utils/circular_buffer.dart';

/// Simple Kalman filter compatible with PPVPredictionService.
///
/// Alias-friendly wrapper around [KalmanPPVFilter] with constructor
/// parameters that match the service API.
class KalmanFilter {
  double _estimate;
  double _errorEstimate;
  final double _q;
  final double _r;

  KalmanFilter({
    double initialEstimate = 0.0,
    double initialError = 1.0,
    double processNoise = 0.01,
    double measurementNoise = 0.1,
  })  : _estimate = initialEstimate,
        _errorEstimate = initialError,
        _q = processNoise,
        _r = measurementNoise;

  double update(double measurement) {
    final errorPrediction = _errorEstimate + _q;
    final kalmanGain = errorPrediction / (errorPrediction + _r);
    _estimate = _estimate + kalmanGain * (measurement - _estimate);
    _errorEstimate = (1 - kalmanGain) * errorPrediction;
    return _estimate;
  }

  double get estimate => _estimate;

  /// Current error covariance (uncertainty) of the Kalman filter.
  double get errorCovariance => _errorEstimate;

  void reset() {
    _estimate = 0.0;
    _errorEstimate = 1.0;
  }
}

/// Adaptive Kalman filter for optimal PPV smoothing.
///
/// Replaces the static EMA (alpha=0.3) with a proper Kalman filter
/// that adapts its gain based on measurement noise. Converges faster
/// on sudden changes while still filtering noise in steady state.
class KalmanPPVFilter {
  /// Process noise covariance — how much the true PPV can change per step.
  final double q;

  /// Measurement noise covariance — how noisy raw PPV readings are.
  final double r;

  double _estimate = 0;
  double _errorCovariance = 1;
  bool _initialized = false;

  KalmanPPVFilter({this.q = 0.01, this.r = 0.5});

  /// Current filtered PPV estimate.
  double get estimate => _estimate;

  /// Current Kalman gain (0–1). Higher = trusting measurement more.
  double get gain =>
      _errorCovariance / (_errorCovariance + r);

  /// Feed a new raw PPV measurement and return the filtered estimate.
  double update(double measurement) {
    if (!_initialized) {
      _estimate = measurement;
      _errorCovariance = r;
      _initialized = true;
      return _estimate;
    }

    // Predict step
    // State prediction: x_hat stays the same (random walk model)
    // Error prediction: P = P + Q
    _errorCovariance += q;

    // Update step
    final k = _errorCovariance / (_errorCovariance + r);
    _estimate += k * (measurement - _estimate);
    _errorCovariance *= (1 - k);

    return _estimate;
  }

  /// Reset filter state.
  void reset() {
    _estimate = 0;
    _errorCovariance = 1;
    _initialized = false;
  }
}

/// Result of PPV trend prediction.
class PPVPrediction {
  /// Predicted PPV values for next [horizon] steps (mm/s).
  final List<double> predicted;

  /// Slope of the linear regression (mm/s per sample).
  final double slope;

  /// R² goodness of fit (0–1). Below 0.3 means trend is unreliable.
  final double rSquared;

  /// Estimated minutes until PPV reaches [targetLimit], or null if
  /// the trend is flat/decreasing or R² is too low.
  final double? minutesToLimit;

  /// The target limit used for time-to-limit calculation.
  final double targetLimit;

  /// Whether the prediction is reliable (R² > 0.3 and enough samples).
  bool get isReliable => rSquared > 0.3;

  /// Whether PPV is trending upward toward the limit.
  bool get isTrendingUp => slope > 0.001 && isReliable;

  const PPVPrediction({
    required this.predicted,
    required this.slope,
    required this.rSquared,
    required this.targetLimit,
    this.minutesToLimit,
  });
}

/// Linear regression trend predictor for PPV time series.
///
/// Uses the last [windowSize] samples to fit a line and extrapolate
/// future PPV values + estimate time-to-limit.
class PPVTrendPredictor {
  /// Number of past samples to use for regression.
  final int windowSize;

  /// BLE update interval in seconds (default 0.5s = 2 Hz).
  final double sampleIntervalSec;

  PPVTrendPredictor({
    this.windowSize = 20,
    this.sampleIntervalSec = 0.5,
  });

  /// Predict future PPV trajectory from recent history.
  ///
  /// [ppvHistory] should contain raw or Kalman-filtered PPV values,
  /// newest last. [limitMmPerSec] is the DIN 4150-3 limit to check
  /// time-to-exceedance against (default 3.0 mm/s for heritage at ≤10Hz).
  /// [horizon] is how many future steps to predict.
  PPVPrediction predict(
    List<double> ppvHistory, {
    double limitMmPerSec = 3.0,
    int horizon = 10,
  }) {
    // Use at most windowSize recent samples
    final data = ppvHistory.length > windowSize
        ? ppvHistory.sublist(ppvHistory.length - windowSize)
        : ppvHistory;

    if (data.length < 3) {
      return PPVPrediction(
        predicted: [],
        slope: 0,
        rSquared: 0,
        targetLimit: limitMmPerSec,
      );
    }

    // Linear regression: y = a + b*x
    final n = data.length;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

    for (int i = 0; i < n; i++) {
      final x = i.toDouble();
      final y = data[i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }

    final denom = n * sumX2 - sumX * sumX;
    if (denom.abs() < 1e-12) {
      return PPVPrediction(
        predicted: List.filled(horizon, data.last),
        slope: 0,
        rSquared: 0,
        targetLimit: limitMmPerSec,
      );
    }

    final b = (n * sumXY - sumX * sumY) / denom; // slope
    final a = (sumY - b * sumX) / n; // intercept

    // R² coefficient of determination
    final yMean = sumY / n;
    double ssRes = 0, ssTot = 0;
    for (int i = 0; i < n; i++) {
      final yPred = a + b * i;
      ssRes += (data[i] - yPred) * (data[i] - yPred);
      ssTot += (data[i] - yMean) * (data[i] - yMean);
    }
    final rSquared = ssTot > 1e-12 ? 1.0 - (ssRes / ssTot) : 0.0;

    // Extrapolate future values
    final predicted = <double>[];
    for (int i = 0; i < horizon; i++) {
      final futureX = n + i;
      predicted.add(max(0, a + b * futureX));
    }

    // Estimate time-to-limit
    double? minutesToLimit;
    if (b > 0.001 && rSquared > 0.3) {
      final currentPPV = a + b * (n - 1);
      if (currentPPV < limitMmPerSec) {
        // Steps to reach limit from current position
        final stepsToLimit = (limitMmPerSec - currentPPV) / b;
        minutesToLimit = stepsToLimit * sampleIntervalSec / 60.0;
        // Cap at reasonable maximum (don't show "500 minutes")
        if (minutesToLimit > 120) minutesToLimit = null;
      }
    }

    return PPVPrediction(
      predicted: predicted,
      slope: b,
      rSquared: rSquared.clamp(0.0, 1.0),
      targetLimit: limitMmPerSec,
      minutesToLimit: minutesToLimit,
    );
  }
}

/// A (predicted, actual) pair used for accuracy tracking.
class _PredictionPair {
  final double predicted;
  final double actual;
  const _PredictionPair(this.predicted, this.actual);
}

/// Service for real-time PPV prediction, Kalman smoothing, and trend analysis.
///
/// Singleton that accumulates PPV samples, maintains a Kalman-filtered
/// parallel history, and exposes exceedance / slope metrics used by the
/// safety UI and BLE processing pipeline.
class PPVPredictionService {
  static final PPVPredictionService instance = PPVPredictionService._();
  PPVPredictionService._();

  static const int _maxHistory = 60;

  /// Threshold above which prediction accuracy is considered degraded (mm/s).
  static const double _maeWarningThreshold = 0.5;

  /// BLE update interval in seconds (2 Hz default).
  static const double _sampleIntervalSec = 0.5;

  final List<double> _ppvHistory = [];
  final List<double> _kalmanHistory = [];
  final KalmanFilter _kalman = KalmanFilter(
    processNoise: 0.005,
    measurementNoise: 0.05,
  );
  final PPVTrendPredictor _predictor = PPVTrendPredictor();

  /// Rolling buffer of the last 20 (predicted, actual) pairs for MAE tracking.
  final CircularBuffer<_PredictionPair> _accuracyBuffer =
      CircularBuffer<_PredictionPair>(20);

  /// The last one-step-ahead prediction made before the most recent sample.
  double? _pendingPrediction;

  // ============================================================================
  // Existing public API
  // ============================================================================

  /// Unmodifiable view of raw PPV samples (newest last).
  List<double> get rawHistory => List.unmodifiable(_ppvHistory);

  /// Unmodifiable view of Kalman-filtered PPV samples (newest last).
  List<double> get kalmanHistory => List.unmodifiable(_kalmanHistory);

  /// Add a new raw PPV measurement (mm/s).
  ///
  /// Also pushes through the Kalman filter and maintains the rolling window.
  /// Records prediction accuracy if a pending prediction exists.
  void addSample(double ppv) {
    // Record accuracy for the prediction made on the previous step.
    if (_pendingPrediction != null) {
      _accuracyBuffer.add(_PredictionPair(_pendingPrediction!, ppv));
      if (predictionMae > _maeWarningThreshold) {
        developer.log(
          'PPV prediction accuracy degraded: MAE=${predictionMae.toStringAsFixed(3)} mm/s',
          name: 'PPVPredictionService',
          level: 900, // WARNING
        );
      }
    }

    final filtered = _kalman.update(ppv);
    _ppvHistory.add(ppv);
    _kalmanHistory.add(filtered);
    if (_ppvHistory.length > _maxHistory) {
      _ppvHistory.removeAt(0);
      _kalmanHistory.removeAt(0);
    }

    // Store the next one-step-ahead Kalman prediction for accuracy tracking.
    _pendingPrediction = filtered;
  }

  /// Current trend prediction based on Kalman-filtered history.
  ///
  /// Returns null when fewer than 5 samples have been collected.
  PPVPrediction? get prediction {
    if (_kalmanHistory.length < 5) return null;
    return _predictor.predict(_kalmanHistory);
  }

  /// Predicted number of samples until PPV exceeds [threshold] mm/s.
  ///
  /// Returns 0 if already exceeded, null if the trend is flat or falling,
  /// and a positive integer otherwise (capped at 600).
  int? samplesUntilExceedance(double threshold) {
    if (_ppvHistory.isEmpty) return null;
    if (_ppvHistory.last >= threshold) return 0;
    final p = prediction;
    if (p == null || !p.isTrendingUp || p.slope <= 0) return null;
    // Using the Kalman-filtered series as the basis for the fitted line:
    // current value approximated by the last Kalman estimate.
    final currentFiltered = _kalmanHistory.last;
    if (currentFiltered >= threshold) return 0;
    final steps = (threshold - currentFiltered) / p.slope;
    return steps.round().clamp(0, 600);
  }

  /// Number of raw PPV samples in history that are >= [threshold] mm/s.
  int exceedanceCount(double threshold) =>
      _ppvHistory.where((v) => v >= threshold).length;

  /// Maximum raw PPV value observed in the current rolling window.
  double get peakPpv =>
      _ppvHistory.isEmpty ? 0.0 : _ppvHistory.reduce(max);

  /// Clear all history and reset the Kalman filter.
  void reset() {
    _ppvHistory.clear();
    _kalmanHistory.clear();
    _kalman.reset();
    _accuracyBuffer.clear();
    _pendingPrediction = null;
  }

  // ============================================================================
  // New: Prediction accuracy tracking
  // ============================================================================

  /// Mean Absolute Error of the last ≤20 one-step-ahead predictions (mm/s).
  ///
  /// Returns 0.0 when no accuracy pairs have been recorded yet.
  double get predictionMae {
    if (_accuracyBuffer.isEmpty) return 0.0;
    double sum = 0.0;
    for (final pair in _accuracyBuffer.iter) {
      sum += (pair.predicted - pair.actual).abs();
    }
    return sum / _accuracyBuffer.length;
  }

  // ============================================================================
  // New: Trend velocity (mm/s per second)
  // ============================================================================

  /// Rate of change of PPV in mm/s per second (first derivative).
  ///
  /// Computed from the linear regression slope converted from per-sample
  /// to per-second using [_sampleIntervalSec]. Positive = increasing,
  /// negative = decreasing. Returns 0.0 when insufficient data.
  double get ppvTrendVelocity {
    final p = prediction;
    if (p == null) return 0.0;
    // slope is in mm/s per sample; divide by interval to get mm/s per second.
    return p.slope / _sampleIntervalSec;
  }

  // ============================================================================
  // New: Time-to-threshold estimate
  // ============================================================================

  /// Estimated time until PPV reaches the DIN 4150-3 warning threshold.
  ///
  /// Uses a simple linear extrapolation from the current Kalman estimate
  /// and [ppvTrendVelocity]. Returns null when PPV is stable or decreasing,
  /// or when the current PPV already exceeds the threshold.
  /// Capped at 10 minutes to avoid misleading long-range predictions.
  Duration? get estimatedTimeToThreshold {
    final velocity = ppvTrendVelocity; // mm/s per second
    if (velocity <= 0) return null;

    final currentPpv =
        _kalmanHistory.isNotEmpty ? _kalmanHistory.last : 0.0;
    const threshold = AppConstants.ppvWarning;

    if (currentPpv >= threshold) return null;

    final secondsToThreshold = (threshold - currentPpv) / velocity;
    if (secondsToThreshold <= 0) return null;

    const maxSeconds = 10 * 60.0; // 10 minutes cap
    final clamped = secondsToThreshold.clamp(0.0, maxSeconds);
    return Duration(milliseconds: (clamped * 1000).round());
  }

  // ============================================================================
  // New: 95 % confidence interval
  // ============================================================================

  /// 95 % confidence interval (±2σ) around the current Kalman estimate.
  ///
  /// Uses the Kalman filter's error covariance as the variance estimate
  /// (σ = √P). If the covariance is unavailable or the history is empty,
  /// falls back to ±10 % of the current estimate.
  ///
  /// Returns (lower, upper) bounds in mm/s (both ≥ 0).
  (double lower, double upper) get ppvConfidenceInterval95 {
    if (_kalmanHistory.isEmpty) return (0.0, 0.0);

    final estimate = _kalmanHistory.last;
    // KalmanFilter.errorCovariance is the posterior error covariance P.
    final covariance = _kalman.errorCovariance;
    final sigma = sqrt(max(0.0, covariance));
    final halfWidth = sigma > 0 ? 2.0 * sigma : 0.1 * estimate;

    return (
      max(0.0, estimate - halfWidth),
      estimate + halfWidth,
    );
  }
}

// ============================================================================
// Seismic risk model
// ============================================================================

/// Risk level classification for seismic / vibration events.
enum SeismicRiskLevel {
  safe,
  low,
  moderate,
  high,
  critical,
}

/// Seismic risk assessment that combines PPV, trend velocity, and time-to-threshold
/// into a human-readable description for field operators.
///
/// Constructed from the current state of [PPVPredictionService].
class SeismicRiskModel {
  /// Current (Kalman-filtered) PPV in mm/s.
  final double currentPpv;

  /// Trend velocity in mm/s per second.
  final double trendVelocity;

  /// Estimated time to warning threshold, or null if not applicable.
  final Duration? timeToThreshold;

  /// Derived risk level.
  final SeismicRiskLevel riskLevel;

  SeismicRiskModel._({
    required this.currentPpv,
    required this.trendVelocity,
    required this.timeToThreshold,
    required this.riskLevel,
  });

  /// Build a [SeismicRiskModel] from the current [PPVPredictionService] state.
  factory SeismicRiskModel.fromService() {
    final svc = PPVPredictionService.instance;
    final ppv = svc.kalmanHistory.isNotEmpty ? svc.kalmanHistory.last : 0.0;
    final velocity = svc.ppvTrendVelocity;
    final ttThreshold = svc.estimatedTimeToThreshold;

    final level = _classify(ppv);

    return SeismicRiskModel._(
      currentPpv: ppv,
      trendVelocity: velocity,
      timeToThreshold: ttThreshold,
      riskLevel: level,
    );
  }

  static SeismicRiskLevel _classify(double ppv) {
    if (ppv >= AppConstants.ppvCritical) return SeismicRiskLevel.critical;
    if (ppv >= AppConstants.ppvWarning) return SeismicRiskLevel.high;
    if (ppv >= AppConstants.ppvSafeMax * 4) return SeismicRiskLevel.moderate;
    if (ppv >= AppConstants.ppvSafeMax) return SeismicRiskLevel.low;
    return SeismicRiskLevel.safe;
  }

  /// Human-readable sentence describing the current seismic risk for operators.
  ///
  /// Example: "Moderate vibration detected. PPV is trending upward at
  /// 0.05 mm/s². Estimated 45s to warning threshold."
  String get riskDescription {
    final ppvStr = currentPpv.toStringAsFixed(2);
    final buffer = StringBuffer();

    switch (riskLevel) {
      case SeismicRiskLevel.safe:
        buffer.write('Vibration within safe limits (PPV $ppvStr mm/s).');
      case SeismicRiskLevel.low:
        buffer.write('Low vibration detected (PPV $ppvStr mm/s).');
      case SeismicRiskLevel.moderate:
        buffer.write('Moderate vibration detected (PPV $ppvStr mm/s).');
      case SeismicRiskLevel.high:
        buffer.write(
          'High vibration — DIN 4150-3 warning threshold exceeded (PPV $ppvStr mm/s).',
        );
      case SeismicRiskLevel.critical:
        buffer.write(
          'CRITICAL vibration — immediate action required (PPV $ppvStr mm/s).',
        );
    }

    if (trendVelocity > 0.001) {
      buffer.write(
        ' PPV is trending upward at ${trendVelocity.toStringAsFixed(3)} mm/s².',
      );
    } else if (trendVelocity < -0.001) {
      buffer.write(
        ' PPV is decreasing at ${trendVelocity.abs().toStringAsFixed(3)} mm/s².',
      );
    } else {
      buffer.write(' PPV is stable.');
    }

    if (timeToThreshold != null) {
      final secs = timeToThreshold!.inSeconds;
      if (secs < 60) {
        buffer.write(' Estimated ${secs}s to warning threshold.');
      } else {
        final mins = timeToThreshold!.inMinutes;
        final remSecs = secs - mins * 60;
        buffer.write(
          ' Estimated ${mins}m${remSecs > 0 ? ' ${remSecs}s' : ''} to warning threshold.',
        );
      }
    }

    return buffer.toString();
  }
}
