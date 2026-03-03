import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:ancient_vision/services/bundle_adjustment_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Helper: build a camera pose matrix from rotation angles and translation
  // ---------------------------------------------------------------------------
  Matrix4 makePose(double rx, double ry, double rz, double tx, double ty, double tz) {
    final R = BundleAdjustmentService.rodrigues(Vector3(rx, ry, rz));
    return Matrix4(
      R.entry(0, 0), R.entry(1, 0), R.entry(2, 0), 0,
      R.entry(0, 1), R.entry(1, 1), R.entry(2, 1), 0,
      R.entry(0, 2), R.entry(1, 2), R.entry(2, 2), 0,
      tx, ty, tz, 1,
    );
  }

  // ---------------------------------------------------------------------------
  // Helper: project a 3D point through a camera to get 2D observation
  // ---------------------------------------------------------------------------
  Vector2? projectPoint(Matrix4 pose, Vector3 point, double fx, double cx, double cy) {
    final R = Matrix3(
      pose.entry(0, 0), pose.entry(0, 1), pose.entry(0, 2),
      pose.entry(1, 0), pose.entry(1, 1), pose.entry(1, 2),
      pose.entry(2, 0), pose.entry(2, 1), pose.entry(2, 2),
    );
    final t = Vector3(pose.entry(0, 3), pose.entry(1, 3), pose.entry(2, 3));
    final transformed = R.transformed(point) + t;
    if (transformed.z <= 1e-8) return null;
    return Vector2(
      fx * (transformed.x / transformed.z) + cx,
      fx * (transformed.y / transformed.z) + cy,
    );
  }

  // ---------------------------------------------------------------------------
  // Helper: generate cube points centered at origin
  // ---------------------------------------------------------------------------
  List<Vector3> cubePoints() {
    return [
      Vector3(-1, -1, -1), Vector3(-1, -1, 1),
      Vector3(-1, 1, -1), Vector3(-1, 1, 1),
      Vector3(1, -1, -1), Vector3(1, -1, 1),
      Vector3(1, 1, -1), Vector3(1, 1, 1),
    ];
  }

  // ---------------------------------------------------------------------------
  // Rodrigues rotation tests
  // ---------------------------------------------------------------------------
  group('Rodrigues rotation', () {
    test('zero vector produces identity matrix', () {
      final R = BundleAdjustmentService.rodrigues(Vector3.zero());
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
          expect(R.entry(i, j), closeTo(i == j ? 1.0 : 0.0, 1e-10));
        }
      }
    });

    test('90 degrees around Z axis produces correct rotation', () {
      const angle = math.pi / 2;
      final R = BundleAdjustmentService.rodrigues(Vector3(0, 0, angle));

      // Expected: [[0, -1, 0], [1, 0, 0], [0, 0, 1]]
      expect(R.entry(0, 0), closeTo(0, 1e-6));
      expect(R.entry(0, 1), closeTo(-1, 1e-6));
      expect(R.entry(0, 2), closeTo(0, 1e-6));
      expect(R.entry(1, 0), closeTo(1, 1e-6));
      expect(R.entry(1, 1), closeTo(0, 1e-6));
      expect(R.entry(1, 2), closeTo(0, 1e-6));
      expect(R.entry(2, 0), closeTo(0, 1e-6));
      expect(R.entry(2, 1), closeTo(0, 1e-6));
      expect(R.entry(2, 2), closeTo(1, 1e-6));
    });

    test('roundtrip: rodrigues -> matrix -> rodrigues', () {
      final original = Vector3(0.3, -0.5, 0.7);
      final R = BundleAdjustmentService.rodrigues(original);
      final recovered = BundleAdjustmentService.rotationMatrixToRodrigues(R);

      expect(recovered.x, closeTo(original.x, 1e-6));
      expect(recovered.y, closeTo(original.y, 1e-6));
      expect(recovered.z, closeTo(original.z, 1e-6));
    });

    test('180 degrees rotation roundtrip', () {
      final original = Vector3(0, math.pi, 0);
      final R = BundleAdjustmentService.rodrigues(original);
      final recovered = BundleAdjustmentService.rotationMatrixToRodrigues(R);

      // Direction may flip but angle should be the same
      expect(recovered.length, closeTo(original.length, 1e-4));
    });
  });

  // ---------------------------------------------------------------------------
  // Robust cost function tests
  // ---------------------------------------------------------------------------
  group('Robust cost functions', () {
    test('Huber weight is 1 for small residuals', () {
      expect(BundleAdjustmentService.huberWeight(0.5, 2.0), 1.0);
      expect(BundleAdjustmentService.huberWeight(1.9, 2.0), 1.0);
    });

    test('Huber weight decreases for large residuals', () {
      final w = BundleAdjustmentService.huberWeight(10.0, 2.0);
      expect(w, closeTo(0.2, 1e-10));
    });

    test('Cauchy weight approaches 0 for very large residuals', () {
      final w = BundleAdjustmentService.cauchyWeight(1000.0, 1.0);
      expect(w, lessThan(0.001));
    });

    test('Tukey weight is exactly 0 beyond threshold', () {
      expect(BundleAdjustmentService.tukeyWeight(5.1, 5.0), 0.0);
      expect(BundleAdjustmentService.tukeyWeight(100.0, 5.0), 0.0);
    });

    test('Tukey weight is 1 at zero residual', () {
      expect(BundleAdjustmentService.tukeyWeight(0.0, 5.0), 1.0);
    });
  });

  // ---------------------------------------------------------------------------
  // Bundle adjustment optimization tests
  // ---------------------------------------------------------------------------
  group('Bundle adjustment', () {
    test('two cameras viewing a cube: error decreases', () {
      final points = cubePoints();
      const fx = 500.0;
      const cx = 320.0;
      const cy = 240.0;

      // Camera 1: looking at the cube from z=5
      final pose1 = makePose(0, 0, 0, 0, 0, 5);
      // Camera 2: looking from slightly different angle
      final pose2 = makePose(0.1, 0.2, 0, 1.0, 0, 5);

      final cameras = [pose1, pose2];

      // Generate perfect observations
      final observations = <List<Vector2?>>[];
      for (final cam in cameras) {
        final row = <Vector2?>[];
        for (final pt in points) {
          row.add(projectPoint(cam, pt, fx, cx, cy));
        }
        observations.add(row);
      }

      // Add noise to points to create non-zero initial error
      final rng = math.Random(42);
      final noisyPoints = points.map((p) => Vector3(
        p.x + (rng.nextDouble() - 0.5) * 0.3,
        p.y + (rng.nextDouble() - 0.5) * 0.3,
        p.z + (rng.nextDouble() - 0.5) * 0.3,
      )).toList();

      final result = BundleAdjustmentService.optimize(
        cameraPoses: cameras,
        points3D: noisyPoints,
        observations: observations,
        focalLength: fx,
        cx: cx,
        cy: cy,
        maxIterations: 50,
        robustCost: RobustCost.none,
      );

      expect(result.finalError, lessThan(result.initialError));
      expect(result.iterations, greaterThan(0));
    });

    test('noisy initial points converge to lower error', () {
      final points = cubePoints();
      const fx = 500.0;
      const cx = 320.0;
      const cy = 240.0;

      // Three cameras viewing the cube
      final cameras = [
        makePose(0, 0, 0, 0, 0, 6),
        makePose(0, 0.3, 0, 2, 0, 6),
        makePose(0.2, 0, 0, -1, 1, 6),
      ];

      // Perfect observations
      final observations = <List<Vector2?>>[];
      for (final cam in cameras) {
        final row = <Vector2?>[];
        for (final pt in points) {
          row.add(projectPoint(cam, pt, fx, cx, cy));
        }
        observations.add(row);
      }

      // Noisy points
      final rng = math.Random(123);
      final noisyPoints = points.map((p) => Vector3(
        p.x + (rng.nextDouble() - 0.5) * 0.5,
        p.y + (rng.nextDouble() - 0.5) * 0.5,
        p.z + (rng.nextDouble() - 0.5) * 0.5,
      )).toList();

      final result = BundleAdjustmentService.optimize(
        cameraPoses: cameras,
        points3D: noisyPoints,
        observations: observations,
        focalLength: fx,
        cx: cx,
        cy: cy,
        maxIterations: 100,
        robustCost: RobustCost.none,
      );

      expect(result.finalError, lessThan(result.initialError));
    });

    test('Huber cost handles outlier observations gracefully', () {
      final points = cubePoints();
      const fx = 500.0;
      const cx = 320.0;
      const cy = 240.0;

      final cameras = [
        makePose(0, 0, 0, 0, 0, 6),
        makePose(0, 0.3, 0, 2, 0, 6),
      ];

      // Perfect observations
      final observations = <List<Vector2?>>[];
      for (final cam in cameras) {
        final row = <Vector2?>[];
        for (final pt in points) {
          row.add(projectPoint(cam, pt, fx, cx, cy));
        }
        observations.add(row);
      }

      // Add outlier: drastically wrong observation for point 0 in camera 1
      observations[1][0] = Vector2(9999, 9999);

      // Slightly noisy points
      final rng = math.Random(7);
      final noisyPoints = points.map((p) => Vector3(
        p.x + (rng.nextDouble() - 0.5) * 0.2,
        p.y + (rng.nextDouble() - 0.5) * 0.2,
        p.z + (rng.nextDouble() - 0.5) * 0.2,
      )).toList();

      // With Huber cost, the optimizer should not blow up
      final result = BundleAdjustmentService.optimize(
        cameraPoses: cameras,
        points3D: noisyPoints,
        observations: observations,
        focalLength: fx,
        cx: cx,
        cy: cy,
        maxIterations: 30,
        robustCost: RobustCost.huber,
        robustParam: 2.0,
      );

      // The result should be finite and reasonable
      expect(result.finalError.isFinite, isTrue);
      expect(result.refinedPoints.length, equals(points.length));
      expect(result.refinedPoses.length, equals(cameras.length));
    });

    test('zero-noise case: final error approximately zero', () {
      final points = cubePoints();
      const fx = 500.0;
      const cx = 320.0;
      const cy = 240.0;

      final cameras = [
        makePose(0, 0, 0, 0, 0, 6),
        makePose(0, 0.3, 0, 2, 0, 6),
        makePose(0.2, 0, 0, -1, 1, 6),
      ];

      // Perfect observations from perfect cameras and perfect points
      final observations = <List<Vector2?>>[];
      for (final cam in cameras) {
        final row = <Vector2?>[];
        for (final pt in points) {
          row.add(projectPoint(cam, pt, fx, cx, cy));
        }
        observations.add(row);
      }

      final result = BundleAdjustmentService.optimize(
        cameraPoses: cameras,
        points3D: points,
        observations: observations,
        focalLength: fx,
        cx: cx,
        cy: cy,
        maxIterations: 50,
        robustCost: RobustCost.none,
      );

      // Error should be essentially zero since everything is already perfect
      expect(result.initialError, closeTo(0, 1e-4));
      expect(result.finalError, closeTo(0, 1e-4));
    });

    test('convergence flag is set when error stops changing', () {
      final points = cubePoints();
      const fx = 500.0;
      const cx = 320.0;
      const cy = 240.0;

      final cameras = [
        makePose(0, 0, 0, 0, 0, 6),
        makePose(0, 0.3, 0, 2, 0, 6),
      ];

      // Perfect observations
      final observations = <List<Vector2?>>[];
      for (final cam in cameras) {
        final row = <Vector2?>[];
        for (final pt in points) {
          row.add(projectPoint(cam, pt, fx, cx, cy));
        }
        observations.add(row);
      }

      // Perfect input -> should converge immediately
      final result = BundleAdjustmentService.optimize(
        cameraPoses: cameras,
        points3D: points,
        observations: observations,
        focalLength: fx,
        cx: cx,
        cy: cy,
        maxIterations: 50,
        convergenceThreshold: 1e-6,
        robustCost: RobustCost.none,
      );

      expect(result.converged, isTrue);
      // Should converge well before maxIterations
      expect(result.iterations, lessThan(50));
    });

    test('result dimensions match input dimensions', () {
      final points = cubePoints();
      const fx = 500.0;

      final cameras = [
        makePose(0, 0, 0, 0, 0, 6),
        makePose(0, 0.3, 0, 2, 0, 6),
        makePose(0.2, -0.1, 0, -1, 0.5, 6),
      ];

      final observations = <List<Vector2?>>[];
      for (final cam in cameras) {
        final row = <Vector2?>[];
        for (final pt in points) {
          row.add(projectPoint(cam, pt, fx, 0, 0));
        }
        observations.add(row);
      }

      final result = BundleAdjustmentService.optimize(
        cameraPoses: cameras,
        points3D: points,
        observations: observations,
        focalLength: fx,
        maxIterations: 5,
      );

      expect(result.refinedPoses.length, equals(3));
      expect(result.refinedPoints.length, equals(8));
    });
  });
}
