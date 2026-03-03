// ═══════════════════════════════════════════════════════════════════════════
// COIN NUMISTA CLIENT - Numista API integration for real coin identification
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../config/env_config.dart';
import 'coin_models.dart';

/// Client for Numista API - real numismatic database
class CoinNumistaClient {
  static final CoinNumistaClient _instance = CoinNumistaClient._internal();
  factory CoinNumistaClient() => _instance;
  CoinNumistaClient._internal();

  static const String _baseUrl = 'https://api.numista.com/v3';
  static const String _defaultApiKey = EnvConfig.numistaApiKey;
  static const String _ocreBaseUrl = 'http://numismatics.org/ocre';

  String? _apiKey = _defaultApiKey;
  final Map<String, dynamic> _cache = {};

  void setApiKey(String key) => _apiKey = key;
  void clearApiKey() => _apiKey = null;
  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  Future<List<NumistaCoin>> searchCoins({required String query, String? category = 'coin', int? year, int count = 20}) async {
    if (!hasApiKey) throw Exception('Numista API key not set');
    try {
      final params = {'q': query, 'category': category ?? 'coin', 'count': count.toString(), 'lang': 'en'};
      if (year != null) params['year'] = year.toString();
      final uri = Uri.parse('$_baseUrl/types').replace(queryParameters: params);
      final response = await http.get(uri, headers: {'Numista-API-Key': _apiKey!}).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return (data['types'] as List<dynamic>? ?? []).map((t) => NumistaCoin.fromJson(t)).toList();
      }
      throw Exception('API error: ${response.statusCode}');
    } catch (e) {
      rethrow;
    }
  }

  Future<NumistaCoinDetails?> getCoinDetails(int coinId) async {
    if (!hasApiKey) return null;
    try {
      final uri = Uri.parse('$_baseUrl/types/$coinId');
      final response = await http.get(uri, headers: {'Numista-API-Key': _apiKey!}).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return NumistaCoinDetails.fromJson(json.decode(response.body));
    } catch (e) {
      debugPrint('Error: $e');
    }
    return null;
  }

  void clearCache() => _cache.clear();

  // ═══════════════════════════════════════════════════════════════════════════
  // NUMISTA API COIN IDENTIFICATION (REAL DATABASE LOOKUP)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check if internet is available
  Future<bool> _hasInternet() async {
    try {
      final result = await http.get(Uri.parse('https://api.numista.com/v3')).timeout(const Duration(seconds: 5));
      return result.statusCode < 500;
    } catch (e) {
      return false;
    }
  }

  /// Identify coin using Numista API - returns real numismatic data
  /// Uses smart search strategies based on detected features
  Future<NumistaIdentificationResult?> identifyWithNumista({
    required String material,
    required List<String> keywords,
    Map<String, dynamic>? colorData,
  }) async {
    if (!hasApiKey) {
      debugPrint('Numista: No API key set');
      return null;
    }

    try {
      // Strategy 1: Search by detected material
      final materialQuery = _getMaterialSearchTerm(material, colorData);
      debugPrint('Numista: Strategy 1 - Material search: "$materialQuery"');

      var coins = await searchCoins(query: materialQuery, count: 10);

      // Strategy 2: If no results, try broader search
      if (coins.isEmpty && colorData != null) {
        final colorQuery = _getColorBasedQuery(colorData);
        debugPrint('Numista: Strategy 2 - Color search: "$colorQuery"');
        coins = await searchCoins(query: colorQuery, count: 10);
      }

      // Strategy 3: Try with useful keywords
      if (coins.isEmpty) {
        final keywordQuery = _getKeywordQuery(keywords);
        if (keywordQuery.isNotEmpty) {
          debugPrint('Numista: Strategy 3 - Keyword search: "$keywordQuery"');
          coins = await searchCoins(query: keywordQuery, count: 10);
        }
      }

      if (coins.isEmpty) {
        debugPrint('Numista: No results from any strategy');
        return null;
      }

      debugPrint('Numista: Found ${coins.length} matches');

      // Get details for the best match
      final bestMatch = coins.first;
      final details = await getCoinDetails(bestMatch.id);

      return NumistaIdentificationResult(
        success: true,
        coin: bestMatch,
        details: details,
        allMatches: coins,
        searchQuery: materialQuery,
        confidence: _calculateNumistaConfidence(bestMatch, material, keywords),
      );
    } catch (e) {
      debugPrint('Numista API error: $e');
      return null;
    }
  }

  /// Get search term based on material and color data
  String _getMaterialSearchTerm(String material, Map<String, dynamic>? colorData) {
    final mat = material.toLowerCase();

    // Check for specific materials from text
    if (mat.contains('gold')) return 'gold coin';
    if (mat.contains('silver')) return 'silver coin';
    if (mat.contains('bronze')) return 'bronze coin';
    if (mat.contains('copper')) return 'copper coin';

    // Use color data if available
    if (colorData != null) {
      final hue = (colorData['hue'] as num?)?.toDouble() ?? 0;
      final saturation = (colorData['saturation'] as num?)?.toDouble() ?? 0;
      final brightness = (colorData['brightness'] as num?)?.toDouble() ?? 0;
      final dominantColor = (colorData['dominantColor'] as String? ?? '').toLowerCase();

      // Check dominant color name first
      if (dominantColor.contains('gold') || dominantColor.contains('yellow')) return 'gold coin';
      if (dominantColor.contains('silver') || dominantColor.contains('grey')) return 'silver coin';
      if (dominantColor.contains('bronze') || dominantColor.contains('brown')) return 'bronze coin';
      if (dominantColor.contains('green')) return 'ancient bronze patina';

      // Fall back to HSB analysis
      // Gold: Yellow hue (35-55), high saturation
      if ((hue >= 35 && hue <= 55) && saturation > 0.4) return 'gold coin';
      // Silver: Low saturation, high brightness
      if (saturation < 0.15 && brightness > 0.5) return 'silver coin';
      // Bronze/Copper: Orange-brown hue (15-40)
      if ((hue >= 15 && hue <= 40) && saturation > 0.2) return 'bronze coin';
      // Green patina (80-160 hue)
      if ((hue >= 80 && hue <= 160) && saturation > 0.2) return 'ancient bronze patina';
    }

    return 'coin';
  }

  /// Get query based on color analysis
  String _getColorBasedQuery(Map<String, dynamic> colorData) {
    final dominant = (colorData['dominantColor'] as String? ?? '').toLowerCase();

    if (dominant.contains('yellow') || dominant.contains('gold')) return 'gold';
    if (dominant.contains('silver') || dominant.contains('gray') || dominant.contains('grey')) return 'silver';
    if (dominant.contains('brown') || dominant.contains('orange')) return 'bronze copper';
    if (dominant.contains('green')) return 'ancient patina';

    return 'coin';
  }

  /// Extract useful keywords
  String _getKeywordQuery(List<String> keywords) {
    final usefulKeywords = <String>[];
    final skipWords = {'coin', 'metal', 'circle', 'round', 'object', 'currency', 'money',
                       'cash', 'token', 'medallion', 'disc', 'disk'};

    for (final k in keywords) {
      final lower = k.toLowerCase();
      if (!skipWords.contains(lower) && lower.length > 2) {
        usefulKeywords.add(lower);
      }
    }

    return usefulKeywords.take(3).join(' ');
  }

  /// Calculate confidence score for Numista result
  double _calculateNumistaConfidence(NumistaCoin coin, String material, List<String> keywords) {
    double confidence = 60.0; // Base confidence for finding a match

    // Boost for material match
    final title = coin.title.toLowerCase();
    if (material.isNotEmpty) {
      final matLower = material.toLowerCase();
      if (title.contains('gold') && matLower.contains('gold')) confidence += 15;
      if (title.contains('silver') && matLower.contains('silver')) confidence += 15;
      if (title.contains('bronze') && matLower.contains('bronze')) confidence += 10;
      if (title.contains('copper') && matLower.contains('copper')) confidence += 10;
    }

    // Boost for keyword matches in title
    for (final keyword in keywords) {
      if (title.contains(keyword.toLowerCase())) {
        confidence += 5;
      }
    }

    // Boost if has images (verified coin)
    if (coin.obverseThumb != null || coin.reverseThumb != null) {
      confidence += 5;
    }

    return confidence.clamp(40, 95);
  }

  /// Convert Numista result to standard CoinAnalysisResult format
  CoinAnalysisResult numistaToAnalysisResult(NumistaIdentificationResult numista) {
    final coin = numista.coin;
    final details = numista.details;

    // Extract period from issuer or title
    String period = coin.issuer ?? 'Unknown';
    String dateRange = '';

    if (coin.minYear != null || coin.maxYear != null) {
      final minYear = coin.minYear ?? coin.maxYear!;
      final maxYear = coin.maxYear ?? coin.minYear!;
      if (minYear == maxYear) {
        dateRange = '$minYear';
      } else {
        dateRange = '$minYear - $maxYear';
      }
    }

    // Build characteristics from details
    final characteristics = <String>[];
    if (details?.type != null) characteristics.add(details!.type!);
    if (details?.material != null) characteristics.add(details!.material!);
    if (details?.obverseDescription != null) characteristics.add('Obverse: ${details!.obverseDescription}');
    if (details?.reverseDescription != null) characteristics.add('Reverse: ${details!.reverseDescription}');

    // Build alternative periods from other matches
    final alternatives = numista.allMatches
        .skip(1)
        .take(4)
        .map((c) => '${c.title} (${c.issuer ?? "Unknown"})'.substring(0, math.min(50, '${c.title} (${c.issuer ?? "Unknown"})'.length)))
        .toList();

    return CoinAnalysisResult(
      isIdentified: true,
      confidence: numista.confidence,
      period: period,
      dateRange: dateRange,
      characteristics: characteristics,
      regions: [coin.issuer ?? 'Unknown region'],
      materials: details?.material != null ? [details!.material!] : [],
      denominations: [coin.title],
      rulers: details?.ruler != null ? [details!.ruler!] : [],
      alternativePeriods: alternatives,
      numistaId: coin.id,
      numistaUrl: 'https://en.numista.com/catalogue/pieces${coin.id}.html',
      obverseImage: coin.obverseThumb,
      reverseImage: coin.reverseThumb,
    );
  }

  /// Main identification method - tries Numista first, falls back to heuristics
  Future<CoinAnalysisResult> identifyCoinSmart({
    required String material,
    List<String>? keywords,
    Map<String, dynamic>? colorData,
    bool forceLocal = false,
  }) async {
    final kw = keywords ?? [];

    // Only use Numista API - no fake heuristic data
    if (hasApiKey) {
      final hasNet = await _hasInternet();
      if (hasNet) {
        debugPrint('Searching Numista database...');
        final numistaResult = await identifyWithNumista(
          material: material,
          keywords: kw,
          colorData: colorData,
        );

        if (numistaResult != null && numistaResult.success) {
          debugPrint('Numista: Found match!');
          return numistaToAnalysisResult(numistaResult);
        }
      }
    }

    // No fake data - just return unknown
    debugPrint('Could not identify coin');
    return CoinAnalysisResult(
      isIdentified: false,
      confidence: 0,
      period: null,
      dateRange: null,
      message: 'Could not identify. Try a clearer photo or different angle.',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // OCRE API FOR ROMAN COINS (FREE & UNLIMITED)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Search OCRE database for Roman Imperial coins
  Future<List<OcreCoin>> searchOcreCoins(String query) async {
    try {
      // OCRE uses a different URL structure for search
      final uri = Uri.parse('$_ocreBaseUrl/results?q=$query&format=json');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data.map((item) => OcreCoin.fromJson(item)).toList();
        }
      }
      return [];
    } catch (e) {
      debugPrint('OCRE API error: $e');
      return [];
    }
  }
}
