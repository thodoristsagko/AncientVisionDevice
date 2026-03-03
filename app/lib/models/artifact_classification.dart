import 'package:flutter/material.dart';

/// Predefined archaeological artifact types with icons and descriptions
class ArtifactType {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color color;
  final List<String> commonMaterials;
  final List<String> subTypes;

  const ArtifactType({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
    this.commonMaterials = const [],
    this.subTypes = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'commonMaterials': commonMaterials,
        'subTypes': subTypes,
      };
}

/// Predefined material types for artifacts
class ArtifactMaterial {
  final String id;
  final String name;
  final String description;
  final Color color;
  final List<String> preservationTips;

  const ArtifactMaterial({
    required this.id,
    required this.name,
    required this.description,
    required this.color,
    this.preservationTips = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'preservationTips': preservationTips,
      };
}

/// Historical periods for dating artifacts
class HistoricalPeriod {
  final String id;
  final String name;
  final String description;
  final int startYear; // negative for BCE
  final int endYear; // negative for BCE
  final Color color;

  const HistoricalPeriod({
    required this.id,
    required this.name,
    required this.description,
    required this.startYear,
    required this.endYear,
    required this.color,
  });

  String get dateRange {
    String start = startYear < 0 ? '${-startYear} BCE' : '$startYear CE';
    String end = endYear < 0 ? '${-endYear} BCE' : '$endYear CE';
    return '$start - $end';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'startYear': startYear,
        'endYear': endYear,
        'dateRange': dateRange,
      };
}

/// Artifact condition assessment
class ArtifactCondition {
  final String id;
  final String name;
  final String description;
  final Color color;
  final int severity; // 1-5 (1=excellent, 5=poor)

  const ArtifactCondition({
    required this.id,
    required this.name,
    required this.description,
    required this.color,
    required this.severity,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'severity': severity,
      };
}

/// Archaeological classification database
class ArtifactClassification {
  // Singleton pattern
  static final ArtifactClassification _instance = ArtifactClassification._internal();
  factory ArtifactClassification() => _instance;
  ArtifactClassification._internal();

  // ========== PRIORITIZED ARTIFACT TYPES (Coins & Fragments First) ==========
  static const List<ArtifactType> artifactTypes = [
    // ★ PRIORITY 1: Coins & Currency
    ArtifactType(
      id: 'coins',
      name: 'Coins & Currency',
      description: 'Ancient coins, tokens, and monetary objects',
      icon: Icons.paid,
      color: Color(0xFFB8860B),
      commonMaterials: ['bronze', 'silver', 'gold', 'copper'],
      subTypes: [
        'Bronze Coin', 'Silver Coin', 'Gold Coin', 'Copper Coin',
        'Token', 'Tessera', 'Medal', 'Seal', 'Weight', 'Ingot'
      ],
    ),
    // ★ PRIORITY 2: Pottery Fragments (Sherds)
    ArtifactType(
      id: 'fragments',
      name: 'Pottery Fragments',
      description: 'Ceramic sherds and vessel fragments',
      icon: Icons.broken_image,
      color: Color(0xFFCD853F),
      commonMaterials: ['ceramic', 'terracotta'],
      subTypes: [
        'Rim Sherd', 'Body Sherd', 'Base Sherd', 'Handle Fragment',
        'Spout Fragment', 'Lid Fragment', 'Foot Fragment', 'Decorated Sherd'
      ],
    ),
    // Complete Pottery (for whole vessels)
    ArtifactType(
      id: 'pottery',
      name: 'Complete Pottery',
      description: 'Intact or reconstructable clay vessels',
      icon: Icons.local_cafe,
      color: Color(0xFFD2691E),
      commonMaterials: ['ceramic', 'terracotta', 'porcelain'],
      subTypes: ['Amphora', 'Bowl', 'Jar', 'Vase', 'Plate', 'Figurine', 'Tile', 'Lamp'],
    ),
    ArtifactType(
      id: 'tools',
      name: 'Tools & Implements',
      description: 'Stone, bone, or metal tools used for work',
      icon: Icons.construction,
      color: Color(0xFF708090),
      commonMaterials: ['stone', 'flint', 'obsidian', 'bone', 'metal'],
      subTypes: ['Blade', 'Scraper', 'Axe', 'Knife', 'Needle', 'Awl', 'Hammer', 'Chisel'],
    ),
    ArtifactType(
      id: 'weapons',
      name: 'Weapons & Armor',
      description: 'Military artifacts including swords, shields, arrowheads',
      icon: Icons.security,
      color: Color(0xFF8B0000),
      commonMaterials: ['bronze', 'iron', 'stone', 'leather'],
      subTypes: ['Sword', 'Spear', 'Arrowhead', 'Shield', 'Helmet', 'Dagger', 'Mace'],
    ),
    ArtifactType(
      id: 'jewelry',
      name: 'Jewelry & Ornaments',
      description: 'Decorative items worn as adornment',
      icon: Icons.diamond,
      color: Color(0xFFFFD700),
      commonMaterials: ['gold', 'silver', 'bronze', 'glass', 'bone', 'shell'],
      subTypes: ['Ring', 'Bracelet', 'Necklace', 'Pendant', 'Earring', 'Brooch', 'Bead'],
    ),
    ArtifactType(
      id: 'sculpture',
      name: 'Sculpture & Statuary',
      description: 'Three-dimensional artistic representations',
      icon: Icons.account_balance,
      color: Color(0xFFF5F5DC),
      commonMaterials: ['marble', 'limestone', 'bronze', 'terracotta', 'wood'],
      subTypes: ['Statue', 'Bust', 'Relief', 'Figurine', 'Mask', 'Idol'],
    ),
    ArtifactType(
      id: 'inscription',
      name: 'Inscriptions & Writing',
      description: 'Tablets, scrolls, and written records',
      icon: Icons.history_edu,
      color: Color(0xFF2F4F4F),
      commonMaterials: ['clay', 'stone', 'papyrus', 'parchment', 'metal'],
      subTypes: ['Tablet', 'Stele', 'Seal', 'Ostracon', 'Scroll', 'Inscription'],
    ),
    ArtifactType(
      id: 'architecture',
      name: 'Architectural Elements',
      description: 'Building components and structural remains',
      icon: Icons.domain,
      color: Color(0xFF696969),
      commonMaterials: ['stone', 'marble', 'brick', 'wood', 'plaster'],
      subTypes: ['Column', 'Capital', 'Frieze', 'Mosaic', 'Floor tile', 'Wall fragment'],
    ),
    ArtifactType(
      id: 'bone',
      name: 'Bone & Organic',
      description: 'Human, animal, or plant remains',
      icon: Icons.pets,
      color: Color(0xFFFFFAF0),
      commonMaterials: ['bone', 'ivory', 'shell', 'wood', 'textile'],
      subTypes: ['Human bone', 'Animal bone', 'Shell', 'Seed', 'Textile', 'Leather'],
    ),
    ArtifactType(
      id: 'glass',
      name: 'Glass & Faience',
      description: 'Glass vessels and faience objects',
      icon: Icons.wine_bar,
      color: Color(0xFF00CED1),
      commonMaterials: ['glass', 'faience'],
      subTypes: ['Vessel', 'Bead', 'Window', 'Mirror', 'Amulet'],
    ),
    ArtifactType(
      id: 'religious',
      name: 'Religious & Ritual',
      description: 'Objects used in religious or ceremonial contexts',
      icon: Icons.temple_hindu,
      color: Color(0xFF9932CC),
      commonMaterials: ['stone', 'bronze', 'gold', 'ceramic'],
      subTypes: ['Altar', 'Offering', 'Amulet', 'Incense burner', 'Votive', 'Shrine'],
    ),
    ArtifactType(
      id: 'domestic',
      name: 'Domestic Objects',
      description: 'Everyday household items',
      icon: Icons.home,
      color: Color(0xFFA0522D),
      commonMaterials: ['ceramic', 'stone', 'metal', 'wood'],
      subTypes: ['Lamp', 'Key', 'Lock', 'Weight', 'Spindle', 'Loom weight', 'Mortar'],
    ),
    ArtifactType(
      id: 'unknown',
      name: 'Unknown/Unidentified',
      description: 'Artifacts requiring further analysis',
      icon: Icons.help_outline,
      color: Color(0xFF808080),
      commonMaterials: [],
      subTypes: ['Fragment', 'Object', 'Sample'],
    ),
  ];

  // ========== MATERIALS ==========
  static const List<ArtifactMaterial> materials = [
    ArtifactMaterial(
      id: 'ceramic',
      name: 'Ceramic/Pottery',
      description: 'Fired clay objects',
      color: Color(0xFFD2691E),
      preservationTips: ['Handle with care', 'Store in padded containers', 'Avoid water exposure'],
    ),
    ArtifactMaterial(
      id: 'stone',
      name: 'Stone',
      description: 'Various stone types including granite, basalt, sandstone',
      color: Color(0xFF696969),
      preservationTips: ['Clean with soft brush', 'Avoid chemical cleaners'],
    ),
    ArtifactMaterial(
      id: 'marble',
      name: 'Marble',
      description: 'Metamorphic rock used for sculpture and architecture',
      color: Color(0xFFFFFAFA),
      preservationTips: ['Avoid acids', 'Handle with gloves', 'Store in stable temperature'],
    ),
    ArtifactMaterial(
      id: 'bronze',
      name: 'Bronze',
      description: 'Copper-tin alloy, common in ancient metalwork',
      color: Color(0xFFCD7F32),
      preservationTips: ['Avoid moisture', 'Document patina before cleaning', 'Store in low humidity'],
    ),
    ArtifactMaterial(
      id: 'iron',
      name: 'Iron',
      description: 'Ferrous metal, prone to corrosion',
      color: Color(0xFF434343),
      preservationTips: ['Keep dry', 'Apply conservation wax', 'Store in desiccated environment'],
    ),
    ArtifactMaterial(
      id: 'gold',
      name: 'Gold',
      description: 'Precious metal, highly resistant to corrosion',
      color: Color(0xFFFFD700),
      preservationTips: ['Handle with gloves', 'Store separately', 'Document weight precisely'],
    ),
    ArtifactMaterial(
      id: 'silver',
      name: 'Silver',
      description: 'Precious metal, prone to tarnishing',
      color: Color(0xFFC0C0C0),
      preservationTips: ['Store in anti-tarnish cloth', 'Document before cleaning', 'Avoid sulfur exposure'],
    ),
    ArtifactMaterial(
      id: 'copper',
      name: 'Copper',
      description: 'Soft metal, develops green patina',
      color: Color(0xFFB87333),
      preservationTips: ['Document corrosion state', 'Handle minimally', 'Store dry'],
    ),
    ArtifactMaterial(
      id: 'bone',
      name: 'Bone/Ivory',
      description: 'Organic material from animals',
      color: Color(0xFFFFFAF0),
      preservationTips: ['Keep humidity stable', 'Avoid light exposure', 'Handle minimally'],
    ),
    ArtifactMaterial(
      id: 'glass',
      name: 'Glass',
      description: 'Silica-based transparent material',
      color: Color(0xFF87CEEB),
      preservationTips: ['Handle with extreme care', 'Store individually padded', 'Avoid temperature changes'],
    ),
    ArtifactMaterial(
      id: 'wood',
      name: 'Wood',
      description: 'Organic plant material, rare in archaeological record',
      color: Color(0xFF8B4513),
      preservationTips: ['Keep wet if found wet', 'Freeze-dry for preservation', 'Document immediately'],
    ),
    ArtifactMaterial(
      id: 'textile',
      name: 'Textile/Fabric',
      description: 'Woven or felted fibers',
      color: Color(0xFFDEB887),
      preservationTips: ['Handle minimally', 'Store flat', 'Control humidity', 'Avoid light'],
    ),
    ArtifactMaterial(
      id: 'leather',
      name: 'Leather',
      description: 'Tanned animal hide',
      color: Color(0xFF8B4513),
      preservationTips: ['Keep humidity stable', 'Apply conservation treatment', 'Store flat'],
    ),
    ArtifactMaterial(
      id: 'shell',
      name: 'Shell',
      description: 'Mollusk shells used for tools or ornaments',
      color: Color(0xFFFFF5EE),
      preservationTips: ['Handle carefully', 'Store padded', 'Document species if possible'],
    ),
    ArtifactMaterial(
      id: 'flint',
      name: 'Flint/Obsidian',
      description: 'Knappable stone for tool making',
      color: Color(0xFF2F4F4F),
      preservationTips: ['Handle with care (sharp edges)', 'Document use-wear', 'Store individually'],
    ),
    ArtifactMaterial(
      id: 'plaster',
      name: 'Plaster/Stucco',
      description: 'Gypsum-based building material',
      color: Color(0xFFFFFFF0),
      preservationTips: ['Consolidate if friable', 'Avoid water', 'Document paint traces'],
    ),
    ArtifactMaterial(
      id: 'other',
      name: 'Other/Unknown',
      description: 'Material requiring analysis',
      color: Color(0xFF808080),
      preservationTips: ['Document thoroughly', 'Sample for analysis', 'Consult specialist'],
    ),
  ];

  // ========== HISTORICAL PERIODS ==========
  static const List<HistoricalPeriod> periods = [
    HistoricalPeriod(
      id: 'paleolithic',
      name: 'Paleolithic',
      description: 'Old Stone Age - earliest human tools',
      startYear: -3300000,
      endYear: -10000,
      color: Color(0xFF8B4513),
    ),
    HistoricalPeriod(
      id: 'mesolithic',
      name: 'Mesolithic',
      description: 'Middle Stone Age - transition period',
      startYear: -10000,
      endYear: -8000,
      color: Color(0xFFA0522D),
    ),
    HistoricalPeriod(
      id: 'neolithic',
      name: 'Neolithic',
      description: 'New Stone Age - agriculture begins',
      startYear: -8000,
      endYear: -3000,
      color: Color(0xFF6B8E23),
    ),
    HistoricalPeriod(
      id: 'bronze_early',
      name: 'Early Bronze Age',
      description: 'Beginning of metalworking',
      startYear: -3000,
      endYear: -2000,
      color: Color(0xFFCD853F),
    ),
    HistoricalPeriod(
      id: 'bronze_middle',
      name: 'Middle Bronze Age',
      description: 'Development of bronze technology',
      startYear: -2000,
      endYear: -1600,
      color: Color(0xFFD2691E),
    ),
    HistoricalPeriod(
      id: 'bronze_late',
      name: 'Late Bronze Age',
      description: 'Peak of Bronze Age civilizations',
      startYear: -1600,
      endYear: -1200,
      color: Color(0xFFB8860B),
    ),
    HistoricalPeriod(
      id: 'iron_early',
      name: 'Early Iron Age',
      description: 'Iron replaces bronze',
      startYear: -1200,
      endYear: -800,
      color: Color(0xFF4682B4),
    ),
    HistoricalPeriod(
      id: 'archaic',
      name: 'Archaic Period',
      description: 'Rise of Greek city-states',
      startYear: -800,
      endYear: -480,
      color: Color(0xFF6495ED),
    ),
    HistoricalPeriod(
      id: 'classical',
      name: 'Classical Period',
      description: 'Golden age of Greece',
      startYear: -480,
      endYear: -323,
      color: Color(0xFF4169E1),
    ),
    HistoricalPeriod(
      id: 'hellenistic',
      name: 'Hellenistic Period',
      description: 'Spread of Greek culture',
      startYear: -323,
      endYear: -31,
      color: Color(0xFF9370DB),
    ),
    HistoricalPeriod(
      id: 'roman_republic',
      name: 'Roman Republic',
      description: 'Rise of Rome',
      startYear: -509,
      endYear: -27,
      color: Color(0xFFDC143C),
    ),
    HistoricalPeriod(
      id: 'roman_empire',
      name: 'Roman Empire',
      description: 'Height of Roman power',
      startYear: -27,
      endYear: 476,
      color: Color(0xFF8B0000),
    ),
    HistoricalPeriod(
      id: 'byzantine',
      name: 'Byzantine Period',
      description: 'Eastern Roman Empire',
      startYear: 330,
      endYear: 1453,
      color: Color(0xFF800080),
    ),
    HistoricalPeriod(
      id: 'medieval',
      name: 'Medieval Period',
      description: 'Middle Ages in Europe',
      startYear: 500,
      endYear: 1500,
      color: Color(0xFF2F4F4F),
    ),
    HistoricalPeriod(
      id: 'ottoman',
      name: 'Ottoman Period',
      description: 'Ottoman Empire era',
      startYear: 1299,
      endYear: 1922,
      color: Color(0xFFB22222),
    ),
    HistoricalPeriod(
      id: 'modern',
      name: 'Modern Period',
      description: 'Recent historical period',
      startYear: 1500,
      endYear: 1900,
      color: Color(0xFF708090),
    ),
    HistoricalPeriod(
      id: 'unknown',
      name: 'Unknown/Undated',
      description: 'Period not yet determined',
      startYear: 0,
      endYear: 0,
      color: Color(0xFF808080),
    ),
  ];

  // ========== CONDITIONS ==========
  static const List<ArtifactCondition> conditions = [
    ArtifactCondition(
      id: 'excellent',
      name: 'Excellent',
      description: 'Complete, minimal wear or damage',
      color: Color(0xFF228B22),
      severity: 1,
    ),
    ArtifactCondition(
      id: 'good',
      name: 'Good',
      description: 'Largely intact with minor damage',
      color: Color(0xFF32CD32),
      severity: 2,
    ),
    ArtifactCondition(
      id: 'fair',
      name: 'Fair',
      description: 'Moderate damage or wear, still identifiable',
      color: Color(0xFFFFD700),
      severity: 3,
    ),
    ArtifactCondition(
      id: 'poor',
      name: 'Poor',
      description: 'Significant damage, fragmentary',
      color: Color(0xFFFF8C00),
      severity: 4,
    ),
    ArtifactCondition(
      id: 'fragmentary',
      name: 'Fragmentary',
      description: 'Only fragments survive',
      color: Color(0xFFFF4500),
      severity: 5,
    ),
  ];

  // ========== HELPER METHODS ==========

  /// Get artifact type by ID
  static ArtifactType? getTypeById(String id) {
    try {
      return artifactTypes.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get material by ID
  static ArtifactMaterial? getMaterialById(String id) {
    try {
      return materials.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get period by ID
  static HistoricalPeriod? getPeriodById(String id) {
    try {
      return periods.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get condition by ID
  static ArtifactCondition? getConditionById(String id) {
    try {
      return conditions.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get all artifact type names
  static List<String> get typeNames => artifactTypes.map((t) => t.name).toList();

  /// Get all material names
  static List<String> get materialNames => materials.map((m) => m.name).toList();

  /// Get all period names
  static List<String> get periodNames => periods.map((p) => p.name).toList();

  /// Get all condition names
  static List<String> get conditionNames => conditions.map((c) => c.name).toList();

  /// Search types by name
  static List<ArtifactType> searchTypes(String query) {
    final lowerQuery = query.toLowerCase();
    return artifactTypes.where((t) =>
        t.name.toLowerCase().contains(lowerQuery) ||
        t.description.toLowerCase().contains(lowerQuery) ||
        t.subTypes.any((s) => s.toLowerCase().contains(lowerQuery))).toList();
  }

  /// Get periods that include a given year
  static List<HistoricalPeriod> getPeriodsForYear(int year) {
    return periods.where((p) =>
        p.id != 'unknown' && year >= p.startYear && year <= p.endYear).toList();
  }

  /// Export full classification to JSON (for backup/sharing)
  static Map<String, dynamic> exportToJson() {
    return {
      'artifactTypes': artifactTypes.map((t) => t.toJson()).toList(),
      'materials': materials.map((m) => m.toJson()).toList(),
      'periods': periods.map((p) => p.toJson()).toList(),
      'conditions': conditions.map((c) => c.toJson()).toList(),
      'exportedAt': DateTime.now().toIso8601String(),
      'version': '1.0',
    };
  }
}

/// Extended finding metadata using classification
class ArtifactMetadata {
  final String? typeId;
  final String? subType;
  final String? materialId;
  final String? periodId;
  final String? conditionId;
  final Map<String, double>? dimensions; // width, height, depth, weight
  final String? recoveryMethod;
  final String? conservationNotes;
  final List<String>? associatedFindings;
  final String? stratigraphicContext;

  // ========== COIN-SPECIFIC FIELDS ==========
  final String? denomination;      // Drachma, Obol, Denarius, As, etc.
  final String? mint;              // Minting location
  final String? ruler;             // Issuing authority/emperor
  final String? obverseLegend;     // Front inscription text
  final String? reverseLegend;     // Back inscription text
  final int? dieAxis;              // Clock position (1-12)
  final String? obverseDescription; // What's depicted on front
  final String? reverseDescription; // What's depicted on back

  // ========== FRAGMENT-SPECIFIC FIELDS ==========
  final String? vesselPart;        // rim, body, base, handle, spout, lid, foot
  final String? wareType;          // coarse, fine, cooking, storage, tableware
  final String? decorationStyle;   // plain, painted, incised, stamped, glazed
  final String? fabricColorInt;    // Interior Munsell color
  final String? fabricColorExt;    // Exterior Munsell color
  final double? rimDiameter;       // Estimated rim diameter in mm
  final double? wallThickness;     // Sherd thickness in mm
  final String? surfaceTreatment;  // slip, burnish, glaze, etc.

  ArtifactMetadata({
    this.typeId,
    this.subType,
    this.materialId,
    this.periodId,
    this.conditionId,
    this.dimensions,
    this.recoveryMethod,
    this.conservationNotes,
    this.associatedFindings,
    this.stratigraphicContext,
    // Coin fields
    this.denomination,
    this.mint,
    this.ruler,
    this.obverseLegend,
    this.reverseLegend,
    this.dieAxis,
    this.obverseDescription,
    this.reverseDescription,
    // Fragment fields
    this.vesselPart,
    this.wareType,
    this.decorationStyle,
    this.fabricColorInt,
    this.fabricColorExt,
    this.rimDiameter,
    this.wallThickness,
    this.surfaceTreatment,
  });

  ArtifactType? get type => ArtifactClassification.getTypeById(typeId ?? '');
  ArtifactMaterial? get material => ArtifactClassification.getMaterialById(materialId ?? '');
  HistoricalPeriod? get period => ArtifactClassification.getPeriodById(periodId ?? '');
  ArtifactCondition? get condition => ArtifactClassification.getConditionById(conditionId ?? '');

  /// Check if this is a coin type
  bool get isCoin => typeId == 'coins';

  /// Check if this is a fragment/sherd type
  bool get isFragment => typeId == 'fragments';

  Map<String, dynamic> toJson() => {
        'typeId': typeId,
        'subType': subType,
        'materialId': materialId,
        'periodId': periodId,
        'conditionId': conditionId,
        'dimensions': dimensions,
        'recoveryMethod': recoveryMethod,
        'conservationNotes': conservationNotes,
        'associatedFindings': associatedFindings,
        'stratigraphicContext': stratigraphicContext,
        // Coin fields
        'denomination': denomination,
        'mint': mint,
        'ruler': ruler,
        'obverseLegend': obverseLegend,
        'reverseLegend': reverseLegend,
        'dieAxis': dieAxis,
        'obverseDescription': obverseDescription,
        'reverseDescription': reverseDescription,
        // Fragment fields
        'vesselPart': vesselPart,
        'wareType': wareType,
        'decorationStyle': decorationStyle,
        'fabricColorInt': fabricColorInt,
        'fabricColorExt': fabricColorExt,
        'rimDiameter': rimDiameter,
        'wallThickness': wallThickness,
        'surfaceTreatment': surfaceTreatment,
      };

  factory ArtifactMetadata.fromJson(Map<String, dynamic> json) => ArtifactMetadata(
        typeId: json['typeId'],
        subType: json['subType'],
        materialId: json['materialId'],
        periodId: json['periodId'],
        conditionId: json['conditionId'],
        dimensions: json['dimensions'] != null
            ? Map<String, double>.from(json['dimensions'])
            : null,
        recoveryMethod: json['recoveryMethod'],
        conservationNotes: json['conservationNotes'],
        associatedFindings: json['associatedFindings'] != null
            ? List<String>.from(json['associatedFindings'])
            : null,
        stratigraphicContext: json['stratigraphicContext'],
        // Coin fields
        denomination: json['denomination'],
        mint: json['mint'],
        ruler: json['ruler'],
        obverseLegend: json['obverseLegend'],
        reverseLegend: json['reverseLegend'],
        dieAxis: json['dieAxis'],
        obverseDescription: json['obverseDescription'],
        reverseDescription: json['reverseDescription'],
        // Fragment fields
        vesselPart: json['vesselPart'],
        wareType: json['wareType'],
        decorationStyle: json['decorationStyle'],
        fabricColorInt: json['fabricColorInt'],
        fabricColorExt: json['fabricColorExt'],
        rimDiameter: json['rimDiameter']?.toDouble(),
        wallThickness: json['wallThickness']?.toDouble(),
        surfaceTreatment: json['surfaceTreatment'],
      );
}

// ========== COIN DENOMINATION OPTIONS ==========
class CoinDenominations {
  static const List<String> greek = [
    'Drachma', 'Didrachm', 'Tetradrachm', 'Obol', 'Hemiobol',
    'Triobol', 'Stater', 'Hemidrachm',
  ];

  static const List<String> roman = [
    'Denarius', 'As', 'Sestertius', 'Dupondius', 'Quadrans',
    'Aureus', 'Antoninianus', 'Follis', 'Solidus',
  ];

  static const List<String> byzantine = [
    'Solidus', 'Semissis', 'Tremissis', 'Follis', 'Nummus',
  ];

  static const List<String> all = [
    ...greek, ...roman, ...byzantine, 'Unknown',
  ];
}

// ========== FRAGMENT VESSEL PART OPTIONS ==========
class VesselParts {
  static const List<String> parts = [
    'Rim', 'Body', 'Base', 'Handle', 'Spout', 'Lid', 'Foot',
    'Neck', 'Shoulder', 'Lug', 'Knob',
  ];
}

// ========== WARE TYPE OPTIONS ==========
class WareTypes {
  static const List<String> types = [
    'Coarse Ware', 'Fine Ware', 'Cooking Ware', 'Storage Ware',
    'Tableware', 'Transport (Amphora)', 'Ritual Ware', 'Unknown',
  ];
}

// ========== DECORATION STYLE OPTIONS ==========
class DecorationStyles {
  static const List<String> styles = [
    'Plain', 'Painted', 'Incised', 'Stamped', 'Glazed',
    'Relief', 'Appliqué', 'Burnished', 'Combed', 'Slipped',
  ];
}
