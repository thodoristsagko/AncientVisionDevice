// ═══════════════════════════════════════════════════════════════════════════
// COIN PATINA ANALYZER - Advanced patina type and quality analysis
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'coin_models.dart';

/// Service for analyzing patina type and quality on coins
class CoinPatinaAnalyzer {
  /// Analyze patina type and quality on the coin
  static Future<PatinaAnalysis> analyzePatinaAdvanced(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        return PatinaAnalysis(patinaType: PatinaType.none, coverage: 0);
      }

      final resized = img.copyResize(image, width: 300);

      int greenVerdigrisPixels = 0;
      int redCupritePixels = 0;
      int blackOxidePixels = 0;
      int brownPatinaPixels = 0;
      int desertPatinaPixels = 0;
      int cleanMetalPixels = 0;
      int totalPixels = 0;

      for (int y = 0; y < resized.height; y++) {
        for (int x = 0; x < resized.width; x++) {
          final pixel = resized.getPixel(x, y);
          final r = pixel.r.toInt();
          final g = pixel.g.toInt();
          final b = pixel.b.toInt();
          totalPixels++;

          final saturation = _calculateSaturation(r, g, b);
          final brightness = (r + g + b) / 3;

          // Green verdigris (aged bronze/copper) - most common ancient patina
          if (g > r && g > b && g > 60 && g < 200 &&
              (g - r) > 15 && (g - b) > 15 && saturation > 0.15) {
            greenVerdigrisPixels++;
          }
          // Red cuprite patina (copper oxide) - reddish-brown
          else if (r > g && r > b && r > 100 && r < 200 &&
                   g > 40 && g < 120 && b < 80 && saturation > 0.3) {
            redCupritePixels++;
          }
          // Black oxide patina - very dark
          else if (brightness < 50 && saturation < 0.2) {
            blackOxidePixels++;
          }
          // Brown patina (earth tones) - common on excavated coins
          else if (r > g && g > b && r > 80 && r < 180 &&
                   g > 50 && g < 140 && b < 100 && saturation > 0.1) {
            brownPatinaPixels++;
          }
          // Desert patina (sandy/tan) - found on middle eastern coins
          else if (r > 150 && g > 130 && g < 200 && b > 80 && b < 150 &&
                   r > g && g > b && saturation < 0.3) {
            desertPatinaPixels++;
          }
          // Clean/bright metal
          else if (brightness > 140 && saturation < 0.15) {
            cleanMetalPixels++;
          }
        }
      }

      // Determine dominant patina type
      final total = totalPixels.toDouble();
      final patinaScores = {
        PatinaType.greenVerdigris: greenVerdigrisPixels / total,
        PatinaType.redCuprite: redCupritePixels / total,
        PatinaType.blackOxide: blackOxidePixels / total,
        PatinaType.brownEarth: brownPatinaPixels / total,
        PatinaType.desertPatina: desertPatinaPixels / total,
        PatinaType.none: cleanMetalPixels / total,
      };

      final sortedPatina = patinaScores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      final dominantPatina = sortedPatina.first;
      final coverage = (1 - (cleanMetalPixels / total)) * 100;

      // Determine patina quality
      PatinaQuality quality;
      if (dominantPatina.value > 0.4) {
        quality = PatinaQuality.heavy;
      } else if (dominantPatina.value > 0.2) {
        quality = PatinaQuality.moderate;
      } else if (dominantPatina.value > 0.1) {
        quality = PatinaQuality.light;
      } else {
        quality = PatinaQuality.minimal;
      }

      // Check for artificial cleaning signs
      final cleaningDetected = cleanMetalPixels / total > 0.6 &&
                                (greenVerdigrisPixels + brownPatinaPixels) / total < 0.1;

      return PatinaAnalysis(
        patinaType: dominantPatina.key,
        coverage: coverage.clamp(0, 100),
        quality: quality,
        isCleaningDetected: cleaningDetected,
        greenVerdigrisRatio: patinaScores[PatinaType.greenVerdigris] ?? 0,
        redCupriteRatio: patinaScores[PatinaType.redCuprite] ?? 0,
        blackOxideRatio: patinaScores[PatinaType.blackOxide] ?? 0,
        brownEarthRatio: patinaScores[PatinaType.brownEarth] ?? 0,
        desertPatinaRatio: patinaScores[PatinaType.desertPatina] ?? 0,
        description: _describePatinaType(dominantPatina.key, quality, cleaningDetected),
      );
    } catch (e) {
      return PatinaAnalysis(patinaType: PatinaType.none, coverage: 0);
    }
  }

  static String _describePatinaType(PatinaType type, PatinaQuality quality, bool cleaned) {
    if (cleaned) {
      return 'Coin appears to have been cleaned - natural patina largely removed. '
             'Collectors typically prefer original surfaces.';
    }

    final qualityText = quality == PatinaQuality.heavy ? 'heavy' :
                        quality == PatinaQuality.moderate ? 'moderate' :
                        quality == PatinaQuality.light ? 'light' : 'minimal';

    switch (type) {
      case PatinaType.greenVerdigris:
        return 'Shows $qualityText green verdigris patina typical of aged bronze or copper coins. '
               'This desirable "cabinet patina" develops over centuries and is prized by collectors.';
      case PatinaType.redCuprite:
        return 'Displays $qualityText red cuprite patina (copper oxide). '
               'This reddish-brown coloration indicates natural aging of copper alloy.';
      case PatinaType.blackOxide:
        return 'Shows $qualityText black oxide patina. '
               'Dark patination often found on silver coins or heavily oxidized bronze.';
      case PatinaType.brownEarth:
        return 'Exhibits $qualityText brown earth patina common on excavated coins. '
               'This stable patina often indicates a ground find.';
      case PatinaType.desertPatina:
        return 'Displays $qualityText desert patina with sandy/tan coloration. '
               'Common on coins from arid Middle Eastern or North African regions.';
      case PatinaType.none:
        return 'Shows minimal patina with largely original metal surface visible.';
    }
  }

  static double _calculateSaturation(int r, int g, int b) {
    final max = [r, g, b].reduce(math.max);
    final min = [r, g, b].reduce(math.min);
    return max > 0 ? (max - min) / max : 0;
  }
}
