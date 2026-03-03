import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Depth map from stereo matching.
class DepthMap {
  final int width;
  final int height;
  final Float32List depths;
  final Float32List confidence;

  DepthMap({
    required this.width,
    required this.height,
    required this.depths,
    required this.confidence,
  });

  double depthAt(int x, int y) => depths[y * width + x];
  double confidenceAt(int x, int y) => confidence[y * width + x];
}

/// PatchMatch stereo depth estimation.
///
/// Estimates per-pixel depth from a pair of rectified images using
/// randomized search with spatial propagation (PatchMatch algorithm).
class PatchMatchStereo {
  /// Patch half-size for NCC computation.
  final int patchRadius;

  /// Number of PatchMatch iterations.
  final int iterations;

  /// Maximum disparity to search.
  final int maxDisparity;

  /// Resolution for depth estimation (longest dimension).
  final int resolution;

  PatchMatchStereo({
    this.patchRadius = 3,
    this.iterations = 3,
    this.maxDisparity = 64,
    this.resolution = 512,
  });

  /// Estimate depth map from a stereo image pair.
  ///
  /// [leftGray] and [rightGray] are grayscale pixel arrays (row-major, 0-255).
  /// [width] and [height] are the image dimensions.
  Future<DepthMap> estimate(
    Float32List leftGray,
    Float32List rightGray,
    int width,
    int height,
  ) async {
    return compute(_estimateIsolate, {
      'left': leftGray,
      'right': rightGray,
      'width': width,
      'height': height,
      'patchRadius': patchRadius,
      'iterations': iterations,
      'maxDisparity': maxDisparity,
    });
  }

  static DepthMap _estimateIsolate(Map<String, dynamic> args) {
    final left = args['left'] as Float32List;
    final right = args['right'] as Float32List;
    final w = args['width'] as int;
    final h = args['height'] as int;
    final patchR = args['patchRadius'] as int;
    final iters = args['iterations'] as int;
    final maxDisp = args['maxDisparity'] as int;
    final rng = math.Random(42);

    // Initialize disparities randomly
    final disparities = Float32List(w * h);
    final confidence = Float32List(w * h);
    final costs = Float32List(w * h);

    for (int i = 0; i < w * h; i++) {
      disparities[i] = rng.nextDouble() * maxDisp;
      costs[i] = double.maxFinite;
    }

    // PatchMatch iterations
    for (int iter = 0; iter < iters; iter++) {
      final forward = iter % 2 == 0;

      for (int y = forward ? patchR : h - patchR - 1;
          forward ? y < h - patchR : y >= patchR;
          forward ? y++ : y--) {
        for (int x = forward ? patchR : w - patchR - 1;
            forward ? x < w - patchR : x >= patchR;
            forward ? x++ : x--) {
          final idx = y * w + x;

          // Current cost
          final currentCost = _nccCost(left, right, w, h, x, y,
              disparities[idx].round().clamp(0, maxDisp - 1), patchR);
          costs[idx] = currentCost;

          // Spatial propagation: try neighbor's disparity
          final neighbors = <int>[];
          if (forward) {
            if (x > patchR) neighbors.add(y * w + x - 1);
            if (y > patchR) neighbors.add((y - 1) * w + x);
          } else {
            if (x < w - patchR - 1) neighbors.add(y * w + x + 1);
            if (y < h - patchR - 1) neighbors.add((y + 1) * w + x);
          }

          for (final ni in neighbors) {
            final nd = disparities[ni].round().clamp(0, maxDisp - 1);
            final nc = _nccCost(left, right, w, h, x, y, nd, patchR);
            if (nc < costs[idx]) {
              costs[idx] = nc;
              disparities[idx] = nd.toDouble();
            }
          }

          // Random refinement: try random offsets with decreasing radius
          double searchRadius = maxDisp / 2.0;
          while (searchRadius >= 1.0) {
            final offset = (rng.nextDouble() * 2 - 1) * searchRadius;
            final nd = (disparities[idx] + offset)
                .round()
                .clamp(0, maxDisp - 1);
            final nc = _nccCost(left, right, w, h, x, y, nd, patchR);
            if (nc < costs[idx]) {
              costs[idx] = nc;
              disparities[idx] = nd.toDouble();
            }
            searchRadius *= 0.5;
          }

          // Confidence from inverse cost (NCC: lower = better, range -1 to 1)
          confidence[idx] = (1.0 - costs[idx]).clamp(0.0, 1.0);
        }
      }
    }

    return DepthMap(
      width: w,
      height: h,
      depths: disparities,
      confidence: confidence,
    );
  }

  /// Normalized Cross-Correlation cost between patches.
  /// Returns value in [-1, 1] where -1 is perfect match (we minimize).
  static double _nccCost(Float32List left, Float32List right, int w, int h,
      int x, int y, int disparity, int patchR) {
    double sumL = 0, sumR = 0, sumLL = 0, sumRR = 0, sumLR = 0;
    int count = 0;

    for (int dy = -patchR; dy <= patchR; dy++) {
      for (int dx = -patchR; dx <= patchR; dx++) {
        final lx = x + dx;
        final ly = y + dy;
        final rx = x + dx - disparity;
        final ry = y + dy;

        if (lx < 0 || lx >= w || ly < 0 || ly >= h) continue;
        if (rx < 0 || rx >= w || ry < 0 || ry >= h) continue;

        final lv = left[ly * w + lx];
        final rv = right[ry * w + rx];

        sumL += lv;
        sumR += rv;
        sumLL += lv * lv;
        sumRR += rv * rv;
        sumLR += lv * rv;
        count++;
      }
    }

    if (count == 0) return 1.0;

    final meanL = sumL / count;
    final meanR = sumR / count;
    final varL = sumLL / count - meanL * meanL;
    final varR = sumRR / count - meanR * meanR;
    final covar = sumLR / count - meanL * meanR;

    final denom = math.sqrt(varL * varR);
    if (denom < 1e-6) return 1.0;

    // NCC in [-1, 1], negate so lower = better match
    return -(covar / denom);
  }
}
