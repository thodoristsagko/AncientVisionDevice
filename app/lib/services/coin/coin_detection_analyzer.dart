// ═══════════════════════════════════════════════════════════════════════════
// COIN DETECTION ANALYZER - Smart coin detection and image analysis
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'coin_models.dart';
import 'coin_period_database.dart';

/// Service for detecting and analyzing coins in images
class CoinDetectionAnalyzer {
  static final Map<String, CoinAnalysisResult> _analysisCache = {};
  // ═══════════════════════════════════════════════════════════════════════════
  // SMART COIN DETECTION - Works even without "coin" ML Kit label
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<SmartCoinDetection> detectCoinInImage(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        return SmartCoinDetection(isCoin: false, confidence: 0, reason: 'Could not decode image');
      }

      final resized = img.copyResize(image, width: 300);

      // Run multiple detection algorithms
      final circularityScore = _detectCircularity(resized);
      final metallicScore = _detectMetallicColor(resized);
      final edgeScore = _detectCoinEdges(resized);
      final aspectRatioScore = _checkAspectRatio(resized);

      // Weighted combination
      final totalScore = (
        circularityScore * 0.35 +
        metallicScore * 0.30 +
        edgeScore * 0.20 +
        aspectRatioScore * 0.15
      );

      final isCoin = totalScore > 0.45;
      final confidence = (totalScore * 100).clamp(0.0, 100.0);

      String reason;
      if (isCoin) {
        final reasons = <String>[];
        if (circularityScore > 0.5) reasons.add('circular shape');
        if (metallicScore > 0.5) reasons.add('metallic color');
        if (edgeScore > 0.5) reasons.add('defined edges');
        if (aspectRatioScore > 0.8) reasons.add('coin-like proportions');
        reason = 'Detected: ${reasons.join(", ")}';
      } else {
        reason = 'Does not appear to be a coin';
      }

      return SmartCoinDetection(
        isCoin: isCoin,
        confidence: confidence,
        reason: reason,
        circularityScore: circularityScore,
        metallicScore: metallicScore,
        edgeScore: edgeScore,
        aspectRatioScore: aspectRatioScore,
      );
    } catch (e) {
      return SmartCoinDetection(isCoin: false, confidence: 0, reason: 'Error: $e');
    }
  }

  static double _detectCircularity(img.Image image) {
    // Simple edge-based circularity detection
    final width = image.width;
    final height = image.height;
    final centerX = width / 2;
    final centerY = height / 2;
    final radius = math.min(width, height) / 2 * 0.8;

    int edgePixelsOnCircle = 0;
    int sampledPoints = 0;

    // Sample points along a circle
    for (double angle = 0; angle < 2 * math.pi; angle += 0.1) {
      final x = (centerX + radius * math.cos(angle)).round().clamp(1, width - 2);
      final y = (centerY + radius * math.sin(angle)).round().clamp(1, height - 2);

      // Check if there's an edge near this point
      final current = image.getPixel(x, y);
      final neighbors = [
        image.getPixel(x - 1, y),
        image.getPixel(x + 1, y),
        image.getPixel(x, y - 1),
        image.getPixel(x, y + 1),
      ];

      for (final neighbor in neighbors) {
        final diff = ((current.r - neighbor.r).abs() +
                      (current.g - neighbor.g).abs() +
                      (current.b - neighbor.b).abs()) ~/ 3;
        if (diff > 30) {
          edgePixelsOnCircle++;
          break;
        }
      }
      sampledPoints++;
    }

    if (sampledPoints == 0) return 0;
    final circleEdgeRatio = edgePixelsOnCircle / sampledPoints;

    return circleEdgeRatio.clamp(0, 1);
  }

  static double _detectMetallicColor(img.Image image) {
    int metallicPixels = 0;
    int totalPixels = 0;

    for (int y = 0; y < image.height; y += 2) {
      for (int x = 0; x < image.width; x += 2) {
        final pixel = image.getPixel(x, y);
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        final b = pixel.b.toInt();
        totalPixels++;

        // Check for metallic colors
        final saturation = _calculateSaturation(r, g, b);
        final brightness = (r + g + b) / 3;

        // Gold/Bronze: warm colors
        if (r > 150 && g > 100 && b < 120 && r > g && g > b) {
          metallicPixels++;
        }
        // Silver: low saturation, bright
        else if (brightness > 130 && saturation < 0.15 && r > 120 && g > 120 && b > 120) {
          metallicPixels++;
        }
        // Green patina (aged bronze)
        else if (g > r && g > b && g > 80 && g < 180 && saturation > 0.1) {
          metallicPixels++;
        }
        // Brown/copper
        else if (r > g && g > b && r > 80 && r < 200 && g > 50 && b < 100) {
          metallicPixels++;
        }
        // Dark metal (iron, heavily oxidized)
        else if (brightness < 80 && saturation < 0.2) {
          metallicPixels++;
        }
      }
    }

    return totalPixels > 0 ? (metallicPixels / totalPixels).clamp(0, 1) : 0;
  }

  static double _detectCoinEdges(img.Image image) {
    // Look for a defined circular edge pattern
    final width = image.width;
    final height = image.height;
    int strongEdges = 0;
    int checkedPixels = 0;

    for (int y = 1; y < height - 1; y += 2) {
      for (int x = 1; x < width - 1; x += 2) {
        final current = image.getPixel(x, y);
        final right = image.getPixel(x + 1, y);
        final down = image.getPixel(x, y + 1);
        final diag = image.getPixel(x + 1, y + 1);

        final diffX = ((current.r - right.r).abs() +
                       (current.g - right.g).abs() +
                       (current.b - right.b).abs()) ~/ 3;
        final diffY = ((current.r - down.r).abs() +
                       (current.g - down.g).abs() +
                       (current.b - down.b).abs()) ~/ 3;
        final diffD = ((current.r - diag.r).abs() +
                       (current.g - diag.g).abs() +
                       (current.b - diag.b).abs()) ~/ 3;

        // Strong edge
        if (diffX > 40 || diffY > 40 || diffD > 40) {
          strongEdges++;
        }
        checkedPixels++;
      }
    }

    // Coins typically have ~5-15% edge pixels (rim + details)
    final edgeRatio = checkedPixels > 0 ? strongEdges / checkedPixels : 0;

    // Score peaks around 8% edge density
    if (edgeRatio >= 0.03 && edgeRatio <= 0.20) {
      return 1.0 - ((edgeRatio - 0.08).abs() * 5).clamp(0, 0.5);
    }
    return 0.2;
  }

  static double _checkAspectRatio(img.Image image) {
    final ratio = image.width / image.height;
    // Coins are roughly circular, aspect ratio ~1.0
    if (ratio >= 0.85 && ratio <= 1.15) return 1.0;
    if (ratio >= 0.7 && ratio <= 1.3) return 0.7;
    if (ratio >= 0.5 && ratio <= 1.5) return 0.4;
    return 0.1;
  }

  static double _calculateSaturation(int r, int g, int b) {
    final max = [r, g, b].reduce(math.max);
    final min = [r, g, b].reduce(math.min);
    return max > 0 ? (max - min) / max : 0;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // IMAGE ANALYSIS FOR MATERIAL ESTIMATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Full image analysis
  static Future<Map<String, dynamic>> analyzeImage(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return {};

      final resized = img.copyResize(image, width: 200);
      final colorAnalysis = _analyzeColorsAdvanced(resized);
      final textureAnalysis = _analyzeTexture(resized);

      String? estimatedMaterial = _estimateMaterial(colorAnalysis, textureAnalysis);

      return {
        'estimatedMaterial': estimatedMaterial,
        'colorAnalysis': colorAnalysis,
        'textureAnalysis': textureAnalysis,
        'isCircular': true,
      };
    } catch (e) {
      debugPrint('Image analysis error: $e');
      return {};
    }
  }

  static Map<String, dynamic> _analyzeColorsAdvanced(img.Image image) {
    int totalR = 0, totalG = 0, totalB = 0;
    int goldPixels = 0, silverPixels = 0, greenPixels = 0, brownPixels = 0, darkPixels = 0;
    int pixelCount = 0;

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        final b = pixel.b.toInt();

        totalR += r;
        totalG += g;
        totalB += b;
        pixelCount++;

        final brightness = (r + g + b) / 3;
        final saturation = _calculateSaturation(r, g, b);

        if (brightness < 60) {
          darkPixels++;
        } else if (r > 150 && g > 100 && g < 200 && b < 100 && r > g && g > b) {
          goldPixels++;
        } else if (r > 140 && g > 140 && b > 140 && saturation < 0.15) {
          silverPixels++;
        } else if (g > r && g > b && g > 80 && g < 180) {
          greenPixels++;
        } else if (r > g && g > b && r > 80 && r < 180 && g > 50 && g < 150 && b < 100) {
          brownPixels++;
        }
      }
    }

    final avgR = pixelCount > 0 ? totalR ~/ pixelCount : 0;
    final avgG = pixelCount > 0 ? totalG ~/ pixelCount : 0;
    final avgB = pixelCount > 0 ? totalB ~/ pixelCount : 0;
    final total = pixelCount.toDouble();

    return {
      'avgR': avgR, 'avgG': avgG, 'avgB': avgB,
      'isGolden': goldPixels / total > 0.15,
      'isSilvery': silverPixels / total > 0.20,
      'isGreen': greenPixels / total > 0.10,
      'isBrown': brownPixels / total > 0.15,
      'isDark': darkPixels / total > 0.30,
      'goldRatio': goldPixels / total,
      'silverRatio': silverPixels / total,
      'greenRatio': greenPixels / total,
      'brownRatio': brownPixels / total,
      'darkRatio': darkPixels / total,
    };
  }

  static Map<String, dynamic> _analyzeTexture(img.Image image) {
    int edgeCount = 0;
    int totalVariance = 0;

    for (int y = 1; y < image.height - 1; y++) {
      for (int x = 1; x < image.width - 1; x++) {
        final current = image.getPixel(x, y);
        final right = image.getPixel(x + 1, y);
        final down = image.getPixel(x, y + 1);

        final diffX = ((current.r - right.r).abs() + (current.g - right.g).abs() + (current.b - right.b).abs()) ~/ 3;
        final diffY = ((current.r - down.r).abs() + (current.g - down.g).abs() + (current.b - down.b).abs()) ~/ 3;

        if (diffX > 20 || diffY > 20) edgeCount++;
        totalVariance += diffX + diffY;
      }
    }

    final totalPixels = (image.width - 2) * (image.height - 2);
    final edgeDensity = edgeCount / totalPixels;
    final avgVariance = totalVariance / totalPixels;

    return {
      'edgeDensity': edgeDensity,
      'avgVariance': avgVariance,
      'isSmooth': edgeDensity < 0.1,
      'isTextured': edgeDensity > 0.2,
      'hasHighDetail': avgVariance > 15,
    };
  }

  static String? _estimateMaterial(Map<String, dynamic> colorData, Map<String, dynamic> textureData) {
    final isGolden = colorData['isGolden'] == true;
    final isSilvery = colorData['isSilvery'] == true;
    final isGreen = colorData['isGreen'] == true;
    final isBrown = colorData['isBrown'] == true;
    final isDark = colorData['isDark'] == true;
    final isSmooth = textureData['isSmooth'] == true;

    if (isGolden && isSmooth) return 'Gold';
    if (isGolden) return 'Gold or Bronze';
    if (isSilvery && isSmooth) return 'Silver';
    if (isSilvery) return 'Silver or Billon';
    if (isGreen) return 'Bronze with patina';
    if (isBrown) return 'Bronze or Copper';
    if (isDark) return 'Iron or heavily oxidized bronze';
    return 'Unknown metal';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PERIOD ANALYSIS WITH MULTI-SIGNAL BOOSTING
  // ═══════════════════════════════════════════════════════════════════════════
  static CoinAnalysisResult analyzeByCharacteristics({
    required String material,
    String? shape,
    String? scriptType,
    String? imageType,
    List<String>? keywords,
    Map<String, dynamic>? colorData,
  }) {
    final cacheKey = '$material|$shape|$scriptType|${keywords?.join(",")}';
    if (_analysisCache.containsKey(cacheKey)) {
      return _analysisCache[cacheKey]!;
    }

    final matches = <String, double>{};
    final materialLower = material.toLowerCase();

    for (final entry in CoinPeriodDatabase.periodDatabase.entries) {
      double score = 0;
      final info = entry.value;

      score += _scoreMaterial(materialLower, info) * 0.35;
      if (keywords != null && keywords.isNotEmpty) {
        score += _scoreKeywords(keywords, info) * 0.30;
      }
      if (scriptType != null) {
        score += _scoreScript(scriptType, entry.key, info) * 0.20;
      }
      if (colorData != null) {
        score += _scoreColorHints(colorData, info) * 0.15;
      }

      score *= info.weight;
      if (score > 0.05) {
        matches[entry.key] = score;
      }
    }

    final sortedMatches = matches.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (sortedMatches.isEmpty) {
      final result = CoinAnalysisResult(
        isIdentified: false,
        confidence: 0,
        message: 'Could not identify coin period. Try providing more details.',
      );
      _analysisCache[cacheKey] = result;
      return result;
    }

    final bestMatch = sortedMatches.first;
    final periodInfo = CoinPeriodDatabase.periodDatabase[bestMatch.key]!;
    final maxPossibleScore = 1.0 * periodInfo.weight;
    final confidence = ((bestMatch.value / maxPossibleScore) * 100).clamp(15, 95).toDouble();

    final result = CoinAnalysisResult(
      isIdentified: true,
      confidence: confidence,
      period: periodInfo.period,
      dateRange: periodInfo.dateRange,
      characteristics: periodInfo.characteristics,
      regions: periodInfo.regions,
      materials: periodInfo.materials,
      denominations: periodInfo.denominations,
      rulers: periodInfo.rulers,
      alternativePeriods: sortedMatches
          .skip(1)
          .take(4)
          .map((e) => '${CoinPeriodDatabase.periodDatabase[e.key]!.period} (${(e.value / maxPossibleScore * 100).clamp(10, 90).toStringAsFixed(0)}%)')
          .toList(),
    );

    _analysisCache[cacheKey] = result;
    return result;
  }

  static double _scoreMaterial(String material, CoinPeriodInfo info) {
    double score = 0;
    for (final periodMaterial in info.materials) {
      if (periodMaterial.toLowerCase() == material ||
          (material.contains('gold') && periodMaterial.toLowerCase().contains('gold')) ||
          (material.contains('silver') && periodMaterial.toLowerCase().contains('silver')) ||
          (material.contains('bronze') && (periodMaterial.toLowerCase().contains('bronze') || periodMaterial.toLowerCase().contains('copper'))) ||
          (material.contains('copper') && (periodMaterial.toLowerCase().contains('copper') || periodMaterial.toLowerCase().contains('bronze')))) {
        score = 1.0;
        break;
      }
    }
    for (final char in info.characteristics) {
      if (char.toLowerCase().contains(material)) {
        score = math.max(score, 0.8);
      }
    }
    return score;
  }

  static double _scoreKeywords(List<String> keywords, CoinPeriodInfo info) {
    double totalScore = 0;
    int matchCount = 0;

    for (final keyword in keywords) {
      final keywordLower = keyword.toLowerCase();
      for (final char in info.characteristics) {
        if (char.toLowerCase().contains(keywordLower) || keywordLower.contains(char.toLowerCase())) {
          totalScore += 0.3;
          matchCount++;
        }
      }
      for (final region in info.regions) {
        if (region.toLowerCase().contains(keywordLower) || keywordLower.contains(region.toLowerCase())) {
          totalScore += 0.25;
          matchCount++;
        }
      }
      for (final ruler in info.rulers) {
        if (ruler.toLowerCase().contains(keywordLower)) {
          totalScore += 0.4;
          matchCount++;
        }
      }
      for (final denom in info.denominations) {
        if (denom.toLowerCase().contains(keywordLower)) {
          totalScore += 0.35;
          matchCount++;
        }
      }
      if (info.period.toLowerCase().contains(keywordLower)) {
        totalScore += 0.5;
        matchCount++;
      }
    }

    return matchCount > 0 ? (totalScore / keywords.length).clamp(0, 1) : 0;
  }

  static double _scoreScript(String scriptType, String periodKey, CoinPeriodInfo info) {
    final scriptLower = scriptType.toLowerCase();

    if (scriptLower.contains('arabic') || scriptLower.contains('kufic')) {
      if (periodKey.contains('umayyad') || periodKey.contains('abbasid') ||
          periodKey.contains('fatimid') || periodKey.contains('ayyubid') ||
          periodKey.contains('mamluk') || periodKey.contains('ottoman')) {
        return 1.0;
      }
    }
    if (scriptLower.contains('greek')) {
      if (periodKey.contains('greek') || periodKey.contains('hellenistic') ||
          periodKey.contains('indo_greek') || periodKey.contains('parthian') ||
          periodKey.contains('byzantine') || periodKey.contains('kushan')) {
        return 1.0;
      }
    }
    if (scriptLower.contains('latin') || scriptLower.contains('roman')) {
      if (periodKey.contains('roman') || periodKey.contains('medieval') ||
          periodKey.contains('crusader') || periodKey.contains('carolingian') ||
          periodKey.contains('anglo_saxon') || periodKey.contains('gothic')) {
        return 1.0;
      }
    }
    if (scriptLower.contains('hebrew') || scriptLower.contains('paleo')) {
      if (periodKey.contains('hasmonean') || periodKey.contains('herodian') ||
          periodKey.contains('jewish')) {
        return 1.0;
      }
    }
    if (scriptLower.contains('persian') || scriptLower.contains('pahlavi')) {
      if (periodKey.contains('sasanian') || periodKey.contains('parthian') ||
          periodKey.contains('mughal') || periodKey.contains('achaemenid')) {
        return 1.0;
      }
    }
    if (scriptLower.contains('chinese') || scriptLower.contains('hanzi')) {
      if (periodKey.contains('chinese')) return 1.0;
    }
    if (scriptLower.contains('sanskrit') || scriptLower.contains('brahmi') || scriptLower.contains('kharosthi')) {
      if (periodKey.contains('mauryan') || periodKey.contains('gupta') ||
          periodKey.contains('kushan') || periodKey.contains('indo_greek')) {
        return 1.0;
      }
    }
    return 0;
  }

  static double _scoreColorHints(Map<String, dynamic> colorData, CoinPeriodInfo info) {
    double score = 0;
    final isGolden = colorData['isGolden'] == true;
    final isSilvery = colorData['isSilvery'] == true;
    final isGreen = colorData['isGreen'] == true;
    final isBrown = colorData['isBrown'] == true;
    final isDark = colorData['isDark'] == true;

    if (isGolden && info.materials.any((m) => m.toLowerCase().contains('gold') || m.toLowerCase().contains('electrum'))) {
      score += 0.8;
    }
    if (isSilvery && info.materials.any((m) => m.toLowerCase().contains('silver'))) {
      score += 0.8;
    }
    if ((isGreen || isBrown) && info.materials.any((m) => m.toLowerCase().contains('bronze') || m.toLowerCase().contains('copper'))) {
      score += 0.6;
    }
    if (isDark && info.materials.any((m) => m.toLowerCase().contains('iron'))) {
      score += 0.5;
    }

    return score.clamp(0, 1);
  }
}
