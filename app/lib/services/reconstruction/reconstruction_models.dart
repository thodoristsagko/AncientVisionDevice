import 'dart:ui' show Color;
import 'package:vector_math/vector_math_64.dart';
import '../../models/point_cloud.dart';
import '../../models/camera_pose.dart';
import '../bundle_adjustment_service.dart' as ba;

/// Represents a feature point in an image
class ImageFeature {
  final double x;
  final double y;
  final double strength;
  final List<double> descriptor;

  ImageFeature({
    required this.x,
    required this.y,
    required this.strength,
    required this.descriptor,
  });
}

/// Represents a match between features in two images
class FeatureMatch {
  final ImageFeature feature1;
  final ImageFeature feature2;
  final double distance;

  FeatureMatch({
    required this.feature1,
    required this.feature2,
    required this.distance,
  });
}

// Note: Made public (no underscore) so it can be used in feature_matcher.dart
class MatchCandidate {
  final int idx;
  final double distance;
  MatchCandidate(this.idx, this.distance);
}

/// Result of bundle adjustment optimization
class BundleAdjustmentResult {
  final PointCloud pointCloud;
  final List<CameraPose> poses;
  final double improvementPercent;

  BundleAdjustmentResult({
    required this.pointCloud,
    required this.poses,
    required this.improvementPercent,
  });
}

// ============================================================================
// PARAMETER CLASSES FOR ISOLATES
// ============================================================================

class TriangulationParams {
  final List<List<FeatureMatch>> matches;
  final List<CameraPose> poses;
  final List<ColorSampleData> colorSamples;
  final double imageWidth;
  final double imageHeight;

  TriangulationParams({
    required this.matches,
    required this.poses,
    required this.colorSamples,
    required this.imageWidth,
    required this.imageHeight,
  });
}

class TriangulationResult {
  final List<Point3D> points;
  final int totalTriangulated;
  final int passed;
  final int failedDepth;
  final int failedAngle;
  final int failedReprojection;

  TriangulationResult({
    required this.points,
    required this.totalTriangulated,
    required this.passed,
    required this.failedDepth,
    required this.failedAngle,
    required this.failedReprojection,
  });
}

class BundleAdjustParams {
  final List<Matrix4> cameraPoseMatrices;
  final List<Vector3> points3D;
  final List<List<Vector2?>> observations;
  final double focalLength;
  final double cx;
  final double cy;
  final int maxIterations;
  final ba.RobustCost robustCost;
  final double robustParam;

  BundleAdjustParams({
    required this.cameraPoseMatrices,
    required this.points3D,
    required this.observations,
    required this.focalLength,
    required this.cx,
    required this.cy,
    required this.maxIterations,
    required this.robustCost,
    required this.robustParam,
  });
}

class BundleAdjustmentIsolateResult {
  final List<Matrix4> refinedPoses;
  final List<Vector3> refinedPoints;
  final int iterations;
  final bool converged;
  final double initialError;
  final double finalError;

  BundleAdjustmentIsolateResult({
    required this.refinedPoses,
    required this.refinedPoints,
    required this.iterations,
    required this.converged,
    required this.initialError,
    required this.finalError,
  });
}

class InterpolationParams {
  final List<Point3D> points;
  final int maxNewPoints;

  InterpolationParams({
    required this.points,
    required this.maxNewPoints,
  });
}

class ColorSampleData {
  final int width;
  final int height;
  final List<Color> colors;

  ColorSampleData({
    required this.width,
    required this.height,
    required this.colors,
  });
}
