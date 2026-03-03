import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:ancient_vision/services/reconstruction_quality_service.dart';

void main() {
  group('ReconstructionQualityService gradeQuality', () {
    test('perfect reprojection gets excellent grade', () {
      final grade = ReconstructionQualityService.gradeQuality(
        0.0, // perfect mean error
        1.0, // all images matched
        10000, // many points
      );
      expect(grade, 'excellent');
    });

    test('high error gets poor grade', () {
      final grade = ReconstructionQualityService.gradeQuality(
        5.0, // high mean error
        0.3, // low completeness
        50, // few points
      );
      expect(grade, 'poor');
    });

    test('moderate values get good grade', () {
      final grade = ReconstructionQualityService.gradeQuality(
        0.8, // acceptable error
        0.8, // decent completeness
        2000, // reasonable points
      );
      expect(grade, 'good');
    });

    test('borderline values get acceptable grade', () {
      final grade = ReconstructionQualityService.gradeQuality(
        1.5, // moderate error
        0.6, // moderate completeness
        500, // moderate points
      );
      expect(grade, 'acceptable');
    });
  });

  group('ReconstructionQualityService assess', () {
    test('generates warning for low match ratio', () {
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [0.5, 0.6, 0.7, 0.8],
        matchedImages: 3,
        totalImages: 10, // 30% match ratio
        pointCount: 1000,
        processingTime: const Duration(seconds: 10),
      );

      expect(
        quality.warnings,
        contains(predicate<String>((s) => s.contains('Low image match ratio'))),
      );
      expect(quality.completeness, closeTo(0.3, 0.01));
    });

    test('generates warning for high mean reprojection error', () {
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [3.0, 4.0, 5.0, 6.0],
        matchedImages: 8,
        totalImages: 10,
        pointCount: 1000,
        processingTime: const Duration(seconds: 10),
      );

      expect(
        quality.warnings,
        contains(predicate<String>((s) => s.contains('High mean reprojection error'))),
      );
    });

    test('generates warning for few points', () {
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [0.5],
        matchedImages: 5,
        totalImages: 5,
        pointCount: 50,
        processingTime: const Duration(seconds: 5),
      );

      expect(
        quality.warnings,
        contains(predicate<String>((s) => s.contains('Very few reconstructed points'))),
      );
    });

    test('point density computed when area is provided', () {
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [0.5, 0.6],
        matchedImages: 5,
        totalImages: 5,
        pointCount: 5000,
        processingTime: const Duration(seconds: 10),
        estimatedArea: 2.0, // 2 m^2
      );

      expect(quality.pointDensity, isNotNull);
      expect(quality.pointDensity!, closeTo(2500.0, 0.1)); // 5000 / 2.0
    });

    test('point density is null when area is not provided', () {
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [0.5],
        matchedImages: 5,
        totalImages: 5,
        pointCount: 1000,
        processingTime: const Duration(seconds: 5),
      );

      expect(quality.pointDensity, isNull);
    });

    test('handles empty reprojection errors', () {
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [],
        matchedImages: 0,
        totalImages: 5,
        pointCount: 0,
        processingTime: const Duration(seconds: 1),
      );

      expect(quality.qualityGrade, 'poor');
      expect(quality.meanReprojectionError, 0.0);
    });
  });

  group('ReconstructionQualityService percentile calculations', () {
    test('median is correct for odd-length list', () {
      // We test via assess which uses _percentile internally
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [1.0, 2.0, 3.0, 4.0, 5.0],
        matchedImages: 5,
        totalImages: 5,
        pointCount: 1000,
        processingTime: const Duration(seconds: 5),
      );

      expect(quality.medianReprojectionError, closeTo(3.0, 0.01));
    });

    test('median is correct for even-length list', () {
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: [1.0, 2.0, 3.0, 4.0],
        matchedImages: 5,
        totalImages: 5,
        pointCount: 1000,
        processingTime: const Duration(seconds: 5),
      );

      // Median of [1,2,3,4] at index 1.5 => interpolation: 2.5
      expect(quality.medianReprojectionError, closeTo(2.5, 0.01));
    });

    test('p95 is correct', () {
      // 20 values from 1 to 20
      final errors = List.generate(20, (i) => (i + 1).toDouble());
      final quality = ReconstructionQualityService.assess(
        reprojectionErrors: errors,
        matchedImages: 10,
        totalImages: 10,
        pointCount: 5000,
        processingTime: const Duration(seconds: 10),
      );

      // p95 index = 0.95 * 19 = 18.05 => interpolation between sorted[18]=19 and sorted[19]=20
      // 19 * 0.95 + 20 * 0.05 = 19.05
      expect(quality.p95ReprojectionError, closeTo(19.05, 0.1));
    });
  });

  group('ReconstructionQualityService computeReprojectionErrors', () {
    test('perfect projection yields zero error', () {
      // A point at (0, 0, 5) viewed by an identity camera with known intrinsics
      // should project to (cx, cy)
      final points3D = [Vector3(0.0, 0.0, 5.0)];

      // Intrinsics: fx=1000, fy=1000, cx=500, cy=400
      const fx = 1000.0;
      const fy = 1000.0;
      const cx = 500.0;
      const cy = 400.0;

      // Identity pose (camera at origin, looking along +Z)
      final pose = Matrix4.identity();

      // The point (0,0,5) projects to: (fx*0/5 + cx, fy*0/5 + cy) = (500, 400)
      final observations2D = [
        [Vector2(cx, cy)],
      ];

      final errors = ReconstructionQualityService.computeReprojectionErrors(
        points3D,
        observations2D,
        [pose],
        [
          [fx, fy, cx, cy]
        ],
      );

      expect(errors.length, 1);
      expect(errors[0], closeTo(0.0, 1e-6));
    });

    test('offset observation yields expected error', () {
      final points3D = [Vector3(0.0, 0.0, 10.0)];
      const fx = 500.0;
      const fy = 500.0;
      const cx = 320.0;
      const cy = 240.0;

      final pose = Matrix4.identity();

      // True projection is (320, 240), observe at (323, 244) => error = 5.0
      final observations2D = [
        [Vector2(323.0, 244.0)],
      ];

      final errors = ReconstructionQualityService.computeReprojectionErrors(
        points3D,
        observations2D,
        [pose],
        [
          [fx, fy, cx, cy]
        ],
      );

      expect(errors.length, 1);
      expect(errors[0], closeTo(5.0, 0.01));
    });
  });
}
