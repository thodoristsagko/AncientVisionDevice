import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'reconstruction_models.dart';

/// Extract corner features from images using LightGlue (preferred) or Harris corner detector (fallback)
/// Extract features from a single image with multi-scale detection (runs in isolate)
List<ImageFeature> extractFeaturesFromImage(img.Image image) {
  final features = <ImageFeature>[];
  final width = image.width;
  final height = image.height;

  try {
    final gray = img.grayscale(image);
    final candidateFeatures = <ImageFeature>[];

    // Multi-scale feature detection for robustness
    final scales = [1.0, 0.75, 0.5];

    for (final scale in scales) {
      img.Image scaledGray;
      if (scale < 1.0) {
        scaledGray = img.copyResize(gray,
          width: (width * scale).toInt(),
          height: (height * scale).toInt(),
          interpolation: img.Interpolation.linear,
        );
      } else {
        scaledGray = gray;
      }

      final sw = scaledGray.width;
      final sh = scaledGray.height;

      // Dense grid sampling
      const gridSize = 25;
      final cellW = sw / gridSize;
      final cellH = sh / gridSize;

      for (int gy = 0; gy < gridSize; gy++) {
        for (int gx = 0; gx < gridSize; gx++) {
          // Multiple samples per cell
          for (int s = 0; s < 3; s++) {
            final cx = ((gx + (s % 2) * 0.5 + 0.25) * cellW).toInt();
            final cy = ((gy + (s ~/ 2) * 0.5 + 0.25) * cellH).toInt();

            if (cx < 5 || cx >= sw - 5 || cy < 5 || cy >= sh - 5) continue;

            final strength = _calculateCornerStrength(scaledGray, cx, cy);

            if (strength > 300) {
              // Scale coordinates back to original
              final origX = cx / scale;
              final origY = cy / scale;

              candidateFeatures.add(ImageFeature(
                x: origX,
                y: origY,
                strength: strength * scale, // Weight by scale
                descriptor: [],
              ));
            }
          }
        }
      }
    }

    // Adaptive threshold
    if (candidateFeatures.isEmpty) return features;

    candidateFeatures.sort((a, b) => b.strength.compareTo(a.strength));
    final threshold = candidateFeatures[candidateFeatures.length ~/ 4].strength * 0.5;

    // Extract descriptors for strong features
    for (final candidate in candidateFeatures) {
      if (candidate.strength > threshold) {
        final x = candidate.x.toInt().clamp(8, width - 9);
        final y = candidate.y.toInt().clamp(8, height - 9);

        final descriptor = _extractDescriptor(gray, x, y);
        features.add(ImageFeature(
          x: candidate.x,
          y: candidate.y,
          strength: candidate.strength,
          descriptor: descriptor,
        ));
      }
    }

    // Non-maximum suppression with spatial hashing for speed
    final suppressedFeatures = <ImageFeature>[];
    features.sort((a, b) => b.strength.compareTo(a.strength));
    final occupied = <int>{};
    const cellSize = 8;

    for (final feature in features) {
      final cellX = (feature.x / cellSize).toInt();
      final cellY = (feature.y / cellSize).toInt();
      final cellKey = cellY * 100003 + cellX;

      // Check neighboring cells
      bool tooClose = false;
      for (int dy = -1; dy <= 1 && !tooClose; dy++) {
        for (int dx = -1; dx <= 1 && !tooClose; dx++) {
          if (occupied.contains((cellY + dy) * 100003 + (cellX + dx))) {
            tooClose = true;
          }
        }
      }

      if (!tooClose) {
        suppressedFeatures.add(feature);
        occupied.add(cellKey);
      }
    }

    // Keep top 500 features and apply radial distortion correction
    final topFeatures = suppressedFeatures.take(500).toList();
    return undistortPoints(topFeatures, width.toDouble(), height.toDouble());
  } catch (e) {
    return features;
  }
}

/// Calculate corner strength using simplified Harris detector
double _calculateCornerStrength(img.Image gray, int x, int y) {
  double ix2 = 0, iy2 = 0, ixIy = 0;

  // Calculate gradients in 5x5 window
  for (int dy = -2; dy <= 2; dy++) {
    for (int dx = -2; dx <= 2; dx++) {
      final px = x + dx;
      final py = y + dy;

      if (px < 1 || px >= gray.width - 1 || py < 1 || py >= gray.height - 1) {
        continue;
      }

      // Sobel-like gradient
      final gx = (gray.getPixel(px + 1, py).r - gray.getPixel(px - 1, py).r) / 2.0;
      final gy = (gray.getPixel(px, py + 1).r - gray.getPixel(px, py - 1).r) / 2.0;

      ix2 += gx * gx;
      iy2 += gy * gy;
      ixIy += gx * gy;
    }
  }

  // Harris response: det(M) - k * trace(M)^2
  const k = 0.04;
  final det = ix2 * iy2 - ixIy * ixIy;
  final trace = ix2 + iy2;
  return det - k * trace * trace;
}

/// Apply Brown-Conrady radial distortion correction to feature points
/// Uses typical phone camera distortion coefficients (k1=-0.1, k2=0.01)
List<ImageFeature> undistortPoints(List<ImageFeature> features, double imageWidth, double imageHeight) {
  const k1 = -0.1;  // Barrel distortion coefficient
  const k2 = 0.01;  // Higher-order correction
  final cx = imageWidth / 2.0;
  final cy = imageHeight / 2.0;
  final maxDim = math.max(imageWidth, imageHeight);

  final correctedFeatures = <ImageFeature>[];
  for (final feature in features) {
    // Normalize coordinates to [-0.5, 0.5] range centered on principal point
    final xNorm = (feature.x - cx) / maxDim;
    final yNorm = (feature.y - cy) / maxDim;

    // Compute radial distance squared
    final r2 = xNorm * xNorm + yNorm * yNorm;

    // Apply Brown-Conrady model: x_corrected = x * (1 + k1*r² + k2*r⁴)
    final distortionFactor = 1.0 + k1 * r2 + k2 * r2 * r2;

    final xCorrected = cx + (xNorm * distortionFactor * maxDim);
    final yCorrected = cy + (yNorm * distortionFactor * maxDim);

    correctedFeatures.add(ImageFeature(
      x: xCorrected,
      y: yCorrected,
      strength: feature.strength,
      descriptor: feature.descriptor,
    ));
  }

  return correctedFeatures;
}

/// Extract orientation-invariant descriptor from 8x8 patch
List<double> _extractDescriptor(img.Image gray, int x, int y) {
  // Compute dominant gradient orientation in a 7x7 window
  double gxSum = 0, gySum = 0;
  for (int dy = -3; dy <= 3; dy++) {
    for (int dx = -3; dx <= 3; dx++) {
      final px = (x + dx).clamp(1, gray.width - 2);
      final py = (y + dy).clamp(1, gray.height - 2);
      final gx = gray.getPixel(px + 1, py).r.toDouble() - gray.getPixel(px - 1, py).r.toDouble();
      final gy = gray.getPixel(px, py + 1).r.toDouble() - gray.getPixel(px, py - 1).r.toDouble();
      gxSum += gx;
      gySum += gy;
    }
  }
  final angle = math.atan2(gySum, gxSum);
  final cosA = math.cos(angle);
  final sinA = math.sin(angle);

  // Sample 8x8 patch rotated by dominant orientation
  final descriptor = <double>[];
  for (int dy = -4; dy < 4; dy++) {
    for (int dx = -4; dx < 4; dx++) {
      // Rotate sample position by -angle
      final rx = (dx * cosA + dy * sinA).round();
      final ry = (-dx * sinA + dy * cosA).round();
      final px = x + rx;
      final py = y + ry;

      if (px >= 0 && px < gray.width && py >= 0 && py < gray.height) {
        descriptor.add(gray.getPixel(px, py).r.toDouble());
      } else {
        descriptor.add(0.0);
      }
    }
  }

  // Normalize descriptor
  final mean = descriptor.reduce((a, b) => a + b) / descriptor.length;
  final std = math.sqrt(
    descriptor.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / descriptor.length,
  );

  if (std > 0) {
    for (int i = 0; i < descriptor.length; i++) {
      descriptor[i] = (descriptor[i] - mean) / std;
    }
  }

  return descriptor;
}
