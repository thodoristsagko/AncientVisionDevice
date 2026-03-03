import 'dart:io';
import 'package:image/image.dart' as img;
import 'coin_models.dart';
import 'coin_period_database.dart';
import 'coin_detection_analyzer.dart';
import 'coin_numista_client.dart';
import 'coin_grading_service.dart';
import 'coin_patina_analyzer.dart';
import 'coin_physical_analyzer.dart';

/// Orchestrator for all coin identification features.
/// Delegates to specialized sub-services.
class CoinIdentificationService {
  static final CoinIdentificationService _instance = CoinIdentificationService._internal();
  factory CoinIdentificationService() => _instance;
  CoinIdentificationService._internal();

  final CoinNumistaClient _numista = CoinNumistaClient();

  // Delegate API key management to numista client
  void setApiKey(String key) => _numista.setApiKey(key);
  void clearApiKey() => _numista.clearApiKey();
  bool get hasApiKey => _numista.hasApiKey;

  // Period database access
  static Map<String, CoinPeriodInfo> get periodDatabase => CoinPeriodDatabase.periodDatabase;

  // Detection
  Future<SmartCoinDetection> detectCoinInImage(File imageFile) =>
      CoinDetectionAnalyzer.detectCoinInImage(imageFile);

  // Analysis
  CoinAnalysisResult analyzeByCharacteristics({
    required String material,
    String? shape,
    String? scriptType,
    String? imageType,
    List<String>? keywords,
    Map<String, dynamic>? colorData,
  }) => CoinDetectionAnalyzer.analyzeByCharacteristics(
    material: material, shape: shape, scriptType: scriptType,
    imageType: imageType, keywords: keywords, colorData: colorData,
  );

  Future<Map<String, dynamic>> analyzeImage(File imageFile) =>
      CoinDetectionAnalyzer.analyzeImage(imageFile);

  // Numista
  Future<List<NumistaCoin>> searchCoins({required String query, String? category = 'coin', int? year, int count = 20}) =>
      _numista.searchCoins(query: query, category: category, year: year, count: count);
  Future<NumistaCoinDetails?> getCoinDetails(int id) => _numista.getCoinDetails(id);
  Future<NumistaIdentificationResult?> identifyWithNumista({
    required String material,
    required List<String> keywords,
    Map<String, dynamic>? colorData,
  }) => _numista.identifyWithNumista(material: material, keywords: keywords, colorData: colorData);
  CoinAnalysisResult numistaToAnalysisResult(NumistaIdentificationResult numista) =>
      _numista.numistaToAnalysisResult(numista);
  Future<CoinAnalysisResult> identifyCoinSmart({
    required String material,
    List<String>? keywords,
    Map<String, dynamic>? colorData,
    bool forceLocal = false,
  }) => _numista.identifyCoinSmart(material: material, keywords: keywords, colorData: colorData, forceLocal: forceLocal);
  Future<List<OcreCoin>> searchOcreCoins(String query) => _numista.searchOcreCoins(query);
  void clearCache() => _numista.clearCache();

  // Grading
  Future<WearGradeAnalysis> analyzeWearGrade(File imageFile) =>
      CoinGradingService.analyzeWearGrade(imageFile);

  // Patina
  Future<PatinaAnalysis> analyzePatinaAdvanced(File imageFile) =>
      CoinPatinaAnalyzer.analyzePatinaAdvanced(imageFile);

  // Physical
  EdgeTypeAnalysis analyzeEdgeType(img.Image image) =>
      CoinPhysicalAnalyzer.analyzeEdgeType(image);
  CoinSideAnalysis analyzeCoinSide(img.Image image) =>
      CoinPhysicalAnalyzer.analyzeCoinSide(image);

  // Comprehensive
  Future<ComprehensiveCoinAnalysis> performComprehensiveAnalysis(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) {
      return ComprehensiveCoinAnalysis(isCoin: false, analysisError: 'Could not decode image');
    }

    final resized = img.copyResize(image, width: 400);

    final smartDetection = await detectCoinInImage(imageFile);
    final patinaAnalysis = await analyzePatinaAdvanced(imageFile);
    final wearGrade = await analyzeWearGrade(imageFile);
    final edgeType = analyzeEdgeType(resized);
    final coinSide = analyzeCoinSide(resized);
    final imageAnalysis = await analyzeImage(imageFile);

    return ComprehensiveCoinAnalysis(
      isCoin: smartDetection.isCoin,
      coinDetectionConfidence: smartDetection.confidence,
      patinaType: patinaAnalysis.patinaType,
      patinaCoverage: patinaAnalysis.coverage,
      patinaQuality: patinaAnalysis.quality,
      patinaDescription: patinaAnalysis.description,
      isCleaningDetected: patinaAnalysis.isCleaningDetected,
      grade: wearGrade.grade,
      gradeConfidence: wearGrade.confidence,
      sheldonNumber: wearGrade.sheldonNumber,
      gradeDescription: wearGrade.description,
      wearLocations: wearGrade.wearLocations,
      edgeType: edgeType.edgeType,
      edgeDescription: edgeType.description,
      coinSide: coinSide.side,
      sideConfidence: coinSide.confidence,
      possibleElements: coinSide.possibleElements,
      estimatedMaterial: imageAnalysis['estimatedMaterial'] as String?,
      colorAnalysis: imageAnalysis['colorAnalysis'] as Map<String, dynamic>?,
    );
  }
}
