// ═══════════════════════════════════════════════════════════════════════════
// COIN GRADING SERVICE - Numismatic wear grade analysis
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'coin_models.dart';

/// Service for analyzing coin wear and assigning numismatic grades
class CoinGradingService {
  /// Estimate numismatic grade based on surface analysis
  static Future<WearGradeAnalysis> analyzeWearGrade(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        return WearGradeAnalysis(grade: CoinGrade.unknown, confidence: 0);
      }

      final resized = img.copyResize(image, width: 300);

      // Analyze detail preservation
      final detailScore = _analyzeDetailPreservation(resized);

      // Analyze high points (first areas to wear)
      final highPointScore = _analyzeHighPointWear(resized);

      // Analyze field (flat areas) condition
      final fieldScore = _analyzeFieldCondition(resized);

      // Analyze luster (original mint shine)
      final lusterScore = _analyzeLuster(resized);

      // Combined scoring
      final totalScore = (
        detailScore * 0.35 +
        highPointScore * 0.30 +
        fieldScore * 0.20 +
        lusterScore * 0.15
      );

      // Map score to grade
      CoinGrade grade;
      String description;
      int sheldonNumber;

      if (totalScore >= 0.95) {
        grade = CoinGrade.ms65Plus;
        sheldonNumber = 65;
        description = 'Mint State (MS-65+) - Gem uncirculated. Full original luster with minimal marks.';
      } else if (totalScore >= 0.90) {
        grade = CoinGrade.ms63;
        sheldonNumber = 63;
        description = 'Mint State (MS-63) - Choice uncirculated. No wear, attractive luster.';
      } else if (totalScore >= 0.85) {
        grade = CoinGrade.ms60;
        sheldonNumber = 60;
        description = 'Mint State (MS-60) - Uncirculated. No wear but may have bag marks.';
      } else if (totalScore >= 0.78) {
        grade = CoinGrade.au58;
        sheldonNumber = 58;
        description = 'About Uncirculated (AU-58) - Slight wear on highest points only.';
      } else if (totalScore >= 0.70) {
        grade = CoinGrade.au50;
        sheldonNumber = 50;
        description = 'About Uncirculated (AU-50) - Traces of wear on high points.';
      } else if (totalScore >= 0.60) {
        grade = CoinGrade.ef45;
        sheldonNumber = 45;
        description = 'Extremely Fine (EF-45) - Light wear on high points. All features sharp.';
      } else if (totalScore >= 0.50) {
        grade = CoinGrade.ef40;
        sheldonNumber = 40;
        description = 'Extremely Fine (EF-40) - Light wear throughout, all features clear.';
      } else if (totalScore >= 0.40) {
        grade = CoinGrade.vf35;
        sheldonNumber = 35;
        description = 'Very Fine (VF-35) - Moderate wear with major features bold.';
      } else if (totalScore >= 0.32) {
        grade = CoinGrade.vf25;
        sheldonNumber = 25;
        description = 'Very Fine (VF-25) - Moderate to heavy wear. Major features clear.';
      } else if (totalScore >= 0.24) {
        grade = CoinGrade.f15;
        sheldonNumber = 15;
        description = 'Fine (F-15) - Moderate to heavy wear. All design elements visible.';
      } else if (totalScore >= 0.18) {
        grade = CoinGrade.vg10;
        sheldonNumber = 10;
        description = 'Very Good (VG-10) - Well worn. Main features clear but flat.';
      } else if (totalScore >= 0.12) {
        grade = CoinGrade.g6;
        sheldonNumber = 6;
        description = 'Good (G-6) - Heavily worn. Design visible but details flat.';
      } else if (totalScore >= 0.06) {
        grade = CoinGrade.ag3;
        sheldonNumber = 3;
        description = 'About Good (AG-3) - Very heavily worn. Outline visible.';
      } else {
        grade = CoinGrade.poor1;
        sheldonNumber = 1;
        description = 'Poor (P-1) - Barely identifiable. Date and/or mint may be gone.';
      }

      return WearGradeAnalysis(
        grade: grade,
        confidence: (totalScore * 100).clamp(10, 95),
        sheldonNumber: sheldonNumber,
        description: description,
        detailScore: detailScore,
        highPointScore: highPointScore,
        fieldScore: fieldScore,
        lusterScore: lusterScore,
        wearLocations: _identifyWearLocations(resized, highPointScore),
      );
    } catch (e) {
      return WearGradeAnalysis(grade: CoinGrade.unknown, confidence: 0);
    }
  }

  static double _analyzeDetailPreservation(img.Image image) {
    // Measure edge sharpness and detail retention
    int sharpEdges = 0;
    int mediumEdges = 0;
    int totalChecked = 0;

    for (int y = 2; y < image.height - 2; y += 2) {
      for (int x = 2; x < image.width - 2; x += 2) {
        final center = image.getPixel(x, y);
        final neighbors = [
          image.getPixel(x - 1, y), image.getPixel(x + 1, y),
          image.getPixel(x, y - 1), image.getPixel(x, y + 1),
          image.getPixel(x - 1, y - 1), image.getPixel(x + 1, y + 1),
        ];

        int maxDiff = 0;
        for (final n in neighbors) {
          final diff = ((center.r - n.r).abs() + (center.g - n.g).abs() + (center.b - n.b).abs()) ~/ 3;
          if (diff > maxDiff) maxDiff = diff;
        }

        totalChecked++;
        if (maxDiff > 50) {
          sharpEdges++;
        } else if (maxDiff > 25) {
          mediumEdges++;
        }
      }
    }

    if (totalChecked == 0) return 0.5;

    // High detail preservation = more sharp edges
    final sharpRatio = sharpEdges / totalChecked;
    final mediumRatio = mediumEdges / totalChecked;

    return (sharpRatio * 1.5 + mediumRatio * 0.7).clamp(0, 1);
  }

  static double _analyzeHighPointWear(img.Image image) {
    // Sample the center area (often where high relief details are)
    final centerX = image.width ~/ 2;
    final centerY = image.height ~/ 2;
    final sampleRadius = math.min(image.width, image.height) ~/ 4;

    double totalVariance = 0;
    int samples = 0;

    for (int dy = -sampleRadius; dy <= sampleRadius; dy += 3) {
      for (int dx = -sampleRadius; dx <= sampleRadius; dx += 3) {
        final x = (centerX + dx).clamp(1, image.width - 2);
        final y = (centerY + dy).clamp(1, image.height - 2);

        final current = image.getPixel(x, y);
        final right = image.getPixel(x + 1, y);
        final down = image.getPixel(x, y + 1);

        final variance = ((current.r - right.r).abs() + (current.g - right.g).abs() +
                         (current.r - down.r).abs() + (current.g - down.g).abs()) / 4;
        totalVariance += variance;
        samples++;
      }
    }

    if (samples == 0) return 0.5;
    final avgVariance = totalVariance / samples;

    // Higher variance = better preservation
    return (avgVariance / 50).clamp(0, 1);
  }

  static double _analyzeFieldCondition(img.Image image) {
    // Analyze the "field" (flat background areas) for smoothness
    // Very worn coins have scratched/rough fields
    int smoothPixels = 0;
    int roughPixels = 0;
    int totalPixels = 0;

    for (int y = 1; y < image.height - 1; y += 3) {
      for (int x = 1; x < image.width - 1; x += 3) {
        final current = image.getPixel(x, y);
        final right = image.getPixel(x + 1, y);
        final down = image.getPixel(x, y + 1);

        final diffX = ((current.r - right.r).abs() + (current.g - right.g).abs()) ~/ 2;
        final diffY = ((current.r - down.r).abs() + (current.g - down.g).abs()) ~/ 2;

        totalPixels++;
        if (diffX < 10 && diffY < 10) {
          smoothPixels++;
        } else if (diffX > 30 || diffY > 30) {
          roughPixels++;
        }
      }
    }

    if (totalPixels == 0) return 0.5;

    // Good condition = smooth fields with some detail
    final smoothRatio = smoothPixels / totalPixels;
    final roughRatio = roughPixels / totalPixels;

    // Fields should be smooth but not completely flat (that would indicate wear)
    if (smoothRatio > 0.8) return 0.4; // Too smooth = worn flat
    if (roughRatio > 0.4) return 0.3; // Too rough = damaged

    return (0.7 + (smoothRatio - roughRatio) * 0.3).clamp(0, 1);
  }

  static double _analyzeLuster(img.Image image) {
    // Luster detection - original mint shine
    int highReflectancePixels = 0;
    int totalPixels = 0;
    double brightnessVariance = 0;

    final brightnessValues = <int>[];

    for (int y = 0; y < image.height; y += 2) {
      for (int x = 0; x < image.width; x += 2) {
        final pixel = image.getPixel(x, y);
        final brightness = (pixel.r.toInt() + pixel.g.toInt() + pixel.b.toInt()) ~/ 3;
        brightnessValues.add(brightness);
        totalPixels++;

        // High reflectance indicates luster
        if (brightness > 180) {
          highReflectancePixels++;
        }
      }
    }

    if (totalPixels == 0 || brightnessValues.isEmpty) return 0.5;

    // Calculate brightness variance (luster shows variation due to die flow lines)
    final avgBrightness = brightnessValues.reduce((a, b) => a + b) / brightnessValues.length;
    for (final b in brightnessValues) {
      brightnessVariance += (b - avgBrightness) * (b - avgBrightness);
    }
    brightnessVariance = math.sqrt(brightnessVariance / brightnessValues.length);

    // Some variance + high points = luster
    final lusterScore = (highReflectancePixels / totalPixels) * 0.6 +
                        (brightnessVariance / 60).clamp(0, 0.4);

    return lusterScore.clamp(0, 1);
  }

  static List<String> _identifyWearLocations(img.Image image, double highPointScore) {
    final locations = <String>[];

    if (highPointScore < 0.5) {
      locations.add('Central high relief (portrait/main device)');
    }
    if (highPointScore < 0.4) {
      locations.add('Lettering/legends');
    }
    if (highPointScore < 0.3) {
      locations.add('Hair/fabric details');
      locations.add('Date numerals');
    }
    if (highPointScore < 0.2) {
      locations.add('Rim');
      locations.add('Background fields');
    }

    return locations;
  }
}
