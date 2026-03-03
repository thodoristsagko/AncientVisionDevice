import 'dart:math' as math;
import 'reconstruction_models.dart';

/// Match features between two images with cross-check (runs in isolate)
List<FeatureMatch> matchFeaturePair(Map<String, dynamic> args) {
  final features1 = args['features1'] as List<ImageFeature>;
  final features2 = args['features2'] as List<ImageFeature>;

  // Forward matching: f1 -> f2
  final forwardMatches = <int, MatchCandidate>{};
  for (int i = 0; i < features1.length; i++) {
    final f1 = features1[i];
    double best = double.infinity;
    double secondBest = double.infinity;
    int bestIdx = -1;

    for (int j = 0; j < features2.length; j++) {
      final dist = _descriptorDistance(f1.descriptor, features2[j].descriptor);
      if (dist < best) {
        secondBest = best;
        best = dist;
        bestIdx = j;
      } else if (dist < secondBest) {
        secondBest = dist;
      }
    }

    // Lowe's ratio test (tighter threshold for quality)
    if (bestIdx >= 0 && best < 0.75 * secondBest) {
      forwardMatches[i] = MatchCandidate(bestIdx, best);
    }
  }

  // Backward matching: f2 -> f1 (cross-check)
  final backwardMatches = <int, int>{};
  for (int j = 0; j < features2.length; j++) {
    final f2 = features2[j];
    double best = double.infinity;
    double secondBest = double.infinity;
    int bestIdx = -1;

    for (int i = 0; i < features1.length; i++) {
      final dist = _descriptorDistance(features1[i].descriptor, f2.descriptor);
      if (dist < best) {
        secondBest = best;
        best = dist;
        bestIdx = i;
      } else if (dist < secondBest) {
        secondBest = dist;
      }
    }

    if (bestIdx >= 0 && best < 0.75 * secondBest) {
      backwardMatches[j] = bestIdx;
    }
  }

  // Keep only bidirectional matches (cross-check validation)
  final matches = <FeatureMatch>[];
  for (final entry in forwardMatches.entries) {
    final i = entry.key;
    final j = entry.value.idx;

    // Cross-check: f1->f2 and f2->f1 must agree
    if (backwardMatches[j] == i) {
      matches.add(FeatureMatch(
        feature1: features1[i],
        feature2: features2[j],
        distance: entry.value.distance,
      ));
    }
  }

  // Sort by descriptor distance (best matches first) for PROSAC
  // PROSAC uses quality ordering to sample high-quality matches earlier
  matches.sort((a, b) => a.distance.compareTo(b.distance));
  return matches;
}


/// Calculate Euclidean distance between descriptors
double _descriptorDistance(List<double> d1, List<double> d2) {
  double sum = 0;
  for (int i = 0; i < d1.length && i < d2.length; i++) {
    final diff = d1[i] - d2[i];
    sum += diff * diff;
  }
  return math.sqrt(sum);
}
