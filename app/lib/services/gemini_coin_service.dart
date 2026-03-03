import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_classification_service.dart';
import '../config/env_config.dart';

/// Gemini AI-powered coin identification service
/// Uses Google Gemini 2.5 Flash vision model for expert numismatic analysis
class GeminiCoinService {
  static final GeminiCoinService _instance = GeminiCoinService._internal();
  factory GeminiCoinService() => _instance;
  GeminiCoinService._internal();

  static const String _apiKeyPref = 'gemini_api_key';
  static const String _defaultApiKey = EnvConfig.geminiApiKey;

  GenerativeModel? _model;
  String? _apiKey;

  // Cache results by image path
  final Map<String, CoinClassificationResult> _cache = {};

  /// Whether a Gemini API key is configured (built-in or user-provided)
  bool get hasApiKey => _activeKey.isNotEmpty;

  /// The active key: user-provided takes priority, otherwise built-in default
  String get _activeKey => (_apiKey != null && _apiKey!.isNotEmpty) ? _apiKey! : _defaultApiKey;

  /// Initialize the service, loading saved API key
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _apiKey = prefs.getString(_apiKeyPref);
    _initModel();
  }

  void _initModel() {
    final key = _activeKey;
    if (key.isEmpty) return;
    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: key,
    );
  }

  /// Set API key and persist it
  Future<void> setApiKey(String key) async {
    _apiKey = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyPref, _apiKey!);
    _initModel();
    _cache.clear();
  }

  /// Remove user-provided API key (falls back to built-in default)
  Future<void> clearApiKey() async {
    _apiKey = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_apiKeyPref);
    _initModel();
    _cache.clear();
  }

  /// Classify a coin from front and back images using Gemini vision
  Future<CoinClassificationResult> classifyCoin(File obverseFile, {File? reverseFile}) async {
    // Check cache
    final cacheKey = '${obverseFile.path}|${reverseFile?.path ?? "single"}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    if (_model == null) {
      await initialize();
      if (_model == null) {
        throw Exception('Gemini API key not configured. Add it in Settings.');
      }
    }

    try {
      String mimeFor(File f) =>
          f.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';

      final parts = <Part>[];

      if (reverseFile != null) {
        parts.add(TextPart(_buildPromptTwoSides()));
        parts.add(TextPart('Image 1 - OBVERSE (front):'));
        parts.add(DataPart(mimeFor(obverseFile), await obverseFile.readAsBytes()));
        parts.add(TextPart('Image 2 - REVERSE (back):'));
        parts.add(DataPart(mimeFor(reverseFile), await reverseFile.readAsBytes()));
      } else {
        parts.add(TextPart(_buildPromptOneSide()));
        parts.add(DataPart(mimeFor(obverseFile), await obverseFile.readAsBytes()));
      }

      final response = await _model!.generateContent([
        Content.multi(parts),
      ]);

      final text = response.text;
      if (text == null || text.isEmpty) {
        throw Exception('Gemini returned empty response');
      }

      final result = _parseResponse(text);
      _cache[cacheKey] = result;
      return result;
    } on GenerativeAIException catch (e) {
      debugPrint('Gemini API error: $e');
      if (e.toString().contains('quota') || e.toString().contains('429')) {
        throw Exception('Gemini quota exceeded. Try again later.');
      }
      if (e.toString().contains('API_KEY') || e.toString().contains('401')) {
        throw Exception('Invalid Gemini API key. Check Settings.');
      }
      throw Exception('Gemini error: ${e.message}');
    } on SocketException {
      throw Exception('No internet connection.');
    } catch (e) {
      debugPrint('Gemini classification error: $e');
      rethrow;
    }
  }

  String _buildPromptTwoSides() {
    return '''You are an expert numismatist and coin specialist. You are given TWO images of the SAME coin: the obverse (front) and reverse (back). Analyze both sides together for the most accurate identification.

Return ONLY valid JSON (no markdown, no code blocks, no extra text):
{
  "isCoin": true,
  "coinType": "specific coin name (e.g. 'Roman Denarius of Augustus', '2 Euro Greece 2002')",
  "period": "historical period (e.g. 'Ancient Roman', 'Byzantine', 'Modern')",
  "dateRange": "estimated date range (e.g. '27 BC - 14 AD', '2002 - Present')",
  "material": "metal type (e.g. 'Silver', 'Bronze', 'Copper-Nickel')",
  "denomination": "denomination if identifiable (e.g. 'Denarius', 'Tetradrachm', '2 Euro')",
  "ruler": "ruler/emperor/authority if visible (e.g. 'Augustus', 'Justinian I')",
  "obverseDescription": "description of front/obverse side",
  "reverseDescription": "description of back/reverse side",
  "confidence": 85,
  "historicalContext": "2-3 sentences about this coin's historical significance",
  "characteristics": ["notable feature 1", "notable feature 2"]
}

If the images are NOT of a coin, return:
{"isCoin": false, "coinType": "Not a coin", "confidence": 95, "characteristics": ["description of what the object appears to be"]}

Important rules:
- You have BOTH sides - use both to cross-reference and identify the exact coin
- Be specific: identify the exact type, denomination, ruler, mint when possible
- Confidence should reflect how certain you are (0-100)
- If you can read inscriptions on either side, include them in the descriptions
- For modern coins, identify the country, year, and denomination
- For ancient coins, identify the ruler, mint, and period''';
  }

  String _buildPromptOneSide() {
    return '''You are an expert numismatist and coin specialist. Analyze this coin image carefully.

Return ONLY valid JSON (no markdown, no code blocks, no extra text):
{
  "isCoin": true,
  "coinType": "specific coin name (e.g. 'Roman Denarius of Augustus', '2 Euro Greece 2002')",
  "period": "historical period (e.g. 'Ancient Roman', 'Byzantine', 'Modern')",
  "dateRange": "estimated date range (e.g. '27 BC - 14 AD', '2002 - Present')",
  "material": "metal type (e.g. 'Silver', 'Bronze', 'Copper-Nickel')",
  "denomination": "denomination if identifiable (e.g. 'Denarius', 'Tetradrachm', '2 Euro')",
  "ruler": "ruler/emperor/authority if visible (e.g. 'Augustus', 'Justinian I')",
  "obverseDescription": "description of front/obverse side",
  "reverseDescription": "description of back/reverse side",
  "confidence": 85,
  "historicalContext": "2-3 sentences about this coin's historical significance",
  "characteristics": ["notable feature 1", "notable feature 2"]
}

If the image is NOT a coin, return:
{"isCoin": false, "coinType": "Not a coin", "confidence": 95, "characteristics": ["description of what the object appears to be"]}

Important rules:
- Be specific: don't just say "Roman coin", identify the exact type if possible
- Confidence should reflect how certain you are (0-100)
- If you can read inscriptions, include them in descriptions
- For modern coins, identify the country and denomination
- For ancient coins, identify the ruler, mint, and period when possible''';
  }

  CoinClassificationResult _parseResponse(String responseText) {
    // Strip markdown code blocks if present
    var text = responseText.trim();
    if (text.startsWith('```json')) {
      text = text.substring(7);
    } else if (text.startsWith('```')) {
      text = text.substring(3);
    }
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    text = text.trim();

    try {
      final json = jsonDecode(text) as Map<String, dynamic>;

      final isCoin = json['isCoin'] as bool? ?? false;
      final coinType = json['coinType'] as String? ?? 'Unknown';
      final period = json['period'] as String?;
      final dateRange = json['dateRange'] as String?;
      final material = json['material'] as String? ?? 'Unknown';
      final denomination = json['denomination'] as String?;
      final ruler = json['ruler'] as String?;
      final obverse = json['obverseDescription'] as String?;
      final reverse = json['reverseDescription'] as String?;
      final confidence = (json['confidence'] as num?)?.toDouble() ?? 50.0;
      final historicalContext = json['historicalContext'] as String?;
      final characteristics = (json['characteristics'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      // Build detailed description
      final descParts = <String>[];
      if (obverse != null && obverse.isNotEmpty) {
        descParts.add('Obverse: $obverse');
      }
      if (reverse != null && reverse.isNotEmpty) {
        descParts.add('Reverse: $reverse');
      }
      if (historicalContext != null && historicalContext.isNotEmpty) {
        descParts.add(historicalContext);
      }

      return CoinClassificationResult(
        isCoin: isCoin,
        material: material,
        period: period,
        dateRange: dateRange,
        confidence: confidence,
        characteristics: [coinType, ...characteristics],
        regions: [],
        alternativePeriods: [],
        colorAnalysis: {},
        denomination: denomination,
        ruler: ruler,
        detailedDescription: descParts.join('\n\n'),
      );
    } catch (e) {
      debugPrint('Failed to parse Gemini JSON: $e');
      debugPrint('Raw response: $text');

      return CoinClassificationResult(
        isCoin: true,
        material: 'Unknown',
        period: null,
        confidence: 30,
        characteristics: ['Gemini response could not be parsed'],
        regions: [],
        alternativePeriods: [],
        colorAnalysis: {},
      );
    }
  }

  /// Clear the result cache
  void clearCache() => _cache.clear();
}
