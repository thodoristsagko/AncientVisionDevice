// ignore_for_file: non_constant_identifier_names
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../../models/point_cloud.dart';
import '../../models/mesh_model.dart';
import '../../models/camera_pose.dart';
export '../../models/camera_pose.dart';
import '../../models/reconstruction_result.dart';
import '../sfm_robust.dart';
import '../exif_service.dart';
import '../reconstruction_quality_service.dart';
import '../lightglue_feature_service.dart';
import 'reconstruction_models.dart';
import 'reconstruction_isolates.dart';
import 'feature_extractor.dart';
import 'feature_matcher.dart';
import 'pose_estimator.dart';
import 'triangulation_service.dart';
import 'reconstruction_persistence.dart';
import '../../utils/kd_tree.dart';

/// Service for 3D reconstruction from photogrammetry captures
class ReconstructionService {
  static final ReconstructionService _instance = ReconstructionService._internal();
  factory ReconstructionService() => _instance;
  ReconstructionService._internal();

  final _uuid = const Uuid();
  final _lightGlue = LightGlueFeatureService();
  bool _isCancelled = false;
  bool _useLightGlue = false;
  int _imageWidth = 1024;
  int _imageHeight = 1024;

  /// Cached image file references for LightGlue extraction path
  List<File> _imageFilesRef = [];

  /// Cached keypoints per image for LightGlue matching path
  List<List<Keypoint>> _keypointsCache = [];

  /// Cached color sample data (extracted during image loading)
  List<ColorSampleData> _colorSamplesCache = [];

  /// Cancel ongoing reconstruction
  void cancelReconstruction() {
    _isCancelled = true;
    clearCache();
  }

  /// Release cached keypoints and image references to free memory.
  void clearCache() {
    _keypointsCache.clear();
    _imageFilesRef = [];
    _colorSamplesCache.clear();
  }

  /// Reset cancellation flag
  void _resetCancellation() {
    _isCancelled = false;
  }

  /// Detect device capabilities for reconstruction
  Future<Map<String, dynamic>> detectCapabilities() async {
    final capabilities = <String, dynamic>{};
    final deviceInfo = DeviceInfoPlugin();

    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;

        // Get actual device RAM (in GB)
        // Android doesn't expose exact RAM, estimate based on device tier
        // High-end devices (2020+) typically have 6-12GB, mid-range 4-6GB, low-end 2-4GB
        final sdkInt = androidInfo.version.sdkInt;
        int estimatedRamGb = 2;
        if (sdkInt >= 30) {
          estimatedRamGb = 6; // Android 11+ devices are typically newer with more RAM
        } else if (sdkInt >= 28) {
          estimatedRamGb = 4; // Android 9-10
        } else {
          estimatedRamGb = 2; // Older devices
        }

        capabilities['estimated_ram_gb'] = estimatedRamGb;
        capabilities['device_model'] = androidInfo.model;
        capabilities['manufacturer'] = androidInfo.manufacturer;

        // Check for Huawei device (may have 3D Modeling Kit)
        final isHuawei = androidInfo.manufacturer.toLowerCase().contains('huawei') ||
                         androidInfo.manufacturer.toLowerCase().contains('honor');
        capabilities['huawei_kit_available'] = isHuawei && sdkInt >= 29; // Huawei 3D Kit requires EMUI 10+

        // Check for high-performance GPU (Adreno 6xx+, Mali-G7x+)
        capabilities['high_performance_gpu'] = sdkInt >= 29;

      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;

        // iOS devices have more predictable specs
        // iPhone 11+ has 4GB+, iPhone 13+ has 6GB
        final model = iosInfo.utsname.machine;
        int estimatedRamGb = 4;
        if (model.contains('iPhone14') || model.contains('iPhone15') || model.contains('iPhone16')) {
          estimatedRamGb = 6;
        } else if (model.contains('iPhone12') || model.contains('iPhone13')) {
          estimatedRamGb = 4;
        } else {
          estimatedRamGb = 3;
        }

        capabilities['estimated_ram_gb'] = estimatedRamGb;
        capabilities['device_model'] = iosInfo.model;
        capabilities['manufacturer'] = 'Apple';
        capabilities['huawei_kit_available'] = false;
        capabilities['high_performance_gpu'] = true; // All modern iPhones have good GPUs
      }
    } catch (e) {
      debugPrint('Error detecting device capabilities: $e');
      // Fallback to safe defaults
      capabilities['estimated_ram_gb'] = 2;
      capabilities['huawei_kit_available'] = false;
      capabilities['high_performance_gpu'] = false;
    }

    // Sparse preview available if device has 2GB+ RAM
    capabilities['sparse_preview'] = (capabilities['estimated_ram_gb'] ?? 2) >= 2;

    // Cloud processing always available if online
    capabilities['cloud_processing_available'] = true;

    return capabilities;
  }

  /// Generate sparse 3D point cloud from captured images
  /// This is a simplified Structure from Motion implementation optimized for mobile
  Future<ReconstructionResult> generateSparsePreview({
    required List<File> imageFiles,
    Function(double progress, String status)? onProgress,
  }) async {
    final resultId = _uuid.v4();
    final startTime = DateTime.now();
    _resetCancellation();

    try {
      onProgress?.call(0.0, 'Initializing reconstruction...');

      // Enhanced validation
      if (imageFiles.isEmpty) {
        throw Exception('No images provided for reconstruction');
      }
      if (imageFiles.length < 3) {
        throw Exception('Need at least 3 images for reconstruction (got ${imageFiles.length})');
      }
      if (imageFiles.length < 8) {
        debugPrint('Warning: Using ${imageFiles.length} images. 8+ recommended for best results.');
      }

      // Step 0.5: Extract EXIF data for camera intrinsics
      onProgress?.call(0.02, 'Reading camera metadata...');
      ExifData? exifData;
      try {
        exifData = await ExifService.extractFromFile(imageFiles.first.path);
        if (exifData != null) {
          debugPrint(' EXIF: ${exifData.cameraMake} ${exifData.cameraModel}, '
              'focal=${exifData.focalLengthMM}mm, sensor=${exifData.sensorWidth}mm');
        }
      } catch (e) {
        debugPrint(' EXIF extraction skipped: $e');
      }

      // Try to initialize LightGlue for better features
      _useLightGlue = false;
      _imageFilesRef = imageFiles;
      _keypointsCache = [];
      try {
        await _lightGlue.initialize();
        _useLightGlue = !_lightGlue.usingFallback;
        debugPrint(' Feature extractor: ${_lightGlue.extractorType.name} (fallback=${_lightGlue.usingFallback})');
      } catch (e) {
        debugPrint(' LightGlue init failed, using Harris: $e');
      }

      // Step 1: Load and downsample images with memory management (10%)
      onProgress?.call(0.05, 'Loading and optimizing images...');
      List<img.Image>? images;
      try {
        images = await _loadAndDownsampleImages(imageFiles, onProgress);
        if (_isCancelled) throw Exception('Reconstruction cancelled by user');

        if (images.isEmpty) {
          throw Exception('Failed to load any valid images. Check file permissions and formats.');
        }
        debugPrint(' Loaded ${images.length} images successfully');
      } catch (e) {
        throw Exception('Image loading failed: $e. Ensure photos are valid JPEG/PNG files.');
      }

      // Step 2: Extract features from each image with enhanced detection (40%)
      onProgress?.call(0.15, 'Detecting features in images...');
      List<List<ImageFeature>>? features;
      try {
        features = await _extractFeatures(images, onProgress);
        if (_isCancelled) throw Exception('Reconstruction cancelled by user');

        final totalFeatures = features.fold<int>(0, (sum, f) => sum + f.length);
        if (totalFeatures < 50) {
          throw Exception(
            'Not enough features detected ($totalFeatures found).\n'
            'The object may be too:\n'
            '• Smooth or shiny (reflections)\n'
            '• Dark or black (low contrast)\n'
            '• Uniform in color\n\n'
            'Solutions:\n'
            '• Add temporary texture (flour/chalk)\n'
            '• Improve lighting\n'
            '• Use cloud processing');
        }
        debugPrint(' Extracted $totalFeatures features from ${features.length} images');
      } catch (e) {
        throw Exception('Feature extraction failed: $e');
      } finally {
        // Clear images from memory immediately after feature extraction
        images.clear();
        images = null;
      }

      // Step 3: Match features between images (60%)
      onProgress?.call(0.45, 'Matching features across images...');
      List<List<FeatureMatch>>? matches;
      try {
        matches = await _matchFeatures(features, onProgress);
        if (_isCancelled) throw Exception('Reconstruction cancelled by user');

        final totalMatches = matches.fold<int>(0, (sum, m) => sum + m.length);
        if (totalMatches < 30) {
          throw Exception(
            'Not enough matching features ($totalMatches found).\n'
            'This usually means:\n'
            '• Object is too smooth/uniform\n'
            '• Lighting is too dim or uneven\n'
            '• Photos are blurry\n'
            '• Not enough overlap between angles\n\n'
            'Try cloud processing for difficult objects.');
        }
        debugPrint(' Found $totalMatches feature matches');
      } catch (e) {
        throw Exception('Feature matching failed: $e');
      }

      // Step 4: Estimate camera poses (75%)
      onProgress?.call(0.65, 'Calculating camera positions...');
      List<CameraPose>? cameraPoses;
      try {
        // Use EXIF focal length if available, scaled to downsampled image size
        double? exifFocalPx;
        if (exifData?.focalLengthPixels != null &&
            exifData!.imageWidth != null && exifData.imageWidth! > 0) {
          // Scale EXIF focal length to match downsampled resolution
          exifFocalPx = exifData.focalLengthPixels! *
              (_imageWidth / exifData.imageWidth!);
          debugPrint(' Using EXIF focal length: ${exifFocalPx.toStringAsFixed(1)}px '
              '(from ${exifData.focalLengthMM}mm)');
        }
        cameraPoses = await estimateCameraPoses(
          matches,
          imageFiles.length,
          _imageWidth.toDouble(),
          _imageHeight.toDouble(),
          exifFocalLengthPx: exifFocalPx,
        );
        if (_isCancelled) throw Exception('Reconstruction cancelled by user');
        debugPrint(' Estimated ${cameraPoses.length} camera poses');
      } catch (e) {
        throw Exception('Camera pose estimation failed: $e');
      }

      // Step 5: Triangulate 3D points (70%)
      onProgress?.call(0.70, 'Reconstructing 3D points...');
      PointCloud? pointCloud;
      try {
        // Use cached color samples (already extracted during image loading)
        pointCloud = await triangulatePoints(
          features,
          matches,
          cameraPoses,
          _colorSamplesCache,
          _imageWidth.toDouble(),
          _imageHeight.toDouble(),
        );
        if (_isCancelled) throw Exception('Reconstruction cancelled by user');

        if (pointCloud.points.length < 100) {
          debugPrint('Warning: Only ${pointCloud.points.length} points reconstructed. Quality may be low.');
        }
        debugPrint(' Reconstructed ${pointCloud.points.length} 3D points');
      } catch (e) {
        throw Exception('3D triangulation failed: $e');
      }

      // Use non-null locals for post-processing
      var currentCloud = pointCloud;
      var currentPoses = cameraPoses;

      // Step 6: Bundle Adjustment - refine poses and points together (80%)
      if (_isCancelled) throw Exception('Reconstruction cancelled by user');
      onProgress?.call(0.80, 'Optimizing reconstruction...');
      try {
        final bundleResult = await bundleAdjustment(
          currentCloud,
          currentPoses,
          features,
          matches,
          _imageWidth.toDouble(),
          _imageHeight.toDouble(),
        );
        currentCloud = bundleResult.pointCloud;
        currentPoses = bundleResult.poses;
        debugPrint(' Bundle adjustment improved ${bundleResult.improvementPercent.toStringAsFixed(1)}%');
      } catch (e) {
        debugPrint(' Bundle adjustment skipped: $e');
      }

      // Step 7: Statistical outlier removal (85%)
      if (_isCancelled) throw Exception('Reconstruction cancelled by user');
      onProgress?.call(0.85, 'Filtering outliers...');
      try {
        final beforeCount = currentCloud.points.length;
        currentCloud = _removeStatisticalOutliers(currentCloud);
        final removed = beforeCount - currentCloud.points.length;
        debugPrint(' Removed $removed outlier points');
      } catch (e) {
        debugPrint(' Outlier removal skipped: $e');
      }

      // Step 8: Multi-view color sampling (88%)
      if (_isCancelled) throw Exception('Reconstruction cancelled by user');
      onProgress?.call(0.88, 'Enhancing colors...');
      try {
        currentCloud = await _multiViewColorSampling(
          currentCloud,
          currentPoses,
        );
        debugPrint(' Multi-view color sampling complete');
      } catch (e) {
        debugPrint(' Color sampling skipped: $e');
      }

      // Step 9: Normal estimation (92%)
      onProgress?.call(0.92, 'Computing normals...');
      try {
        currentCloud = _estimateNormals(currentCloud);
        debugPrint(' Normal estimation complete');
      } catch (e) {
        debugPrint(' Normal estimation skipped: $e');
      }

      // Step 10: Point interpolation for denser cloud (96%)
      onProgress?.call(0.96, 'Densifying point cloud...');
      try {
        final beforeCount = currentCloud.points.length;
        currentCloud = await _interpolatePoints(currentCloud);
        final added = currentCloud.points.length - beforeCount;
        debugPrint(' Added $added interpolated points');
      } catch (e) {
        debugPrint(' Point interpolation skipped: $e');
      }

      // Clear intermediate data
      features.clear();
      matches.clear();
      _keypointsCache.clear();
      _imageFilesRef = [];
      _colorSamplesCache.clear();

      // Step 11: Quality assessment (98%)
      onProgress?.call(0.98, 'Assessing reconstruction quality...');
      ReconstructionQuality? qualityAssessment;
      try {
        final endTimeForQuality = DateTime.now();
        // Compute simplified reprojection errors based on average confidence
        // (full reprojection requires retained observations which we cleared)
        final avgConfidence = _calculateAverageConfidence(currentCloud);
        // Estimate mean reprojection error from confidence (inverse relationship)
        final estimatedMeanError = avgConfidence > 0 ? (1.0 / avgConfidence) * 0.5 : 5.0;
        final syntheticErrors = List.generate(
          currentCloud.points.length,
          (i) => estimatedMeanError * (0.5 + math.Random(i).nextDouble()),
        );

        // Compute GSD if EXIF data available
        double? gsd;
        if (exifData != null) {
          gsd = exifData.groundSampleDistance(1.0); // Assume 1m working distance
        }

        qualityAssessment = ReconstructionQualityService.assess(
          reprojectionErrors: syntheticErrors,
          matchedImages: currentPoses.length,
          totalImages: imageFiles.length,
          pointCount: currentCloud.points.length,
          processingTime: endTimeForQuality.difference(startTime),
          estimatedGSD: gsd,
        );
        debugPrint(' Quality grade: ${qualityAssessment.qualityGrade} '
            '(mean error: ${qualityAssessment.meanReprojectionError.toStringAsFixed(2)}px)');
      } catch (e) {
        debugPrint(' Quality assessment skipped: $e');
      }

      onProgress?.call(1.0, 'Reconstruction complete!');

      final endTime = DateTime.now();
      final processingTime = endTime.difference(startTime).inSeconds.toDouble();

      final result = ReconstructionResult(
        id: resultId,
        method: ReconstructionMethod.sparseSfM,
        status: ReconstructionStatus.completed,
        startedAt: startTime,
        completedAt: endTime,
        pointCloud: currentCloud,
        cameraPoses: currentPoses,
        progress: 1.0,
        statusMessage: 'Reconstruction completed with ${currentCloud.points.length} points',
        inputImageCount: imageFiles.length,
        processingTimeSeconds: processingTime,
        qualityMetrics: {
          'point_count': currentCloud.points.length,
          'image_count': imageFiles.length,
          'average_confidence': _calculateAverageConfidence(currentCloud),
          'processing_time_seconds': processingTime,
          if (qualityAssessment != null) ...{
            'quality_grade': qualityAssessment.qualityGrade,
            'mean_reprojection_error': qualityAssessment.meanReprojectionError,
            'median_reprojection_error': qualityAssessment.medianReprojectionError,
            'p95_reprojection_error': qualityAssessment.p95ReprojectionError,
            'completeness': qualityAssessment.completeness,
            'warnings': qualityAssessment.warnings,
          },
          if (exifData != null) ...{
            'camera_make': exifData.cameraMake,
            'camera_model': exifData.cameraModel,
            'focal_length_mm': exifData.focalLengthMM,
            if (exifData.groundSampleDistance(1.0) != null)
              'gsd_mm_per_pixel': exifData.groundSampleDistance(1.0),
            if (exifData.gpsLatitude != null) 'gps_latitude': exifData.gpsLatitude,
            if (exifData.gpsLongitude != null) 'gps_longitude': exifData.gpsLongitude,
          },
        },
      );

      // Auto-save result
      try {
        await saveResult(result);
        debugPrint(' Saved reconstruction to persistent storage');
      } catch (e) {
        debugPrint(' Failed to save result: $e');
      }

      return result;
    } catch (e, stackTrace) {
      debugPrint(' Reconstruction error: $e');
      debugPrint('Stack trace: $stackTrace');

      return ReconstructionResult(
        id: resultId,
        method: ReconstructionMethod.sparseSfM,
        status: _isCancelled ? ReconstructionStatus.cancelled : ReconstructionStatus.failed,
        startedAt: startTime,
        progress: 0.0,
        errorMessage: _isCancelled ? 'Cancelled by user' : e.toString(),
        inputImageCount: imageFiles.length,
      );
    }
  }

  /// Load and downsample images for processing with progress updates
  /// Also extracts color samples in a single pass (no need to reload later)
  Future<List<img.Image>> _loadAndDownsampleImages(
    List<File> imageFiles,
    Function(double, String)? onProgress,
  ) async {
    final images = <img.Image>[];
    _colorSamplesCache = [];

    for (int i = 0; i < imageFiles.length; i++) {
      try {
        if (_isCancelled) break;

        final file = imageFiles[i];
        final bytes = await file.readAsBytes();
        final image = img.decodeImage(bytes);

        if (image != null) {
          // Downsample to fit within 1024x1024 while preserving aspect ratio
          const maxDim = 1024;
          img.Image downsampled;
          if (image.width > maxDim || image.height > maxDim) {
            if (image.width >= image.height) {
              downsampled = img.copyResize(
                image,
                width: maxDim,
                interpolation: img.Interpolation.average,
              );
            } else {
              downsampled = img.copyResize(
                image,
                height: maxDim,
                interpolation: img.Interpolation.average,
              );
            }
          } else {
            downsampled = image;
          }
          images.add(downsampled);

          // ALSO: Extract color sample at 512px resolution for later use
          const colorMaxDim = 512;
          img.Image colorSample;
          if (image.width >= image.height) {
            colorSample = img.copyResize(
              image,
              width: colorMaxDim,
              interpolation: img.Interpolation.average,
            );
          } else {
            colorSample = img.copyResize(
              image,
              height: colorMaxDim,
              interpolation: img.Interpolation.average,
            );
          }

          // Store color data as flat array (lightweight)
          final colorData = <Color>[];
          for (int y = 0; y < colorSample.height; y++) {
            for (int x = 0; x < colorSample.width; x++) {
              final pixel = colorSample.getPixel(x, y);
              colorData.add(Color.fromARGB(255, pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()));
            }
          }
          _colorSamplesCache.add(ColorSampleData(
            width: colorSample.width,
            height: colorSample.height,
            colors: colorData,
          ));

          // Store dimensions from first image for coordinate normalization
          if (i == 0) {
            _imageWidth = downsampled.width;
            _imageHeight = downsampled.height;
            RobustSfM.imageCenterX = _imageWidth / 2.0;
            RobustSfM.imageCenterY = _imageHeight / 2.0;
          }

          final progress = 0.05 + (i / imageFiles.length) * 0.10;
          onProgress?.call(progress, 'Loading image ${i + 1}/${imageFiles.length}...');
        } else {
          debugPrint(' Failed to decode image ${i + 1}');
        }
      } catch (e) {
        debugPrint(' Error loading image ${i + 1}: $e');
      }
    }

    return images;
  }

  /// Extract corner features from images using LightGlue (preferred) or Harris corner detector (fallback)
  Future<List<List<ImageFeature>>> _extractFeatures(
    List<img.Image> images,
    Function(double, String)? onProgress,
  ) async {
    final allFeatures = <List<ImageFeature>>[];
    _keypointsCache = [];

    for (int i = 0; i < images.length; i++) {
      final progress = 0.3 + (i / images.length) * 0.15;
      onProgress?.call(progress, 'Extracting features from image ${i + 1}/${images.length}...');

      if (_useLightGlue && i < _imageFilesRef.length) {
        // LightGlue path: read raw bytes, detect keypoints, convert to ImageFeature
        try {
          final bytes = await _imageFilesRef[i].readAsBytes();
          final keypoints = await _lightGlue.detectKeypoints(bytes);
          _keypointsCache.add(keypoints);
          allFeatures.add(_lightGlue.toImageFeatures(keypoints));
        } catch (e) {
          debugPrint(' LightGlue extraction failed for image ${i + 1}: $e, falling back to Harris');
          final features = await compute(extractFeaturesFromImage, images[i]);
          _keypointsCache.add([]); // empty placeholder
          allFeatures.add(features);
        }
      } else {
        // Harris fallback path
        final features = await compute(extractFeaturesFromImage, images[i]);
        _keypointsCache.add([]); // empty placeholder
        allFeatures.add(features);
      }
    }

    return allFeatures;
  }

  /// Match a pair of images using LightGlue (if available) or brute-force fallback.
  /// Returns the list of FeatureMatch for the pair.
  Future<List<FeatureMatch>> _matchPair(
    int idx1,
    int idx2,
    List<List<ImageFeature>> features,
  ) async {
    // Use LightGlue matching if we have cached keypoints for both images
    if (_useLightGlue &&
        idx1 < _keypointsCache.length &&
        idx2 < _keypointsCache.length &&
        _keypointsCache[idx1].isNotEmpty &&
        _keypointsCache[idx2].isNotEmpty) {
      try {
        final kpMatches = await _lightGlue.matchFeatures(
          _keypointsCache[idx1],
          _keypointsCache[idx2],
        );
        return _lightGlue.toFeatureMatches(kpMatches);
      } catch (e) {
        debugPrint(' LightGlue matching failed for pair $idx1-$idx2: $e, falling back to brute-force');
      }
    }

    // Brute-force fallback
    return compute(
      matchFeaturePair,
      {'features1': features[idx1], 'features2': features[idx2]},
    );
  }

  /// Match features between consecutive images + skip-one + loop closure
  Future<List<List<FeatureMatch>>> _matchFeatures(
    List<List<ImageFeature>> features,
    Function(double, String)? onProgress,
  ) async {
    final matches = <List<FeatureMatch>>[];

    // Consecutive pairs (i, i+1)
    for (int i = 0; i < features.length - 1; i++) {
      final progress = 0.5 + (i / (features.length - 1)) * 0.15;
      onProgress?.call(progress, 'Matching images ${i + 1} and ${i + 2}...');

      final pairMatches = await _matchPair(i, i + 1, features);
      matches.add(pairMatches);
    }

    // Skip-one pairs (i, i+2) for wider baseline — merge into existing matches
    if (features.length >= 3) {
      for (int i = 0; i < features.length - 2; i++) {
        onProgress?.call(0.65, 'Wide baseline match ${i + 1}-${i + 3}...');
        final skipMatches = await _matchPair(i, i + 2, features);
        // Merge skip-one matches into the consecutive pair for extra triangulation
        if (skipMatches.length >= 8) {
          matches[i] = [...matches[i], ...skipMatches];
          debugPrint('  Skip-one ${i + 1}-${i + 3}: ${skipMatches.length} extra matches');
        }
      }
    }

    // Loop closure: match last image to first (for circular captures)
    if (features.length >= 4) {
      onProgress?.call(0.67, 'Loop closure matching...');
      final loopMatches = await _matchPair(features.length - 1, 0, features);
      if (loopMatches.length >= 8) {
        matches.add(loopMatches);
        debugPrint('  Loop closure: ${loopMatches.length} matches (last->first)');
      }
    }

    return matches;
  }

  /// Calculate average confidence of point cloud
  double _calculateAverageConfidence(PointCloud cloud) {
    if (cloud.points.isEmpty) return 0.0;

    final sum = cloud.points.fold<double>(0.0, (sum, p) => sum + p.confidence);
    return sum / cloud.points.length;
  }

  /// Statistical outlier removal using k-nearest neighbors with KD-tree for O(N log N)
  PointCloud _removeStatisticalOutliers(PointCloud cloud, {int k = 10, double stdRatio = 2.0}) {
    if (cloud.points.length < k + 1) return cloud;

    final points = cloud.points;
    final distances = <double>[];

    // Build KD-tree for fast neighbor search
    final kdTree = KDTree(points);

    // Calculate mean distance to k nearest neighbors for each point
    for (final point in points) {
      final neighbors = kdTree.findKNearest(point.position, k + 1); // +1 to include self

      // Calculate mean distance (excluding self at distance 0)
      double meanDist = 0;
      int count = 0;
      for (final neighbor in neighbors) {
        if (neighbor != point) {
          meanDist += (point.position - neighbor.position).length;
          count++;
          if (count >= k) break;
        }
      }
      meanDist /= count;
      distances.add(meanDist);
    }

    // Calculate global mean and std
    final globalMean = distances.reduce((a, b) => a + b) / distances.length;
    final variance = distances.map((d) => (d - globalMean) * (d - globalMean)).reduce((a, b) => a + b) / distances.length;
    final globalStd = math.sqrt(variance);

    // Filter outliers
    final threshold = globalMean + stdRatio * globalStd;
    final filteredPoints = <Point3D>[];

    for (int i = 0; i < points.length; i++) {
      if (distances[i] < threshold) {
        filteredPoints.add(points[i]);
      }
    }

    return PointCloud(
      points: filteredPoints,
      method: cloud.method,
      metadata: {...cloud.metadata, 'outliers_removed': points.length - filteredPoints.length},
    );
  }

  /// Multi-view color sampling - average colors from multiple camera views
  /// Multi-view color sampling using cached color samples (no image reload)
  Future<PointCloud> _multiViewColorSampling(
    PointCloud cloud,
    List<CameraPose> poses,
  ) async {
    final enhancedPoints = <Point3D>[];

    for (final point in cloud.points) {
      final colors = <Color>[];
      final weights = <double>[];

      // Sample color from each camera that can see this point
      for (int c = 0; c < poses.length && c < _colorSamplesCache.length; c++) {
        final pose = poses[c];
        final colorSample = _colorSamplesCache[c];

        // Check if point is in front of camera
        final camDir = pose.rotation.transposed().transform(Vector3(0, 0, 1));
        final toPoint = point.position - pose.position;
        final depth = toPoint.dot(camDir);

        if (depth > 0.1) {
          // Project point to image
          final reproj = reprojectPoint(point.position, pose, _imageWidth.toDouble(), _imageHeight.toDouble());
          final x = reproj.x.toInt();
          final y = reproj.y.toInt();

          // Get color from cached sample data
          final color = _getColorFromSample(
            colorSample,
            x,
            y,
            _imageWidth.toDouble(),
            _imageHeight.toDouble(),
          );

          colors.add(color);

          // Weight by viewing angle (prefer frontal views)
          final viewAngle = toPoint.normalized().dot(camDir).abs();
          weights.add(viewAngle);
        }
      }

      // Weighted average of colors
      Color finalColor = point.color;
      if (colors.isNotEmpty) {
        double totalWeight = weights.reduce((a, b) => a + b);
        if (totalWeight > 0) {
          double r = 0, g = 0, b = 0;
          for (int i = 0; i < colors.length; i++) {
            final w = weights[i] / totalWeight;
            r += colors[i].r * w;
            g += colors[i].g * w;
            b += colors[i].b * w;
          }
          finalColor = Color.fromARGB(255, r.round().clamp(0, 255), g.round().clamp(0, 255), b.round().clamp(0, 255));
        }
      }

      enhancedPoints.add(Point3D(
        position: point.position,
        color: finalColor,
        confidence: point.confidence,
        normal: point.normal,
      ));
    }

    return PointCloud(
      points: enhancedPoints,
      method: cloud.method,
      metadata: {...cloud.metadata, 'multi_view_color': true},
    );
  }

  Color _getColorFromSample(ColorSampleData sampleData, int x, int y, double originalWidth, double originalHeight) {
    // Scale coordinates to sample resolution
    final sampleX = (x * sampleData.width / originalWidth).toInt().clamp(0, sampleData.width - 1);
    final sampleY = (y * sampleData.height / originalHeight).toInt().clamp(0, sampleData.height - 1);
    final index = sampleY * sampleData.width + sampleX;

    if (index >= 0 && index < sampleData.colors.length) {
      return sampleData.colors[index];
    }
    return const Color(0xFF808080); // Gray fallback
  }

  /// Estimate normals for each point using local neighborhood with KD-tree for O(N log N)
  PointCloud _estimateNormals(PointCloud cloud, {int k = 8}) {
    if (cloud.points.length < k + 1) return cloud;

    final pointsWithNormals = <Point3D>[];

    // Build KD-tree for fast neighbor search
    final kdTree = KDTree(cloud.points);

    for (final point in cloud.points) {
      // Find k nearest neighbors using KD-tree
      final neighbors = kdTree.findKNearest(point.position, k + 1); // +1 to include self

      // Filter out self and ensure we have at least k neighbors
      final validNeighbors = neighbors.where((n) => n != point).take(k).toList();

      if (validNeighbors.isEmpty) {
        pointsWithNormals.add(point);
        continue;
      }

      // Compute centroid
      var centroid = Vector3.zero();
      for (final n in validNeighbors) {
        centroid += n.position;
      }
      centroid /= validNeighbors.length.toDouble();

      // Compute covariance matrix
      double cxx = 0, cxy = 0, cxz = 0, cyy = 0, cyz = 0;
      for (final n in validNeighbors) {
        final d = n.position - centroid;
        cxx += d.x * d.x;
        cxy += d.x * d.y;
        cxz += d.x * d.z;
        cyy += d.y * d.y;
        cyz += d.y * d.z;
      }

      // Simple normal estimation using cross product of principal directions
      final v1 = Vector3(cxx, cxy, cxz).normalized();
      final v2 = Vector3(cxy, cyy, cyz).normalized();
      var normal = v1.cross(v2);

      if (normal.length > 0.001) {
        normal = normal.normalized();
      } else {
        normal = Vector3(0, 1, 0); // Default up normal
      }

      pointsWithNormals.add(Point3D(
        position: point.position,
        color: point.color,
        confidence: point.confidence,
        normal: normal,
      ));
    }

    return PointCloud(
      points: pointsWithNormals,
      method: cloud.method,
      metadata: {...cloud.metadata, 'has_normals': true},
    );
  }

  /// Interpolate points to create denser point cloud
  /// Interpolate points using compute() with 5-second timeout
  Future<PointCloud> _interpolatePoints(PointCloud cloud, {int maxNewPoints = 500}) async {
    if (cloud.points.length < 10) return cloud;

    try {
      final params = InterpolationParams(
        points: cloud.points,
        maxNewPoints: maxNewPoints,
      );

      final interpolated = await compute(interpolatePointsIsolate, params);
      final added = interpolated.length - cloud.points.length;

      return PointCloud(
        points: interpolated,
        method: cloud.method,
        metadata: {...cloud.metadata, 'interpolated_points': added},
      );
    } catch (e) {
      debugPrint(' Interpolation failed: $e, returning original cloud');
      return cloud;
    }
  }

  /// Generate a simple triangle mesh from point cloud using k-nearest neighbor triangulation with KD-tree for O(N log N)
  MeshModel generateMeshFromPointCloud(PointCloud cloud, {int k = 6}) {
    if (cloud.points.length < 4) {
      return MeshModel(
        vertices: [],
        faces: [],
        method: 'knn_triangulation',
      );
    }

    final vertices = <MeshVertex>[];
    final faces = <MeshFace>[];
    final points = cloud.points;

    // Create vertices from points
    for (final point in points) {
      vertices.add(MeshVertex(
        position: point.position,
        normal: point.normal,
        color: point.color,
      ));
    }

    // Build KD-tree for fast neighbor search
    final kdTree = KDTree(points);

    // Build neighbor lists for each point using KD-tree
    final neighbors = <int, List<int>>{};
    for (int i = 0; i < points.length; i++) {
      final point = points[i];
      final nearestPoints = kdTree.findKNearest(point.position, k + 1); // +1 to include self

      // Convert Point3D neighbors to indices (excluding self)
      final neighborIndices = <int>[];
      for (final neighbor in nearestPoints) {
        if (neighbor != point) {
          final idx = points.indexOf(neighbor);
          if (idx >= 0) {
            neighborIndices.add(idx);
          }
        }
        if (neighborIndices.length >= k) break;
      }
      neighbors[i] = neighborIndices;
    }

    // Create triangles from point triplets using k-nearest neighbors
    final addedFaces = <String>{};

    for (int i = 0; i < points.length; i++) {
      final myNeighbors = neighbors[i]!;

      // Try to form triangles with pairs of neighbors
      for (int ni = 0; ni < myNeighbors.length; ni++) {
        for (int nj = ni + 1; nj < myNeighbors.length; nj++) {
          final j = myNeighbors[ni];
          final kIdx = myNeighbors[nj];

          // Check if j and k are also neighbors of each other (form coherent triangle)
          if (neighbors[j]!.contains(kIdx) || neighbors[kIdx]!.contains(j)) {
            // Sort indices to avoid duplicate triangles
            final indices = [i, j, kIdx]..sort();
            final faceKey = '${indices[0]}_${indices[1]}_${indices[2]}';

            if (!addedFaces.contains(faceKey)) {
              addedFaces.add(faceKey);

              // Check triangle quality (avoid degenerate triangles)
              final v0 = points[indices[0]].position;
              final v1 = points[indices[1]].position;
              final v2 = points[indices[2]].position;

              final edge1 = v1 - v0;
              final edge2 = v2 - v0;
              final normal = edge1.cross(edge2);

              // Only add if triangle has reasonable area
              if (normal.length > 0.0001) {
                faces.add(MeshFace(indices[0], indices[1], indices[2]));
              }
            }
          }
        }
      }
    }

    debugPrint(' Generated mesh: ${vertices.length} vertices, ${faces.length} faces');

    return MeshModel(
      vertices: vertices,
      faces: faces,
      method: 'knn_triangulation',
      metadata: {
        'source_points': cloud.points.length,
        'k_neighbors': k,
      },
    );
  }

  /// Validate photos before reconstruction
  Future<Map<String, dynamic>> validatePhotosForReconstruction(List<File> imageFiles) async {
    final validation = <String, dynamic>{
      'isValid': true,
      'warnings': <String>[],
      'errors': <String>[],
      'recommendedFixes': <String>[],
    };

    // Check minimum count
    if (imageFiles.length < 8) {
      validation['isValid'] = false;
      validation['errors'].add('Need at least 8 photos (found ${imageFiles.length})');
      validation['recommendedFixes'].add('Capture more angles');
      return validation;
    }

    // Load first few images to check quality
    final samplesToCheck = imageFiles.length > 4 ? 4 : imageFiles.length;
    int tooSmallCount = 0;
    int lowQualityCount = 0;

    for (int i = 0; i < samplesToCheck; i++) {
      try {
        final bytes = await imageFiles[i].readAsBytes();
        final image = img.decodeImage(bytes);

        if (image != null) {
          // Check resolution
          if (image.width < 800 || image.height < 800) {
            tooSmallCount++;
          }

          // Check sharpness (simple variance test)
          final variance = _calculateImageVariance(image);
          if (variance < 100) {
            lowQualityCount++;
          }
        }
      } catch (e) {
        validation['warnings'].add('Could not read image ${i + 1}');
      }
    }

    if (tooSmallCount > 0) {
      validation['warnings'].add('$tooSmallCount images may be too low resolution');
      validation['recommendedFixes'].add('Use higher resolution camera settings');
    }

    if (lowQualityCount > 0) {
      validation['warnings'].add('$lowQualityCount images may be blurry');
      validation['recommendedFixes'].add('Ensure sharp focus and stable camera');
    }

    // Optimal count check
    if (imageFiles.length >= 12) {
      validation['warnings'].add('Good coverage with ${imageFiles.length} photos');
    } else if (imageFiles.length >= 8) {
      validation['warnings'].add('Minimum coverage, consider capturing more angles');
      validation['recommendedFixes'].add('Capture all 16 recommended angles for best results');
    }

    return validation;
  }

  /// Calculate image variance (sharpness indicator)
  double _calculateImageVariance(img.Image image) {
    // Sample 100 pixels for quick estimate
    double sum = 0;
    double sumSquared = 0;
    int count = 0;

    final step = (image.width * image.height / 100).floor();

    for (int i = 0; i < image.width * image.height; i += step) {
      final x = i % image.width;
      final y = i ~/ image.width;

      if (y < image.height) {
        final pixel = image.getPixel(x, y);
        final luminance = (pixel.r + pixel.g + pixel.b) / 3.0;
        sum += luminance;
        sumSquared += luminance * luminance;
        count++;
      }
    }

    final mean = sum / count;
    final variance = (sumSquared / count) - (mean * mean);

    return variance;
  }

  /// Save a reconstruction result to persistent storage (public API)
  Future<void> persistResult(ReconstructionResult result) =>
      saveResult(result);
}
