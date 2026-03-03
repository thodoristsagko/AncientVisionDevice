import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';
import '../../models/camera_pose.dart';
import '../sfm_robust.dart';
import 'reconstruction_models.dart';

/// Estimate camera poses using PRODUCTION-GRADE incremental SfM with RANSAC
Future<List<CameraPose>> estimateCameraPoses(
  List<List<FeatureMatch>> matches,
  int imageCount,
  double imageWidth,
  double imageHeight, {
  double? exifFocalLengthPx,
}) async {
  final poses = <CameraPose>[];
  // Use EXIF focal length if available, otherwise estimate from image dimensions (~28mm equivalent on mobile)
  final focalLength = exifFocalLengthPx ?? math.max(imageWidth, imageHeight) * 0.85;

  // First camera at origin
  poses.add(CameraPose(
    position: Vector3.zero(),
    rotation: Matrix3.identity(),
    focalLength: focalLength,
  ));

  debugPrint(' Starting ROBUST camera pose estimation with RANSAC...');

  // Estimate each subsequent camera pose using Essential Matrix + RANSAC
  // Only process consecutive pairs (skip loop closure which is extra)
  final poseMatchCount = math.min(matches.length, imageCount - 1);
  for (int i = 0; i < poseMatchCount; i++) {
    final pairMatches = matches[i];

    if (pairMatches.length < 8) {
      // Not enough matches - suggest solutions
      throw Exception(
        'Images ${i + 1} and ${i + 2} don\'t overlap enough.\n'
        'Found only ${pairMatches.length} matching points (need 8+).\n\n'
        'Solutions:\n'
        '• Capture smaller angle steps between photos\n'
        '• Ensure 60-80% overlap between adjacent shots\n'
        '• Try cloud processing (more robust)'
      );
    }

    try {
      // ✅ REAL ALGORITHM: RANSAC + Essential Matrix estimation
      debugPrint('  🔍 Image pair ${i + 1}-${i + 2}: ${pairMatches.length} matches');

      final essentialResult = RobustSfM.estimateEssentialMatrix(
        pairMatches,
        focalLength,
      );

      debugPrint(' RANSAC: ${essentialResult.inlierCount} inliers '
          '(${(essentialResult.inlierRatio * 100).toInt()}%)');

      // Recover camera pose from Essential Matrix
      final poseHypotheses = RobustSfM.recoverPoseFromEssential(
        essentialResult.matrix,
        essentialResult.inliers,
        focalLength,
      );

      if (poseHypotheses.isEmpty) {
        throw Exception('Failed to recover camera pose from Essential Matrix');
      }

      // Choose best hypothesis (most points with positive depth)
      final bestPose = poseHypotheses.first;

      // Transform to world coordinates (relative to previous camera)
      final prevPose = poses[i];
      final worldRotation = prevPose.rotation * bestPose.rotation;
      final worldPosition = prevPose.position + prevPose.rotation.transform(bestPose.translation);

      poses.add(CameraPose(
        position: worldPosition,
        rotation: worldRotation,
        focalLength: focalLength,
      ));

      debugPrint(' Pose ${i + 2}: pos=${worldPosition.x.toStringAsFixed(2)}, '
          '${worldPosition.y.toStringAsFixed(2)}, ${worldPosition.z.toStringAsFixed(2)}');

    } catch (e) {
      // RANSAC failed - provide actionable error
      debugPrint(' Pose estimation failed: $e');
      throw Exception(
        'Camera pose estimation failed for images ${i + 1}-${i + 2}:\n$e'
      );
    }
  }

  debugPrint(' Estimated ${poses.length} camera poses with RANSAC');
  return poses;
}
