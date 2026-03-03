import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart';

/// Quality assessment results for a photogrammetry reconstruction.
class ReconstructionQuality {
  final double meanReprojectionError;
  final double medianReprojectionError;
  final double p95ReprojectionError;
  final int matchedImages;
  final int totalImages;
  final int reconstructedPoints;
  final double? pointDensity;
  final double? gsd;
  final double completeness;
  final String qualityGrade;
  final List<String> warnings;
  final Duration processingTime;

  const ReconstructionQuality({
    required this.meanReprojectionError,
    required this.medianReprojectionError,
    required this.p95ReprojectionError,
    required this.matchedImages,
    required this.totalImages,
    required this.reconstructedPoints,
    this.pointDensity,
    this.gsd,
    required this.completeness,
    required this.qualityGrade,
    required this.warnings,
    required this.processingTime,
  });

  @override
  String toString() =>
      'ReconstructionQuality(grade=$qualityGrade, '
      'meanErr=${meanReprojectionError.toStringAsFixed(2)}px, '
      'points=$reconstructedPoints, '
      'matched=$matchedImages/$totalImages)';
}

/// Service for computing quality metrics for photogrammetry reconstructions.
class ReconstructionQualityService {
  /// Compute reprojection errors for all 3D points observed across cameras.
  ///
  /// [points3D] - The reconstructed 3D points.
  /// [observations2D] - For each point, its 2D observations in each camera.
  ///   observations2D[i] contains the 2D projections of points3D[i].
  /// [cameraPoses] - Camera extrinsic matrices (world-to-camera transforms).
  ///   cameraPoses[j] corresponds to the j-th camera for observations2D[i][j].
  /// [intrinsics] - Camera intrinsic parameters as [fx, fy, cx, cy] per camera.
  static List<double> computeReprojectionErrors(
    List<Vector3> points3D,
    List<List<Vector2>> observations2D,
    List<Matrix4> cameraPoses,
    List<List<double>> intrinsics,
  ) {
    final errors = <double>[];

    for (int i = 0; i < points3D.length; i++) {
      final pt3d = points3D[i];
      final observations = observations2D[i];

      for (int j = 0; j < observations.length; j++) {
        if (j >= cameraPoses.length || j >= intrinsics.length) continue;

        final observed = observations[j];
        final pose = cameraPoses[j];
        final k = intrinsics[j]; // [fx, fy, cx, cy]

        if (k.length < 4) continue;

        // Project 3D point to camera coordinates
        final pt4 = Vector4(pt3d.x, pt3d.y, pt3d.z, 1.0);
        final camPt = pose.transform(pt4);

        // Avoid division by zero / behind-camera points
        if (camPt.z.abs() < 1e-10) continue;

        // Project to 2D pixel coordinates
        final fx = k[0];
        final fy = k[1];
        final cx = k[2];
        final cy = k[3];

        final projX = fx * (camPt.x / camPt.z) + cx;
        final projY = fy * (camPt.y / camPt.z) + cy;

        // Euclidean distance between observed and reprojected
        final dx = projX - observed.x;
        final dy = projY - observed.y;
        errors.add(math.sqrt(dx * dx + dy * dy));
      }
    }

    return errors;
  }

  /// Compute an overall quality assessment for a reconstruction.
  static ReconstructionQuality assess({
    required List<double> reprojectionErrors,
    required int matchedImages,
    required int totalImages,
    required int pointCount,
    required Duration processingTime,
    double? estimatedGSD,
    double? estimatedArea,
  }) {
    final warnings = <String>[];

    // Handle empty error list
    if (reprojectionErrors.isEmpty) {
      return ReconstructionQuality(
        meanReprojectionError: 0.0,
        medianReprojectionError: 0.0,
        p95ReprojectionError: 0.0,
        matchedImages: matchedImages,
        totalImages: totalImages,
        reconstructedPoints: pointCount,
        pointDensity: null,
        gsd: estimatedGSD,
        completeness: 0.0,
        qualityGrade: 'poor',
        warnings: ['No reprojection data available'],
        processingTime: processingTime,
      );
    }

    // Sort errors for percentile computation
    final sorted = List<double>.from(reprojectionErrors)..sort();

    final mean = sorted.reduce((a, b) => a + b) / sorted.length;
    final median = _percentile(sorted, 0.5);
    final p95 = _percentile(sorted, 0.95);

    // Completeness: ratio of matched to total images
    final completeness =
        totalImages > 0 ? matchedImages / totalImages.toDouble() : 0.0;

    // Point density (points per m^2)
    double? pointDensity;
    if (estimatedArea != null && estimatedArea > 0) {
      pointDensity = pointCount / estimatedArea;
    }

    // Generate warnings
    if (completeness < 0.5) {
      warnings.add(
          'Low image match ratio (${(completeness * 100).toStringAsFixed(0)}%): '
          'many images could not be registered');
    }
    if (mean > 2.0) {
      warnings.add(
          'High mean reprojection error (${mean.toStringAsFixed(2)}px): '
          'consider recapturing with better overlap');
    }
    if (p95 > 5.0) {
      warnings.add(
          'Some points have large errors (p95=${p95.toStringAsFixed(2)}px): '
          'outliers may affect quality');
    }
    if (pointCount < 100) {
      warnings.add(
          'Very few reconstructed points ($pointCount): '
          'object may lack texture or images may lack overlap');
    }
    if (matchedImages < 3) {
      warnings.add(
          'Fewer than 3 images matched: '
          'reconstruction geometry may be unreliable');
    }

    final grade = gradeQuality(mean, completeness, pointCount);

    return ReconstructionQuality(
      meanReprojectionError: mean,
      medianReprojectionError: median,
      p95ReprojectionError: p95,
      matchedImages: matchedImages,
      totalImages: totalImages,
      reconstructedPoints: pointCount,
      pointDensity: pointDensity,
      gsd: estimatedGSD,
      completeness: completeness,
      qualityGrade: grade,
      warnings: warnings,
      processingTime: processingTime,
    );
  }

  /// Grade the reconstruction quality based on reprojection error,
  /// completeness, and point count.
  ///
  /// Returns one of: 'excellent', 'good', 'acceptable', 'poor'.
  static String gradeQuality(
    double meanError,
    double completeness,
    int pointCount,
  ) {
    // Score each dimension 0-3 (excellent=3, good=2, acceptable=1, poor=0)
    int errorScore;
    if (meanError <= 0.5) {
      errorScore = 3;
    } else if (meanError <= 1.0) {
      errorScore = 2;
    } else if (meanError <= 2.0) {
      errorScore = 1;
    } else {
      errorScore = 0;
    }

    int completenessScore;
    if (completeness >= 0.9) {
      completenessScore = 3;
    } else if (completeness >= 0.7) {
      completenessScore = 2;
    } else if (completeness >= 0.5) {
      completenessScore = 1;
    } else {
      completenessScore = 0;
    }

    int pointScore;
    if (pointCount >= 5000) {
      pointScore = 3;
    } else if (pointCount >= 1000) {
      pointScore = 2;
    } else if (pointCount >= 100) {
      pointScore = 1;
    } else {
      pointScore = 0;
    }

    // Weighted average: error matters most
    final totalScore =
        (errorScore * 3 + completenessScore * 2 + pointScore * 1) / 6.0;

    if (totalScore >= 2.5) return 'excellent';
    if (totalScore >= 1.5) return 'good';
    if (totalScore >= 0.8) return 'acceptable';
    return 'poor';
  }

  /// Compute the [p]-th percentile (0..1) from a pre-sorted list.
  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0.0;
    if (sorted.length == 1) return sorted[0];

    final index = p * (sorted.length - 1);
    final lower = index.floor();
    final upper = index.ceil();

    if (lower == upper) return sorted[lower];

    final fraction = index - lower;
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction;
  }
}
