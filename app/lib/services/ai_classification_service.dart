import 'dart:io';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'coin/index.dart';

/// Advanced AI-powered artifact classification using Google ML Kit
/// Provides professional-grade on-device image labeling and object detection
/// Optimized for archaeological artifact analysis
class AIClassificationService {
  static final AIClassificationService _instance = AIClassificationService._internal();
  factory AIClassificationService() => _instance;
  AIClassificationService._internal();

  ImageLabeler? _imageLabeler;
  ObjectDetector? _objectDetector;

  // LRU classification cache — bounded to 50 entries to prevent unbounded growth
  // O'Neil, O'Neil & Weikum (1993) "The LRU-K Page Replacement Algorithm"
  static const int _maxCacheSize = 50;
  final Map<String, ArtifactClassificationResult> _cache = {};

  // ═══════════════════════════════════════════════════════════════
  // COMPREHENSIVE ARTIFACT TYPE MAPPINGS (100+ labels)
  // ═══════════════════════════════════════════════════════════════
  static const Map<String, String> _labelToArtifactType = {
    // Coins & Currency
    'coin': 'Coin',
    'money': 'Coin',
    'currency': 'Coin',
    'medal': 'Coin',
    'token': 'Coin',
    'medallion': 'Coin',
    'numismatic': 'Coin',
    'penny': 'Coin',
    'dime': 'Coin',
    'quarter': 'Coin',
    'dollar': 'Coin',

    // Pottery & Ceramics
    'pottery': 'Pottery',
    'ceramic': 'Pottery',
    'vase': 'Pottery',
    'bowl': 'Pottery',
    'jar': 'Pottery',
    'pot': 'Pottery',
    'cup': 'Pottery',
    'plate': 'Pottery',
    'dish': 'Pottery',
    'amphora': 'Pottery',
    'urn': 'Pottery',
    'jug': 'Pottery',
    'pitcher': 'Pottery',
    'vessel': 'Pottery',
    'terracotta': 'Pottery',
    'earthenware': 'Pottery',
    'porcelain': 'Pottery',
    'stoneware': 'Pottery',
    'crockery': 'Pottery',

    // Tools & Implements
    'tool': 'Tool',
    'knife': 'Tool',
    'blade': 'Tool',
    'axe': 'Tool',
    'hammer': 'Tool',
    'chisel': 'Tool',
    'scraper': 'Tool',
    'awl': 'Tool',
    'needle': 'Tool',
    'spindle': 'Tool',
    'loom': 'Tool',
    'millstone': 'Tool',
    'mortar': 'Tool',
    'pestle': 'Tool',
    'sickle': 'Tool',
    'plowshare': 'Tool',
    'hoe': 'Tool',

    // Weapons
    'sword': 'Weapon',
    'weapon': 'Weapon',
    'arrowhead': 'Weapon',
    'spear': 'Weapon',
    'dagger': 'Weapon',
    'arrow': 'Weapon',
    'bow': 'Weapon',
    'shield': 'Weapon',
    'helmet': 'Weapon',
    'armor': 'Weapon',
    'mace': 'Weapon',
    'lance': 'Weapon',
    'javelin': 'Weapon',
    'sling': 'Weapon',
    'projectile': 'Weapon',

    // Jewelry & Ornaments
    'jewelry': 'Jewelry',
    'ring': 'Jewelry',
    'bracelet': 'Jewelry',
    'necklace': 'Jewelry',
    'pendant': 'Jewelry',
    'brooch': 'Jewelry',
    'earring': 'Jewelry',
    'bead': 'Jewelry',
    'amulet': 'Jewelry',
    'fibula': 'Jewelry',
    'torque': 'Jewelry',
    'diadem': 'Jewelry',
    'crown': 'Jewelry',
    'tiara': 'Jewelry',
    'charm': 'Jewelry',
    'ornament': 'Jewelry',
    'seal': 'Jewelry',
    'signet': 'Jewelry',

    // Sculpture & Art
    'sculpture': 'Sculpture',
    'statue': 'Sculpture',
    'figurine': 'Sculpture',
    'bust': 'Sculpture',
    'relief': 'Sculpture',
    'carving': 'Sculpture',
    'idol': 'Sculpture',
    'mask': 'Sculpture',
    'head': 'Sculpture',
    'torso': 'Sculpture',
    'statuette': 'Sculpture',

    // Building Materials & Architecture
    'brick': 'Building Material',
    'tile': 'Building Material',
    'mosaic': 'Building Material',
    'column': 'Building Material',
    'capital': 'Building Material',
    'frieze': 'Building Material',
    'architrave': 'Building Material',
    'cornice': 'Building Material',
    'plaster': 'Building Material',

    // Stone & Lithic
    'stone': 'Stone',
    'rock': 'Stone',
    'marble': 'Stone',
    'granite': 'Stone',
    'flint': 'Lithic',
    'obsidian': 'Lithic',
    'chert': 'Lithic',
    'quartz': 'Stone',
    'basalt': 'Stone',
    'limestone': 'Stone',
    'sandstone': 'Stone',
    'slate': 'Stone',
    'stele': 'Stone',
    'obelisk': 'Stone',

    // Bone & Organic
    'bone': 'Bone/Organic',
    'skeleton': 'Bone/Organic',
    'shell': 'Bone/Organic',
    'ivory': 'Bone/Organic',
    'horn': 'Bone/Organic',
    'tooth': 'Bone/Organic',
    'antler': 'Bone/Organic',
    'tusk': 'Bone/Organic',
    'skull': 'Bone/Organic',
    'fossil': 'Bone/Organic',

    // Metal Objects
    'metal': 'Metal Object',
    'bronze': 'Metal Object',
    'iron': 'Metal Object',
    'copper': 'Metal Object',
    'gold': 'Metal Object',
    'silver': 'Metal Object',
    'brass': 'Metal Object',
    'pewter': 'Metal Object',
    'lead': 'Metal Object',
    'tin': 'Metal Object',

    // Glass
    'glass': 'Glass',
    'bottle': 'Glass',
    'glassware': 'Glass',
    'window': 'Glass',

    // Textile & Fiber
    'fabric': 'Textile',
    'textile': 'Textile',
    'cloth': 'Textile',
    'leather': 'Textile',
    'linen': 'Textile',
    'wool': 'Textile',
    'silk': 'Textile',
    'cotton': 'Textile',
    'rope': 'Textile',
    'basket': 'Textile',
    'weaving': 'Textile',

    // Writing & Documents
    'inscription': 'Inscription',
    'tablet': 'Inscription',
    'papyrus': 'Inscription',
    'scroll': 'Inscription',
    'codex': 'Inscription',
    'ostracon': 'Inscription',
    'cuneiform': 'Inscription',
    'hieroglyph': 'Inscription',

    // Religious & Ritual
    'altar': 'Religious Object',
    'incense': 'Religious Object',
    'offering': 'Religious Object',
    'votive': 'Religious Object',
    'lamp': 'Lamp',
    'lantern': 'Lamp',
    'candle': 'Lamp',
    'oil lamp': 'Lamp',

    // Containers
    'container': 'Container',
    'box': 'Container',
    'chest': 'Container',
    'casket': 'Container',
    'coffin': 'Container',
    'sarcophagus': 'Container',
  };

  // ═══════════════════════════════════════════════════════════════
  // MATERIAL DETECTION MAPPINGS (50+ materials)
  // ═══════════════════════════════════════════════════════════════
  static const Map<String, String> _labelToMaterial = {
    // Metals
    'metal': 'Metal',
    'bronze': 'Bronze',
    'iron': 'Iron',
    'copper': 'Copper',
    'gold': 'Gold',
    'silver': 'Silver',
    'brass': 'Bronze',
    'pewter': 'Lead/Tin',
    'lead': 'Lead',
    'tin': 'Tin',
    'electrum': 'Electrum',
    'orichalcum': 'Bronze',
    'billon': 'Billon',

    // Ceramics
    'ceramic': 'Ceramic',
    'pottery': 'Ceramic',
    'clay': 'Ceramic',
    'terracotta': 'Terracotta',
    'earthenware': 'Ceramic',
    'stoneware': 'Ceramic',
    'porcelain': 'Porcelain',
    'faience': 'Faience',

    // Stone
    'stone': 'Stone',
    'rock': 'Stone',
    'marble': 'Marble',
    'granite': 'Granite',
    'limestone': 'Limestone',
    'sandstone': 'Sandstone',
    'basalt': 'Basalt',
    'alabaster': 'Alabaster',
    'jade': 'Jade',
    'obsidian': 'Obsidian',
    'flint': 'Flint',
    'chert': 'Chert',
    'quartz': 'Quartz',
    'slate': 'Slate',
    'lapis': 'Lapis Lazuli',

    // Organic
    'bone': 'Bone',
    'ivory': 'Ivory',
    'wood': 'Wood',
    'shell': 'Shell',
    'horn': 'Horn',
    'antler': 'Antler',
    'amber': 'Amber',
    'coral': 'Coral',

    // Glass
    'glass': 'Glass',

    // Textile
    'leather': 'Leather',
    'fabric': 'Textile',
    'textile': 'Textile',
    'linen': 'Linen',
    'wool': 'Wool',
    'silk': 'Silk',
    'cotton': 'Cotton',

    // Other
    'papyrus': 'Papyrus',
    'parchment': 'Parchment',
    'plaster': 'Plite',
    'wax': 'Wax',
    'bitumen': 'Bitumen',
  };

  // ═══════════════════════════════════════════════════════════════
  // PERIOD DETECTION MAPPINGS
  // ═══════════════════════════════════════════════════════════════
  static const Map<String, Map<String, String>> _periodMappings = {
    // Type + Material combinations
    'Coin|Bronze': {'period': 'Roman/Byzantine', 'confidence': '0.6'},
    'Coin|Silver': {'period': 'Classical/Roman', 'confidence': '0.6'},
    'Coin|Gold': {'period': 'Imperial/Medieval', 'confidence': '0.5'},
    'Pottery|Ceramic': {'period': 'Classical/Hellenistic', 'confidence': '0.5'},
    'Pottery|Terracotta': {'period': 'Archaic/Classical', 'confidence': '0.5'},
    'Tool|Bronze': {'period': 'Bronze Age', 'confidence': '0.7'},
    'Tool|Iron': {'period': 'Iron Age', 'confidence': '0.7'},
    'Weapon|Bronze': {'period': 'Bronze Age', 'confidence': '0.7'},
    'Weapon|Iron': {'period': 'Iron Age/Medieval', 'confidence': '0.6'},
    'Lithic|Flint': {'period': 'Paleolithic/Neolithic', 'confidence': '0.8'},
    'Lithic|Obsidian': {'period': 'Neolithic/Bronze Age', 'confidence': '0.7'},
    'Sculpture|Marble': {'period': 'Classical/Hellenistic', 'confidence': '0.6'},
    'Sculpture|Bronze': {'period': 'Classical/Roman', 'confidence': '0.6'},
    'Glass|Glass': {'period': 'Roman/Byzantine', 'confidence': '0.5'},
    'Jewelry|Gold': {'period': 'Various (context needed)', 'confidence': '0.3'},
    'Jewelry|Bronze': {'period': 'Bronze Age/Iron Age', 'confidence': '0.5'},
  };

  /// Initialize the ML Kit services with optimized settings
  Future<void> initialize() async {
    try {
      // Lower threshold for better detection (0.3 instead of 0.5)
      final labelerOptions = ImageLabelerOptions(confidenceThreshold: 0.3);
      _imageLabeler = ImageLabeler(options: labelerOptions);

      // Multi-object detection for complex scenes
      final detectorOptions = ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      );
      _objectDetector = ObjectDetector(options: detectorOptions);

      debugPrint('AI Classification Service initialized (optimized)');
    } catch (e) {
      debugPrint('Error initializing AI service: $e');
    }
  }

  /// Classify an artifact image with comprehensive analysis
  Future<ArtifactClassificationResult> classifyArtifact(File imageFile) async {
    // Check cache first
    final cacheKey = imageFile.path;
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    if (_imageLabeler == null) {
      await initialize();
    }

    final inputImage = InputImage.fromFile(imageFile);
    final labels = await _imageLabeler?.processImage(inputImage) ?? [];
    final objects = await _objectDetector?.processImage(inputImage) ?? [];

    // Process labels to find artifact type and material
    String? detectedType;
    String? detectedMaterial;
    double typeConfidence = 0;
    double materialConfidence = 0;
    final allLabels = <ClassificationLabel>[];

    for (final label in labels) {
      final labelText = label.label.toLowerCase();
      final confidence = label.confidence;

      allLabels.add(ClassificationLabel(
        label: label.label,
        confidence: confidence,
      ));

      // Check for artifact type match (prioritize higher confidence)
      for (final entry in _labelToArtifactType.entries) {
        if (labelText.contains(entry.key)) {
          // Use weighted confidence for better accuracy
          final weightedConf = confidence * (labelText == entry.key ? 1.2 : 1.0);
          if (weightedConf > typeConfidence) {
            detectedType = entry.value;
            typeConfidence = confidence;
          }
        }
      }

      // Check for material match
      for (final entry in _labelToMaterial.entries) {
        if (labelText.contains(entry.key)) {
          final weightedConf = confidence * (labelText == entry.key ? 1.2 : 1.0);
          if (weightedConf > materialConfidence) {
            detectedMaterial = entry.value;
            materialConfidence = confidence;
          }
        }
      }
    }

    // Process detected objects for additional context
    final detectedObjects = <DetectedObject>[];
    for (final obj in objects) {
      detectedObjects.add(DetectedObject(
        boundingBox: obj.boundingBox,
        labels: obj.labels.map((l) => ClassificationLabel(
          label: l.text,
          confidence: l.confidence,
        )).toList(),
        trackingId: obj.trackingId,
      ));

      // Use object labels to improve detection
      for (final objLabel in obj.labels) {
        final labelText = objLabel.text.toLowerCase();
        for (final entry in _labelToArtifactType.entries) {
          if (labelText.contains(entry.key) && objLabel.confidence > typeConfidence) {
            detectedType = entry.value;
            typeConfidence = objLabel.confidence;
          }
        }
      }
    }

    // Generate suggested period based on type + material combination
    String? suggestedPeriod;
    double periodConfidence = 0;

    if (detectedType != null && detectedMaterial != null) {
      final key = '$detectedType|$detectedMaterial';
      if (_periodMappings.containsKey(key)) {
        suggestedPeriod = _periodMappings[key]!['period'];
        periodConfidence = double.tryParse(_periodMappings[key]!['confidence'] ?? '0') ?? 0;
      }
    }

    // Fallback period detection
    if (suggestedPeriod == null) {
      if (detectedMaterial == 'Bronze' || detectedMaterial == 'Copper') {
        suggestedPeriod = 'Bronze Age';
        periodConfidence = 0.4;
      } else if (detectedMaterial == 'Iron') {
        suggestedPeriod = 'Iron Age';
        periodConfidence = 0.4;
      } else if (detectedMaterial == 'Flint' || detectedMaterial == 'Obsidian') {
        suggestedPeriod = 'Stone Age';
        periodConfidence = 0.6;
      }
    }

    final result = ArtifactClassificationResult(
      artifactType: detectedType,
      material: detectedMaterial,
      suggestedPeriod: suggestedPeriod,
      typeConfidence: typeConfidence,
      materialConfidence: materialConfidence,
      periodConfidence: periodConfidence,
      allLabels: allLabels,
      detectedObjects: detectedObjects,
      isHighConfidence: typeConfidence > 0.6 || materialConfidence > 0.6,
    );

    // Evict oldest entry if cache is full (LRU approximation)
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[cacheKey] = result;
    return result;
  }

  /// Quick classification - returns just the top prediction
  Future<({String? type, String? material, double confidence})> quickClassify(File imageFile) async {
    final result = await classifyArtifact(imageFile);
    return (
      type: result.artifactType,
      material: result.material,
      confidence: (result.typeConfidence + result.materialConfidence) / 2,
    );
  }

  /// Enhanced coin classification with Numista API + fallback to heuristics
  Future<CoinClassificationResult> classifyCoin(File imageFile, {String? detectedMaterial}) async {
    final coinService = CoinIdentificationService();

    // Analyze image colors and texture for better material/period estimation
    final imageAnalysis = await coinService.analyzeImage(imageFile);
    final material = detectedMaterial ?? imageAnalysis['estimatedMaterial'] as String? ?? 'Unknown';

    // Extract keywords from ML Kit labels for period matching
    final mlResult = await classifyArtifact(imageFile);
    final keywords = mlResult.allLabels
        .where((l) => l.confidence > 0.25) // Lower threshold for more keywords
        .map((l) => l.label)
        .toList();

    // Pass color data to coin service for enhanced analysis
    final colorData = imageAnalysis['colorAnalysis'] as Map<String, dynamic>? ?? {};

    // Use smart identification (Numista API first, then heuristics)
    final periodResult = await coinService.identifyCoinSmart(
      material: material,
      keywords: keywords,
      colorData: colorData,
    );

    return CoinClassificationResult(
      isCoin: mlResult.artifactType == 'Coin',
      material: material,
      period: periodResult.period,
      dateRange: periodResult.dateRange,
      confidence: periodResult.confidence,
      characteristics: periodResult.characteristics ?? [],
      regions: periodResult.regions ?? [],
      materials: periodResult.materials ?? [],
      alternativePeriods: periodResult.alternativePeriods ?? [],
      colorAnalysis: colorData,
      textureAnalysis: imageAnalysis['textureAnalysis'] as Map<String, dynamic>? ?? {},
      numistaId: periodResult.numistaId,
      numistaUrl: periodResult.numistaUrl,
      obverseImage: periodResult.obverseImage,
      reverseImage: periodResult.reverseImage,
    );
  }

  /// Generate intelligent description based on classification
  String generateDescription(ArtifactClassificationResult result) {
    final parts = <String>[];

    if (result.artifactType != null) {
      parts.add('This appears to be a ${result.artifactType?.toLowerCase()}');
    }

    if (result.material != null) {
      if (parts.isNotEmpty) {
        parts.add('made of ${result.material?.toLowerCase()}');
      } else {
        parts.add('${result.material} artifact');
      }
    }

    if (result.suggestedPeriod != null) {
      parts.add('possibly from the ${result.suggestedPeriod} period');
    }

    if (parts.isEmpty) {
      return 'Unable to classify automatically. Please enter details manually.';
    }

    final avgConfidence = (result.typeConfidence + result.materialConfidence) / 2 * 100;
    return '${parts.join(', ')}. Confidence: ${avgConfidence.toStringAsFixed(0)}%';
  }

  /// Clear classification cache
  void clearCache() => _cache.clear();

  /// Dispose resources
  Future<void> dispose() async {
    await _imageLabeler?.close();
    await _objectDetector?.close();
    _imageLabeler = null;
    _objectDetector = null;
    _cache.clear();
  }
}

/// Result of artifact classification
class ArtifactClassificationResult {
  final String? artifactType;
  final String? material;
  final String? suggestedPeriod;
  final double typeConfidence;
  final double materialConfidence;
  final double periodConfidence;
  final List<ClassificationLabel> allLabels;
  final List<DetectedObject> detectedObjects;
  final bool isHighConfidence;

  ArtifactClassificationResult({
    this.artifactType,
    this.material,
    this.suggestedPeriod,
    required this.typeConfidence,
    required this.materialConfidence,
    this.periodConfidence = 0,
    required this.allLabels,
    required this.detectedObjects,
    required this.isHighConfidence,
  });

  Map<String, dynamic> toJson() => {
    'artifactType': artifactType,
    'material': material,
    'suggestedPeriod': suggestedPeriod,
    'typeConfidence': typeConfidence,
    'materialConfidence': materialConfidence,
    'periodConfidence': periodConfidence,
    'allLabels': allLabels.map((l) => l.toJson()).toList(),
    'isHighConfidence': isHighConfidence,
  };
}

/// A classification label with confidence score
class ClassificationLabel {
  final String label;
  final double confidence;

  ClassificationLabel({
    required this.label,
    required this.confidence,
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'confidence': confidence,
  };
}

/// A detected object in the image
class DetectedObject {
  final Rect boundingBox;
  final List<ClassificationLabel> labels;
  final int? trackingId;

  DetectedObject({
    required this.boundingBox,
    required this.labels,
    this.trackingId,
  });
}

/// Enhanced coin classification result with full analysis data
class CoinClassificationResult {
  final bool isCoin;
  final String material;
  final String? period;
  final String? dateRange;
  final double confidence;
  final List<String> characteristics;
  final List<String> regions;
  final List<String> materials;
  final List<String> alternativePeriods;
  final Map<String, dynamic> colorAnalysis;
  final Map<String, dynamic> textureAnalysis;

  // Numista API integration fields
  final int? numistaId;
  final String? numistaUrl;
  final String? obverseImage;
  final String? reverseImage;

  // Gemini AI fields
  final String? denomination;
  final String? ruler;
  final String? detailedDescription;

  CoinClassificationResult({
    required this.isCoin,
    required this.material,
    this.period,
    this.dateRange,
    required this.confidence,
    required this.characteristics,
    required this.regions,
    this.materials = const [],
    required this.alternativePeriods,
    required this.colorAnalysis,
    this.textureAnalysis = const {},
    this.numistaId,
    this.numistaUrl,
    this.obverseImage,
    this.reverseImage,
    this.denomination,
    this.ruler,
    this.detailedDescription,
  });

  Map<String, dynamic> toJson() => {
    'isCoin': isCoin,
    'material': material,
    'period': period,
    'dateRange': dateRange,
    'confidence': confidence,
    'characteristics': characteristics,
    'regions': regions,
    'materials': materials,
    'alternativePeriods': alternativePeriods,
    'numistaId': numistaId,
    'numistaUrl': numistaUrl,
    'obverseImage': obverseImage,
    'reverseImage': reverseImage,
    'denomination': denomination,
    'ruler': ruler,
    'detailedDescription': detailedDescription,
  };

  String get description {
    if (period == null) {
      return 'Coin detected, material: $material. Period could not be determined.';
    }
    return '$period coin ($dateRange), material: $material. Confidence: ${confidence.toStringAsFixed(0)}%';
  }
}
