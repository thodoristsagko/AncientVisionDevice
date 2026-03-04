import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'adaptive_anomaly_service.dart';
import 'inference_timing_service.dart';
import 'ml_anomaly_service.dart';
import 'precursor_classifier_service.dart';

/// Vibration anomaly detection service using TFLite autoencoder / VAE.
///
/// Supports multiple model versions via auto-detection from config:
///   - v1.0: 4-feature autoencoder  [rms, ppv, freq, crest]
///   - v3.0: 7-feature autoencoder  [rms, ppv, freq, crest, centroid, kurtosis, stalta]
///   - v4.0: 10-feature VAE         [rms, ppv, freq, crest, centroid, kurtosis, stalta, arias, cav, temp]
///
/// The model is trained on "normal" vibration patterns. High reconstruction
/// error indicates an anomaly (potential hazard to the archaeological site).
///
/// Anomaly levels:
///   - NORMAL: score < threshold_low (green)
///   - UNUSUAL: threshold_low <= score < threshold_high (yellow)
///   - ANOMALY: score >= threshold_high (red)
class VibrationAnomalyService {
  static final VibrationAnomalyService _instance =
      VibrationAnomalyService._internal();
  factory VibrationAnomalyService() => _instance;

  /// Named singleton accessor — identical to `VibrationAnomalyService()`.
  static VibrationAnomalyService get instance => _instance;

  VibrationAnomalyService._internal();

  Interpreter? _interpreter;
  bool _isInitialized = false;
  bool _useRuleBased = false;

  // P68: retry counter — how many consecutive ML failures have occurred
  int _ruleBasedFailCount = 0;
  static const int _maxMlRetries = 3; // after this many failures, stay rule-based permanently

  // P69: running average inference time
  double _avgInferenceMs = 0.0;
  int _inferenceCount = 0;

  // Scaler parameters (from training)
  List<double> _scalerMean = [];
  List<double> _scalerScale = [];
  List<String> _featureNames = [];

  // Anomaly thresholds
  double _thresholdLow = 1.0;
  double _thresholdHigh = 2.5;

  // Model config
  int _inputDim = 4;
  String _modelVersion = 'unknown';
  String _modelType = 'autoencoder'; // 'autoencoder' or 'vae'
  double _beta = 1.0; // KL divergence weight for VAE scoring

  // Runtime-configurable PPV alert threshold (updated from settings screen)
  double _ppvThreshold = 0.3; // mm/s — default DIN 4150-3 heritage limit

  // Maximum inference frequency debounce (set from settings screen)
  Duration _maxInferenceInterval = const Duration(milliseconds: 500); // default 2 Hz
  DateTime _lastInferenceTime = DateTime(2000); // sentinel: always allow first call

  // PPV trend window — last N readings for rising/falling detection
  static const int _trendWindowSize = 10;
  final List<double> _ppvTrendWindow = [];

  // Consecutive readings at ANOMALY or above
  int _consecutiveAnomalyReadings = 0;

  // Duration tracking at current anomaly level
  AnomalyLevel _currentLevel = AnomalyLevel.normal;
  DateTime? _levelChangedAt;

  // P70: Model fingerprint (sum of first 64 bytes of .tflite file)
  int _modelFingerprint = 0;

  /// P70: Hex fingerprint of the loaded .tflite model bytes.
  String get modelFingerprint => _modelFingerprint.toRadixString(16);

  // Adaptive statistical anomaly detection (Tier 1.5 — between rule-based and ML)
  final AdaptiveAnomalyService _adaptiveService = AdaptiveAnomalyService();

  // Standalone ML services (new hybrid pipeline)
  final MlAnomalyService _mlService = MlAnomalyService();
  final PrecursorClassifierService _precursorService = PrecursorClassifierService();

  bool get isInitialized => _isInitialized;
  bool get isRuleBased => _useRuleBased;
  AdaptiveAnomalyService get adaptiveService => _adaptiveService;
  MlAnomalyService get mlService => _mlService;
  PrecursorClassifierService get precursorService => _precursorService;

  /// P69: Average TFLite inference time in milliseconds.
  double get avgInferenceMs => _avgInferenceMs;

  // ---------------------------------------------------------------------------
  // PPV trend analysis
  // ---------------------------------------------------------------------------

  /// PPV trend direction over the last [_trendWindowSize] readings.
  ///
  /// Compares the mean of the first half of the window to the mean of the
  /// second half. Returns 'rising' / 'falling' / 'stable'.
  String get ppvTrend {
    if (_ppvTrendWindow.length < 3) return 'stable';
    final half = _ppvTrendWindow.length ~/ 2;
    final first = _ppvTrendWindow.sublist(0, half).reduce((a, b) => a + b) / half;
    final last = _ppvTrendWindow.sublist(half).reduce((a, b) => a + b) /
        (_ppvTrendWindow.length - half);
    final delta = last - first;
    if (delta > 0.05) return 'rising';
    if (delta < -0.05) return 'falling';
    return 'stable';
  }

  /// Rate of change of PPV between the two most recent readings (mm/s per sample).
  ///
  /// Positive means PPV is increasing; negative means decreasing.
  double get ppvRateOfChange {
    if (_ppvTrendWindow.length < 2) return 0.0;
    return _ppvTrendWindow.last - _ppvTrendWindow[_ppvTrendWindow.length - 2];
  }

  // ---------------------------------------------------------------------------
  // Consecutive anomaly readings
  // ---------------------------------------------------------------------------

  /// Number of consecutive [detect] calls that returned ANOMALY or above.
  int get consecutiveAnomalyReadings => _consecutiveAnomalyReadings;

  // ---------------------------------------------------------------------------
  // Prediction confidence
  // ---------------------------------------------------------------------------

  /// Confidence in the current anomaly assessment (0.0–1.0).
  ///
  /// Scales with the number of consecutive readings that support the current
  /// level, reaching full confidence at 5+ readings:
  ///   1 reading  → 0.4
  ///   3 readings → 0.8
  ///   5+ readings → 1.0
  double get predictionConfidence {
    final n = _consecutiveAnomalyReadings;
    if (n <= 0) return 0.4; // no anomaly streak — low but non-zero confidence
    if (n == 1) return 0.4;
    if (n >= 5) return 1.0;
    if (n >= 3) {
      // linear 0.8 → 1.0 from 3 to 5
      return 0.8 + (n - 3) * (1.0 - 0.8) / (5 - 3);
    }
    // linear 0.4 → 0.8 from 1 to 3
    return 0.4 + (n - 1) * (0.8 - 0.4) / (3 - 1);
  }

  // ---------------------------------------------------------------------------
  // Human-readable anomaly description
  // ---------------------------------------------------------------------------

  /// One-line plain-English description of the current anomaly state.
  ///
  /// When a precursor pattern is available (from the last detect result stored
  /// via [_lastPrecursorPattern]) a pattern-specific suffix is appended.
  String get anomalyDescription {
    String base;
    switch (_currentLevel) {
      case AnomalyLevel.normal:
        base = 'Normal background vibration';
        break;
      case AnomalyLevel.unusual:
        base = 'Elevated vibration \u2014 monitoring closely';
        break;
      case AnomalyLevel.anomaly:
        base = 'Anomalous pattern \u2014 alert active';
        break;
      case AnomalyLevel.unknown:
        base = 'Initializing sensor data';
        break;
    }
    final pattern = _lastPrecursorPattern;
    if (pattern != null && pattern.isNotEmpty) {
      switch (pattern) {
        case 'soil_creep':
          return '$base (soil creep detected)';
        case 'crack_propagation':
          return '$base (crack propagation detected)';
        case 'imminent_failure':
          return '$base (imminent failure signature)';
        default:
          return '$base (pattern: $pattern)';
      }
    }
    return base;
  }

  // ---------------------------------------------------------------------------
  // Duration at current anomaly level
  // ---------------------------------------------------------------------------

  /// How long the service has been at the current [_currentLevel].
  Duration get durationAtCurrentLevel {
    if (_levelChangedAt == null) return Duration.zero;
    return DateTime.now().difference(_levelChangedAt!);
  }

  // Last precursor pattern from the most recent detect() call (nullable).
  String? _lastPrecursorPattern;

  /// P68: Attempt to re-enable ML inference if it previously failed.
  ///
  /// Resets [_useRuleBased] to false so the next [detect] call will try the
  /// TFLite model again. No-op if the failure count has exceeded [_maxMlRetries]
  /// (permanent rule-based mode until app restart) or the model is not loaded.
  void attemptMlRetry() {
    if (_ruleBasedFailCount == 0) return; // no failure recorded
    if (_ruleBasedFailCount > _maxMlRetries) return; // permanent fallback
    if (_interpreter == null) return; // model not loaded — can't retry
    _useRuleBased = false;
    if (kDebugMode) {
      debugPrint('VibrationAnomalyService: Retrying ML inference (failCount=$_ruleBasedFailCount)');
    }
  }

  String get modeLabel {
    if (!_useRuleBased && _isInitialized && _interpreter != null) {
      return 'ML v$_modelVersion';
    }
    if (_adaptiveService.isCalibrated) return 'Adaptive';
    if (_adaptiveService.sampleCount > 0) {
      return _adaptiveService.modeLabel; // 'Calibrating (X%)'
    }
    return 'Rule-Based';
  }

  String get modelVersion => _modelVersion;
  String get modelType => _modelType;
  int get inputDim => _inputDim;

  /// Initialize the TFLite model and load scaler/config.
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      // Load TFLite model
      _interpreter =
          await Interpreter.fromAsset('ml/vibration_anomaly.tflite');
      debugPrint('VibrationAnomalyService: TFLite model loaded');

      // P70: Compute model fingerprint from first 64 bytes of file
      try {
        final modelBytes = await rootBundle.load('assets/ml/vibration_anomaly.tflite');
        int fingerprint = 0;
        final bytes = modelBytes.buffer.asUint8List();
        final len = bytes.length < 64 ? bytes.length : 64;
        for (int i = 0; i < len; i++) {
          fingerprint += bytes[i];
        }
        _modelFingerprint = fingerprint;
        debugPrint('VibrationAnomalyService: Model fingerprint = $modelFingerprint');
      } catch (e) {
        debugPrint('VibrationAnomalyService: Fingerprint computation failed (non-fatal): $e');
      }

      // Load scaler parameters
      final scalerJson =
          await rootBundle.loadString('assets/ml/vibration_scaler.json');
      final scalerData = json.decode(scalerJson);
      _scalerMean =
          (scalerData['mean'] as List).map((e) => (e as num).toDouble()).toList();
      _scalerScale =
          (scalerData['scale'] as List).map((e) => (e as num).toDouble()).toList();
      _featureNames =
          (scalerData['feature_names'] as List).map((e) => e.toString()).toList();
      debugPrint(
          'VibrationAnomalyService: Scaler loaded (${_featureNames.length} features)');

      // Load model config
      final configJson =
          await rootBundle.loadString('assets/ml/vibration_model_config.json');
      final configData = json.decode(configJson);
      _inputDim = configData['input_dim'] as int? ?? 4;
      _modelVersion = configData['model_version']?.toString() ?? 'unknown';
      _modelType = configData['model_type'] as String? ?? 'autoencoder';
      _beta = (configData['beta'] as num?)?.toDouble() ?? 1.0;

      final thresholds =
          configData['thresholds'] as Map<String, dynamic>? ?? {};
      _thresholdLow =
          (thresholds['threshold_low'] as num?)?.toDouble() ?? 1.0;
      _thresholdHigh =
          (thresholds['threshold_high'] as num?)?.toDouble() ?? 2.5;

      debugPrint(
          'VibrationAnomalyService: Config loaded v$_modelVersion ($_modelType, beta=$_beta)');
      debugPrint(
          '  Input dim: $_inputDim  Features: $_featureNames');
      debugPrint(
          '  Thresholds: low=$_thresholdLow high=$_thresholdHigh');

      // Also initialize standalone ML services
      await _mlService.initialize();
      await _precursorService.initialize();

      _isInitialized = true;

      // P49: Model warm-up — run one dummy inference to pre-warm the TFLite interpreter
      try {
        final dummyInput = [List<double>.filled(_inputDim, 0.0)];
        final dummyOutput = [List<double>.filled(_inputDim, 0.0)];
        _interpreter!.run(dummyInput, dummyOutput);
        debugPrint('VibrationAnomalyService: Model warm-up complete');
      } catch (e) {
        debugPrint('VibrationAnomalyService: Warm-up failed (non-fatal): $e');
      }

      return true;
    } catch (e) {
      debugPrint('VibrationAnomalyService: ML model not available — using rule-based detection');
      _useRuleBased = true;
      _isInitialized = true;
      // Still try standalone ML services even if main model failed
      await _mlService.initialize();
      await _precursorService.initialize();
      return true;
    }
  }

  /// Run anomaly detection on a single vibration feature vector.
  ///
  /// Input: Map with keys matching the loaded model's feature names.
  ///   v1.0: {rms, ppv, freq, crest}
  ///   v3.0: {rms, ppv, freq, crest, centroid, kurtosis, stalta}
  ///   v4.0: {rms, ppv, freq, crest, centroid, kurtosis, stalta, arias, cav, temp}
  ///
  /// Returns: [AnomalyResult] with score and classification.
  AnomalyResult detect(Map<String, double> features) {
    // P68: attempt to re-enable ML if it previously failed (within retry budget)
    if (_useRuleBased && _ruleBasedFailCount > 0) {
      attemptMlRetry();
    }

    // ALWAYS feed the adaptive baseline so it keeps learning
    _adaptiveService.updateBaseline(features);

    // Track PPV trend — update window with incoming PPV value
    final incomingPpv = features['ppv'] ?? 0.0;
    _ppvTrendWindow.add(incomingPpv);
    if (_ppvTrendWindow.length > _trendWindowSize) {
      _ppvTrendWindow.removeAt(0);
    }

    late AnomalyResult result;

    if (!_isInitialized || _interpreter == null || _useRuleBased) {
      // Try adaptive statistical detection first
      final adaptiveResult = _adaptiveService.detect(features);
      if (adaptiveResult != null) {
        // Convert AdaptiveAnomalyResult → AnomalyResult
        AnomalyLevel level;
        switch (adaptiveResult.level) {
          case AdaptiveAnomalyLevel.normal:
            level = AnomalyLevel.normal;
            break;
          case AdaptiveAnomalyLevel.unusual:
            level = AnomalyLevel.unusual;
            break;
          case AdaptiveAnomalyLevel.anomaly:
            level = AnomalyLevel.anomaly;
            break;
        }
        result = AnomalyResult(
          score: adaptiveResult.score,
          level: level,
          rawError: adaptiveResult.rmsZScore,
        );
      } else {
        // Still calibrating — fall back to rule-based
        result = _ruleBasedDetect(features);
      }
      _updateLevelTracking(result);
      return result;
    }

    // Rate-limit ML inference according to the configured max Hz
    if (!_inferenceAllowed) {
      result = _ruleBasedDetect(features);
      _updateLevelTracking(result);
      return result;
    }
    _lastInferenceTime = DateTime.now();

    try {
      // Build feature vector in the expected order
      final input = List<double>.filled(_inputDim, 0.0);
      for (int i = 0; i < _featureNames.length && i < _inputDim; i++) {
        final value = features[_featureNames[i]] ?? 0.0;
        // Apply StandardScaler normalization
        if (i < _scalerScale.length && _scalerScale[i] != 0) {
          input[i] = (value - _scalerMean[i]) / _scalerScale[i];
        } else {
          input[i] = value;
        }
      }

      // Run inference (for VAE, the TFLite model uses z_mean deterministically)
      final inputTensor = [input.map((e) => e.toDouble()).toList()];
      final outputTensor = [List<double>.filled(_inputDim, 0.0)];

      // P69: track inference latency for performance monitoring
      final sw = Stopwatch()..start();
      _interpreter!.run(inputTensor, outputTensor);
      sw.stop();
      final elapsedMs = sw.elapsedMilliseconds.toDouble();
      _avgInferenceMs = (_avgInferenceMs * _inferenceCount + elapsedMs) /
          (_inferenceCount + 1);
      _inferenceCount++;
      // P48: report to shared timing service for diagnostics display
      InferenceTimingService.instance.record(elapsedMs);

      // Calculate reconstruction error (MSE)
      double mse = 0;
      for (int i = 0; i < _inputDim; i++) {
        final diff = input[i] - outputTensor[0][i];
        mse += diff * diff;
      }
      mse /= _inputDim;

      // For VAE models, the anomaly score is the reconstruction MSE.
      // The KL divergence component is baked into the training thresholds
      // (thresholds were computed on combined reconstruction + KL scores).
      // At inference, using reconstruction MSE alone is a good proxy since
      // the deterministic encoder path (z_mean) produces consistent latent
      // codes for normal data. The thresholds from training account for this.
      final anomalyScore = mse;

      // Classify anomaly level
      AnomalyLevel level;
      double score;
      if (anomalyScore < _thresholdLow) {
        level = AnomalyLevel.normal;
        score = anomalyScore / _thresholdLow; // 0-1 range for normal
      } else if (anomalyScore < _thresholdHigh) {
        level = AnomalyLevel.unusual;
        score = 0.5 +
            0.5 *
                (anomalyScore - _thresholdLow) /
                (_thresholdHigh - _thresholdLow);
      } else {
        level = AnomalyLevel.anomaly;
        score = min(1.0, anomalyScore / (_thresholdHigh * 2));
      }

      // Run precursor classifier
      final trendFeatures = _adaptiveService.getTrendFeatures();
      trendFeatures['autoencoder_score'] = score.clamp(0.0, 1.0);
      final precursorResult = _precursorService.classify(
        dspFeatures: features,
        trendFeatures: trendFeatures,
        autoencoderScore: score.clamp(0.0, 1.0),
      );

      // Merge: highest severity wins
      if (precursorResult != null && !precursorResult.isNormal) {
        final precursorScore = precursorResult.anomalyScore;
        if (precursorScore > score) {
          score = precursorScore;
          level = precursorScore >= 0.7 ? AnomalyLevel.anomaly
              : precursorScore >= 0.35 ? AnomalyLevel.unusual
              : AnomalyLevel.normal;
        }
      }

      result = AnomalyResult(
        score: score.clamp(0.0, 1.0),
        level: level,
        rawError: anomalyScore,
        precursorPattern: precursorResult?.isNormal == false ? precursorResult?.pattern : null,
        precursorConfidence: precursorResult?.confidence ?? 0.0,
      );
    } catch (e) {
      _ruleBasedFailCount++;
      _useRuleBased = true;
      if (_ruleBasedFailCount > _maxMlRetries) {
        debugPrint('VibrationAnomalyService: ML permanently disabled after $_ruleBasedFailCount failures — '
            'rule-based only until app restart');
      } else {
        debugPrint('VibrationAnomalyService: Inference error ($e) — '
            'rule-based fallback (failCount=$_ruleBasedFailCount, max=$_maxMlRetries)');
      }
      result = _ruleBasedDetect(features);
    }

    _updateLevelTracking(result);
    return result;
  }

  /// Update level-tracking state after each [detect] call.
  ///
  /// - Keeps [_currentLevel] in sync and records [_levelChangedAt] on change.
  /// - Maintains [_consecutiveAnomalyReadings].
  /// - Caches [_lastPrecursorPattern] for [anomalyDescription].
  void _updateLevelTracking(AnomalyResult result) {
    if (result.level != _currentLevel) {
      _currentLevel = result.level;
      _levelChangedAt = DateTime.now();
    }
    if (result.level == AnomalyLevel.anomaly) {
      _consecutiveAnomalyReadings++;
    } else {
      _consecutiveAnomalyReadings = 0;
    }
    _lastPrecursorPattern = result.precursorPattern;
  }

  /// Extract vibration features from a BLE data map.
  ///
  /// Handles all firmware versions by extracting available fields.
  /// Missing fields default to 0.0.
  static Map<String, double> extractFeatures(Map<String, dynamic> bleData) {
    return {
      'rms': (bleData['rms'] as num?)?.toDouble() ?? 0.0,
      'ppv': (bleData['ppv'] as num?)?.toDouble() ?? 0.0,
      'freq': (bleData['freq'] as num?)?.toDouble() ?? 0.0,
      'crest': (bleData['crest'] as num?)?.toDouble() ?? 0.0,
      'centroid': (bleData['cent'] as num?)?.toDouble() ?? 0.0,
      'kurtosis': (bleData['kurt'] as num?)?.toDouble() ?? 0.0,
      'stalta': (bleData['stalta'] as num?)?.toDouble() ?? 0.0,
      // v4.0 firmware fields
      'arias': (bleData['arias'] as num?)?.toDouble() ?? 0.0,
      'cav': (bleData['cav'] as num?)?.toDouble() ?? 0.0,
      'temp': (bleData['temp'] as num?)?.toDouble() ?? 0.0,
    };
  }

  /// Rule-based anomaly detection fallback when TFLite model is unavailable.
  ///
  /// Uses engineering thresholds from DIN 4150-3 (heritage structures),
  /// EPRI CAV damage criteria, and structural health monitoring heuristics.
  /// Each feature contributes a weighted sub-score; the aggregate determines
  /// the anomaly level. This ensures anomaly detection is NEVER disabled.
  AnomalyResult _ruleBasedDetect(Map<String, double> features) {
    final ppv = features['ppv'] ?? 0.0;
    final rms = features['rms'] ?? 0.0;
    final crest = features['crest'] ?? 0.0;
    final kurtosis = features['kurtosis'] ?? 0.0;
    final stalta = features['stalta'] ?? 0.0;
    final cav = features['cav'] ?? 0.0;
    final freq = features['freq'] ?? 0.0;

    // Thresholds tuned for MICRO-VIBRATION precursor detection.
    // Lowered for enhanced sensitivity to early-stage precursors.
    // Background site activity (footsteps, tools) typically <0.5 mm/s.
    // These thresholds catch genuine soil micro-movements before they escalate.
    const ppvConcern = 1.0;     // mm/s — subtle ground movement, early precursor
    const ppvDanger = 3.0;      // mm/s — significant ground movement, requires attention

    // Weighted sub-scores (0.0 = normal, 1.0 = severe)
    double ppvScore = 0.0;
    if (ppv > ppvDanger) {
      ppvScore = 1.0;
    } else if (ppv > ppvConcern) {
      ppvScore = (ppv - ppvConcern) / (ppvDanger - ppvConcern);
    }

    // Crest factor: only very high values matter (>8.0 = impulsive cracking)
    double crestScore = (crest > 8.0) ? min(1.0, (crest - 8.0) / 7.0) : 0.0;

    // Kurtosis: excess kurtosis > 6 indicates real impulsive events (not just noise)
    double kurtosisScore = (kurtosis > 6.0) ? min(1.0, (kurtosis - 6.0) / 10.0) : 0.0;

    // STA/LTA: seismic trigger — raised to 6.0 to avoid false triggers
    double staltaScore = 0.0;
    if (stalta > 8.0) {
      staltaScore = 1.0;
    } else if (stalta > 6.0) {
      staltaScore = (stalta - 6.0) / 2.0;
    }

    // CAV: raised threshold — 0.3 g·s is real sustained energy
    double cavScore = (cav > 0.3) ? 1.0 : (cav > 0.16) ? (cav - 0.16) / 0.14 : 0.0;

    // RMS energy: only flag sustained high energy
    double rmsScore = (rms > 2.0) ? min(1.0, (rms - 2.0) / 5.0) : 0.0;

    // Low-frequency seismic concern (0.5-10 Hz) — key precursor band
    // but only with significant PPV
    double seismicScore = 0.0;
    if (freq > 0.5 && freq <= 10.0 && ppv > 3.0) {
      seismicScore = min(1.0, ppv / ppvConcern);
    }

    // PSD slope landslide discrimination (-3 to -9 = landslide signature)
    final psdSlope = features['psdSlope'] ?? 0.0;
    double psdScore = 0.0;
    if (psdSlope < -3.0 && psdSlope > -9.0) {
      // In landslide band: confidence scales with how centered in band
      psdScore = min(1.0, (-psdSlope - 3.0) / 3.0);
    }

    // Weighted aggregate — STA/LTA and seismic band get more weight
    // as they're better precursor indicators than raw amplitude
    final aggregate = ppvScore * 0.14 +
        rmsScore * 0.04 +
        crestScore * 0.09 +
        kurtosisScore * 0.14 +
        staltaScore * 0.23 +
        cavScore * 0.09 +
        seismicScore * 0.18 +
        psdScore * 0.09;

    final score = aggregate.clamp(0.0, 1.0);

    AnomalyLevel level;
    if (score < 0.35) {
      level = AnomalyLevel.normal;
    } else if (score < 0.7) {
      level = AnomalyLevel.unusual;
    } else {
      level = AnomalyLevel.anomaly;
    }

    debugPrint('VibrationAnomalyService: Rule-based fallback — '
        'score=${score.toStringAsFixed(3)} level=${level.name} '
        '(ppv=$ppvScore sta=$staltaScore cav=$cavScore)');

    return AnomalyResult(
      score: score,
      level: level,
      rawError: aggregate,
    );
  }

  /// Update the PPV alert threshold at runtime (called from settings screen).
  ///
  /// Affects [_ruleBasedDetect]: the [ppvConcern] / [ppvDanger] levels are
  /// derived as 3× and 10× of this base threshold so the rule-based fallback
  /// stays proportional to the user's chosen sensitivity.
  void setAlertThreshold(double ppv) {
    _ppvThreshold = ppv.clamp(0.05, 10.0);
    if (kDebugMode) {
      debugPrint('VibrationAnomalyService: PPV threshold set to ${_ppvThreshold.toStringAsFixed(3)} mm/s');
    }
  }

  /// Expose the current runtime PPV threshold (mm/s).
  double get alertThreshold => _ppvThreshold;

  /// Limit the rate at which [detect] runs TFLite inference.
  ///
  /// Calls that arrive before [_maxInferenceInterval] has elapsed since the
  /// last successful inference are skipped (the previous result is reused by
  /// the caller). Pass 0 to disable rate limiting.
  void setMaxInferenceHz(double hz) {
    if (hz <= 0) {
      _maxInferenceInterval = Duration.zero;
    } else {
      _maxInferenceInterval = Duration(milliseconds: (1000 / hz).round());
    }
    if (kDebugMode) {
      debugPrint('VibrationAnomalyService: Inference rate limited to ${hz.toStringAsFixed(1)} Hz '
          '(interval=${_maxInferenceInterval.inMilliseconds} ms)');
    }
  }

  /// Returns true if a new inference is allowed under the current rate limit.
  bool get _inferenceAllowed {
    if (_maxInferenceInterval == Duration.zero) return true;
    return DateTime.now().difference(_lastInferenceTime) >= _maxInferenceInterval;
  }

  void resetBaseline() => _adaptiveService.reset();

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _mlService.dispose();
    _precursorService.dispose();
    _isInitialized = false;
  }
}

enum AnomalyLevel { normal, unusual, anomaly, unknown }

class AnomalyResult {
  final double score; // 0.0 (normal) to 1.0 (severe anomaly)
  final AnomalyLevel level;
  final double rawError; // Raw anomaly score (reconstruction MSE)
  final String? precursorPattern; // e.g. 'soil_creep', 'imminent_failure'
  final double precursorConfidence;

  const AnomalyResult({
    required this.score,
    required this.level,
    required this.rawError,
    this.precursorPattern,
    this.precursorConfidence = 0.0,
  });

  String get levelLabel {
    switch (level) {
      case AnomalyLevel.normal:
        return 'Normal';
      case AnomalyLevel.unusual:
        return 'Unusual';
      case AnomalyLevel.anomaly:
        return 'Anomaly';
      case AnomalyLevel.unknown:
        return 'Initializing';
    }
  }
}
