import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Classifies vibration patterns into precursor categories.
class PrecursorClassifierService {
  Interpreter? _interpreter;
  bool _isLoaded = false;
  List<String> _classNames = ['normal', 'soil_creep', 'crack_propagation', 'imminent_failure'];
  List<double> _scalerMean = [];
  List<double> _scalerStd = [];
  static const int _inputDim = 17;

  bool get isLoaded => _isLoaded;

  Future<bool> initialize() async {
    try {
      _interpreter = await Interpreter.fromAsset('ml/precursor_classifier.tflite');
      final configJson = await rootBundle.loadString('assets/ml/precursor_classifier_config.json');
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      _classNames = (config['class_names'] as List).map((e) => e.toString()).toList();

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
      _interpreter!.run([input], outputTensor);

      final probs = outputTensor[0];
      int maxIdx = 0;
      double maxProb = probs[0];
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > maxProb) { maxProb = probs[i]; maxIdx = i; }
      }
      return PrecursorResult(
        pattern: _classNames[maxIdx],
        confidence: maxProb.clamp(0.0, 1.0),
        probabilities: Map.fromIterables(_classNames, probs),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('PrecursorClassifier: inference error: $e');
      return null;
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
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
