// ignore_for_file: non_constant_identifier_names
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart';
import 'reconstruction/index.dart';

/// Production-grade Structure from Motion with PROSAC and Essential Matrix
class RobustSfM {
  /// PROSAC parameters (progressive RANSAC with quality ordering)
  static const int maxRansacIterations = 500; // Reduced from 1000 (adaptive termination compensates)
  static const double ransacThreshold = 0.02; // Reprojection error threshold (relaxed)
  static const double minInlierRatio = 0.15; // 15% inliers required (more tolerant)
  static const double earlyTerminationThreshold = 0.8; // Stop if inlier ratio > 80%

  /// Image center coordinates (updated when image dimensions are known)
  static double imageCenterX = 512;
  static double imageCenterY = 512;

  /// Estimate essential matrix using RANSAC with 8-point algorithm
  static EssentialMatrixResult estimateEssentialMatrix(
    List<FeatureMatch> matches,
    double focalLength,
  ) {
    if (matches.length < 8) {
      throw Exception('Need at least 8 matches for Essential Matrix estimation');
    }

    Matrix3? bestE;
    List<FeatureMatch> bestInliers = [];
    int maxInliers = 0;
    double bestInlierRatio = 0.0;

    // PROSAC loop: adaptive iterations with quality-ordered sampling
    // Matches are already sorted by descriptor distance (best first)
    int adaptiveIterations = maxRansacIterations;
    for (int iter = 0; iter < adaptiveIterations; iter++) {
      // PROSAC: Sample preferentially from high-quality matches
      // Use a mix of top matches and random sampling
      final sampleMatches = _prosacSample(matches, 8, iter, adaptiveIterations);

      try {
        // Compute Essential Matrix from 8 points
        final E = _computeEssentialMatrix(sampleMatches, focalLength);

        // Count inliers
        final inliers = <FeatureMatch>[];
        for (final match in matches) {
          final error = _epipolarError(match, E, focalLength);
          if (error < ransacThreshold) {
            inliers.add(match);
          }
        }

        // Update best model if more inliers
        if (inliers.length > maxInliers) {
          maxInliers = inliers.length;
          bestInliers = inliers;
          bestE = E;
          bestInlierRatio = maxInliers / matches.length;

          // Adaptive iteration count: if we have a good model, reduce iterations
          if (bestInlierRatio > 0.5) {
            final newIterCount = (iter + (maxRansacIterations - iter) * 0.5).toInt();
            adaptiveIterations = math.min(adaptiveIterations, newIterCount);
          }
        }

        // Early termination if we have excellent inlier ratio
        if (bestInlierRatio > earlyTerminationThreshold) {
          break;
        }
      } catch (e) {
        // Degenerate configuration, try next sample
        continue;
      }
    }

    if (bestE == null || maxInliers < 8) {
      throw Exception(
          'Could not find consistent camera geometry ($maxInliers valid matches).\n'
          'This can happen with:\n'
          '• Very smooth or reflective objects\n'
          '• Inconsistent lighting between shots\n'
          '• Camera too far from object\n\n'
          'Try cloud processing for better results.');
    }

    final inlierRatio = maxInliers / matches.length;
    if (inlierRatio < minInlierRatio) {
      throw Exception(
          'Low match quality (${(inlierRatio * 100).toInt()}% consistent matches).\n'
          'Try:\n'
          '• Better/more even lighting\n'
          '• More textured objects\n'
          '• Keep camera steady\n'
          '• More overlap between photos');
    }

    return EssentialMatrixResult(
      matrix: bestE,
      inliers: bestInliers,
      inlierCount: maxInliers,
      totalMatches: matches.length,
    );
  }

  /// Compute Essential Matrix using normalized 8-point algorithm
  static Matrix3 _computeEssentialMatrix(
    List<FeatureMatch> matches,
    double focalLength,
  ) {
    // Normalize coordinates (shift to origin, scale by focal length)
    final pts1 = <Vector3>[];
    final pts2 = <Vector3>[];

    for (final match in matches) {
      pts1.add(Vector3(
        (match.feature1.x - imageCenterX) / focalLength,
        (match.feature1.y - imageCenterY) / focalLength,
        1.0,
      ));
      pts2.add(Vector3(
        (match.feature2.x - imageCenterX) / focalLength,
        (match.feature2.y - imageCenterY) / focalLength,
        1.0,
      ));
    }

    // Build coefficient matrix A for Af = 0
    final A = List.generate(8, (_) => List.filled(9, 0.0));

    for (int i = 0; i < 8; i++) {
      final p1 = pts1[i];
      final p2 = pts2[i];

      A[i][0] = p2.x * p1.x;
      A[i][1] = p2.x * p1.y;
      A[i][2] = p2.x;
      A[i][3] = p2.y * p1.x;
      A[i][4] = p2.y * p1.y;
      A[i][5] = p2.y;
      A[i][6] = p1.x;
      A[i][7] = p1.y;
      A[i][8] = 1.0;
    }

    // Solve Af=0 for the null space of A (smallest singular value's vector)
    final F = _solveSVD(A);

    // Enforce Essential Matrix constraint: E = U*diag(1,1,0)*V^T
    final E = _enforceEssentialConstraint(F);

    return E;
  }

  /// Solve Af=0 by finding the eigenvector of A^T*A with smallest eigenvalue.
  /// Uses inverse power iteration with Gaussian elimination.
  static Matrix3 _solveSVD(List<List<double>> A) {
    const n = 9;

    // Compute A^T * A (9x9 symmetric positive semi-definite)
    final AtA = List.generate(n, (_) => List.filled(n, 0.0));
    for (int i = 0; i < n; i++) {
      for (int j = i; j < n; j++) {
        double sum = 0;
        for (int k = 0; k < A.length; k++) {
          sum += A[k][i] * A[k][j];
        }
        AtA[i][j] = sum;
        AtA[j][i] = sum; // symmetric
      }
    }

    // Add small shift to make it invertible (shifted inverse iteration)
    // We solve (A^T*A - sigma*I)^{-1} * v iteratively
    // sigma = 0 (or very small) finds smallest eigenvalue
    const sigma = 1e-10;
    final M = List.generate(n, (i) => List.generate(n, (j) => AtA[i][j]));
    for (int i = 0; i < n; i++) {
      M[i][i] += sigma;
    }

    // Inverse power iteration
    var v = List.filled(n, 1.0 / math.sqrt(n.toDouble()));

    for (int iter = 0; iter < 50; iter++) {
      // Solve M * w = v using Gaussian elimination
      final w = _solveLinearSystem(M, v);
      if (w == null) break; // singular, current v is good enough

      // Normalize
      final norm = math.sqrt(w.fold<double>(0, (s, x) => s + x * x));
      if (norm < 1e-15) break;
      for (int i = 0; i < n; i++) {
        v[i] = w[i] / norm;
      }
    }

    return Matrix3(
      v[0], v[1], v[2],
      v[3], v[4], v[5],
      v[6], v[7], v[8],
    );
  }

  /// Solve Ax = b using Gaussian elimination with partial pivoting
  static List<double>? _solveLinearSystem(List<List<double>> A, List<double> b) {
    final n = A.length;
    // Create augmented matrix [A|b]
    final aug = List.generate(n, (i) => [...A[i], b[i]]);

    // Forward elimination with partial pivoting
    for (int col = 0; col < n; col++) {
      // Find pivot
      int maxRow = col;
      double maxVal = aug[col][col].abs();
      for (int row = col + 1; row < n; row++) {
        if (aug[row][col].abs() > maxVal) {
          maxVal = aug[row][col].abs();
          maxRow = row;
        }
      }
      if (maxVal < 1e-14) return null; // Singular

      // Swap rows
      if (maxRow != col) {
        final temp = aug[col];
        aug[col] = aug[maxRow];
        aug[maxRow] = temp;
      }

      // Eliminate below
      for (int row = col + 1; row < n; row++) {
        final factor = aug[row][col] / aug[col][col];
        for (int j = col; j <= n; j++) {
          aug[row][j] -= factor * aug[col][j];
        }
      }
    }

    // Back substitution
    final x = List.filled(n, 0.0);
    for (int row = n - 1; row >= 0; row--) {
      double sum = aug[row][n];
      for (int j = row + 1; j < n; j++) {
        sum -= aug[row][j] * x[j];
      }
      if (aug[row][row].abs() < 1e-14) return null;
      x[row] = sum / aug[row][row];
    }

    return x;
  }

  /// Enforce Essential Matrix constraints using SVD-like decomposition.
  /// Projects F onto the space of valid Essential Matrices: U*diag(s,s,0)*V^T
  /// where s = (sigma1 + sigma2) / 2.
  static Matrix3 _enforceEssentialConstraint(Matrix3 F) {
    // Compute F^T * F
    final FtF = F.transposed() * F;

    // Find eigenvalues/eigenvectors of F^T*F using Jacobi iteration (3x3 symmetric)
    final eigResult = _symmetricEigen3x3(FtF);
    final eigenvalues = eigResult.values;
    final V = eigResult.vectors;

    // Sort eigenvalues descending (with corresponding eigenvectors)
    final indices = [0, 1, 2];
    indices.sort((a, b) => eigenvalues[b].compareTo(eigenvalues[a]));

    final s1 = math.sqrt(math.max(0, eigenvalues[indices[0]]));
    final s2 = math.sqrt(math.max(0, eigenvalues[indices[1]]));

    // Average of two largest singular values
    final s = (s1 + s2) / 2.0;
    if (s < 1e-10) return F; // Degenerate

    // Reconstruct with diag(s, s, 0)
    // U = F * V * diag(1/s1, 1/s2, ...) but we need to be careful
    // Simpler approach: compute U columns from F * v_i / sigma_i
    final v0 = Vector3(V.entry(0, indices[0]), V.entry(1, indices[0]), V.entry(2, indices[0]));
    final v1 = Vector3(V.entry(0, indices[1]), V.entry(1, indices[1]), V.entry(2, indices[1]));

    Vector3 u0, u1, u2;
    if (s1 > 1e-10) {
      u0 = F.transform(v0) / s1;
    } else {
      u0 = Vector3(1, 0, 0);
    }
    if (s2 > 1e-10) {
      u1 = F.transform(v1) / s2;
    } else {
      u1 = Vector3(0, 1, 0);
    }
    // u2 = u0 x u1 (ensure orthogonality)
    u2 = u0.cross(u1);
    u2.normalize();

    // E = U * diag(s, s, 0) * V^T
    // = s * (u0*v0^T + u1*v1^T)
    final E = Matrix3.zero();
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        E.setEntry(i, j, s * (u0[i] * v0[j] + u1[i] * v1[j]));
      }
    }

    // Normalize so Frobenius norm is sqrt(2)
    double frobSq = 0;
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        frobSq += E.entry(i, j) * E.entry(i, j);
      }
    }
    if (frobSq > 1e-10) {
      final scale = math.sqrt(2.0 / frobSq);
      return E.scaled(scale);
    }
    return E;
  }

  /// Eigendecomposition of a 3x3 symmetric matrix using Jacobi iteration.
  /// Returns eigenvalues and eigenvector matrix (columns are eigenvectors).
  static _EigenResult _symmetricEigen3x3(Matrix3 A) {
    // Work with a mutable copy
    final a = List.generate(3, (i) => List.generate(3, (j) => A.entry(i, j)));
    // Eigenvector matrix starts as identity
    final v = List.generate(3, (i) => List.generate(3, (j) => i == j ? 1.0 : 0.0));

    // Jacobi rotations
    for (int sweep = 0; sweep < 50; sweep++) {
      // Check convergence: sum of off-diagonal squared
      double offDiag = 0;
      for (int i = 0; i < 3; i++) {
        for (int j = i + 1; j < 3; j++) {
          offDiag += a[i][j] * a[i][j];
        }
      }
      if (offDiag < 1e-20) break;

      for (int p = 0; p < 3; p++) {
        for (int q = p + 1; q < 3; q++) {
          if (a[p][q].abs() < 1e-15) continue;

          // Compute rotation angle
          final tau = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
          final t = (tau >= 0 ? 1.0 : -1.0) /
              (tau.abs() + math.sqrt(1.0 + tau * tau));
          final c = 1.0 / math.sqrt(1.0 + t * t);
          final s = t * c;

          // Apply Jacobi rotation to A: A' = G^T * A * G
          final app = a[p][p] - t * a[p][q];
          final aqq = a[q][q] + t * a[p][q];
          a[p][q] = 0;
          a[q][p] = 0;
          a[p][p] = app;
          a[q][q] = aqq;

          // Update off-diagonal elements
          for (int r = 0; r < 3; r++) {
            if (r == p || r == q) continue;
            final arp = a[r][p];
            final arq = a[r][q];
            a[r][p] = c * arp - s * arq;
            a[p][r] = a[r][p];
            a[r][q] = s * arp + c * arq;
            a[q][r] = a[r][q];
          }

          // Update eigenvectors
          for (int r = 0; r < 3; r++) {
            final vrp = v[r][p];
            final vrq = v[r][q];
            v[r][p] = c * vrp - s * vrq;
            v[r][q] = s * vrp + c * vrq;
          }
        }
      }
    }

    final eigenvalues = [a[0][0], a[1][1], a[2][2]];
    final vectors = Matrix3(
      v[0][0], v[0][1], v[0][2],
      v[1][0], v[1][1], v[1][2],
      v[2][0], v[2][1], v[2][2],
    );

    return _EigenResult(values: eigenvalues, vectors: vectors);
  }

  /// Calculate epipolar error for a match
  static double _epipolarError(
    FeatureMatch match,
    Matrix3 E,
    double focalLength,
  ) {
    // Normalize points
    final p1 = Vector3(
      (match.feature1.x - imageCenterX) / focalLength,
      (match.feature1.y - imageCenterY) / focalLength,
      1.0,
    );
    final p2 = Vector3(
      (match.feature2.x - imageCenterX) / focalLength,
      (match.feature2.y - imageCenterY) / focalLength,
      1.0,
    );

    // Epipolar constraint: p2^T * E * p1 = 0
    final Ep1 = E.transform(p1);
    final error = p2.dot(Ep1).abs();

    return error;
  }

  /// Recover camera pose from Essential Matrix
  static List<CameraPoseHypothesis> recoverPoseFromEssential(
    Matrix3 E,
    List<FeatureMatch> inliers,
    double focalLength,
  ) {
    // Decompose Essential Matrix into rotation and translation
    // E = U * diag(1,1,0) * V^T
    // Four solutions: R = U * W * V^T or U * W^T * V^T, t = +-u3

    final hypotheses = <CameraPoseHypothesis>[];

    final decomp = _decomposeEssentialMatrix(E);
    final rotations = decomp.rotations;
    final translation = decomp.translation;

    for (final R in rotations) {
      for (final tSign in [1.0, -1.0]) {
        final t = translation.scaled(tSign);

        // Test hypothesis by triangulating a few points
        int positiveDepth = 0;
        for (int i = 0; i < math.min(10, inliers.length); i++) {
          final match = inliers[i];
          final point3D = _triangulatePoint(
            match,
            Matrix3.identity(),
            Vector3.zero(),
            R,
            t,
            focalLength,
          );

          // Check if point is in front of both cameras
          if (point3D.z > 0 && (R.transform(point3D) + t).z > 0) {
            positiveDepth++;
          }
        }

        hypotheses.add(CameraPoseHypothesis(
          rotation: R,
          translation: t,
          positiveDepthCount: positiveDepth,
        ));
      }
    }

    // Sort by number of points with positive depth
    hypotheses.sort((a, b) => b.positiveDepthCount.compareTo(a.positiveDepthCount));

    return hypotheses;
  }

  /// Decompose Essential Matrix into R1, R2 and t using proper SVD.
  /// E = U * diag(1,1,0) * V^T
  /// R1 = U * W * V^T, R2 = U * W^T * V^T, t = U[:, 2]
  static _EssentialDecomposition _decomposeEssentialMatrix(Matrix3 E) {
    // Compute E^T * E
    final EtE = E.transposed() * E;

    // Eigendecomposition of E^T*E to get V and singular values
    final eigResult = _symmetricEigen3x3(EtE);

    // Sort eigenvalues descending
    final indices = [0, 1, 2];
    indices.sort((a, b) => eigResult.values[b].compareTo(eigResult.values[a]));

    final s1 = math.sqrt(math.max(0, eigResult.values[indices[0]]));
    final s2 = math.sqrt(math.max(0, eigResult.values[indices[1]]));

    // V columns (right singular vectors) sorted by singular value
    final v0 = Vector3(
      eigResult.vectors.entry(0, indices[0]),
      eigResult.vectors.entry(1, indices[0]),
      eigResult.vectors.entry(2, indices[0]),
    );
    final v1 = Vector3(
      eigResult.vectors.entry(0, indices[1]),
      eigResult.vectors.entry(1, indices[1]),
      eigResult.vectors.entry(2, indices[1]),
    );
    var v2 = Vector3(
      eigResult.vectors.entry(0, indices[2]),
      eigResult.vectors.entry(1, indices[2]),
      eigResult.vectors.entry(2, indices[2]),
    );

    // Ensure V is a proper rotation (det = +1)
    final Vmat = Matrix3(
      v0.x, v1.x, v2.x,
      v0.y, v1.y, v2.y,
      v0.z, v1.z, v2.z,
    );
    if (Vmat.determinant() < 0) {
      v2 = -v2;
    }
    final V = Matrix3(
      v0.x, v1.x, v2.x,
      v0.y, v1.y, v2.y,
      v0.z, v1.z, v2.z,
    );

    // Compute U columns: u_i = E * v_i / sigma_i
    Vector3 u0, u1, u2;
    if (s1 > 1e-10) {
      u0 = E.transform(v0) / s1;
    } else {
      u0 = Vector3(1, 0, 0);
    }
    if (s2 > 1e-10) {
      u1 = E.transform(v1) / s2;
    } else {
      u1 = Vector3(0, 1, 0);
    }
    u2 = u0.cross(u1);
    u2.normalize();

    // Ensure U is a proper rotation
    var U = Matrix3(
      u0.x, u1.x, u2.x,
      u0.y, u1.y, u2.y,
      u0.z, u1.z, u2.z,
    );
    if (U.determinant() < 0) {
      u2 = -u2;
      U = Matrix3(
        u0.x, u1.x, u2.x,
        u0.y, u1.y, u2.y,
        u0.z, u1.z, u2.z,
      );
    }

    // W matrix (90° rotation)
    final W = Matrix3(
      0, -1, 0,
      1,  0, 0,
      0,  0, 1,
    );

    // Two possible rotations: R1 = U * W * V^T, R2 = U * W^T * V^T
    final Vt = V.transposed();
    final R1 = U * W * Vt;
    final R2 = U * W.transposed() * Vt;

    // Ensure proper rotations (det = +1)
    Matrix3 r1Final = R1;
    Matrix3 r2Final = R2;
    if (R1.determinant() < 0) r1Final = R1.scaled(-1);
    if (R2.determinant() < 0) r2Final = R2.scaled(-1);

    // Translation = third column of U
    final t = Vector3(U.entry(0, 2), U.entry(1, 2), U.entry(2, 2)).normalized();

    return _EssentialDecomposition(
      rotations: [r1Final, r2Final],
      translation: t,
    );
  }

  /// Triangulate a single point with two camera poses
  static Vector3 _triangulatePoint(
    FeatureMatch match,
    Matrix3 R1,
    Vector3 t1,
    Matrix3 R2,
    Vector3 t2,
    double focalLength,
  ) {
    // Normalize pixel coordinates
    final p1 = Vector3(
      (match.feature1.x - imageCenterX) / focalLength,
      (match.feature1.y - imageCenterY) / focalLength,
      1.0,
    ).normalized();

    final p2 = Vector3(
      (match.feature2.x - imageCenterX) / focalLength,
      (match.feature2.y - imageCenterY) / focalLength,
      1.0,
    ).normalized();

    // Ray directions in world coordinates
    final ray1 = R1.transposed().transform(p1);
    final ray2 = R2.transposed().transform(p2);

    // Ray origins
    final o1 = -R1.transposed().transform(t1);
    final o2 = -R2.transposed().transform(t2);

    // Find closest point between rays
    return _closestPointBetweenRays(o1, ray1, o2, ray2);
  }

  /// Find closest point between two rays
  static Vector3 _closestPointBetweenRays(
    Vector3 o1,
    Vector3 d1,
    Vector3 o2,
    Vector3 d2,
  ) {
    final w = o1 - o2;
    final a = d1.dot(d1);
    final b = d1.dot(d2);
    final c = d2.dot(d2);
    final d = d1.dot(w);
    final e = d2.dot(w);

    final denom = a * c - b * b;
    if (denom.abs() < 1e-10) {
      return o1; // Rays are parallel
    }

    final t1 = (b * e - c * d) / denom;
    final t2 = (a * e - b * d) / denom;

    final p1 = o1 + d1.scaled(t1);
    final p2 = o2 + d2.scaled(t2);

    return (p1 + p2).scaled(0.5); // Midpoint
  }

  /// PROSAC (Progressive Sample Consensus) sampling
  /// Samples preferentially from high-quality matches (already sorted by distance)
  /// Early iterations use only top matches, later iterations expand to all matches
  static List<FeatureMatch> _prosacSample(List<FeatureMatch> matches, int n, int iteration, int maxIterations) {
    // Progressive pool size: start with top 20% of matches, grow to 100%
    final minPoolSize = math.max(n * 2, (matches.length * 0.2).toInt());
    final maxPoolSize = matches.length;
    final progress = iteration / maxIterations;
    final poolSize = (minPoolSize + (maxPoolSize - minPoolSize) * progress).toInt().clamp(n, maxPoolSize);

    // Sample from the quality-ordered pool
    final pool = matches.take(poolSize).toList();
    final indices = List.generate(pool.length, (i) => i);
    indices.shuffle();
    return indices.take(n).map((i) => pool[i]).toList();
  }
}

/// Internal: eigenvalues + eigenvectors result
class _EigenResult {
  final List<double> values;
  final Matrix3 vectors;
  _EigenResult({required this.values, required this.vectors});
}

/// Internal: Essential Matrix decomposition result
class _EssentialDecomposition {
  final List<Matrix3> rotations;
  final Vector3 translation;
  _EssentialDecomposition({required this.rotations, required this.translation});
}

/// Result from Essential Matrix estimation
class EssentialMatrixResult {
  final Matrix3 matrix;
  final List<FeatureMatch> inliers;
  final int inlierCount;
  final int totalMatches;

  EssentialMatrixResult({
    required this.matrix,
    required this.inliers,
    required this.inlierCount,
    required this.totalMatches,
  });

  double get inlierRatio => inlierCount / totalMatches;
}

/// Camera pose hypothesis from Essential Matrix decomposition
class CameraPoseHypothesis {
  final Matrix3 rotation;
  final Vector3 translation;
  final int positiveDepthCount;

  CameraPoseHypothesis({
    required this.rotation,
    required this.translation,
    required this.positiveDepthCount,
  });
}
