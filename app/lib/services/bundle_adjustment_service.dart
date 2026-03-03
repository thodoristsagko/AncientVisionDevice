// ignore_for_file: non_constant_identifier_names
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart';

/// Result of bundle adjustment optimization
class BundleAdjustmentResult {
  final List<Matrix4> refinedPoses;
  final List<Vector3> refinedPoints;
  final double initialError;
  final double finalError;
  final int iterations;
  final bool converged;

  BundleAdjustmentResult({
    required this.refinedPoses,
    required this.refinedPoints,
    required this.initialError,
    required this.finalError,
    required this.iterations,
    required this.converged,
  });
}

/// Robust cost function types for outlier handling
enum RobustCost { none, huber, cauchy, tukey }

/// Levenberg-Marquardt bundle adjustment optimizer.
///
/// Jointly optimizes camera poses and 3D point positions to minimize
/// reprojection error. Uses alternating minimization (cameras then points)
/// with LM damping for stable convergence.
class BundleAdjustmentService {
  // ---------------------------------------------------------------------------
  // Robust weight functions
  // ---------------------------------------------------------------------------

  /// Huber weight: linear penalty beyond threshold k
  static double huberWeight(double residual, double k) {
    final absR = residual.abs();
    return absR <= k ? 1.0 : k / absR;
  }

  /// Cauchy weight: smooth, heavy-tailed penalty
  static double cauchyWeight(double residual, double k) {
    return 1.0 / (1.0 + (residual / k) * (residual / k));
  }

  /// Tukey biweight: hard rejection beyond threshold k
  static double tukeyWeight(double residual, double k) {
    final absR = residual.abs();
    if (absR > k) return 0.0;
    final x = 1.0 - (residual / k) * (residual / k);
    return x * x;
  }

  /// Compute robust weight for a given residual
  static double _robustWeight(
      double residual, RobustCost cost, double param) {
    switch (cost) {
      case RobustCost.none:
        return 1.0;
      case RobustCost.huber:
        return huberWeight(residual, param);
      case RobustCost.cauchy:
        return cauchyWeight(residual, param);
      case RobustCost.tukey:
        return tukeyWeight(residual, param);
    }
  }

  // ---------------------------------------------------------------------------
  // Rodrigues rotation vector <-> rotation matrix
  // ---------------------------------------------------------------------------

  /// Convert a Rodrigues rotation vector (3 params) to a 3x3 rotation matrix.
  ///
  /// Uses the Rodrigues formula: R = I + sin(theta)*K + (1-cos(theta))*K^2
  /// where K is the skew-symmetric matrix of the unit rotation axis.
  static Matrix3 rodrigues(Vector3 rvec) {
    final theta = rvec.length;
    if (theta < 1e-10) return Matrix3.identity();

    final kx = rvec.x / theta;
    final ky = rvec.y / theta;
    final kz = rvec.z / theta;

    // Skew-symmetric matrix K (column-major for vector_math)
    final K = Matrix3(
      0, kz, -ky, //
      -kz, 0, kx, //
      ky, -kx, 0, //
    );

    final sinT = math.sin(theta);
    final cosT = math.cos(theta);

    // K^2
    final K2 = Matrix3.zero();
    K2.setFrom(K);
    K2.multiply(K);

    // R = I + sin(theta)*K + (1-cos(theta))*K^2
    final R = Matrix3.identity();
    final sinK = Matrix3.zero()..setFrom(K);
    _scaleMatrix3(sinK, sinT);
    final cosK2 = Matrix3.zero()..setFrom(K2);
    _scaleMatrix3(cosK2, 1.0 - cosT);

    R.add(sinK);
    R.add(cosK2);
    return R;
  }

  /// Extract Rodrigues rotation vector from a 3x3 rotation matrix.
  static Vector3 rotationMatrixToRodrigues(Matrix3 R) {
    // Use the formula: theta = acos((trace(R)-1)/2), axis from skew part
    final trace = R.entry(0, 0) + R.entry(1, 1) + R.entry(2, 2);
    final cosTheta = ((trace - 1.0) / 2.0).clamp(-1.0, 1.0);
    final theta = math.acos(cosTheta);

    if (theta < 1e-10) return Vector3.zero();

    final sinTheta = math.sin(theta);
    if (sinTheta.abs() < 1e-10) {
      // theta ~ pi, need special handling
      // Find the column of R+I with the largest norm
      final rPlusI = Matrix3.copy(R);
      rPlusI.setEntry(0, 0, rPlusI.entry(0, 0) + 1);
      rPlusI.setEntry(1, 1, rPlusI.entry(1, 1) + 1);
      rPlusI.setEntry(2, 2, rPlusI.entry(2, 2) + 1);

      // Pick column with largest norm
      Vector3 axis = Vector3.zero();
      double bestNorm = 0;
      for (int c = 0; c < 3; c++) {
        final col = rPlusI.getColumn(c);
        final n = col.length;
        if (n > bestNorm) {
          bestNorm = n;
          axis = col;
        }
      }
      if (bestNorm > 1e-10) axis.normalize();
      return axis * theta;
    }

    // General case
    final factor = theta / (2.0 * sinTheta);
    final rx = (R.entry(2, 1) - R.entry(1, 2)) * factor;
    final ry = (R.entry(0, 2) - R.entry(2, 0)) * factor;
    final rz = (R.entry(1, 0) - R.entry(0, 1)) * factor;
    return Vector3(rx, ry, rz);
  }

  // ---------------------------------------------------------------------------
  // Projection
  // ---------------------------------------------------------------------------

  /// Project a 3D point through a camera defined by Rodrigues vector + translation.
  ///
  /// Returns the 2D projected point, or null if the point is behind the camera.
  static Vector2? _project(
    Vector3 rvec,
    Vector3 tvec,
    Vector3 point3D,
    double fx,
    double cx,
    double cy,
  ) {
    final R = rodrigues(rvec);
    final rotated = R.transformed(point3D);
    final transformed = rotated + tvec;

    if (transformed.z <= 1e-8) return null; // Behind camera

    final u = fx * (transformed.x / transformed.z) + cx;
    final v = fx * (transformed.y / transformed.z) + cy;
    return Vector2(u, v);
  }

  // ---------------------------------------------------------------------------
  // Camera pose <-> parameter vector helpers
  // ---------------------------------------------------------------------------

  /// Extract Rodrigues vector and translation from a 4x4 pose matrix.
  static (Vector3, Vector3) _poseToParams(Matrix4 pose) {
    final R = Matrix3(
      pose.entry(0, 0), pose.entry(0, 1), pose.entry(0, 2),
      pose.entry(1, 0), pose.entry(1, 1), pose.entry(1, 2),
      pose.entry(2, 0), pose.entry(2, 1), pose.entry(2, 2),
    );
    final t = Vector3(pose.entry(0, 3), pose.entry(1, 3), pose.entry(2, 3));
    final rvec = rotationMatrixToRodrigues(R);
    return (rvec, t);
  }

  /// Build a 4x4 pose matrix from Rodrigues vector and translation.
  static Matrix4 _paramsToMatrix(Vector3 rvec, Vector3 tvec) {
    final R = rodrigues(rvec);
    return Matrix4(
      R.entry(0, 0), R.entry(1, 0), R.entry(2, 0), 0,
      R.entry(0, 1), R.entry(1, 1), R.entry(2, 1), 0,
      R.entry(0, 2), R.entry(1, 2), R.entry(2, 2), 0,
      tvec.x, tvec.y, tvec.z, 1,
    );
  }

  // ---------------------------------------------------------------------------
  // Cost computation
  // ---------------------------------------------------------------------------

  /// Compute mean reprojection error over all observations.
  static double _computeMeanError(
    List<Vector3> rvecs,
    List<Vector3> tvecs,
    List<Vector3> points3D,
    List<List<Vector2?>> observations,
    double fx,
    double cx,
    double cy,
  ) {
    double totalError = 0;
    int count = 0;
    final nCams = rvecs.length;
    final nPts = points3D.length;

    for (int i = 0; i < nCams; i++) {
      for (int j = 0; j < nPts; j++) {
        final obs = observations[i][j];
        if (obs == null) continue;

        final proj = _project(rvecs[i], tvecs[i], points3D[j], fx, cx, cy);
        if (proj == null) {
          totalError += 100.0; // Penalty for behind-camera
          count++;
          continue;
        }

        final dx = proj.x - obs.x;
        final dy = proj.y - obs.y;
        totalError += math.sqrt(dx * dx + dy * dy);
        count++;
      }
    }
    return count > 0 ? totalError / count : 0;
  }

  /// Compute weighted squared residual sum.
  static double _computeWeightedCost(
    List<Vector3> rvecs,
    List<Vector3> tvecs,
    List<Vector3> points3D,
    List<List<Vector2?>> observations,
    double fx,
    double cx,
    double cy,
    RobustCost robustCost,
    double robustParam,
  ) {
    double totalCost = 0;
    final nCams = rvecs.length;
    final nPts = points3D.length;

    for (int i = 0; i < nCams; i++) {
      for (int j = 0; j < nPts; j++) {
        final obs = observations[i][j];
        if (obs == null) continue;

        final proj = _project(rvecs[i], tvecs[i], points3D[j], fx, cx, cy);
        if (proj == null) {
          totalCost += 10000.0;
          continue;
        }

        final dx = proj.x - obs.x;
        final dy = proj.y - obs.y;
        final r = math.sqrt(dx * dx + dy * dy);
        final w = _robustWeight(r, robustCost, robustParam);
        totalCost += w * (dx * dx + dy * dy);
      }
    }
    return totalCost;
  }

  // ---------------------------------------------------------------------------
  // Numerical Jacobian + LM solve for camera parameters (points fixed)
  // ---------------------------------------------------------------------------

  /// Run one LM step optimizing camera parameters only.
  /// Returns updated (rvecs, tvecs, accepted, newCost).
  static (List<Vector3>, List<Vector3>, bool, double) _lmStepCameras(
    List<Vector3> rvecs,
    List<Vector3> tvecs,
    List<Vector3> points3D,
    List<List<Vector2?>> observations,
    double fx,
    double cx,
    double cy,
    double lambda,
    RobustCost robustCost,
    double robustParam,
  ) {
    final nCams = rvecs.length;
    final nPts = points3D.length;
    final nParams = nCams * 6; // 6 params per camera
    const h = 1e-6;

    // Collect residuals and weights
    final residuals = <double>[];
    final weights = <double>[];
    final obsIndices = <(int, int)>[]; // (cam, point)

    for (int i = 0; i < nCams; i++) {
      for (int j = 0; j < nPts; j++) {
        final obs = observations[i][j];
        if (obs == null) continue;

        final proj = _project(rvecs[i], tvecs[i], points3D[j], fx, cx, cy);
        if (proj == null) {
          residuals.addAll([100.0, 100.0]);
          weights.add(0.0); // zero weight for behind-camera
          obsIndices.add((i, j));
          continue;
        }

        final rx = proj.x - obs.x;
        final ry = proj.y - obs.y;
        final r = math.sqrt(rx * rx + ry * ry);
        final w = _robustWeight(r, robustCost, robustParam);
        residuals.addAll([rx, ry]);
        weights.add(w);
        obsIndices.add((i, j));
      }
    }

    if (obsIndices.isEmpty) {
      return (rvecs, tvecs, false, double.infinity);
    }

    final nObs = obsIndices.length;
    final nResiduals = nObs * 2;

    // Build Jacobian numerically (only camera params)
    // J[r][p] = d residual_r / d param_p
    final J = List.generate(nResiduals, (_) => List.filled(nParams, 0.0));

    // Pack camera params into a flat vector for perturbation
    final camParams = List<double>.filled(nParams, 0);
    for (int i = 0; i < nCams; i++) {
      camParams[i * 6 + 0] = rvecs[i].x;
      camParams[i * 6 + 1] = rvecs[i].y;
      camParams[i * 6 + 2] = rvecs[i].z;
      camParams[i * 6 + 3] = tvecs[i].x;
      camParams[i * 6 + 4] = tvecs[i].y;
      camParams[i * 6 + 5] = tvecs[i].z;
    }

    for (int p = 0; p < nParams; p++) {
      final camIdx = p ~/ 6;
      final orig = camParams[p];

      // Forward
      camParams[p] = orig + h;
      final rvecF = Vector3(
          camParams[camIdx * 6], camParams[camIdx * 6 + 1], camParams[camIdx * 6 + 2]);
      final tvecF = Vector3(
          camParams[camIdx * 6 + 3], camParams[camIdx * 6 + 4], camParams[camIdx * 6 + 5]);

      // Backward
      camParams[p] = orig - h;
      final rvecB = Vector3(
          camParams[camIdx * 6], camParams[camIdx * 6 + 1], camParams[camIdx * 6 + 2]);
      final tvecB = Vector3(
          camParams[camIdx * 6 + 3], camParams[camIdx * 6 + 4], camParams[camIdx * 6 + 5]);

      camParams[p] = orig; // Restore

      for (int o = 0; o < nObs; o++) {
        final (ci, pj) = obsIndices[o];
        if (ci != camIdx) continue; // This param only affects its own camera

        final projF = _project(rvecF, tvecF, points3D[pj], fx, cx, cy);
        final projB = _project(rvecB, tvecB, points3D[pj], fx, cx, cy);

        if (projF != null && projB != null) {
          J[o * 2][p] = (projF.x - projB.x) / (2 * h);
          J[o * 2 + 1][p] = (projF.y - projB.y) / (2 * h);
        }
      }
    }

    // Solve normal equations: (J^T W J + lambda * diag(J^T W J)) delta = -J^T W r
    final JtWJ = List.generate(nParams, (_) => List.filled(nParams, 0.0));
    final JtWr = List.filled(nParams, 0.0);

    for (int o = 0; o < nObs; o++) {
      final w = weights[o];
      for (int p = 0; p < nParams; p++) {
        final jp0 = J[o * 2][p];
        final jp1 = J[o * 2 + 1][p];

        JtWr[p] += w * (jp0 * residuals[o * 2] + jp1 * residuals[o * 2 + 1]);

        for (int q = p; q < nParams; q++) {
          final jq0 = J[o * 2][q];
          final jq1 = J[o * 2 + 1][q];
          final val = w * (jp0 * jq0 + jp1 * jq1);
          JtWJ[p][q] += val;
          if (p != q) JtWJ[q][p] += val;
        }
      }
    }

    // Add damping
    for (int p = 0; p < nParams; p++) {
      JtWJ[p][p] *= (1.0 + lambda);
      if (JtWJ[p][p] < 1e-12) JtWJ[p][p] = 1e-12; // Regularize
    }

    // Solve via Cholesky-like approach (simple Gaussian elimination for small systems)
    final delta = _solveLinearSystem(JtWJ, JtWr.map((v) => -v).toList());
    if (delta == null) {
      return (rvecs, tvecs, false, double.infinity);
    }

    // Apply update
    final newRvecs = List<Vector3>.generate(nCams, (i) => Vector3.copy(rvecs[i]));
    final newTvecs = List<Vector3>.generate(nCams, (i) => Vector3.copy(tvecs[i]));

    for (int i = 0; i < nCams; i++) {
      newRvecs[i].x += delta[i * 6 + 0];
      newRvecs[i].y += delta[i * 6 + 1];
      newRvecs[i].z += delta[i * 6 + 2];
      newTvecs[i].x += delta[i * 6 + 3];
      newTvecs[i].y += delta[i * 6 + 4];
      newTvecs[i].z += delta[i * 6 + 5];
    }

    final newCost = _computeWeightedCost(
        newRvecs, newTvecs, points3D, observations, fx, cx, cy,
        robustCost, robustParam);
    final oldCost = _computeWeightedCost(
        rvecs, tvecs, points3D, observations, fx, cx, cy,
        robustCost, robustParam);

    if (newCost < oldCost) {
      return (newRvecs, newTvecs, true, newCost);
    } else {
      return (rvecs, tvecs, false, oldCost);
    }
  }

  // ---------------------------------------------------------------------------
  // Numerical Jacobian + LM solve for point parameters (cameras fixed)
  // ---------------------------------------------------------------------------

  /// Run one LM step optimizing 3D points only.
  /// Returns updated (points3D, accepted, newCost).
  static (List<Vector3>, bool, double) _lmStepPoints(
    List<Vector3> rvecs,
    List<Vector3> tvecs,
    List<Vector3> points3D,
    List<List<Vector2?>> observations,
    double fx,
    double cx,
    double cy,
    double lambda,
    RobustCost robustCost,
    double robustParam,
  ) {
    final nCams = rvecs.length;
    final nPts = points3D.length;
    const h = 1e-6;

    // Optimize each point independently (they don't interact)
    final newPoints = List<Vector3>.generate(nPts, (j) => Vector3.copy(points3D[j]));
    bool anyAccepted = false;

    for (int j = 0; j < nPts; j++) {
      // Collect observations of this point
      final obsForPoint = <(int, Vector2)>[];
      for (int i = 0; i < nCams; i++) {
        final obs = observations[i][j];
        if (obs != null) obsForPoint.add((i, obs));
      }
      if (obsForPoint.isEmpty) continue;

      final nObs = obsForPoint.length;
      final nResiduals = nObs * 2;
      const nP = 3; // x, y, z

      // Compute residuals
      final residuals = List<double>.filled(nResiduals, 0);
      final weights = List<double>.filled(nObs, 1);

      for (int o = 0; o < nObs; o++) {
        final (ci, obs) = obsForPoint[o];
        final proj = _project(rvecs[ci], tvecs[ci], points3D[j], fx, cx, cy);
        if (proj == null) {
          residuals[o * 2] = 100.0;
          residuals[o * 2 + 1] = 100.0;
          weights[o] = 0.0;
        } else {
          residuals[o * 2] = proj.x - obs.x;
          residuals[o * 2 + 1] = proj.y - obs.y;
          final r = math.sqrt(residuals[o * 2] * residuals[o * 2] +
              residuals[o * 2 + 1] * residuals[o * 2 + 1]);
          weights[o] = _robustWeight(r, robustCost, robustParam);
        }
      }

      // Compute 3x3 Jacobian numerically
      final J = List.generate(nResiduals, (_) => List.filled(nP, 0.0));
      final ptParams = [points3D[j].x, points3D[j].y, points3D[j].z];

      for (int p = 0; p < nP; p++) {
        final orig = ptParams[p];

        ptParams[p] = orig + h;
        final ptF = Vector3(ptParams[0], ptParams[1], ptParams[2]);
        ptParams[p] = orig - h;
        final ptB = Vector3(ptParams[0], ptParams[1], ptParams[2]);
        ptParams[p] = orig;

        for (int o = 0; o < nObs; o++) {
          final (ci, _) = obsForPoint[o];
          final projF = _project(rvecs[ci], tvecs[ci], ptF, fx, cx, cy);
          final projB = _project(rvecs[ci], tvecs[ci], ptB, fx, cx, cy);

          if (projF != null && projB != null) {
            J[o * 2][p] = (projF.x - projB.x) / (2 * h);
            J[o * 2 + 1][p] = (projF.y - projB.y) / (2 * h);
          }
        }
      }

      // Normal equations (3x3 system)
      final JtWJ = List.generate(nP, (_) => List.filled(nP, 0.0));
      final JtWr = List.filled(nP, 0.0);

      for (int o = 0; o < nObs; o++) {
        final w = weights[o];
        for (int p = 0; p < nP; p++) {
          final jp0 = J[o * 2][p];
          final jp1 = J[o * 2 + 1][p];
          JtWr[p] += w * (jp0 * residuals[o * 2] + jp1 * residuals[o * 2 + 1]);
          for (int q = p; q < nP; q++) {
            final jq0 = J[o * 2][q];
            final jq1 = J[o * 2 + 1][q];
            final val = w * (jp0 * jq0 + jp1 * jq1);
            JtWJ[p][q] += val;
            if (p != q) JtWJ[q][p] += val;
          }
        }
      }

      // Damping
      for (int p = 0; p < nP; p++) {
        JtWJ[p][p] *= (1.0 + lambda);
        if (JtWJ[p][p] < 1e-12) JtWJ[p][p] = 1e-12;
      }

      final delta = _solveLinearSystem(JtWJ, JtWr.map((v) => -v).toList());
      if (delta == null) continue;

      final candidate = Vector3(
        points3D[j].x + delta[0],
        points3D[j].y + delta[1],
        points3D[j].z + delta[2],
      );

      // Check if update improves this point's cost
      double oldCost = 0, newCost = 0;
      for (int o = 0; o < nObs; o++) {
        final (ci, obs) = obsForPoint[o];
        final w = weights[o];

        final projOld = _project(rvecs[ci], tvecs[ci], points3D[j], fx, cx, cy);
        final projNew = _project(rvecs[ci], tvecs[ci], candidate, fx, cx, cy);

        if (projOld != null) {
          final dx = projOld.x - obs.x;
          final dy = projOld.y - obs.y;
          oldCost += w * (dx * dx + dy * dy);
        } else {
          oldCost += 10000.0;
        }

        if (projNew != null) {
          final dx = projNew.x - obs.x;
          final dy = projNew.y - obs.y;
          newCost += w * (dx * dx + dy * dy);
        } else {
          newCost += 10000.0;
        }
      }

      if (newCost < oldCost) {
        newPoints[j] = candidate;
        anyAccepted = true;
      }
    }

    final totalCost = _computeWeightedCost(
        rvecs, tvecs, newPoints, observations, fx, cx, cy,
        robustCost, robustParam);

    return (newPoints, anyAccepted, totalCost);
  }

  // ---------------------------------------------------------------------------
  // Linear system solver (Gaussian elimination with partial pivoting)
  // ---------------------------------------------------------------------------

  /// Solve Ax = b using Gaussian elimination with partial pivoting.
  /// Returns null if the system is singular.
  static List<double>? _solveLinearSystem(
      List<List<double>> A, List<double> b) {
    final n = b.length;
    // Augmented matrix
    final aug = List.generate(
        n, (i) => List<double>.from(A[i])..add(b[i]));

    for (int col = 0; col < n; col++) {
      // Partial pivoting
      int maxRow = col;
      double maxVal = aug[col][col].abs();
      for (int row = col + 1; row < n; row++) {
        if (aug[row][col].abs() > maxVal) {
          maxVal = aug[row][col].abs();
          maxRow = row;
        }
      }

      if (maxVal < 1e-14) return null; // Singular

      if (maxRow != col) {
        final tmp = aug[col];
        aug[col] = aug[maxRow];
        aug[maxRow] = tmp;
      }

      // Elimination
      for (int row = col + 1; row < n; row++) {
        final factor = aug[row][col] / aug[col][col];
        for (int k = col; k <= n; k++) {
          aug[row][k] -= factor * aug[col][k];
        }
      }
    }

    // Back-substitution
    final x = List<double>.filled(n, 0);
    for (int row = n - 1; row >= 0; row--) {
      double sum = aug[row][n];
      for (int col = row + 1; col < n; col++) {
        sum -= aug[row][col] * x[col];
      }
      if (aug[row][row].abs() < 1e-14) return null;
      x[row] = sum / aug[row][row];
    }
    return x;
  }

  // ---------------------------------------------------------------------------
  // Matrix3 scaling helper
  // ---------------------------------------------------------------------------

  static void _scaleMatrix3(Matrix3 m, double s) {
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        m.setEntry(i, j, m.entry(i, j) * s);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Main optimization entry point
  // ---------------------------------------------------------------------------

  /// Run Levenberg-Marquardt bundle adjustment.
  ///
  /// Uses alternating minimization: each iteration first optimizes camera
  /// parameters (fixing points), then optimizes point positions (fixing cameras).
  /// Both sub-problems use LM damping for stable convergence.
  ///
  /// Parameters:
  /// - [cameraPoses]: initial camera extrinsic matrices [R|t]
  /// - [points3D]: initial 3D point positions
  /// - [observations]: observations[i][j] = 2D observation of point j in camera i
  ///   (null if point j is not visible in camera i)
  /// - [focalLength]: focal length in pixels (assumes same for all cameras)
  /// - [cx], [cy]: principal point coordinates
  /// - [maxIterations]: maximum LM iterations (default 50)
  /// - [lambda]: initial damping parameter (default 1e-3)
  /// - [convergenceThreshold]: stop when relative error change < this (default 1e-6)
  /// - [robustCost]: robust cost function type for outlier handling
  /// - [robustParam]: parameter for the robust cost function
  static BundleAdjustmentResult optimize({
    required List<Matrix4> cameraPoses,
    required List<Vector3> points3D,
    required List<List<Vector2?>> observations,
    required double focalLength,
    double cx = 0,
    double cy = 0,
    int maxIterations = 50,
    double lambda = 1e-3,
    double convergenceThreshold = 1e-6,
    RobustCost robustCost = RobustCost.huber,
    double robustParam = 2.0,
  }) {
    final nCams = cameraPoses.length;

    // Convert poses to Rodrigues + translation
    final rvecs = List<Vector3>.filled(nCams, Vector3.zero());
    final tvecs = List<Vector3>.filled(nCams, Vector3.zero());
    for (int i = 0; i < nCams; i++) {
      final (r, t) = _poseToParams(cameraPoses[i]);
      rvecs[i] = r;
      tvecs[i] = t;
    }

    var currentPoints = List<Vector3>.generate(
        points3D.length, (i) => Vector3.copy(points3D[i]));

    final initialError = _computeMeanError(
        rvecs, tvecs, currentPoints, observations, focalLength, cx, cy);

    double currentLambda = lambda;
    double prevError = initialError;
    bool converged = false;
    int iter = 0;

    for (iter = 0; iter < maxIterations; iter++) {
      // Step 1: Optimize cameras (points fixed)
      final (newRvecs, newTvecs, camAccepted, _) = _lmStepCameras(
        rvecs, tvecs, currentPoints, observations,
        focalLength, cx, cy, currentLambda,
        robustCost, robustParam,
      );

      if (camAccepted) {
        for (int i = 0; i < nCams; i++) {
          rvecs[i] = newRvecs[i];
          tvecs[i] = newTvecs[i];
        }
        currentLambda = math.max(currentLambda / 10.0, 1e-10);
      } else {
        currentLambda = math.min(currentLambda * 10.0, 1e10);
      }

      // Step 2: Optimize points (cameras fixed)
      final (newPoints, ptAccepted, _) = _lmStepPoints(
        rvecs, tvecs, currentPoints, observations,
        focalLength, cx, cy, currentLambda,
        robustCost, robustParam,
      );

      if (ptAccepted) {
        currentPoints = newPoints;
        currentLambda = math.max(currentLambda / 10.0, 1e-10);
      } else {
        currentLambda = math.min(currentLambda * 10.0, 1e10);
      }

      // Check convergence
      final currentError = _computeMeanError(
          rvecs, tvecs, currentPoints, observations, focalLength, cx, cy);

      if (prevError > 1e-12) {
        final relChange = (prevError - currentError).abs() / prevError;
        if (relChange < convergenceThreshold) {
          converged = true;
          iter++;
          break;
        }
      } else if (currentError < 1e-12) {
        converged = true;
        iter++;
        break;
      }

      // Early termination: if cost change is very small, stop
      final costChange = (prevError - currentError).abs();
      if (costChange < 1e-8) {
        converged = true;
        iter++;
        break;
      }

      prevError = currentError;
    }

    // Build final poses
    final refinedPoses = List<Matrix4>.generate(
        nCams, (i) => _paramsToMatrix(rvecs[i], tvecs[i]));

    final finalError = _computeMeanError(
        rvecs, tvecs, currentPoints, observations, focalLength, cx, cy);

    return BundleAdjustmentResult(
      refinedPoses: refinedPoses,
      refinedPoints: currentPoints,
      initialError: initialError,
      finalError: finalError,
      iterations: iter,
      converged: converged,
    );
  }
}
