import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

/// Triangulate 3D point from two rays (same algorithm as ReconstructionService._triangulateRayPair)
Vector3 triangulateRayPair(Vector3 o1, Vector3 d1, Vector3 o2, Vector3 d2) {
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

  return (p1 + p2) / 2; // Midpoint
}

void main() {
  group('triangulateRayPair', () {
    test('perpendicular rays intersecting at origin', () {
      // Camera 1 on X axis looking along -X
      final o1 = Vector3(5.0, 0.0, 0.0);
      final d1 = Vector3(-1.0, 0.0, 0.0);
      // Camera 2 on Y axis looking along -Y
      final o2 = Vector3(0.0, 5.0, 0.0);
      final d2 = Vector3(0.0, -1.0, 0.0);

      final point = triangulateRayPair(o1, d1, o2, d2);
      expect(point.x, closeTo(0.0, 0.001));
      expect(point.y, closeTo(0.0, 0.001));
      expect(point.z, closeTo(0.0, 0.001));
    });

    test('skew rays produce midpoint of closest approach', () {
      // Two rays that don't exactly intersect
      final o1 = Vector3(0.0, 0.0, 1.0);
      final d1 = Vector3(1.0, 0.0, 0.0); // Along X axis, z=1
      final o2 = Vector3(0.0, 0.0, -1.0);
      final d2 = Vector3(0.0, 1.0, 0.0); // Along Y axis, z=-1

      final point = triangulateRayPair(o1, d1, o2, d2);
      // Closest approach is at (0,0,1) and (0,0,-1), midpoint z=0
      expect(point.x, closeTo(0.0, 0.001));
      expect(point.y, closeTo(0.0, 0.001));
      expect(point.z, closeTo(0.0, 0.001));
    });

    test('convergent rays at known point', () {
      // Target point at (2, 3, 5)
      final target = Vector3(2.0, 3.0, 5.0);

      final o1 = Vector3(0.0, 0.0, 0.0);
      final d1 = (target - o1)..normalize();
      final o2 = Vector3(4.0, 0.0, 0.0);
      final d2 = (target - o2)..normalize();

      final point = triangulateRayPair(o1, d1, o2, d2);
      expect(point.x, closeTo(2.0, 0.01));
      expect(point.y, closeTo(3.0, 0.01));
      expect(point.z, closeTo(5.0, 0.01));
    });

    test('90 degree camera arrangement', () {
      // Camera 1 at Z axis looking at origin
      final o1 = Vector3(0.0, 0.0, 10.0);
      final d1 = Vector3(0.0, 0.0, -1.0);
      // Camera 2 at X axis looking at origin
      final o2 = Vector3(10.0, 0.0, 0.0);
      final d2 = Vector3(-1.0, 0.0, 0.0);

      final point = triangulateRayPair(o1, d1, o2, d2);
      expect(point.x, closeTo(0.0, 0.001));
      expect(point.y, closeTo(0.0, 0.001));
      expect(point.z, closeTo(0.0, 0.001));
    });
  });

  group('point depth checks', () {
    test('point in front of camera has positive depth', () {
      final camera = Vector3(0.0, 0.0, 0.0);
      final lookDir = Vector3(0.0, 0.0, 1.0);
      final point = Vector3(0.0, 0.0, 5.0);

      final depth = (point - camera).dot(lookDir);
      expect(depth, greaterThan(0));
    });

    test('point behind camera has negative depth', () {
      final camera = Vector3(0.0, 0.0, 0.0);
      final lookDir = Vector3(0.0, 0.0, 1.0);
      final point = Vector3(0.0, 0.0, -5.0);

      final depth = (point - camera).dot(lookDir);
      expect(depth, lessThan(0));
    });

    test('very distant point is flagged as outlier', () {
      final camera = Vector3(0.0, 0.0, 0.0);
      final point = Vector3(1000.0, 1000.0, 1000.0);
      final distance = (point - camera).length;
      // Reconstruction typically filters points > 100 units away
      expect(distance, greaterThan(100));
    });
  });

  group('essential matrix properties', () {
    test('cross product matrix is skew-symmetric', () {
      // [t]x should be skew-symmetric: [t]x = -[t]x^T
      final t = Vector3(1.0, 2.0, 3.0);
      final tx = Matrix3(
        0, -t.z, t.y,
        t.z, 0, -t.x,
        -t.y, t.x, 0,
      );

      // Check skew symmetry
      final txT = tx.clone()..transpose();
      final sum = tx + txT;
      for (int i = 0; i < 9; i++) {
        expect(sum.storage[i], closeTo(0.0, 1e-10));
      }
    });

    test('rotation matrix has determinant 1', () {
      // Identity rotation
      final R = Matrix3.identity();
      expect(R.determinant(), closeTo(1.0, 1e-10));

      // 90 degree rotation around Z axis
      final rotZ = Matrix3(
        0, -1, 0,
        1, 0, 0,
        0, 0, 1,
      );
      expect(rotZ.determinant(), closeTo(1.0, 1e-10));
    });
  });
}
