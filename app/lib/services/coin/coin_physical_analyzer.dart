// ═══════════════════════════════════════════════════════════════════════════
// COIN PHYSICAL ANALYZER - Edge type and coin side detection
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'coin_models.dart';

/// Service for analyzing physical coin characteristics (edge, side detection)
class CoinPhysicalAnalyzer {
  /// Detect edge type from coin image (if edge is visible)
  static EdgeTypeAnalysis analyzeEdgeType(img.Image image) {
    // This is a simplified analysis - true edge detection requires edge-on photography
    // We analyze the rim area for patterns

    final width = image.width;
    final height = image.height;
    final rimWidth = math.min(width, height) ~/ 15;

    // Sample the rim area
    int regularPatternPixels = 0;
    int smoothPixels = 0;
    int totalRimPixels = 0;

    // Sample top and bottom rim
    for (int x = rimWidth; x < width - rimWidth; x += 2) {
      // Top rim
      for (int y = 0; y < rimWidth; y++) {
        _analyzeRimPixel(image, x, y, (regular, smooth) {
          if (regular) regularPatternPixels++;
          if (smooth) smoothPixels++;
          totalRimPixels++;
        });
      }
      // Bottom rim
      for (int y = height - rimWidth; y < height; y++) {
        _analyzeRimPixel(image, x, y, (regular, smooth) {
          if (regular) regularPatternPixels++;
          if (smooth) smoothPixels++;
          totalRimPixels++;
        });
      }
    }

    if (totalRimPixels == 0) {
      return EdgeTypeAnalysis(
        edgeType: EdgeType.unknown,
        confidence: 0,
        description: 'Could not analyze edge - ensure rim is visible in image.',
      );
    }

    final regularRatio = regularPatternPixels / totalRimPixels;
    final smoothRatio = smoothPixels / totalRimPixels;

    EdgeType edgeType;
    String description;
    double confidence;

    if (smoothRatio > 0.7) {
      edgeType = EdgeType.plain;
      confidence = smoothRatio * 100;
      description = 'Plain edge - smooth, unmarked edge common on ancient coins and some modern issues.';
    } else if (regularRatio > 0.4) {
      edgeType = EdgeType.reeded;
      confidence = regularRatio * 100;
      description = 'Reeded edge - vertical lines around the edge. Common anti-counterfeiting feature.';
    } else if (regularRatio > 0.2) {
      edgeType = EdgeType.decorated;
      confidence = (regularRatio + 0.3) * 100;
      description = 'Decorated/ornamented edge - complex pattern or design on edge.';
    } else {
      edgeType = EdgeType.unknown;
      confidence = 30;
      description = 'Edge type unclear - may need better image angle.';
    }

    return EdgeTypeAnalysis(
      edgeType: edgeType,
      confidence: confidence.clamp(10, 95),
      description: description,
      hints: _getEdgeTypeHints(edgeType),
    );
  }

  static void _analyzeRimPixel(img.Image image, int x, int y, Function(bool regular, bool smooth) callback) {
    if (x < 1 || x >= image.width - 1 || y < 1 || y >= image.height - 1) return;

    final current = image.getPixel(x, y);
    final right = image.getPixel(x + 1, y);
    final diff = ((current.r - right.r).abs() + (current.g - right.g).abs() + (current.b - right.b).abs()) ~/ 3;

    callback(diff > 25 && diff < 60, diff < 15);
  }

  static List<String> _getEdgeTypeHints(EdgeType type) {
    switch (type) {
      case EdgeType.plain:
        return [
          'Common on Greek, Roman, and early medieval coins',
          'Also found on small denomination modern coins',
          'Check for file marks (may indicate shaving/clipping)',
        ];
      case EdgeType.reeded:
        return [
          'Introduced to prevent coin clipping',
          'Common from 17th century onwards',
          'Silver and gold coins typically have more reeds',
        ];
      case EdgeType.lettered:
        return [
          'May contain mint motto or anti-counterfeiting text',
          'Common on British coins: "DECUS ET TUTAMEN"',
          'Check for edge inscription direction (incuse/raised)',
        ];
      case EdgeType.decorated:
        return [
          'May indicate special commemorative issue',
          'Check for stars, leaves, or other ornaments',
          'Some ancient coins have decorated edges',
        ];
      case EdgeType.unknown:
        return [
          'Take edge-on photo for better analysis',
          'Ensure good lighting on the edge',
        ];
    }
  }

  /// Analyze if image shows obverse (portrait) or reverse (design) side
  static CoinSideAnalysis analyzeCoinSide(img.Image image) {
    // Detect portrait-like features (face detection simplified)
    final portraitScore = _detectPortraitFeatures(image);

    // Detect common reverse elements (shields, eagles, buildings)
    final reverseScore = _detectReverseFeatures(image);

    // Detect text/legend presence
    final hasLegend = _detectLegendPresence(image);

    CoinSide side;
    double confidence;
    String description;

    if (portraitScore > reverseScore && portraitScore > 0.4) {
      side = CoinSide.obverse;
      confidence = portraitScore * 100;
      description = 'Likely OBVERSE (heads) side showing portrait or main device.';
    } else if (reverseScore > portraitScore && reverseScore > 0.3) {
      side = CoinSide.reverse;
      confidence = reverseScore * 100;
      description = 'Likely REVERSE (tails) side showing secondary design.';
    } else {
      side = CoinSide.unknown;
      confidence = 30;
      description = 'Could not determine coin side with certainty.';
    }

    return CoinSideAnalysis(
      side: side,
      confidence: confidence.clamp(10, 90),
      description: description,
      portraitScore: portraitScore,
      designScore: reverseScore,
      hasLegend: hasLegend,
      possibleElements: _identifyPossibleElements(portraitScore, reverseScore),
    );
  }

  static double _detectPortraitFeatures(img.Image image) {
    // Simplified portrait detection - look for:
    // 1. High contrast circular/oval shape in center
    // 2. Concentration of detail in upper half (head position)

    final centerX = image.width ~/ 2;
    final centerY = image.height ~/ 2;
    final radius = math.min(image.width, image.height) ~/ 3;

    double upperDetail = 0;
    double lowerDetail = 0;
    int upperSamples = 0;
    int lowerSamples = 0;

    for (int y = 1; y < image.height - 1; y += 2) {
      for (int x = 1; x < image.width - 1; x += 2) {
        // Check if within coin boundary
        final distFromCenter = math.sqrt(
          math.pow(x - centerX, 2) + math.pow(y - centerY, 2)
        );
        if (distFromCenter > radius * 1.2) continue;

        final current = image.getPixel(x, y);
        final right = image.getPixel(x + 1, y);
        final down = image.getPixel(x, y + 1);

        final detail = ((current.r - right.r).abs() + (current.g - right.g).abs() +
                       (current.r - down.r).abs() + (current.g - down.g).abs()) / 4;

        if (y < centerY) {
          upperDetail += detail;
          upperSamples++;
        } else {
          lowerDetail += detail;
          lowerSamples++;
        }
      }
    }

    if (upperSamples == 0 || lowerSamples == 0) return 0.3;

    final upperAvg = upperDetail / upperSamples;
    final lowerAvg = lowerDetail / lowerSamples;

    // Portrait typically has more detail in upper area (head/bust)
    final ratio = upperAvg / (lowerAvg + 0.1);

    if (ratio > 1.2) return 0.7;
    if (ratio > 1.0) return 0.5;
    return 0.3;
  }

  static double _detectReverseFeatures(img.Image image) {
    // Reverse typically has:
    // 1. More symmetric designs
    // 2. Detail spread more evenly
    // 3. Often has denomination text

    final centerX = image.width ~/ 2;

    double leftDetail = 0;
    double rightDetail = 0;
    int leftSamples = 0;
    int rightSamples = 0;

    for (int y = 1; y < image.height - 1; y += 2) {
      for (int x = 1; x < image.width - 1; x += 2) {
        final current = image.getPixel(x, y);
        final right = image.getPixel(x + 1, y);

        final detail = ((current.r - right.r).abs() + (current.g - right.g).abs()) / 2;

        if (x < centerX) {
          leftDetail += detail;
          leftSamples++;
        } else {
          rightDetail += detail;
          rightSamples++;
        }
      }
    }

    if (leftSamples == 0 || rightSamples == 0) return 0.3;

    final leftAvg = leftDetail / leftSamples;
    final rightAvg = rightDetail / rightSamples;

    // Reverse designs tend to be more symmetric
    final symmetryRatio = 1.0 - ((leftAvg - rightAvg).abs() / (leftAvg + rightAvg + 0.1));

    if (symmetryRatio > 0.85) return 0.7;
    if (symmetryRatio > 0.7) return 0.5;
    return 0.3;
  }

  static bool _detectLegendPresence(img.Image image) {
    // Check for text-like patterns around the rim
    final width = image.width;
    final height = image.height;
    final rimWidth = math.min(width, height) ~/ 6;

    int textLikePatterns = 0;
    int totalChecked = 0;

    // Check outer rim for repeated vertical patterns (letters)
    for (double angle = 0; angle < 2 * math.pi; angle += 0.15) {
      final x = (width / 2 + (width / 2 - rimWidth) * math.cos(angle)).round().clamp(2, width - 3);
      final y = (height / 2 + (height / 2 - rimWidth) * math.sin(angle)).round().clamp(2, height - 3);

      final current = image.getPixel(x, y);
      final prev = image.getPixel(x - 1, y);
      final next = image.getPixel(x + 1, y);

      final diff1 = ((current.r - prev.r).abs() + (current.g - prev.g).abs()) ~/ 2;
      final diff2 = ((current.r - next.r).abs() + (current.g - next.g).abs()) ~/ 2;

      totalChecked++;
      if (diff1 > 20 && diff2 > 20) {
        textLikePatterns++;
      }
    }

    return totalChecked > 0 && (textLikePatterns / totalChecked) > 0.3;
  }

  static List<String> _identifyPossibleElements(double portraitScore, double designScore) {
    final elements = <String>[];

    if (portraitScore > 0.5) {
      elements.addAll([
        'Portrait (emperor/ruler/deity)',
        'Bust (head and shoulders)',
        'Laureate/diademed head',
      ]);
    }

    if (designScore > 0.5) {
      elements.addAll([
        'Heraldic device (eagle/lion/shield)',
        'Architectural element (temple/building)',
        'Symbolic figure (Victory/Liberty)',
        'Denomination/value',
      ]);
    }

    elements.add('Legend/inscription around rim');

    return elements;
  }
}
