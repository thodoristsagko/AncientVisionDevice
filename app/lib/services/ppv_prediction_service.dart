import 'dart:math';

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
