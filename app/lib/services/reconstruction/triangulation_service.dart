import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';
import '../../models/point_cloud.dart';
import '../../models/camera_pose.dart';
import '../bundle_adjustment_service.dart' as ba;
import 'reconstruction_models.dart';
import 'reconstruction_isolates.dart';

/// Triangulate 3D points from feature matches and camera poses with ROBUST filtering
/// Uses compute() to run heavy calculations in isolate (off main thread)
Future<PointCloud> triangulatePoints(
  List<List<ImageFeature>> features,
  List<List<FeatureMatch>> matches,
  List<CameraPose> poses,
  List<ColorSampleData> colorSamplesCache,
  double imageWidth,
  double imageHeight,
) async {
  debugPrint(' Starting ROBUST triangulation (in isolate)...');

  // Run heavy triangulation in isolate using cached color samples
  final params = TriangulationParams(
    matches: matches,
    poses: poses,
    colorSamples: colorSamplesCache,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );

  final result = await compute(triangulatePointsIsolate, params);

  debugPrint(' Triangulation complete:');
  debugPrint('   Total: ${result.totalTriangulated}');
  debugPrint(' Passed: ${result.passed} (${(result.passed / result.totalTriangulated * 100).toInt()}%)');
  debugPrint(' Failed depth: ${result.failedDepth}');
  debugPrint(' Failed angle: ${result.failedAngle}');
  debugPrint(' Failed reproj: ${result.failedReprojection}');

  if (result.passed < 100) {
    debugPrint('Warning: Low point count. Consider:');
    debugPrint('   • Better lighting');
    debugPrint('   • More textured object');
    debugPrint('   • More photos (16 recommended)');
  }

  // Light bundle adjustment: 3 iterations of gradient descent on point positions
  if (result.points.length > 3 && poses.length >= 2) {
    debugPrint(' Running light bundle adjustment (3 iterations)...');
    await lightBundleAdjust(result.points, poses, matches, features, imageWidth, imageHeight);
  }

  return PointCloud(
    points: result.points,
    method: 'robust_sfm_ransac',
    metadata: {
      'image_count': colorSamplesCache.length,
      'total_triangulated': result.totalTriangulated,
      'passed_filters': result.passed,
      'pass_rate': result.passed / result.totalTriangulated,
      'failed_depth': result.failedDepth,
      'failed_angle': result.failedAngle,
      'failed_reprojection': result.failedReprojection,
    },
  );
}

/// Reproject 3D point back to 2D image coordinates
Vector2 reprojectPoint(Vector3 point3D, CameraPose pose, double imageWidth, double imageHeight) {
  final pCam = pose.rotation.transform(point3D - pose.position);
  final x = (pCam.x / pCam.z) * pose.focalLength + imageWidth / 2.0;
  final y = (pCam.y / pCam.z) * pose.focalLength + imageHeight / 2.0;
  return Vector2(x, y);
}

/// Light bundle adjustment: refine point positions using Levenberg-Marquardt
/// Only optimizes points (cameras fixed) with fewer iterations than full BA.
/// Light bundle adjustment using compute() to avoid blocking main thread
Future<void> lightBundleAdjust(
  List<Point3D> points,
  List<CameraPose> poses,
  List<List<FeatureMatch>> matches,
  List<List<ImageFeature>> features,
  double imageWidth,
  double imageHeight,
) async {
  final nCams = poses.length;
  final nPts = points.length;

  if (nCams < 2 || nPts == 0) return;

  final focalLength = poses.first.focalLength;
  final cx = imageWidth / 2.0;
  final cy = imageHeight / 2.0;

  // Convert camera poses to Matrix4
  final cameraPoseMatrices = <Matrix4>[];
  for (final pose in poses) {
    final R = pose.rotation;
    final t = -(R.transformed(pose.position));
    cameraPoseMatrices.add(Matrix4(
      R.entry(0, 0), R.entry(1, 0), R.entry(2, 0), 0,
      R.entry(0, 1), R.entry(1, 1), R.entry(2, 1), 0,
      R.entry(0, 2), R.entry(1, 2), R.entry(2, 2), 0,
      t.x, t.y, t.z, 1,
    ));
  }

  // Convert points to Vector3
  final points3D = points.map((p) => Vector3.copy(p.position)).toList();

  // Build observations from matches
  final observations = List.generate(
    nCams,
    (_) => List<Vector2?>.filled(nPts, null),
  );

  int pointIdx = 0;
  for (int i = 0; i < matches.length && i < nCams - 1; i++) {
    for (final match in matches[i]) {
      if (pointIdx >= nPts) break;
      observations[i][pointIdx] = Vector2(match.feature1.x, match.feature1.y);
      observations[i + 1][pointIdx] = Vector2(match.feature2.x, match.feature2.y);
      pointIdx++;
    }
  }

  // Run L-M in isolate with max 150 iterations and 30 second timeout (light version)
  final startTime = DateTime.now();
  try {
    final params = BundleAdjustParams(
      cameraPoseMatrices: cameraPoseMatrices,
      points3D: points3D,
      observations: observations,
      focalLength: focalLength,
      cx: cx,
      cy: cy,
      maxIterations: 150,
      robustCost: ba.RobustCost.huber,
      robustParam: 2.0,
    );

    final baResult = await compute(bundleAdjustIsolate, params).timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        debugPrint('   Light LM BA: TIMEOUT after 30s, keeping original points');
        throw TimeoutException('Bundle adjustment timed out');
      },
    );

    final duration = DateTime.now().difference(startTime);
    debugPrint('   Light LM BA: ${baResult.iterations} iters in ${duration.inSeconds}s, '
        'error ${baResult.initialError.toStringAsFixed(2)} -> ${baResult.finalError.toStringAsFixed(2)} px');

    // Update points in-place with refined positions
    for (int i = 0; i < nPts; i++) {
      points[i] = Point3D(
        position: baResult.refinedPoints[i],
        color: points[i].color,
        confidence: points[i].confidence,
        normal: points[i].normal,
      );
    }
  } catch (e) {
    final duration = DateTime.now().difference(startTime);
    if (e is TimeoutException) {
      debugPrint('   Light LM BA: Timed out after ${duration.inSeconds}s, keeping original points');
    } else {
      debugPrint('   Light LM BA: Failed: $e');
    }
    // Keep original points if optimization fails
  }
}

/// Bundle Adjustment - jointly optimize camera poses and 3D points
/// Uses Levenberg-Marquardt optimization via BundleAdjustmentService
Future<BundleAdjustmentResult> bundleAdjustment(
  PointCloud pointCloud,
  List<CameraPose> poses,
  List<List<ImageFeature>> features,
  List<List<FeatureMatch>> matches,
  double imageWidth,
  double imageHeight,
) async {
  final points = List<Point3D>.from(pointCloud.points);
  final nCams = poses.length;
  final nPts = points.length;

  if (nCams < 2 || nPts == 0) {
    return BundleAdjustmentResult(
      pointCloud: pointCloud,
      poses: poses,
      improvementPercent: 0,
    );
  }

  // Convert CameraPose objects to Matrix4 for BundleAdjustmentService.
  // CameraPose uses: pCam = R * (point - position), so t = -R * position.
  final focalLength = poses.first.focalLength;
  final cx = imageWidth / 2.0;
  final cy = imageHeight / 2.0;

  final cameraPoseMatrices = <Matrix4>[];
  for (final pose in poses) {
    final R = pose.rotation;
    final t = -(R.transformed(pose.position)); // t = -R * position
    cameraPoseMatrices.add(Matrix4(
      R.entry(0, 0), R.entry(1, 0), R.entry(2, 0), 0,
      R.entry(0, 1), R.entry(1, 1), R.entry(2, 1), 0,
      R.entry(0, 2), R.entry(1, 2), R.entry(2, 2), 0,
      t.x, t.y, t.z, 1,
    ));
  }

  // Convert Point3D positions to Vector3 list
  final points3D = points.map((p) => Vector3.copy(p.position)).toList();

  // Build observations matrix: observations[camIdx][pointIdx] = Vector2? observation
  // Points are ordered sequentially from matches: matches[i] pairs image i and i+1.
  // Each match contributes one point observed in cameras i and i+1.
  final observations = List.generate(
    nCams,
    (_) => List<Vector2?>.filled(nPts, null),
  );

  int pointIdx = 0;
  for (int i = 0; i < matches.length && i < nCams - 1; i++) {
    for (final match in matches[i]) {
      if (pointIdx >= nPts) break;
      observations[i][pointIdx] = Vector2(match.feature1.x, match.feature1.y);
      observations[i + 1][pointIdx] = Vector2(match.feature2.x, match.feature2.y);
      pointIdx++;
    }
  }

  // Run Levenberg-Marquardt bundle adjustment with Huber robust cost
  final baResult = ba.BundleAdjustmentService.optimize(
    cameraPoses: cameraPoseMatrices,
    points3D: points3D,
    observations: observations,
    focalLength: focalLength,
    cx: cx,
    cy: cy,
    maxIterations: 50,
    robustCost: ba.RobustCost.huber,
    robustParam: 2.0,
  );

  debugPrint('   LM Bundle Adjustment: ${baResult.iterations} iterations, '
      'converged=${baResult.converged}, '
      'error ${baResult.initialError.toStringAsFixed(2)} -> ${baResult.finalError.toStringAsFixed(2)} px');

  // Convert refined poses back to CameraPose objects
  final refinedPoses = <CameraPose>[];
  for (int i = 0; i < nCams; i++) {
    final m = baResult.refinedPoses[i];
    final R = Matrix3(
      m.entry(0, 0), m.entry(0, 1), m.entry(0, 2),
      m.entry(1, 0), m.entry(1, 1), m.entry(1, 2),
      m.entry(2, 0), m.entry(2, 1), m.entry(2, 2),
    );
    final t = Vector3(m.entry(0, 3), m.entry(1, 3), m.entry(2, 3));
    // Recover position: position = -R^T * t
    final rt = R.transposed();
    final position = -(rt.transformed(t));
    refinedPoses.add(CameraPose(
      position: position,
      rotation: R,
      focalLength: poses[i].focalLength,
    ));
  }

  // Convert refined points back to Point3D objects
  final refinedPoints = <Point3D>[];
  for (int i = 0; i < nPts; i++) {
    refinedPoints.add(Point3D(
      position: baResult.refinedPoints[i],
      color: points[i].color,
      confidence: points[i].confidence,
      normal: points[i].normal,
    ));
  }

  final improvement = baResult.initialError > 1e-12
      ? ((baResult.initialError - baResult.finalError) / baResult.initialError * 100).clamp(0.0, 100.0)
      : 0.0;

  return BundleAdjustmentResult(
    pointCloud: PointCloud(
      points: refinedPoints,
      method: pointCloud.method,
      metadata: pointCloud.metadata,
    ),
    poses: refinedPoses,
    improvementPercent: improvement,
  );
}
