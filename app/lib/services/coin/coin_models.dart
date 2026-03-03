// ═══════════════════════════════════════════════════════════════════════════
// COIN MODELS - Data classes for coin identification and analysis
// ═══════════════════════════════════════════════════════════════════════════

/// Patina type enumeration
enum PatinaType {
  greenVerdigris,  // Green patina on bronze/copper
  redCuprite,      // Red copper oxide
  blackOxide,      // Black toning
  brownEarth,      // Brown earth patina
  desertPatina,    // Sandy/tan desert patina
  none,            // Clean metal
}

/// Patina quality levels
enum PatinaQuality {
  heavy,     // Thick patina covering most surface
  moderate,  // Noticeable patina with visible metal
  light,     // Thin patina, most metal visible
  minimal,   // Almost no patina
}

/// Patina analysis result
class PatinaAnalysis {
  final PatinaType patinaType;
  final double coverage;
  final PatinaQuality quality;
  final bool isCleaningDetected;
  final double greenVerdigrisRatio;
  final double redCupriteRatio;
  final double blackOxideRatio;
  final double brownEarthRatio;
  final double desertPatinaRatio;
  final String description;

  PatinaAnalysis({
    required this.patinaType,
    required this.coverage,
    this.quality = PatinaQuality.minimal,
    this.isCleaningDetected = false,
    this.greenVerdigrisRatio = 0,
    this.redCupriteRatio = 0,
    this.blackOxideRatio = 0,
    this.brownEarthRatio = 0,
    this.desertPatinaRatio = 0,
    this.description = '',
  });
}

/// Numismatic grade enumeration (Sheldon scale)
enum CoinGrade {
  poor1,     // P-1
  ag3,       // AG-3
  g6,        // G-6
  vg10,      // VG-10
  f15,       // F-15
  vf25,      // VF-25
  vf35,      // VF-35
  ef40,      // EF-40
  ef45,      // EF-45
  au50,      // AU-50
  au58,      // AU-58
  ms60,      // MS-60
  ms63,      // MS-63
  ms65Plus,  // MS-65+
  unknown,
}

/// Wear grade analysis result
class WearGradeAnalysis {
  final CoinGrade grade;
  final double confidence;
  final int sheldonNumber;
  final String description;
  final double detailScore;
  final double highPointScore;
  final double fieldScore;
  final double lusterScore;
  final List<String> wearLocations;

  WearGradeAnalysis({
    required this.grade,
    required this.confidence,
    this.sheldonNumber = 0,
    this.description = '',
    this.detailScore = 0,
    this.highPointScore = 0,
    this.fieldScore = 0,
    this.lusterScore = 0,
    this.wearLocations = const [],
  });

  String get gradeLabel {
    switch (grade) {
      case CoinGrade.ms65Plus: return 'MS-65+';
      case CoinGrade.ms63: return 'MS-63';
      case CoinGrade.ms60: return 'MS-60';
      case CoinGrade.au58: return 'AU-58';
      case CoinGrade.au50: return 'AU-50';
      case CoinGrade.ef45: return 'EF-45';
      case CoinGrade.ef40: return 'EF-40';
      case CoinGrade.vf35: return 'VF-35';
      case CoinGrade.vf25: return 'VF-25';
      case CoinGrade.f15: return 'F-15';
      case CoinGrade.vg10: return 'VG-10';
      case CoinGrade.g6: return 'G-6';
      case CoinGrade.ag3: return 'AG-3';
      case CoinGrade.poor1: return 'P-1';
      case CoinGrade.unknown: return 'Unknown';
    }
  }
}

/// Edge types
enum EdgeType {
  plain,      // Smooth edge
  reeded,     // Vertical lines
  lettered,   // Text on edge
  decorated,  // Ornamental design
  unknown,
}

/// Edge type analysis result
class EdgeTypeAnalysis {
  final EdgeType edgeType;
  final double confidence;
  final String description;
  final List<String> hints;

  EdgeTypeAnalysis({
    required this.edgeType,
    required this.confidence,
    required this.description,
    this.hints = const [],
  });
}

/// Coin side enumeration
enum CoinSide {
  obverse,   // Heads/portrait side
  reverse,   // Tails/design side
  unknown,
}

/// Coin side analysis result
class CoinSideAnalysis {
  final CoinSide side;
  final double confidence;
  final String description;
  final double portraitScore;
  final double designScore;
  final bool hasLegend;
  final List<String> possibleElements;

  CoinSideAnalysis({
    required this.side,
    required this.confidence,
    required this.description,
    this.portraitScore = 0,
    this.designScore = 0,
    this.hasLegend = false,
    this.possibleElements = const [],
  });
}

/// Comprehensive coin analysis combining all features
class ComprehensiveCoinAnalysis {
  final bool isCoin;
  final double coinDetectionConfidence;
  final String? analysisError;

  // Patina
  final PatinaType? patinaType;
  final double patinaCoverage;
  final PatinaQuality? patinaQuality;
  final String? patinaDescription;
  final bool isCleaningDetected;

  // Grade
  final CoinGrade? grade;
  final double gradeConfidence;
  final int sheldonNumber;
  final String? gradeDescription;
  final List<String> wearLocations;

  // Edge
  final EdgeType? edgeType;
  final String? edgeDescription;

  // Side
  final CoinSide? coinSide;
  final double sideConfidence;
  final List<String> possibleElements;

  // Material
  final String? estimatedMaterial;
  final Map<String, dynamic>? colorAnalysis;

  ComprehensiveCoinAnalysis({
    required this.isCoin,
    this.coinDetectionConfidence = 0,
    this.analysisError,
    this.patinaType,
    this.patinaCoverage = 0,
    this.patinaQuality,
    this.patinaDescription,
    this.isCleaningDetected = false,
    this.grade,
    this.gradeConfidence = 0,
    this.sheldonNumber = 0,
    this.gradeDescription,
    this.wearLocations = const [],
    this.edgeType,
    this.edgeDescription,
    this.coinSide,
    this.sideConfidence = 0,
    this.possibleElements = const [],
    this.estimatedMaterial,
    this.colorAnalysis,
  });

  Map<String, dynamic> toJson() => {
    'isCoin': isCoin,
    'coinDetectionConfidence': coinDetectionConfidence,
    'patinaType': patinaType?.name,
    'patinaCoverage': patinaCoverage,
    'patinaQuality': patinaQuality?.name,
    'isCleaningDetected': isCleaningDetected,
    'grade': grade?.name,
    'gradeConfidence': gradeConfidence,
    'sheldonNumber': sheldonNumber,
    'edgeType': edgeType?.name,
    'coinSide': coinSide?.name,
    'estimatedMaterial': estimatedMaterial,
  };
}

/// Smart coin detection result
class SmartCoinDetection {
  final bool isCoin;
  final double confidence;
  final String reason;
  final double circularityScore;
  final double metallicScore;
  final double edgeScore;
  final double aspectRatioScore;

  SmartCoinDetection({
    required this.isCoin,
    required this.confidence,
    required this.reason,
    this.circularityScore = 0,
    this.metallicScore = 0,
    this.edgeScore = 0,
    this.aspectRatioScore = 0,
  });
}

/// Enhanced period info with denominations and rulers
class CoinPeriodInfo {
  final String period;
  final String dateRange;
  final List<String> characteristics;
  final List<String> regions;
  final List<String> materials;
  final List<String> denominations;
  final List<String> rulers;
  final double weight;

  const CoinPeriodInfo({
    required this.period,
    required this.dateRange,
    required this.characteristics,
    required this.regions,
    this.materials = const ['Bronze', 'Silver', 'Gold'],
    this.denominations = const [],
    this.rulers = const [],
    this.weight = 0.35,
  });
}

class CoinAnalysisResult {
  final bool isIdentified;
  final double confidence;
  final String? period;
  final String? dateRange;
  final List<String>? characteristics;
  final List<String>? regions;
  final List<String>? materials;
  final List<String>? denominations;
  final List<String>? rulers;
  final List<String>? alternativePeriods;
  final String? message;
  // Numista integration fields
  final int? numistaId;
  final String? numistaUrl;
  final String? obverseImage;
  final String? reverseImage;

  CoinAnalysisResult({
    required this.isIdentified,
    required this.confidence,
    this.period,
    this.dateRange,
    this.characteristics,
    this.regions,
    this.materials,
    this.denominations,
    this.rulers,
    this.alternativePeriods,
    this.message,
    this.numistaId,
    this.numistaUrl,
    this.obverseImage,
    this.reverseImage,
  });

  bool get hasNumistaData => numistaId != null;

  Map<String, dynamic> toJson() => {
    'isIdentified': isIdentified, 'confidence': confidence, 'period': period,
    'dateRange': dateRange, 'characteristics': characteristics, 'regions': regions,
    'materials': materials, 'denominations': denominations, 'rulers': rulers,
    'alternativePeriods': alternativePeriods, 'message': message,
    'numistaId': numistaId, 'numistaUrl': numistaUrl,
    'obverseImage': obverseImage, 'reverseImage': reverseImage,
  };
}

class NumistaCoin {
  final int id;
  final String title;
  final String? category;
  final String? issuer;
  final int? minYear;
  final int? maxYear;
  final String? obverseThumb;
  final String? reverseThumb;

  NumistaCoin({required this.id, required this.title, this.category, this.issuer, this.minYear, this.maxYear, this.obverseThumb, this.reverseThumb});

  factory NumistaCoin.fromJson(Map<String, dynamic> json) => NumistaCoin(
    id: json['id'] ?? 0, title: json['title'] ?? '', category: json['category'],
    issuer: json['issuer']?['name'], minYear: json['min_year'], maxYear: json['max_year'],
    obverseThumb: json['obverse']?['thumbnail'], reverseThumb: json['reverse']?['thumbnail'],
  );

  String get yearRange => minYear == null && maxYear == null ? 'Unknown' : minYear == maxYear ? '$minYear' : '${minYear ?? '?'} - ${maxYear ?? '?'}';
}

class NumistaCoinDetails {
  final int id;
  final String title;
  final String? issuer;
  final String? ruler;
  final String? type;
  final String? material;
  final String? weight;
  final String? diameter;
  final String? obverseDescription;
  final String? reverseDescription;
  final int? minYear;
  final int? maxYear;

  NumistaCoinDetails({required this.id, required this.title, this.issuer, this.ruler, this.type, this.material, this.weight, this.diameter, this.obverseDescription, this.reverseDescription, this.minYear, this.maxYear});

  factory NumistaCoinDetails.fromJson(Map<String, dynamic> json) => NumistaCoinDetails(
    id: json['id'] ?? 0, title: json['title'] ?? '', issuer: json['issuer']?['name'],
    ruler: json['ruler']?['name'], type: json['type'], material: json['composition']?['text'],
    weight: json['weight']?.toString(), diameter: json['size']?.toString(),
    obverseDescription: json['obverse']?['description'], reverseDescription: json['reverse']?['description'],
    minYear: json['min_year'], maxYear: json['max_year'],
  );
}

/// Result from Numista API identification
class NumistaIdentificationResult {
  final bool success;
  final NumistaCoin coin;
  final NumistaCoinDetails? details;
  final List<NumistaCoin> allMatches;
  final String searchQuery;
  final double confidence;

  NumistaIdentificationResult({
    required this.success,
    required this.coin,
    this.details,
    required this.allMatches,
    required this.searchQuery,
    required this.confidence,
  });
}

/// Result from OCRE API for Roman coins
class OcreCoin {
  final String id;
  final String title;
  final String? emperor;
  final String? denomination;
  final String? mint;
  final String? material;
  final int? year;
  final String? obverseDescription;
  final String? reverseDescription;
  final String? imageUrl;

  OcreCoin({
    required this.id,
    required this.title,
    this.emperor,
    this.denomination,
    this.mint,
    this.material,
    this.year,
    this.obverseDescription,
    this.reverseDescription,
    this.imageUrl,
  });

  factory OcreCoin.fromJson(Map<String, dynamic> json) => OcreCoin(
    id: json['id'] ?? '',
    title: json['title'] ?? '',
    emperor: json['emperor'],
    denomination: json['denomination'],
    mint: json['mint'],
    material: json['material'],
    year: json['year'],
    obverseDescription: json['obverse'],
    reverseDescription: json['reverse'],
    imageUrl: json['image'],
  );
}
