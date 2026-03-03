import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io';
import '../models/site_profile.dart';

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

  bool _isCalibrating = false;
  final List<List<double>> _calibrationSamples = [];
  static const int minCalibrationSamples = 600;

  SiteProfile? _activeSiteProfile;

  bool get isLoaded => _isLoaded;
  bool get isCalibrating => _isCalibrating;
  bool get isCalibrated => _activeSiteProfile != null;
  int get calibrationSampleCount => _calibrationSamples.length;
  double get calibrationProgress =>
      (_calibrationSamples.length / minCalibrationSamples).clamp(0.0, 1.0);
  SiteProfile? get activeSiteProfile => _activeSiteProfile;

  Future<bool> initialize() async {
    try {
      _interpreter = await Interpreter.fromAsset('ml/vibration_anomaly.tflite');
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

      // Validate scaler dimensions match model input
      if (_scalerMean.length != inputDim || _scalerStd.length != inputDim) {
        if (kDebugMode) debugPrint('MlAnomalyService: scaler dimension mismatch (mean=${_scalerMean.length}, std=${_scalerStd.length}, expected=$inputDim)');
        _isLoaded = false;
        return false;
      }

      _isLoaded = true;
      if (kDebugMode) debugPrint('MlAnomalyService: loaded v$_modelVersion');
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
      _interpreter!.run(inputTensor, outputTensor);

      double mse = 0;
      for (int i = 0; i < inputDim; i++) {
        final diff = input[i] - outputTensor[0][i];
        mse += diff * diff;
      }
      mse /= inputDim;

      if (mse < _thresholdLow) {
        return (mse / _thresholdLow).clamp(0.0, 1.0);
      } else if (mse < _thresholdHigh) {
        return (0.5 + 0.5 * (mse - _thresholdLow) / (_thresholdHigh - _thresholdLow)).clamp(0.0, 1.0);
      } else {
        return min(1.0, mse / (_thresholdHigh * 2));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MlAnomalyService: inference error: $e');
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

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
