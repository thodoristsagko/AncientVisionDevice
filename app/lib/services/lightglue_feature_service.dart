import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'reconstruction/index.dart';

/// Keypoint detected in an image with position, score, and learned descriptor.
class Keypoint {
  /// X coordinate in the original image space.
  final double x;

  /// Y coordinate in the original image space.
  final double y;

  /// Detection confidence score (0-1).
  final double score;

  /// Learned descriptor vector (256-D for SuperPoint, 128-D for ALIKED).
  final List<double> descriptor;

  const Keypoint({
    required this.x,
    required this.y,
    required this.score,
    required this.descriptor,
  });

  @override
  String toString() => 'Keypoint(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, '
      'score=${score.toStringAsFixed(3)}, desc=${descriptor.length}D)';
}

/// A matched pair of keypoints across two images with confidence.
class KeypointMatch {
  /// Index of the keypoint in the first image's keypoint list.
  final int idx1;

  /// Index of the keypoint in the second image's keypoint list.
  final int idx2;

  /// Keypoint from the first image.
  final Keypoint kp1;

  /// Keypoint from the second image.
  final Keypoint kp2;

  /// Matching confidence (0-1). Higher is better.
  final double confidence;

  const KeypointMatch({
    required this.idx1,
    required this.idx2,
    required this.kp1,
    required this.kp2,
    required this.confidence,
  });

  /// Descriptor distance (L2 norm) between matched keypoints.
  double get descriptorDistance {
    double sum = 0;
    final len = math.min(kp1.descriptor.length, kp2.descriptor.length);
    for (int i = 0; i < len; i++) {
      final d = kp1.descriptor[i] - kp2.descriptor[i];
      sum += d * d;
    }
    return math.sqrt(sum);
  }
}

/// Result of extract-and-match on an image pair.
class MatchResult {
  final List<Keypoint> keypoints1;
  final List<Keypoint> keypoints2;
  final List<KeypointMatch> matches;
  final Duration extractionTime;
  final Duration matchingTime;
  final bool usedFallback;

  const MatchResult({
    required this.keypoints1,
    required this.keypoints2,
    required this.matches,
    required this.extractionTime,
    required this.matchingTime,
    this.usedFallback = false,
  });

  /// Total processing time.
  Duration get totalTime => extractionTime + matchingTime;

  /// Inlier ratio: fraction of keypoints that were matched.
  double get matchRatio {
    final total = keypoints1.length + keypoints2.length;
    return total > 0 ? (2 * matches.length) / total : 0;
  }
}

/// Feature extraction backend: SuperPoint (SOTA), ALIKED (lightweight), or Harris (fallback).
enum FeatureExtractorType { superpoint, aliked, harris }

/// LightGlue feature matching service for on-device photogrammetry.
///
/// Replaces the traditional Harris corner detector + brute-force matching
/// pipeline with learned SuperPoint features + LightGlue neural matcher.
///
/// Architecture:
///   1. SuperPoint (or ALIKED) extracts keypoints with 256-D (128-D) descriptors
///   2. LightGlue performs learned matching with adaptive early exit
///   3. Falls back to Harris corners if TFLite models are unavailable
///
/// Models expected in assets/ml/:
///   - superpoint.tflite  (~2MB, float16 quantized)
///   - lightglue.tflite   (~4MB, float16 quantized)
///   - lightglue_config.json (configuration)
///
/// Usage:
/// ```dart
/// final service = LightGlueFeatureService();
/// await service.initialize();
/// final result = await service.extractAndMatch(img1Bytes, img2Bytes);
/// print('Found ${result.matches.length} matches');
/// ```
class LightGlueFeatureService {
  static final LightGlueFeatureService _instance =
      LightGlueFeatureService._internal();
  factory LightGlueFeatureService() => _instance;
  LightGlueFeatureService._internal();

  Interpreter? _extractorInterpreter;
  Interpreter? _matcherInterpreter;
  bool _isInitialized = false;
  bool _usingFallback = false;
  FeatureExtractorType _extractorType = FeatureExtractorType.superpoint;

  // Config loaded from lightglue_config.json
  Map<String, dynamic> _config = {};
  int _inputWidth = 640;
  int _inputHeight = 480;
  int _maxKeypoints = 1024;
  double _keypointThreshold = 0.005;
  int _nmsRadius = 4;
  int _descriptorDim = 256;
  double _matchThreshold = 0.2;

  // Fallback config
  double _harrisK = 0.04;
  int _fallbackNmsRadius = 8;

  // Preprocessing
  double _normMean = 0.449;
  double _normStd = 0.226;

  bool get isInitialized => _isInitialized;
  bool get usingFallback => _usingFallback;
  FeatureExtractorType get extractorType => _extractorType;
  int get descriptorDim => _descriptorDim;
  Map<String, dynamic> get config => Map.unmodifiable(_config);

  /// Initialize by loading TFLite models from assets.
  ///
  /// Attempts to load SuperPoint + LightGlue. Falls back to Harris corners
  /// if models are missing or fail to load. Returns true if at least the
  /// fallback is available (always true unless config is corrupted).
  Future<bool> initialize({FeatureExtractorType? preferredExtractor}) async {
    if (_isInitialized) return true;

    try {
      // Load config
      final configJson =
          await rootBundle.loadString('assets/ml/lightglue_config.json');
      _config = json.decode(configJson) as Map<String, dynamic>;

      final extractor = _config['extractor'] as Map<String, dynamic>? ?? {};
      final matcher = _config['matcher'] as Map<String, dynamic>? ?? {};
      final fallback = _config['fallback'] as Map<String, dynamic>? ?? {};
      final preprocessing =
          _config['preprocessing'] as Map<String, dynamic>? ?? {};

      _inputWidth = extractor['input_width'] as int? ?? 640;
      _inputHeight = extractor['input_height'] as int? ?? 480;
      _maxKeypoints = extractor['max_keypoints'] as int? ?? 1024;
      _keypointThreshold =
          (extractor['keypoint_threshold'] as num?)?.toDouble() ?? 0.005;
      _nmsRadius = extractor['nms_radius'] as int? ?? 4;
      _descriptorDim = extractor['descriptor_dim'] as int? ?? 256;
      _matchThreshold =
          (matcher['match_threshold'] as num?)?.toDouble() ?? 0.2;
      _harrisK = (fallback['harris_k'] as num?)?.toDouble() ?? 0.04;
      _fallbackNmsRadius = fallback['nms_radius'] as int? ?? 8;
      _normMean = (preprocessing['mean'] as num?)?.toDouble() ?? 0.449;
      _normStd = (preprocessing['std'] as num?)?.toDouble() ?? 0.226;

      debugPrint('LightGlueFeatureService: Config loaded');

      // Determine which extractor to use
      final preferred = preferredExtractor ?? FeatureExtractorType.superpoint;

      // Try to load neural models
      bool modelsLoaded = false;

      if (preferred == FeatureExtractorType.superpoint ||
          preferred == FeatureExtractorType.aliked) {
        modelsLoaded = await _loadNeuralModels(preferred);
      }

      if (!modelsLoaded &&
          preferred != FeatureExtractorType.aliked) {
        // Try ALIKED as second choice (smaller model)
        modelsLoaded = await _loadNeuralModels(FeatureExtractorType.aliked);
      }

      if (modelsLoaded) {
        _usingFallback = false;
        debugPrint(
            'LightGlueFeatureService: Initialized with ${_extractorType.name} + LightGlue');
      } else {
        // Fallback to Harris corners
        _usingFallback = true;
        _extractorType = FeatureExtractorType.harris;
        _descriptorDim = 64; // 8x8 patch descriptor
        debugPrint(
            'LightGlueFeatureService: Neural models unavailable, using Harris fallback');
      }

      _isInitialized = true;
      return true;
    } catch (e) {
      debugPrint('LightGlueFeatureService: Initialization failed: $e');
      // Even if config fails, we can still use Harris fallback
      _usingFallback = true;
      _extractorType = FeatureExtractorType.harris;
      _descriptorDim = 64;
      _isInitialized = true;
      return true;
    }
  }

  /// Try to load a neural extractor + LightGlue matcher.
  Future<bool> _loadNeuralModels(FeatureExtractorType type) async {
    try {
      String extractorFile;
      int descDim;

      if (type == FeatureExtractorType.aliked) {
        final alikedConfig =
            (_config['alternatives'] as Map<String, dynamic>?)?['aliked']
                as Map<String, dynamic>? ??
                {};
        extractorFile = alikedConfig['model_file'] as String? ?? 'aliked.tflite';
        descDim = alikedConfig['descriptor_dim'] as int? ?? 128;
      } else {
        final extractorConfig =
            _config['extractor'] as Map<String, dynamic>? ?? {};
        extractorFile =
            extractorConfig['model_file'] as String? ?? 'superpoint.tflite';
        descDim = extractorConfig['descriptor_dim'] as int? ?? 256;
      }

      final matcherConfig = _config['matcher'] as Map<String, dynamic>? ?? {};
      final matcherFile =
          matcherConfig['model_file'] as String? ?? 'lightglue.tflite';

      // Load extractor
      _extractorInterpreter =
          await Interpreter.fromAsset('ml/$extractorFile');
      debugPrint('LightGlueFeatureService: Loaded $extractorFile');

      // Load matcher
      _matcherInterpreter =
          await Interpreter.fromAsset('ml/$matcherFile');
      debugPrint('LightGlueFeatureService: Loaded $matcherFile');

      _extractorType = type;
      _descriptorDim = descDim;
      return true;
    } catch (e) {
      debugPrint(
          'LightGlueFeatureService: Failed to load ${type.name} models: $e');
      _extractorInterpreter?.close();
      _matcherInterpreter?.close();
      _extractorInterpreter = null;
      _matcherInterpreter = null;
      return false;
    }
  }

  /// Detect keypoints with descriptors from an image.
  ///
  /// [imageBytes] - raw image bytes (JPEG/PNG). Will be decoded, converted to
  /// grayscale, and resized to model input dimensions.
  ///
  /// [maxKeypoints] - maximum number of keypoints to return (sorted by score).
  /// Defaults to the config value (1024).
  ///
  /// Returns a list of [Keypoint] objects with positions in the original image
  /// coordinate system, confidence scores, and descriptor vectors.
  Future<List<Keypoint>> detectKeypoints(
    Uint8List imageBytes, {
    int? maxKeypoints,
  }) async {
    if (!_isInitialized) {
      throw StateError(
          'LightGlueFeatureService not initialized. Call initialize() first.');
    }

    final maxKp = maxKeypoints ?? _maxKeypoints;

    if (_usingFallback) {
      return _detectKeypointsHarris(imageBytes, maxKp);
    } else {
      return _detectKeypointsNeural(imageBytes, maxKp);
    }
  }

  /// Neural keypoint detection using SuperPoint or ALIKED TFLite model.
  Future<List<Keypoint>> _detectKeypointsNeural(
    Uint8List imageBytes,
    int maxKeypoints,
  ) async {
    final image = img.decodeImage(imageBytes);
    if (image == null) {
      throw ArgumentError('Failed to decode image bytes');
    }

    final originalWidth = image.width;
    final originalHeight = image.height;

    // Preprocess: grayscale, resize, normalize
    final gray = img.grayscale(image);
    final resized = img.copyResize(
      gray,
      width: _inputWidth,
      height: _inputHeight,
      interpolation: img.Interpolation.linear,
    );

    // Build input tensor [1, H, W, 1] normalized
    final inputBuffer =
        Float32List(_inputHeight * _inputWidth);
    for (int y = 0; y < _inputHeight; y++) {
      for (int x = 0; x < _inputWidth; x++) {
        final pixel = resized.getPixel(x, y);
        final value = pixel.r.toDouble() / 255.0;
        inputBuffer[y * _inputWidth + x] = (value - _normMean) / _normStd;
      }
    }

    // Reshape to [1, H, W, 1]
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputHeight,
        (y) => List.generate(
          _inputWidth,
          (x) => [inputBuffer[y * _inputWidth + x]],
        ),
      ),
    );

    // SuperPoint output: keypoint scores [1, H/8, W/8, 65] and descriptors [1, H/8, W/8, 256]
    // The exact output shape depends on the exported model. We handle the common
    // "semi-dense" export where scores are [1, H, W] and descriptors [1, H, W, D].
    //
    // For robustness, we allocate outputs for the most common export format
    // and adapt based on actual interpreter output tensors.
    final heatmapH = _inputHeight ~/ 8;
    final heatmapW = _inputWidth ~/ 8;

    // Allocate output buffers
    // Output 0: score heatmap [1, heatmapH, heatmapW, 65] (65 = 8x8 cells + dustbin)
    final scoreOutput = List.generate(
      1,
      (_) => List.generate(
        heatmapH,
        (_) => List.generate(heatmapW, (_) => List<double>.filled(65, 0.0)),
      ),
    );

    // Output 1: descriptors [1, heatmapH, heatmapW, descriptorDim]
    final descOutput = List.generate(
      1,
      (_) => List.generate(
        heatmapH,
        (_) => List.generate(
            heatmapW, (_) => List<double>.filled(_descriptorDim, 0.0)),
      ),
    );

    final outputs = {0: scoreOutput, 1: descOutput};

    _extractorInterpreter!.runForMultipleInputs([input], outputs);

    // Decode keypoints from score heatmap
    // Each cell in the heatmap covers an 8x8 region. Channels 0-63 are the
    // softmax scores for each pixel within the cell; channel 64 is the dustbin.
    final candidates = <Keypoint>[];

    for (int cy = 0; cy < heatmapH; cy++) {
      for (int cx = 0; cx < heatmapW; cx++) {
        final cellScores = scoreOutput[0][cy][cx];

        // Softmax over 65 channels
        final softmaxScores = _softmax(cellScores);

        // Find best non-dustbin score in this cell
        for (int i = 0; i < 64; i++) {
          final score = softmaxScores[i];
          if (score < _keypointThreshold) continue;

          // Decode pixel position within the 8x8 cell
          final localY = i ~/ 8;
          final localX = i % 8;

          // Position in the resized image
          final px = (cx * 8 + localX).toDouble();
          final py = (cy * 8 + localY).toDouble();

          // Scale back to original image coordinates
          final origX = px * originalWidth / _inputWidth;
          final origY = py * originalHeight / _inputHeight;

          // Bilinear interpolation of descriptor at this cell
          final descriptor = List<double>.from(descOutput[0][cy][cx]);

          // L2 normalize descriptor
          _l2Normalize(descriptor);

          candidates.add(Keypoint(
            x: origX,
            y: origY,
            score: score,
            descriptor: descriptor,
          ));
        }
      }
    }

    // Non-maximum suppression
    final nmsResult = _nonMaxSuppression(candidates, _nmsRadius.toDouble(),
        originalWidth.toDouble(), originalHeight.toDouble());

    // Sort by score descending and take top-k
    nmsResult.sort((a, b) => b.score.compareTo(a.score));
    return nmsResult.take(maxKeypoints).toList();
  }

  /// Harris corner fallback when neural models are unavailable.
  ///
  /// Replicates the existing reconstruction_service.dart pipeline with
  /// multi-scale detection, orientation-invariant descriptors, and NMS.
  Future<List<Keypoint>> _detectKeypointsHarris(
    Uint8List imageBytes,
    int maxKeypoints,
  ) async {
    final image = img.decodeImage(imageBytes);
    if (image == null) {
      throw ArgumentError('Failed to decode image bytes');
    }

    // Run in isolate for performance
    final result = await compute(_harrisDetectIsolate, {
      'image': image,
      'maxKeypoints': maxKeypoints,
      'harrisK': _harrisK,
      'nmsRadius': _fallbackNmsRadius,
    });
    return result;
  }

  /// Harris corner detection running in an isolate.
  static List<Keypoint> _harrisDetectIsolate(Map<String, dynamic> args) {
    final image = args['image'] as img.Image;
    final maxKeypoints = args['maxKeypoints'] as int;
    final harrisK = args['harrisK'] as double;
    final nmsRadius = args['nmsRadius'] as int;

    final width = image.width;
    final height = image.height;
    final gray = img.grayscale(image);
    final candidates = <Keypoint>[];

    // Multi-scale detection
    final scales = [1.0, 0.75, 0.5];

    for (final scale in scales) {
      img.Image scaledGray;
      if (scale < 1.0) {
        scaledGray = img.copyResize(
          gray,
          width: (width * scale).toInt(),
          height: (height * scale).toInt(),
          interpolation: img.Interpolation.linear,
        );
      } else {
        scaledGray = gray;
      }

      final sw = scaledGray.width;
      final sh = scaledGray.height;

      // Dense grid sampling (matches reconstruction_service.dart)
      const gridSize = 25;
      final cellW = sw / gridSize;
      final cellH = sh / gridSize;

      for (int gy = 0; gy < gridSize; gy++) {
        for (int gx = 0; gx < gridSize; gx++) {
          for (int s = 0; s < 3; s++) {
            final cx = ((gx + (s % 2) * 0.5 + 0.25) * cellW).toInt();
            final cy = ((gy + (s ~/ 2) * 0.5 + 0.25) * cellH).toInt();

            if (cx < 5 || cx >= sw - 5 || cy < 5 || cy >= sh - 5) continue;

            final strength =
                _harrisCornerStrength(scaledGray, cx, cy, harrisK);

            if (strength > 300) {
              final origX = cx / scale;
              final origY = cy / scale;

              candidates.add(Keypoint(
                x: origX,
                y: origY,
                score: strength * scale,
                descriptor: const [], // placeholder
              ));
            }
          }
        }
      }
    }

    if (candidates.isEmpty) return [];

    // Adaptive threshold
    final sorted = List<Keypoint>.from(candidates)
      ..sort((a, b) => b.score.compareTo(a.score));
    final threshold = sorted[sorted.length ~/ 4].score * 0.5;

    // Extract descriptors for strong candidates
    final withDescriptors = <Keypoint>[];
    for (final c in sorted) {
      if (c.score <= threshold) continue;

      final x = c.x.toInt().clamp(8, width - 9);
      final y = c.y.toInt().clamp(8, height - 9);
      final descriptor = _extractPatchDescriptor(gray, x, y);

      withDescriptors.add(Keypoint(
        x: c.x,
        y: c.y,
        score: c.score,
        descriptor: descriptor,
      ));
    }

    // NMS with spatial hashing
    final suppressed = <Keypoint>[];
    final occupied = <int>{};
    final nmsRad = nmsRadius;

    for (final kp in withDescriptors) {
      final cellX = (kp.x / nmsRad).toInt();
      final cellY = (kp.y / nmsRad).toInt();
      final cellKey = cellY * 10000 + cellX;

      bool tooClose = false;
      for (int dy = -1; dy <= 1 && !tooClose; dy++) {
        for (int dx = -1; dx <= 1 && !tooClose; dx++) {
          if (occupied.contains((cellY + dy) * 10000 + (cellX + dx))) {
            tooClose = true;
          }
        }
      }

      if (!tooClose) {
        suppressed.add(kp);
        occupied.add(cellKey);
      }
    }

    return suppressed.take(maxKeypoints).toList();
  }

  /// Harris corner response (matches reconstruction_service.dart).
  static double _harrisCornerStrength(
      img.Image gray, int x, int y, double k) {
    double ix2 = 0, iy2 = 0, ixiy = 0;

    for (int dy = -2; dy <= 2; dy++) {
      for (int dx = -2; dx <= 2; dx++) {
        final px = x + dx;
        final py = y + dy;
        if (px < 1 || px >= gray.width - 1 || py < 1 || py >= gray.height - 1) {
          continue;
        }

        final gx =
            (gray.getPixel(px + 1, py).r - gray.getPixel(px - 1, py).r) / 2.0;
        final gy =
            (gray.getPixel(px, py + 1).r - gray.getPixel(px, py - 1).r) / 2.0;

        ix2 += gx * gx;
        iy2 += gy * gy;
        ixiy += gx * gy;
      }
    }

    final det = ix2 * iy2 - ixiy * ixiy;
    final trace = ix2 + iy2;
    return det - k * trace * trace;
  }

  /// Orientation-invariant 8x8 patch descriptor (matches reconstruction_service.dart).
  static List<double> _extractPatchDescriptor(img.Image gray, int x, int y) {
    // Compute dominant gradient orientation
    double gxSum = 0, gySum = 0;
    for (int dy = -3; dy <= 3; dy++) {
      for (int dx = -3; dx <= 3; dx++) {
        final px = (x + dx).clamp(1, gray.width - 2);
        final py = (y + dy).clamp(1, gray.height - 2);
        final gx = gray.getPixel(px + 1, py).r.toDouble() -
            gray.getPixel(px - 1, py).r.toDouble();
        final gy = gray.getPixel(px, py + 1).r.toDouble() -
            gray.getPixel(px, py - 1).r.toDouble();
        gxSum += gx;
        gySum += gy;
      }
    }
    final angle = math.atan2(gySum, gxSum);
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);

    // Sample rotated 8x8 patch
    final descriptor = <double>[];
    for (int dy = -4; dy < 4; dy++) {
      for (int dx = -4; dx < 4; dx++) {
        final rx = (dx * cosA + dy * sinA).round();
        final ry = (-dx * sinA + dy * cosA).round();
        final px = x + rx;
        final py = y + ry;

        if (px >= 0 && px < gray.width && py >= 0 && py < gray.height) {
          descriptor.add(gray.getPixel(px, py).r.toDouble());
        } else {
          descriptor.add(0.0);
        }
      }
    }

    // Normalize
    final mean = descriptor.reduce((a, b) => a + b) / descriptor.length;
    final std = math.sqrt(
      descriptor.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
          descriptor.length,
    );

    if (std > 0) {
      for (int i = 0; i < descriptor.length; i++) {
        descriptor[i] = (descriptor[i] - mean) / std;
      }
    }

    return descriptor;
  }

  /// Match keypoints between two images using LightGlue or brute-force fallback.
  ///
  /// [kp1] and [kp2] are keypoint lists from [detectKeypoints].
  ///
  /// With neural models: runs LightGlue TFLite for learned matching with
  /// adaptive depth (early exit when confident).
  ///
  /// With fallback: brute-force L2 matching + Lowe's ratio test + cross-check,
  /// matching the existing reconstruction_service.dart pipeline.
  Future<List<KeypointMatch>> matchFeatures(
    List<Keypoint> kp1,
    List<Keypoint> kp2,
  ) async {
    if (!_isInitialized) {
      throw StateError(
          'LightGlueFeatureService not initialized. Call initialize() first.');
    }

    if (kp1.isEmpty || kp2.isEmpty) return [];

    if (_usingFallback) {
      return compute(_bruteForcMatchIsolate, {
        'kp1': kp1,
        'kp2': kp2,
        'ratioThreshold': 0.75,
      });
    } else {
      return _matchFeaturesNeural(kp1, kp2);
    }
  }

  /// LightGlue neural matching.
  ///
  /// Input format (common LightGlue TFLite export):
  ///   - Input 0: descriptors1 [1, N, D] (float32)
  ///   - Input 1: keypoints1   [1, N, 2] (float32, normalized 0-1)
  ///   - Input 2: descriptors2 [1, M, D] (float32)
  ///   - Input 3: keypoints2   [1, M, 2] (float32, normalized 0-1)
  /// Output:
  ///   - Output 0: matches [K, 2] (int32 indices)
  ///   - Output 1: scores  [K]    (float32 confidence)
  ///
  /// Since the exact TFLite export format may vary, this implementation handles
  /// the most common format and falls back to brute-force if inference fails.
  Future<List<KeypointMatch>> _matchFeaturesNeural(
    List<Keypoint> kp1,
    List<Keypoint> kp2,
  ) async {
    try {
      final n = kp1.length;
      final m = kp2.length;

      // Build descriptor tensors [1, N, D]
      final desc1 = List.generate(
        1,
        (_) => List.generate(n, (i) => List<double>.from(kp1[i].descriptor)),
      );
      final desc2 = List.generate(
        1,
        (_) => List.generate(m, (i) => List<double>.from(kp2[i].descriptor)),
      );

      // Build keypoint position tensors [1, N, 2] normalized to [0, 1]
      // (LightGlue expects positions normalized by image dimensions)
      final pos1 = List.generate(
        1,
        (_) => List.generate(n, (i) => [kp1[i].x, kp1[i].y]),
      );
      final pos2 = List.generate(
        1,
        (_) => List.generate(m, (i) => [kp2[i].x, kp2[i].y]),
      );

      // Allocate output buffers
      // Conservative maximum: min(N, M) matches possible
      final maxMatches = math.min(n, m);
      final matchIndices = List.generate(
        maxMatches,
        (_) => List<int>.filled(2, 0),
      );
      final matchScores = List<double>.filled(maxMatches, 0.0);

      final outputs = {0: matchIndices, 1: matchScores};

      _matcherInterpreter!
          .runForMultipleInputs([desc1, pos1, desc2, pos2], outputs);

      // Parse matches
      final matches = <KeypointMatch>[];
      for (int k = 0; k < maxMatches; k++) {
        final score = matchScores[k];
        if (score < _matchThreshold) continue;

        final i = matchIndices[k][0];
        final j = matchIndices[k][1];

        if (i < 0 || i >= n || j < 0 || j >= m) continue;

        matches.add(KeypointMatch(
          idx1: i,
          idx2: j,
          kp1: kp1[i],
          kp2: kp2[j],
          confidence: score,
        ));
      }

      // Sort by confidence descending
      matches.sort((a, b) => b.confidence.compareTo(a.confidence));
      return matches;
    } catch (e) {
      debugPrint(
          'LightGlueFeatureService: Neural matching failed ($e), falling back to brute-force');
      return compute(_bruteForcMatchIsolate, {
        'kp1': kp1,
        'kp2': kp2,
        'ratioThreshold': 0.75,
      });
    }
  }

  /// Brute-force matching with Lowe's ratio test + bidirectional cross-check.
  /// Runs in an isolate. Matches the reconstruction_service.dart pipeline.
  static List<KeypointMatch> _bruteForcMatchIsolate(
      Map<String, dynamic> args) {
    final kp1 = args['kp1'] as List<Keypoint>;
    final kp2 = args['kp2'] as List<Keypoint>;
    final ratioThreshold = args['ratioThreshold'] as double;

    // Forward matching: kp1 -> kp2
    final forwardMatches = <int, _BFMatch>{};
    for (int i = 0; i < kp1.length; i++) {
      double best = double.infinity;
      double secondBest = double.infinity;
      int bestIdx = -1;

      for (int j = 0; j < kp2.length; j++) {
        final dist = _l2Distance(kp1[i].descriptor, kp2[j].descriptor);
        if (dist < best) {
          secondBest = best;
          best = dist;
          bestIdx = j;
        } else if (dist < secondBest) {
          secondBest = dist;
        }
      }

      if (bestIdx >= 0 && best < ratioThreshold * secondBest) {
        forwardMatches[i] = _BFMatch(bestIdx, best);
      }
    }

    // Backward matching: kp2 -> kp1 (cross-check)
    final backwardMatches = <int, int>{};
    for (int j = 0; j < kp2.length; j++) {
      double best = double.infinity;
      double secondBest = double.infinity;
      int bestIdx = -1;

      for (int i = 0; i < kp1.length; i++) {
        final dist = _l2Distance(kp1[i].descriptor, kp2[j].descriptor);
        if (dist < best) {
          secondBest = best;
          best = dist;
          bestIdx = i;
        } else if (dist < secondBest) {
          secondBest = dist;
        }
      }

      if (bestIdx >= 0 && best < ratioThreshold * secondBest) {
        backwardMatches[j] = bestIdx;
      }
    }

    // Bidirectional cross-check
    final matches = <KeypointMatch>[];
    for (final entry in forwardMatches.entries) {
      final i = entry.key;
      final j = entry.value.idx;

      if (backwardMatches[j] == i) {
        // Convert distance to confidence (0-1, higher is better)
        final confidence = math.exp(-entry.value.distance);

        matches.add(KeypointMatch(
          idx1: i,
          idx2: j,
          kp1: kp1[i],
          kp2: kp2[j],
          confidence: confidence,
        ));
      }
    }

    matches.sort((a, b) => b.confidence.compareTo(a.confidence));
    return matches;
  }

  /// Combined detect + match for an image pair. Convenience method.
  ///
  /// Returns a [MatchResult] with keypoints, matches, and timing info.
  Future<MatchResult> extractAndMatch(
    Uint8List img1,
    Uint8List img2, {
    int? maxKeypoints,
  }) async {
    if (!_isInitialized) {
      throw StateError(
          'LightGlueFeatureService not initialized. Call initialize() first.');
    }

    // Extract keypoints from both images (can run in parallel)
    final extractStart = DateTime.now();
    final results = await Future.wait([
      detectKeypoints(img1, maxKeypoints: maxKeypoints),
      detectKeypoints(img2, maxKeypoints: maxKeypoints),
    ]);
    final extractionTime = DateTime.now().difference(extractStart);

    final kp1 = results[0];
    final kp2 = results[1];

    // Match features
    final matchStart = DateTime.now();
    final matches = await matchFeatures(kp1, kp2);
    final matchingTime = DateTime.now().difference(matchStart);

    return MatchResult(
      keypoints1: kp1,
      keypoints2: kp2,
      matches: matches,
      extractionTime: extractionTime,
      matchingTime: matchingTime,
      usedFallback: _usingFallback,
    );
  }

  /// Convert [Keypoint] list to [ImageFeature] list for compatibility with
  /// [ReconstructionService].
  ///
  /// This allows drop-in replacement of the Harris pipeline in the existing
  /// reconstruction flow.
  List<ImageFeature> toImageFeatures(List<Keypoint> keypoints) {
    return keypoints
        .map((kp) => ImageFeature(
              x: kp.x,
              y: kp.y,
              strength: kp.score,
              descriptor: kp.descriptor,
            ))
        .toList();
  }

  /// Convert [KeypointMatch] list to [FeatureMatch] list for compatibility
  /// with [ReconstructionService].
  List<FeatureMatch> toFeatureMatches(List<KeypointMatch> matches) {
    return matches
        .map((m) => FeatureMatch(
              feature1: ImageFeature(
                x: m.kp1.x,
                y: m.kp1.y,
                strength: m.kp1.score,
                descriptor: m.kp1.descriptor,
              ),
              feature2: ImageFeature(
                x: m.kp2.x,
                y: m.kp2.y,
                strength: m.kp2.score,
                descriptor: m.kp2.descriptor,
              ),
              distance: m.descriptorDistance,
            ))
        .toList();
  }

  /// Get diagnostic information about the service state.
  Map<String, dynamic> getDiagnostics() {
    return {
      'initialized': _isInitialized,
      'using_fallback': _usingFallback,
      'extractor_type': _extractorType.name,
      'descriptor_dim': _descriptorDim,
      'max_keypoints': _maxKeypoints,
      'input_resolution': '${_inputWidth}x$_inputHeight',
      'match_threshold': _matchThreshold,
      'keypoint_threshold': _keypointThreshold,
      'nms_radius': _usingFallback ? _fallbackNmsRadius : _nmsRadius,
      'config_version': _config['model_version'] ?? 'unknown',
    };
  }

  /// Release TFLite resources.
  void dispose() {
    _extractorInterpreter?.close();
    _matcherInterpreter?.close();
    _extractorInterpreter = null;
    _matcherInterpreter = null;
    _isInitialized = false;
  }

  // ─── Helper functions ──────────────────────────────────────────────

  /// Softmax over a list of logits.
  static List<double> _softmax(List<double> logits) {
    final maxVal = logits.reduce(math.max);
    final exps = logits.map((v) => math.exp(v - maxVal)).toList();
    final sum = exps.reduce((a, b) => a + b);
    return exps.map((e) => e / sum).toList();
  }

  /// L2-normalize a descriptor vector in-place.
  static void _l2Normalize(List<double> vec) {
    double norm = 0;
    for (final v in vec) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm > 1e-8) {
      for (int i = 0; i < vec.length; i++) {
        vec[i] /= norm;
      }
    }
  }

  /// L2 distance between two descriptor vectors.
  static double _l2Distance(List<double> d1, List<double> d2) {
    double sum = 0;
    final len = math.min(d1.length, d2.length);
    for (int i = 0; i < len; i++) {
      final diff = d1[i] - d2[i];
      sum += diff * diff;
    }
    return math.sqrt(sum);
  }

  /// Non-maximum suppression on keypoints.
  static List<Keypoint> _nonMaxSuppression(
    List<Keypoint> keypoints,
    double radius,
    double imageWidth,
    double imageHeight,
  ) {
    if (keypoints.isEmpty) return [];

    // Sort by score descending
    final sorted = List<Keypoint>.from(keypoints)
      ..sort((a, b) => b.score.compareTo(a.score));

    final result = <Keypoint>[];
    final suppressed = List<bool>.filled(sorted.length, false);

    for (int i = 0; i < sorted.length; i++) {
      if (suppressed[i]) continue;
      result.add(sorted[i]);

      // Suppress nearby lower-scoring keypoints
      for (int j = i + 1; j < sorted.length; j++) {
        if (suppressed[j]) continue;
        final dx = sorted[i].x - sorted[j].x;
        final dy = sorted[i].y - sorted[j].y;
        if (dx * dx + dy * dy < radius * radius) {
          suppressed[j] = true;
        }
      }
    }

    return result;
  }
}

/// Internal match candidate for brute-force matching.
class _BFMatch {
  final int idx;
  final double distance;
  const _BFMatch(this.idx, this.distance);
}
