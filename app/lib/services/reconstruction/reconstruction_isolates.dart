import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';
import '../../models/point_cloud.dart';
import '../../models/camera_pose.dart';
import '../bundle_adjustment_service.dart' as ba;
import 'reconstruction_models.dart';

// ============================================================================
// TOP-LEVEL ISOLATE FUNCTIONS (required by compute())
// ============================================================================

/// Top-level function for triangulation in isolate (no closures allowed)
Future<TriangulationResult> triangulatePointsIsolate(TriangulationParams params) async {
  final points = <Point3D>[];
  final seenFeatures = <String>{};
  int totalTriangulated = 0;
  int passed = 0;
  int failedDepth = 0;
  int failedAngle = 0;
  int failedReprojection = 0;

  // Triangulate points from image pairs
  for (int i = 0; i < params.matches.length; i++) {
    final pairMatches = params.matches[i];
    final CameraPose pose1;
    final CameraPose pose2;
    final int img1Idx;

    if (i < params.poses.length - 1) {
      pose1 = params.poses[i];
      pose2 = params.poses[i + 1];
      img1Idx = i;
    } else if (i == params.matches.length - 1 && params.matches.length > params.poses.length - 1) {
      pose1 = params.poses.last;
      pose2 = params.poses.first;
      img1Idx = params.poses.length - 1;
    } else {
      continue;
    }

    for (final match in pairMatches) {
      final featureId = '${i}_${match.feature1.x}_${match.feature1.y}';
      if (seenFeatures.contains(featureId)) continue;
      seenFeatures.add(featureId);
      totalTriangulated++;

      // Transform rays to world coordinates
      final cx = params.imageWidth / 2.0;
      final cy = params.imageHeight / 2.0;
      final ray1Dir = pose1.rotation.transposed().transform(Vector3(
        (match.feature1.x - cx) / pose1.focalLength,
        (match.feature1.y - cy) / pose1.focalLength,
        1.0,
      ).normalized());

      final ray2Dir = pose2.rotation.transposed().transform(Vector3(
        (match.feature2.x - cx) / pose2.focalLength,
        (match.feature2.y - cy) / pose2.focalLength,
        1.0,
      ).normalized());

      // Triangulate point
      final point3D = _triangulateRayPairStatic(
        pose1.position,
        ray1Dir,
        pose2.position,
        ray2Dir,
      );

      // Quality check 1: Depth validation
      final depth1 = (point3D - pose1.position).dot(pose1.rotation.transposed().transform(Vector3(0, 0, 1)));
      final depth2 = (point3D - pose2.position).dot(pose2.rotation.transposed().transform(Vector3(0, 0, 1)));

      if (depth1 < 0.1 || depth2 < 0.1) {
        failedDepth++;
        continue;
      }

      // Quality check 2: Triangulation angle
      final angle = _calculateTriangulationAngleStatic(pose1.position, pose2.position, point3D);
      final angleDegrees = angle * (180.0 / math.pi);

      if (angleDegrees < 5 || angleDegrees > 175) {
        failedAngle++;
        continue;
      }

      // Quality check 3: Reprojection error
      final reproj1 = _reprojectPointStatic(point3D, pose1, params.imageWidth, params.imageHeight);
      final reproj2 = _reprojectPointStatic(point3D, pose2, params.imageWidth, params.imageHeight);

      final error1 = math.sqrt(
        math.pow(reproj1.x - match.feature1.x, 2) +
        math.pow(reproj1.y - match.feature1.y, 2)
      );
      final error2 = math.sqrt(
        math.pow(reproj2.x - match.feature2.x, 2) +
        math.pow(reproj2.y - match.feature2.y, 2)
      );

      final maxError = math.max(error1, error2);
      if (maxError > 5.0) {
        failedReprojection++;
        continue;
      }

      passed++;

      // Get color from color sample data
      final colorData = params.colorSamples[img1Idx.clamp(0, params.colorSamples.length - 1)];
      final color = _getColorFromSample(
        colorData,
        match.feature1.x.toInt(),
        match.feature1.y.toInt(),
        params.imageWidth,
        params.imageHeight,
      );

      // Calculate confidence
      final angleConfidence = angleDegrees > 30 && angleDegrees < 60 ? 1.0 : 0.7;
      final reprojConfidence = 1.0 - (maxError / 5.0).clamp(0.0, 1.0);
      final confidence = angleConfidence * reprojConfidence;

      points.add(Point3D(
        position: point3D,
        color: color,
        confidence: confidence,
      ));
    }
  }

  return TriangulationResult(
    points: points,
    totalTriangulated: totalTriangulated,
    passed: passed,
    failedDepth: failedDepth,
    failedAngle: failedAngle,
    failedReprojection: failedReprojection,
  );
}

/// Top-level function for bundle adjustment in isolate
Future<BundleAdjustmentIsolateResult> bundleAdjustIsolate(BundleAdjustParams params) async {
  final baResult = ba.BundleAdjustmentService.optimize(
    cameraPoses: params.cameraPoseMatrices,
    points3D: params.points3D,
    observations: params.observations,
    focalLength: params.focalLength,
    cx: params.cx,
    cy: params.cy,
    maxIterations: params.maxIterations,
    robustCost: params.robustCost,
    robustParam: params.robustParam,
  );

  return BundleAdjustmentIsolateResult(
    refinedPoses: baResult.refinedPoses,
    refinedPoints: baResult.refinedPoints,
    iterations: baResult.iterations,
    converged: baResult.converged,
    initialError: baResult.initialError,
    finalError: baResult.finalError,
  );
}

/// Top-level function for point interpolation in isolate with timeout
Future<List<Point3D>> interpolatePointsIsolate(InterpolationParams params) async {
  final startTime = DateTime.now();
  const timeoutDuration = Duration(seconds: 5);

  final interpolated = List<Point3D>.from(params.points);
  final original = params.points;
  int added = 0;

  // Early termination: Check timeout every N iterations
  const checkInterval = 100;
  int iterCount = 0;

  for (int i = 0; i < original.length && added < params.maxNewPoints; i++) {
    for (int j = i + 1; j < original.length && added < params.maxNewPoints; j++) {
      iterCount++;

      // Check timeout periodically
      if (iterCount % checkInterval == 0) {
        if (DateTime.now().difference(startTime) > timeoutDuration) {
          debugPrint(' Interpolation timeout reached, returning early with $added points added');
          return interpolated;
        }
      }

      final dist = (original[i].position - original[j].position).length;

      // Only interpolate between nearby points
      if (dist > 0.01 && dist < 0.5) {
        final midPos = (original[i].position + original[j].position) / 2;

        final midColor = Color.fromARGB(
          255,
          ((original[i].color.r + original[j].color.r) / 2).round(),
          ((original[i].color.g + original[j].color.g) / 2).round(),
          ((original[i].color.b + original[j].color.b) / 2).round(),
        );

        final midConf = (original[i].confidence + original[j].confidence) / 2;

        Vector3? midNormal;
        if (original[i].normal != null && original[j].normal != null) {
          midNormal = ((original[i].normal! + original[j].normal!) / 2).normalized();
        }

        interpolated.add(Point3D(
          position: midPos,
          color: midColor,
          confidence: midConf * 0.9,
          normal: midNormal,
        ));
        added++;
      }
    }
  }

  return interpolated;
}

// Static helper functions for isolate (no instance access)
Vector3 _triangulateRayPairStatic(Vector3 o1, Vector3 d1, Vector3 o2, Vector3 d2) {
  final w = o1 - o2;
  final a = d1.dot(d1);
  final b = d1.dot(d2);
  final c = d2.dot(d2);
  final d = d1.dot(w);
  final e = d2.dot(w);

  final denom = a * c - b * b;
  final t1 = (b * e - c * d) / denom;
  final t2 = (a * e - b * d) / denom;

  final p1 = o1 + d1 * t1;
  final p2 = o2 + d2 * t2;

  return (p1 + p2) / 2;
}

Vector2 _reprojectPointStatic(Vector3 point3D, CameraPose pose, double imageWidth, double imageHeight) {
  final pCam = pose.rotation.transform(point3D - pose.position);
  final x = (pCam.x / pCam.z) * pose.focalLength + imageWidth / 2.0;
  final y = (pCam.y / pCam.z) * pose.focalLength + imageHeight / 2.0;
  return Vector2(x, y);
}

double _calculateTriangulationAngleStatic(Vector3 cam1, Vector3 cam2, Vector3 point) {
  final dir1 = (point - cam1).normalized();
  final dir2 = (point - cam2).normalized();
  return math.acos(dir1.dot(dir2).clamp(-1.0, 1.0));
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
