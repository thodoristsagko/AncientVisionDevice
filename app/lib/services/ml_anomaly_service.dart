import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io';
import '../models/site_profile.dart';
import '../utils/circular_buffer.dart';
import 'inference_timing_service.dart';

/// Manages the autoencoder TFLite model for anomaly detection.
///
/// Two modes:
/// 1. Default: uses base model with shipped scaler/thresholds
/// 2. Calibrated: uses site-specific scaler/thresholds from SiteProfile
class MlAnomalyService {
  Interpreter? _interpreter;
  bool _isLoaded = false;

  static const featureNames = [
    'rms', 'ppv', 'freq', 'crest', 'centroid', 'kurtosis',
    'stalta', 'arias', 'cav', 'temp', 'psdSlope'
  ];
  static const int inputDim = 11;

  List<double> _scalerMean = [];
  List<double> _scalerStd = [];
  double _thresholdLow = 1.0;
  double _thresholdHigh = 2.5;
  String _modelVersion = 'unknown';
  String _modelFingerprint = '';

  bool _isCalibrating = false;
  final List<List<double>> _calibrationSamples = [];
  static const int minCalibrationSamples = 600;

  SiteProfile? _activeSiteProfile;

  // Error tracking for inference health monitoring
  String? _lastError;
  bool _lastInferenceSucceeded = true;
  int _errorCount = 0;
  static const int _maxErrorCount = 3;

  // Sliding-window anomaly score smoothing (EMA, α=0.3)
  static const double _emaAlpha = 0.3;
  double _smoothedScore = 0.0;

  // Consecutive anomaly frame counter
  int _consecutiveAnomalyFrames = 0;

  // Score history circular buffer (last 100 scores)
  static const int _scoreHistorySize = 100;
  final CircularBuffer<double> _scoreHistory =
      CircularBuffer<double>(_scoreHistorySize);

  bool get isLoaded => _isLoaded;
  bool get isCalibrating => _isCalibrating;
  bool get isCalibrated => _activeSiteProfile != null;
  int get calibrationSampleCount => _calibrationSamples.length;
  double get calibrationProgress =>
      (_calibrationSamples.length / minCalibrationSamples).clamp(0.0, 1.0);
  SiteProfile? get activeSiteProfile => _activeSiteProfile;

  /// Most recent inference error message, or null if last inference succeeded.
  String? get lastError => _lastError;

  /// True if the last inference completed without error.
  bool get isHealthy => _lastInferenceSucceeded;

  /// Exponentially smoothed anomaly score (α=0.3). Updated on each [infer] call.
  double get smoothedScore => _smoothedScore;

  /// Number of consecutive frames whose raw anomaly score exceeded [_thresholdHigh].
  /// Resets to zero as soon as a frame falls below that threshold.
  int get consecutiveAnomalyFrames => _consecutiveAnomalyFrames;

  /// Last 100 raw anomaly scores returned by [infer], oldest first.
  List<double> get scoreHistory => _scoreHistory.toList();

  /// Variance of [scoreHistory]. Returns 0 when fewer than two samples exist.
  double get scoreVariance {
    final history = _scoreHistory.toList();
    if (history.length < 2) return 0.0;
    final mean = history.reduce((a, b) => a + b) / history.length;
    final sumSq = history.fold<double>(
        0.0, (acc, v) => acc + (v - mean) * (v - mean));
    return sumSq / history.length;
  }

  Future<bool> initialize() async {
    try {
      // Load raw bytes first so we can compute a fingerprint before building the interpreter.
      final modelBytes = await rootBundle.load('assets/ml/vibration_anomaly.tflite');
      final byteList = modelBytes.buffer.asUint8List();
      final modelByteLen = byteList.length;
      // Fingerprint: byte length + hex of first 16 bytes
      final prefix = byteList.sublist(0, byteList.length < 16 ? byteList.length : 16);
      final prefixHex = prefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _modelFingerprint = '${modelByteLen}_$prefixHex';
      if (kDebugMode) {
        debugPrint('[ML] MlAnomalyService: model loaded $modelByteLen bytes, fingerprint=$_modelFingerprint');
      }

      _interpreter = Interpreter.fromBuffer(byteList);

      final scalerJson = await rootBundle.loadString('assets/ml/vibration_scaler.json');
      final scaler = jsonDecode(scalerJson) as Map<String, dynamic>;
      _scalerMean = (scaler['mean'] as List).map((e) => (e as num).toDouble()).toList();
      _scalerStd = (scaler['scale'] as List).map((e) => (e as num).toDouble()).toList();

      final configJson = await rootBundle.loadString('assets/ml/vibration_model_config.json');
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      _modelVersion = config['model_version']?.toString() ?? 'unknown';
      final thresholds = config['thresholds'] as Map<String, dynamic>? ?? {};
      _thresholdLow = (thresholds['threshold_low'] as num?)?.toDouble() ?? 1.0;
      _thresholdHigh = (thresholds['threshold_high'] as num?)?.toDouble() ?? 2.5;

      // P70: fingerprint check against config (if present)
      final expectedFingerprint = config['model_fingerprint']?.toString();
      if (expectedFingerprint != null && expectedFingerprint.isNotEmpty) {
        if (_modelFingerprint != expectedFingerprint) {
          if (kDebugMode) {
            debugPrint('[WARNING] MlAnomalyService: model fingerprint mismatch '
                '— model may have changed. '
                'Expected=$expectedFingerprint actual=$_modelFingerprint');
          }
        } else {
          if (kDebugMode) debugPrint('[ML] MlAnomalyService: fingerprint OK');
        }
      }

      // Validate scaler dimensions match model input
      if (_scalerMean.length != inputDim || _scalerStd.length != inputDim) {
        if (kDebugMode) debugPrint('MlAnomalyService: scaler dimension mismatch (mean=${_scalerMean.length}, std=${_scalerStd.length}, expected=$inputDim)');
        _isLoaded = false;
        return false;
      }

      _isLoaded = true;
      if (kDebugMode) debugPrint('MlAnomalyService: loaded v$_modelVersion');

      // P49: Model warm-up — run one dummy inference to pre-warm the TFLite interpreter
      // so the first real inference does not incur JIT/cache-miss latency.
      try {
        final dummyInput = [List<double>.filled(inputDim, 0.0)];
        final dummyOutput = [List<double>.filled(inputDim, 0.0)];
        _interpreter!.run(dummyInput, dummyOutput);
        if (kDebugMode) debugPrint('MlAnomalyService: warm-up complete');
      } catch (e) {
        if (kDebugMode) debugPrint('MlAnomalyService: warm-up failed (non-fatal): $e');
      }

      return true;
    } catch (e) {
      _isLoaded = false;
      if (kDebugMode) debugPrint('MlAnomalyService: load failed: $e');
      return false;
    }
  }

  double? infer(Map<String, double> features) {
    if (!_isLoaded || _interpreter == null) return null;
    try {
      final input = List<double>.filled(inputDim, 0.0);
      for (int i = 0; i < featureNames.length; i++) {
        final value = features[featureNames[i]] ?? 0.0;
        if (i < _scalerStd.length && _scalerStd[i] != 0) {
          input[i] = (value - _scalerMean[i]) / _scalerStd[i];
        } else {
          input[i] = value;
        }
      }
      final inputTensor = [input];
      final outputTensor = [List<double>.filled(inputDim, 0.0)];
      final inferenceSw = Stopwatch()..start();
      _interpreter!.run(inputTensor, outputTensor);
      inferenceSw.stop();
      InferenceTimingService.instance.record(inferenceSw.elapsedMilliseconds.toDouble());

      double mse = 0;
      for (int i = 0; i < inputDim; i++) {
        final diff = input[i] - outputTensor[0][i];
        mse += diff * diff;
      }
      mse /= inputDim;

      // Inference succeeded — clear error state
      _lastInferenceSucceeded = true;
      _lastError = null;
      _errorCount = 0;

      double score;
      if (mse < _thresholdLow) {
        score = (mse / _thresholdLow).clamp(0.0, 1.0);
      } else if (mse < _thresholdHigh) {
        score = (0.5 + 0.5 * (mse - _thresholdLow) / (_thresholdHigh - _thresholdLow)).clamp(0.0, 1.0);
      } else {
        score = min(1.0, mse / (_thresholdHigh * 2));
      }

      // Update EMA smoothed score
      _smoothedScore = _emaAlpha * score + (1.0 - _emaAlpha) * _smoothedScore;

      // Update consecutive anomaly frame counter (threshold on raw MSE)
      if (mse >= _thresholdHigh) {
        _consecutiveAnomalyFrames++;
      } else {
        _consecutiveAnomalyFrames = 0;
      }

      // Append to score history
      _scoreHistory.add(score);

      return score;
    } catch (e) {
      _lastInferenceSucceeded = false;
      _errorCount++;

      // Categorise error type for actionable diagnostics
      String errorType;
      if (e.toString().contains('not allocated') || e.toString().contains('InterpreterNotAllocated')) {
        errorType = 'interpreter not allocated';
      } else if (e.toString().contains('shape') || e.toString().contains('dimension')) {
        errorType = 'input shape mismatch (expected $inputDim features)';
      } else if (e.toString().contains('null')) {
        errorType = 'null interpreter handle';
      } else {
        errorType = e.toString();
      }
      _lastError = errorType;

      if (kDebugMode) {
        debugPrint('MlAnomalyService: inference error [$errorType] '
            '(count=$_errorCount/$_maxErrorCount)');
      }

      // Disable after repeated failures to avoid log spam and trigger re-init
      if (_errorCount >= _maxErrorCount) {
        _isLoaded = false;
        if (kDebugMode) {
          debugPrint('MlAnomalyService: disabled after $_errorCount consecutive '
              'errors — call initialize() to reload');
        }
      }

      return null;
    }
  }

  void startCalibration() {
    _isCalibrating = true;
    _calibrationSamples.clear();
  }

  void feedCalibrationSample(Map<String, double> features) {
    if (!_isCalibrating) return;
    _calibrationSamples.add(featureNames.map((n) => features[n] ?? 0.0).toList());
  }

  SiteProfile? finishCalibration(String siteName) {
    _isCalibrating = false;
    if (_calibrationSamples.length < minCalibrationSamples) return null;
    // Validate sample dimensions
    if (_calibrationSamples.any((s) => s.length != inputDim)) {
      if (kDebugMode) debugPrint('MlAnomalyService: calibration samples have inconsistent dimensions');
      return null;
    }
    final n = _calibrationSamples.length;
    final mean = List<double>.filled(inputDim, 0.0);
    final std = List<double>.filled(inputDim, 0.0);
    for (int f = 0; f < inputDim; f++) {
      double sum = 0, sumSq = 0;
      for (int s = 0; s < n; s++) {
        sum += _calibrationSamples[s][f];
        sumSq += _calibrationSamples[s][f] * _calibrationSamples[s][f];
      }
      mean[f] = sum / n;
      final variance = (sumSq / n) - (mean[f] * mean[f]);
      std[f] = variance > 0 ? sqrt(variance) : 1.0;
    }
    final errors = <double>[];
    for (final sample in _calibrationSamples) {
      final normalized = List<double>.filled(inputDim, 0.0);
      for (int i = 0; i < inputDim; i++) {
        normalized[i] = (sample[i] - mean[i]) / std[i];
      }
      final output = [List<double>.filled(inputDim, 0.0)];
      _interpreter!.run([normalized], output);
      double mse = 0;
      for (int i = 0; i < inputDim; i++) {
        final diff = normalized[i] - output[0][i];
        mse += diff * diff;
      }
      errors.add(mse / inputDim);
    }
    final errMean = errors.reduce((a, b) => a + b) / errors.length;
    double errStd = 0;
    for (final e in errors) {
      errStd += (e - errMean) * (e - errMean);
    }
    errStd = sqrt(errStd / errors.length);
    final ppvIdx = featureNames.indexOf('ppv');
    final ppvCV = std[ppvIdx] / (mean[ppvIdx].abs() + 1e-10);

    final profile = SiteProfile(
      name: siteName,
      createdAt: DateTime.now(),
      modelVersion: _modelVersion,
      scalerMean: mean,
      scalerStd: std,
      thresholdLow: errMean + 2 * errStd,
      thresholdHigh: errMean + 4 * errStd,
      sampleCount: n,
      ppvCoefficientOfVariation: ppvCV,
    );
    applySiteProfile(profile);
    _calibrationSamples.clear();
    return profile;
  }

  void cancelCalibration() {
    _isCalibrating = false;
    _calibrationSamples.clear();
  }

  void applySiteProfile(SiteProfile profile) {
    _activeSiteProfile = profile;
    _scalerMean = List.from(profile.scalerMean);
    _scalerStd = List.from(profile.scalerStd);
    _thresholdLow = profile.thresholdLow;
    _thresholdHigh = profile.thresholdHigh;
    if (kDebugMode) {
      debugPrint('MlAnomalyService: applied site "${profile.name}" '
          '(${profile.sampleCount} samples)');
    }
  }

  Future<void> saveSiteProfile(SiteProfile profile) async {
    final dir = await getApplicationDocumentsDirectory();
    final profileDir = Directory('${dir.path}/site_profiles');
    if (!profileDir.existsSync()) profileDir.createSync(recursive: true);
    final file = File('${profileDir.path}/${profile.name}.json');
    await file.writeAsString(profile.encode());
  }

  Future<List<SiteProfile>> loadSiteProfiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final profileDir = Directory('${dir.path}/site_profiles');
    if (!profileDir.existsSync()) return [];
    final profiles = <SiteProfile>[];
    for (final file in profileDir.listSync().whereType<File>()) {
      if (file.path.endsWith('.json')) {
        try {
          profiles.add(SiteProfile.decode(await file.readAsString()));
        } catch (_) {}
      }
    }
    profiles.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return profiles;
  }

  Future<void> deleteSiteProfile(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/site_profiles/$name.json');
    if (file.existsSync()) await file.delete();
    if (_activeSiteProfile?.name == name) _activeSiteProfile = null;
  }

  /// Calibrates [_thresholdHigh] (95th percentile) and [_thresholdLow]
  /// (85th percentile) from a list of reconstruction-error scores recorded
  /// during a normal-vibration baseline period.
  ///
  /// Scores are expected to be the raw MSE values produced by the autoencoder
  /// (not the normalised 0-1 anomaly scores returned by [infer]).
  ///
  /// Throws [ArgumentError] when [normalScores] is empty.
  Future<void> calibrateThresholds(List<double> normalScores) async {
    if (normalScores.isEmpty) {
      throw ArgumentError('normalScores must not be empty');
    }
    final sorted = List<double>.from(normalScores)..sort();
    final n = sorted.length;

    // Linear-interpolation percentile helper
    double percentile(double p) {
      final idx = p / 100.0 * (n - 1);
      final lo = idx.floor();
      final hi = idx.ceil();
      if (lo == hi) return sorted[lo];
      final frac = idx - lo;
      return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
    }

    _thresholdLow = percentile(85);
    _thresholdHigh = percentile(95);

    // Keep thresholds sensible: high must exceed low
    if (_thresholdHigh <= _thresholdLow) {
      _thresholdHigh = _thresholdLow * 1.5;
    }

    if (kDebugMode) {
      debugPrint('MlAnomalyService: calibrateThresholds '
          'low=${_thresholdLow.toStringAsFixed(4)} '
          'high=${_thresholdHigh.toStringAsFixed(4)} '
          '(n=${normalScores.length})');
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
