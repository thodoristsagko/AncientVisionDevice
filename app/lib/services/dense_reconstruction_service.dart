import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';
import '../models/point_cloud.dart';
import '../models/mesh_model.dart';
import 'reconstruction/index.dart';
import 'patch_match_stereo.dart';
import 'depth_map_fusion.dart';
import 'poisson_mesh_service.dart';

/// Result of dense reconstruction.
class DenseReconstructionResult {
  final PointCloud pointCloud;
  final MeshModel? mesh;
  final int depthMapsComputed;
  final Duration processingTime;
  final String? errorMessage;

  DenseReconstructionResult({
    required this.pointCloud,
    this.mesh,
    required this.depthMapsComputed,
    required this.processingTime,
    this.errorMessage,
  });
}

/// Orchestrates dense MVS reconstruction from captured images.
///
/// Pipeline:
/// 1. Use sparse SfM poses from [ReconstructionService]
/// 2. For each image pair, run PatchMatch stereo to estimate depth
/// 3. Fuse depth maps into a consistent dense point cloud
/// 4. Optionally extract mesh via Marching Cubes
class DenseReconstructionService {
  final PatchMatchStereo _stereo;
  final DepthMapFusion _fusion;
  final PoissonMeshService _mesher;

  /// Resolution for stereo matching (longest dimension).
  final int stereoResolution;

  DenseReconstructionService({
    this.stereoResolution = 512,
    PatchMatchStereo? stereo,
    DepthMapFusion? fusion,
    PoissonMeshService? mesher,
  })  :
        _stereo = stereo ?? PatchMatchStereo(resolution: stereoResolution),
        _fusion = fusion ?? DepthMapFusion(),
        _mesher = mesher ?? PoissonMeshService();

  /// Run dense reconstruction from images and sparse camera poses.
  ///
  /// [imageFiles] - captured images.
  /// [poses] - camera poses from sparse SfM.
  /// [focalLength] - camera focal length in pixels.
  /// [generateMesh] - if true, also extract a triangle mesh.
  Future<DenseReconstructionResult> reconstruct({
    required List<File> imageFiles,
    required List<CameraPose> poses,
    required double focalLength,
    bool generateMesh = true,
    Function(double progress, String status)? onProgress,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final startTime = DateTime.now();

    try {
      return await _reconstructImpl(
        imageFiles: imageFiles,
        poses: poses,
        focalLength: focalLength,
        generateMesh: generateMesh,
        onProgress: onProgress,
        startTime: startTime,
      ).timeout(timeout, onTimeout: () {
        if (kDebugMode) {
        debugPrint('DenseReconstruction: Timed out after ${timeout.inSeconds}s');
        }
        return DenseReconstructionResult(
          pointCloud: PointCloud(points: [], method: 'dense_mvs_timeout'),
          depthMapsComputed: 0,
          processingTime: DateTime.now().difference(startTime),
        );
      });
    } catch (e) {
      if (kDebugMode) {
      debugPrint('DenseReconstruction: Unexpected error: $e');
      }
      return DenseReconstructionResult(
        pointCloud: PointCloud(points: [], method: 'dense_mvs_error'),
        depthMapsComputed: 0,
        processingTime: DateTime.now().difference(startTime),
      );
    }
  }

  Future<DenseReconstructionResult> _reconstructImpl({
    required List<File> imageFiles,
    required List<CameraPose> poses,
    required double focalLength,
    required bool generateMesh,
    required DateTime startTime,
    Function(double progress, String status)? onProgress,
  }) async {
    final depthMaps = <DepthMap>[];
    final projections = <Matrix4>[];
    final colorArrays = <Float32List>[];

    onProgress?.call(0.0, 'Loading images for dense reconstruction...');

    // Load and downsample all images to stereo resolution (preserving aspect ratio)
    final grayImages = <Float32List>[];
    final colorImages = <Float32List>[];
    final imageWidths = <int>[];
    final imageHeights = <int>[];
    final resizeScales = <double>[];

    for (int i = 0; i < imageFiles.length && i < poses.length; i++) {
      try {
        final bytes = await imageFiles[i].readAsBytes();
        final image = img.decodeImage(bytes);
        if (image == null) continue;

        final originalWidth = image.width;
        final originalHeight = image.height;

        // Resize preserving aspect ratio (longest side = stereoResolution)
        final img.Image resized;
        final int resizedWidth;
        final int resizedHeight;
        final double scale;

        if (originalWidth >= originalHeight) {
          resizedWidth = stereoResolution;
          resizedHeight = (originalHeight * stereoResolution / originalWidth).round();
          scale = stereoResolution / originalWidth;
          resized = img.copyResize(
            image,
            width: resizedWidth,
            interpolation: img.Interpolation.linear,
          );
        } else {
          resizedWidth = (originalWidth * stereoResolution / originalHeight).round();
          resizedHeight = stereoResolution;
          scale = stereoResolution / originalHeight;
          resized = img.copyResize(
            image,
            height: resizedHeight,
            interpolation: img.Interpolation.linear,
          );
        }

        imageWidths.add(resizedWidth);
        imageHeights.add(resizedHeight);
        resizeScales.add(scale);

        // Convert to grayscale float array
        final gray = Float32List(resizedWidth * resizedHeight);
        final color = Float32List(resizedWidth * resizedHeight * 4);
        for (int y = 0; y < resizedHeight; y++) {
          for (int x = 0; x < resizedWidth; x++) {
            final pixel = resized.getPixel(x, y);
            final idx = y * resizedWidth + x;
            gray[idx] = (pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114)
                .toDouble();
            color[idx * 4] = pixel.r.toDouble();
            color[idx * 4 + 1] = pixel.g.toDouble();
            color[idx * 4 + 2] = pixel.b.toDouble();
            color[idx * 4 + 3] = 255.0;
          }
        }

        grayImages.add(gray);
        colorImages.add(color);
      } catch (e) {
        if (kDebugMode) {
        debugPrint('DenseReconstruction: Failed to load image $i: $e');
        }
      }
    }

    if (grayImages.length < 2) {
      return DenseReconstructionResult(
        pointCloud: PointCloud(points: [], method: 'dense_mvs_failed'),
        depthMapsComputed: 0,
        processingTime: DateTime.now().difference(startTime),
      );
    }

    // Compute depth maps for consecutive pairs (i, i+1) and skip-one pairs (i, i+2)
    final totalPairs = (grayImages.length - 1) + (grayImages.length >= 3 ? grayImages.length - 2 : 0);
    int pairCount = 0;

    // Consecutive pairs (i, i+1)
    for (int i = 0; i < grayImages.length - 1; i++) {
      onProgress?.call(
        0.1 + 0.6 * (pairCount / totalPairs),
        'Computing depth map ${pairCount + 1}/$totalPairs (consecutive)...',
      );

      try {
        final dm = await _stereo.estimate(
          grayImages[i],
          grayImages[i + 1],
          imageWidths[i],
          imageHeights[i],
        );
        depthMaps.add(dm);

        // Build projection matrix from pose with scaled focal length
        final pose = poses[i];
        final R = pose.rotation;
        final t = -(R.transformed(pose.position));
        final proj = Matrix4(
          R.entry(0, 0), R.entry(1, 0), R.entry(2, 0), 0,
          R.entry(0, 1), R.entry(1, 1), R.entry(2, 1), 0,
          R.entry(0, 2), R.entry(1, 2), R.entry(2, 2), 0,
          t.x, t.y, t.z, 1,
        );
        projections.add(proj);
        colorArrays.add(colorImages[i]);
        pairCount++;
      } catch (e) {
        debugPrint(
            'DenseReconstruction: Depth estimation failed for consecutive pair $i: $e');
      }
    }

    // Skip-one pairs (i, i+2) for better triangulation
    if (grayImages.length >= 3) {
      for (int i = 0; i < grayImages.length - 2; i++) {
        onProgress?.call(
          0.1 + 0.6 * (pairCount / totalPairs),
          'Computing depth map ${pairCount + 1}/$totalPairs (skip-one)...',
        );

        try {
          final dm = await _stereo.estimate(
            grayImages[i],
            grayImages[i + 2],
            imageWidths[i],
            imageHeights[i],
          );
          depthMaps.add(dm);

          // Build projection matrix from pose with scaled focal length
          final pose = poses[i];
          final R = pose.rotation;
          final t = -(R.transformed(pose.position));
          final proj = Matrix4(
            R.entry(0, 0), R.entry(1, 0), R.entry(2, 0), 0,
            R.entry(0, 1), R.entry(1, 1), R.entry(2, 1), 0,
            R.entry(0, 2), R.entry(1, 2), R.entry(2, 2), 0,
            t.x, t.y, t.z, 1,
          );
          projections.add(proj);
          colorArrays.add(colorImages[i]);
          pairCount++;
        } catch (e) {
          debugPrint(
              'DenseReconstruction: Depth estimation failed for skip-one pair $i: $e');
        }
      }
    }

    if (depthMaps.length < 3) {
      return DenseReconstructionResult(
        pointCloud: PointCloud(points: [], method: 'dense_mvs_failed'),
        depthMapsComputed: depthMaps.length,
        processingTime: DateTime.now().difference(startTime),
        errorMessage: 'Dense reconstruction failed: Only ${depthMaps.length} depth maps succeeded (need at least 3). '
            'This usually means stereo matching failed for most image pairs. '
            'Try: better lighting, more textured object, or different capture angles.',
      );
    }

    // Fuse depth maps
    onProgress?.call(0.75, 'Fusing ${depthMaps.length} depth maps...');
    // Use the first image dimensions and scale as reference
    final refWidth = imageWidths.isNotEmpty ? imageWidths[0] : stereoResolution;
    final refHeight = imageHeights.isNotEmpty ? imageHeights[0] : stereoResolution;
    final refScale = resizeScales.isNotEmpty ? resizeScales[0] : 1.0;

    final denseCloud = await _fusion.fuse(
      depthMaps: depthMaps,
      projections: projections,
      colorImages: colorArrays,
      imageWidth: refWidth,
      imageHeight: refHeight,
      focalLength: focalLength * refScale, // Scale focal length by actual resize factor
    );

    if (kDebugMode) {
      debugPrint(
          'DenseReconstruction: ${denseCloud.points.length} dense points');
    }

    // Optional mesh extraction
    MeshModel? mesh;
    if (generateMesh && denseCloud.points.length >= 4) {
      onProgress?.call(0.85, 'Extracting mesh...');
      try {
        mesh = await _mesher.generateMesh(denseCloud);
        if (kDebugMode) {
          debugPrint(
              'DenseReconstruction: Mesh with ${mesh.vertices.length} vertices, ${mesh.faces.length} faces');
        }
      } catch (e) {
        debugPrint('DenseReconstruction: Mesh extraction failed: $e');
      }
    }

    onProgress?.call(1.0, 'Dense reconstruction complete!');

    return DenseReconstructionResult(
      pointCloud: denseCloud,
      mesh: mesh,
      depthMapsComputed: depthMaps.length,
      processingTime: DateTime.now().difference(startTime),
    );
  }
}
