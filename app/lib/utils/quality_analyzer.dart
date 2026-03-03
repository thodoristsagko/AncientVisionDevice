import 'dart:math' as math;
import 'package:image/image.dart' as img;

/// Real-time quality analysis for photogrammetry captures
class QualityAnalyzer {
  /// Analyze image quality in real-time
  static Future<QualityMetrics> analyzeImage(img.Image image) async {
    // Run analysis in parallel for speed
    final sharpnessFuture = _calculateSharpness(image);
    final exposureFuture = _analyzeExposure(image);
    final motionBlurFuture = _detectMotionBlur(image);
    final noiseFuture = _estimateNoise(image);

    final results = await Future.wait([
      sharpnessFuture,
      exposureFuture,
      motionBlurFuture,
      noiseFuture,
    ]);

    return QualityMetrics(
      sharpness: results[0],
      exposure: results[1],
      motionBlur: results[2],
      noise: results[3],
    );
  }

  /// Calculate sharpness using Laplacian variance
  static Future<double> _calculateSharpness(img.Image image) async {
    // Sample center region (more important for photogrammetry)
    final centerX = image.width ~/ 2;
    final centerY = image.height ~/ 2;
    final sampleSize = math.min(image.width, image.height) ~/ 4;

    double sumVariance = 0;
    int count = 0;

    for (int y = centerY - sampleSize; y < centerY + sampleSize; y += 4) {
      for (int x = centerX - sampleSize; x < centerX + sampleSize; x += 4) {
        if (x < 1 || x >= image.width - 1 || y < 1 || y >= image.height - 1) {
          continue;
        }

        // Laplacian kernel: center - 8*neighbors
        final center = _getGray(image, x, y);
        final laplacian = (8 * center -
                _getGray(image, x - 1, y) -
                _getGray(image, x + 1, y) -
                _getGray(image, x, y - 1) -
                _getGray(image, x, y + 1) -
                _getGray(image, x - 1, y - 1) -
                _getGray(image, x + 1, y - 1) -
                _getGray(image, x - 1, y + 1) -
                _getGray(image, x + 1, y + 1))
            .abs();

        sumVariance += laplacian * laplacian;
        count++;
      }
    }

    // Normalize to 0-1 range (empirically, good images > 500)
    final variance = count > 0 ? sumVariance / count : 0;
    return (variance / 1000).clamp(0.0, 1.0);
  }

  /// Analyze exposure (brightness and contrast)
  static Future<double> _analyzeExposure(img.Image image) async {
    double sum = 0;
    double sumSquared = 0;
    int count = 0;

    // Sample every 8th pixel for speed
    for (int y = 0; y < image.height; y += 8) {
      for (int x = 0; x < image.width; x += 8) {
        final gray = _getGray(image, x, y);
        sum += gray;
        sumSquared += gray * gray;
        count++;
      }
    }

    final mean = sum / count;
    final variance = (sumSquared / count) - (mean * mean);
    final stdDev = math.sqrt(variance);

    // Good exposure: mean around 128, stdDev > 40
    final exposureScore = 1.0 - ((mean - 128).abs() / 128);
    final contrastScore = (stdDev / 60).clamp(0.0, 1.0);

    return (exposureScore * 0.6 + contrastScore * 0.4).clamp(0.0, 1.0);
  }

  /// Detect motion blur using edge analysis
  static Future<double> _detectMotionBlur(img.Image image) async {
    // Calculate horizontal and vertical edge strengths
    double horizontalEdges = 0;
    double verticalEdges = 0;
    int count = 0;

    for (int y = 1; y < image.height - 1; y += 8) {
      for (int x = 1; x < image.width - 1; x += 8) {
        // Horizontal gradient
        final dx = (_getGray(image, x + 1, y) - _getGray(image, x - 1, y)).abs();
        horizontalEdges += dx;

        // Vertical gradient
        final dy = (_getGray(image, x, y + 1) - _getGray(image, x, y - 1)).abs();
        verticalEdges += dy;

        count++;
      }
    }

    if (count == 0) return 1.0;

    horizontalEdges /= count;
    verticalEdges /= count;

    // Motion blur shows directional edge asymmetry
    final maxEdge = math.max(horizontalEdges, verticalEdges);
    final ratio = maxEdge > 0
        ? math.min(horizontalEdges, verticalEdges) / maxEdge
        : 1.0;

    // Higher ratio (closer to 1.0) = less motion blur
    return ratio.clamp(0.0, 1.0);
  }

  /// Estimate noise level
  static Future<double> _estimateNoise(img.Image image) async {
    // Use high-frequency components as noise estimate
    double noiseEstimate = 0;
    int count = 0;

    for (int y = 1; y < image.height - 1; y += 16) {
      for (int x = 1; x < image.width - 1; x += 16) {
        final center = _getGray(image, x, y);

        // Calculate local variance (noise indicator)
        double localVariance = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final neighbor = _getGray(image, x + dx, y + dy);
            final diff = neighbor - center;
            localVariance += diff * diff;
          }
        }

        noiseEstimate += math.sqrt(localVariance / 9);
        count++;
      }
    }

    final avgNoise = count > 0 ? noiseEstimate / count : 0;

    // Lower noise = higher score (empirically, good images < 10)
    return (1.0 - (avgNoise / 20)).clamp(0.0, 1.0);
  }

  /// Helper: Get grayscale value
  static double _getGray(img.Image image, int x, int y) {
    final pixel = image.getPixel(x, y);
    return (pixel.r + pixel.g + pixel.b) / 3.0;
  }

  /// Get quality rating from metrics
  static QualityRating getQualityRating(QualityMetrics metrics) {
    final overall = metrics.overallScore;

    if (overall >= 0.85) {
      return QualityRating.excellent;
    } else if (overall >= 0.70) {
      return QualityRating.good;
    } else if (overall >= 0.55) {
      return QualityRating.fair;
    } else if (overall >= 0.40) {
      return QualityRating.poor;
    } else {
      return QualityRating.veryPoor;
    }
  }

  /// Get recommendations based on metrics
  static List<String> getRecommendations(QualityMetrics metrics) {
    final recommendations = <String>[];

    if (metrics.sharpness < 0.6) {
      recommendations.add('💡 Hold camera steady or use tripod');
    }

    if (metrics.exposure < 0.6) {
      recommendations.add('💡 Adjust lighting or use HDR mode');
    }

    if (metrics.motionBlur < 0.7) {
      recommendations.add('💡 Camera moving - keep very still during capture');
    }

    if (metrics.noise < 0.6) {
      recommendations.add('💡 Increase lighting to reduce noise');
    }

    if (recommendations.isEmpty) {
      recommendations.add('✓ Perfect capture quality!');
    }

    return recommendations;
  }
}

/// Quality metrics for an image
class QualityMetrics {
  final double sharpness; // 0-1, higher = sharper
  final double exposure; // 0-1, higher = better exposed
  final double motionBlur; // 0-1, higher = less blur
  final double noise; // 0-1, higher = less noise

  QualityMetrics({
    required this.sharpness,
    required this.exposure,
    required this.motionBlur,
    required this.noise,
  });

  /// Overall quality score (weighted average)
  double get overallScore {
    return (sharpness * 0.40 + // Most important
            exposure * 0.25 +
            motionBlur * 0.25 +
            noise * 0.10)
        .clamp(0.0, 1.0);
  }

  /// Get color for UI display
  int get scoreColor {
    if (overallScore >= 0.85) return 0xFF4CAF50; // Green
    if (overallScore >= 0.70) return 0xFF8BC34A; // Light green
    if (overallScore >= 0.55) return 0xFFFFC107; // Yellow
    if (overallScore >= 0.40) return 0xFFFF9800; // Orange
    return 0xFFF44336; // Red
  }

  Map<String, dynamic> toJson() => {
        'sharpness': sharpness,
        'exposure': exposure,
        'motionBlur': motionBlur,
        'noise': noise,
        'overallScore': overallScore,
      };
}

/// Quality rating categories
enum QualityRating {
  excellent,
  good,
  fair,
  poor,
  veryPoor,
}

extension QualityRatingExtension on QualityRating {
  String get label {
    switch (this) {
      case QualityRating.excellent:
        return 'Excellent';
      case QualityRating.good:
        return 'Good';
      case QualityRating.fair:
        return 'Fair';
      case QualityRating.poor:
        return 'Poor';
      case QualityRating.veryPoor:
        return 'Very Poor';
    }
  }

  String get icon {
    switch (this) {
      case QualityRating.excellent:
        return '⭐⭐⭐';
      case QualityRating.good:
        return '⭐⭐';
      case QualityRating.fair:
        return '⭐';
      case QualityRating.poor:
        return '⚠️';
      case QualityRating.veryPoor:
        return '❌';
    }
  }
}
