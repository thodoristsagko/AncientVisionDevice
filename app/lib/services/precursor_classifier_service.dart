import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'inference_timing_service.dart';

/// Classifies vibration patterns into precursor categories.
class PrecursorClassifierService {
  Interpreter? _interpreter;
  bool _isLoaded = false;
  List<String> _classNames = ['normal', 'soil_creep', 'crack_propagation', 'imminent_failure'];
  List<double> _scalerMean = [];
  List<double> _scalerStd = [];
  static const int _inputDim = 17;
  String _modelFingerprint = '';

  // Error tracking for inference health monitoring
  String? _lastError;
  bool _lastInferenceSucceeded = true;
  int _errorCount = 0;
  static const int _maxErrorCount = 3;

  // ── Result state for the most recent successful inference ─────────────────
  Map<String, double> _lastProbabilities = {};

  // ── Result history — last 5 dominant classes ──────────────────────────────
  static const int _historySize = 5;
  final List<String> _patternHistory = [];

  bool get isLoaded => _isLoaded;

  /// Most recent inference error message, or null if last inference succeeded.
  String? get lastError => _lastError;

  /// True if the last inference completed without error.
  bool get isHealthy => _lastInferenceSucceeded;

  // ── New getters ───────────────────────────────────────────────────────────

  /// Probabilities from the most recent inference mapped to class names.
  /// Returns an empty map when no inference has been run yet.
  Map<String, double> get classConfidences => Map.unmodifiable(_lastProbabilities);

  /// The class name with the highest probability from the last inference,
  /// or null if no inference has been run yet.
  String? get dominantClass {
    if (_lastProbabilities.isEmpty) return null;
    return _lastProbabilities.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
  }

  /// Shannon entropy of the probability distribution from the last inference.
  ///
  /// A value close to 0 means the model is confident; a high value means the
  /// model is uncertain (probability spread across multiple classes).
  /// Returns 0.0 when no inference has been run yet.
  double get uncertainty {
    if (_lastProbabilities.isEmpty) return 0.0;
    double entropy = 0.0;
    for (final p in _lastProbabilities.values) {
      if (p > 0) entropy -= p * math.log(p);
    }
    return entropy;
  }

  /// The last [_historySize] dominant-class names from recent inferences,
  /// oldest first.  May contain fewer than [_historySize] entries if not
  /// enough inferences have been run yet.
  List<String> get recentPatterns => List.unmodifiable(_patternHistory);

  Future<bool> initialize() async {
    try {
      // Load raw bytes first to compute fingerprint before building the interpreter.
      final modelBytes = await rootBundle.load('assets/ml/precursor_classifier.tflite');
      final byteList = modelBytes.buffer.asUint8List();
      final modelByteLen = byteList.length;
      final prefix = byteList.sublist(0, byteList.length < 16 ? byteList.length : 16);
      final prefixHex = prefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _modelFingerprint = '${modelByteLen}_$prefixHex';
      if (kDebugMode) {
        debugPrint('[ML] PrecursorClassifier: model loaded $modelByteLen bytes, fingerprint=$_modelFingerprint');
      }

      _interpreter = Interpreter.fromBuffer(byteList);

      final configJson = await rootBundle.loadString('assets/ml/precursor_classifier_config.json');
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      _classNames = (config['class_names'] as List).map((e) => e.toString()).toList();

      // P70: fingerprint check against config (if present)
      final expectedFingerprint = config['model_fingerprint']?.toString();
      if (expectedFingerprint != null && expectedFingerprint.isNotEmpty) {
        if (_modelFingerprint != expectedFingerprint) {
          if (kDebugMode) {
            debugPrint('[WARNING] PrecursorClassifier: model fingerprint mismatch '
                '— model may have changed. '
                'Expected=$expectedFingerprint actual=$_modelFingerprint');
          }
        } else {
          if (kDebugMode) debugPrint('[ML] PrecursorClassifier: fingerprint OK');
        }
      }

      // Load scaler for input normalization
      try {
        final scalerJson = await rootBundle.loadString('assets/ml/precursor_classifier_scaler.json');
        final scaler = jsonDecode(scalerJson) as Map<String, dynamic>;
        _scalerMean = (scaler['mean'] as List).map((e) => (e as num).toDouble()).toList();
        _scalerStd = (scaler['scale'] as List).map((e) => (e as num).toDouble()).toList();
        if (_scalerMean.length != _inputDim || _scalerStd.length != _inputDim) {
          if (kDebugMode) debugPrint('PrecursorClassifier: scaler dimension mismatch, ignoring');
          _scalerMean = [];
          _scalerStd = [];
        }
      } catch (e) {
        if (kDebugMode) debugPrint('PrecursorClassifier: scaler not found, running without normalization: $e');
      }

      _isLoaded = true;
      if (kDebugMode) debugPrint('PrecursorClassifier: loaded (${_classNames.length} classes, scaler=${_scalerMean.isNotEmpty})');

      // P49: Model warm-up — run one dummy inference to pre-warm the TFLite interpreter
      // so the first real classification call does not incur JIT/cache-miss latency.
      try {
        final dummyInput = [List<double>.filled(_inputDim, 0.0)];
        final dummyOutput = [List<double>.filled(_classNames.length, 0.0)];
        _interpreter!.run(dummyInput, dummyOutput);
        if (kDebugMode) debugPrint('PrecursorClassifier: warm-up complete');
      } catch (e) {
        if (kDebugMode) debugPrint('PrecursorClassifier: warm-up failed (non-fatal): $e');
      }

      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('PrecursorClassifier: load failed: $e');
      return false;
    }
  }

  PrecursorResult? classify({
    required Map<String, double> dspFeatures,
    required Map<String, double> trendFeatures,
    required double autoencoderScore,
  }) {
    if (!_isLoaded || _interpreter == null) return null;
    try {
      final raw = <double>[
        dspFeatures['rms'] ?? 0, dspFeatures['ppv'] ?? 0, dspFeatures['freq'] ?? 0,
        dspFeatures['crest'] ?? 0, dspFeatures['centroid'] ?? 0, dspFeatures['kurtosis'] ?? 0,
        dspFeatures['stalta'] ?? 0, dspFeatures['arias'] ?? 0, dspFeatures['cav'] ?? 0,
        dspFeatures['temp'] ?? 0, dspFeatures['psdSlope'] ?? 0,
        trendFeatures['ppv_trend'] ?? 1.0, trendFeatures['freq_trend'] ?? 1.0,
        trendFeatures['kurtosis_trend'] ?? 1.0, trendFeatures['stalta_trend'] ?? 1.0,
        trendFeatures['cusum_max'] ?? 0.0, autoencoderScore,
      ];
      // Apply scaler normalization if available
      final input = _scalerMean.isNotEmpty
          ? List<double>.generate(raw.length, (i) =>
              i < _scalerStd.length && _scalerStd[i] != 0
                  ? (raw[i] - _scalerMean[i]) / _scalerStd[i]
                  : raw[i])
          : raw;
      final outputTensor = [List<double>.filled(_classNames.length, 0.0)];
      final inferenceSw = Stopwatch()..start();
      _interpreter!.run([input], outputTensor);
      inferenceSw.stop();
      InferenceTimingService.instance.record(inferenceSw.elapsedMilliseconds.toDouble());

      final probs = outputTensor[0];
      int maxIdx = 0;
      double maxProb = probs[0];
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > maxProb) { maxProb = probs[i]; maxIdx = i; }
      }

      // Inference succeeded — clear error state and persist result state.
      _lastInferenceSucceeded = true;
      _lastError = null;
      _errorCount = 0;

      _lastProbabilities = Map.fromIterables(_classNames, probs);

      // Update pattern history (fixed size, oldest entry evicted first).
      _patternHistory.add(_classNames[maxIdx]);
      if (_patternHistory.length > _historySize) {
        _patternHistory.removeAt(0);
      }

      return PrecursorResult(
        pattern: _classNames[maxIdx],
        confidence: maxProb.clamp(0.0, 1.0),
        probabilities: _lastProbabilities,
      );
    } catch (e) {
      _lastInferenceSucceeded = false;
      _errorCount++;

      // Categorise error type for actionable diagnostics
      String errorType;
      if (e.toString().contains('not allocated') || e.toString().contains('InterpreterNotAllocated')) {
        errorType = 'interpreter not allocated';
      } else if (e.toString().contains('shape') || e.toString().contains('dimension')) {
        errorType = 'input shape mismatch (expected $_inputDim features, '
            '${_classNames.length} output classes)';
      } else if (e.toString().contains('null')) {
        errorType = 'null interpreter handle';
      } else {
        errorType = e.toString();
      }
      _lastError = errorType;

      if (kDebugMode) {
        debugPrint('PrecursorClassifier: inference error [$errorType] '
            '(count=$_errorCount/$_maxErrorCount)');
      }

      // Disable after repeated failures to avoid log spam and trigger re-init
      if (_errorCount >= _maxErrorCount) {
        _isLoaded = false;
        if (kDebugMode) {
          debugPrint('PrecursorClassifier: disabled after $_errorCount consecutive '
              'errors — call initialize() to reload');
        }
      }

      return null;
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
    _lastProbabilities = {};
    _patternHistory.clear();
  }
}

class PrecursorResult {
  final String pattern;
  final double confidence;
  final Map<String, double> probabilities;

  const PrecursorResult({
    required this.pattern,
    required this.confidence,
    required this.probabilities,
  });

  bool get isNormal => pattern == 'normal';
  bool get isDangerous => pattern == 'imminent_failure' && confidence > 0.5;

  double get anomalyScore {
    if (isNormal) return (1.0 - confidence) * 0.3;
    return confidence;
  }
}
