import 'package:flutter/material.dart';

/// Context types for archaeological stratigraphy
enum ContextType {
  deposit('Deposit', Icons.layers, Color(0xFF8B4513), 'Natural or cultural accumulation'),
  cut('Cut', Icons.content_cut, Color(0xFFDC143C), 'Negative feature (pit, ditch, etc.)'),
  fill('Fill', Icons.format_color_fill, Color(0xFF4682B4), 'Material filling a cut'),
  structure('Structure', Icons.account_balance, Color(0xFF696969), 'Built feature (wall, floor, etc.)'),
  surface('Surface', Icons.landscape, Color(0xFF228B22), 'Occupation or activity surface'),
  natural('Natural', Icons.grass, Color(0xFF6B8E23), 'Natural geological layer'),
  other('Other', Icons.layers, Color(0xFF808080), 'Other context type');

  final String label;
  final IconData icon;
  final Color color;
  final String description;

  const ContextType(this.label, this.icon, this.color, this.description);
}

/// Soil composition types
enum SoilType {
  clay('Clay', Color(0xFFA0522D)),
  silt('Silt', Color(0xFFD2B48C)),
  sand('Sand', Color(0xFFF4A460)),
  gravel('Gravel', Color(0xFF808080)),
  loam('Loam', Color(0xFF8B4513)),
  peat('Peat', Color(0xFF2F4F4F)),
  chalk('Chalk', Color(0xFFFFFFF0)),
  rock('Rock/Bedrock', Color(0xFF696969)),
  mixed('Mixed', Color(0xFFBC8F8F)),
  other('Other', Color(0xFF808080));

  final String label;
  final Color color;

  const SoilType(this.label, this.color);
}

/// Munsell soil color (simplified)
class SoilColor {
  final String hue; // e.g., "10YR"
  final String value; // e.g., "4"
  final String chroma; // e.g., "3"
  final String name; // e.g., "Dark yellowish brown"

  const SoilColor({
    required this.hue,
    required this.value,
    required this.chroma,
    required this.name,
  });

  String get munsellCode => '$hue $value/$chroma';

  Map<String, dynamic> toJson() => {
        'hue': hue,
        'value': value,
        'chroma': chroma,
        'name': name,
      };

  factory SoilColor.fromJson(Map<String, dynamic> json) => SoilColor(
        hue: json['hue'],
        value: json['value'],
        chroma: json['chroma'],
        name: json['name'],
      );

  /// Common Munsell colors for quick selection
  static const List<SoilColor> commonColors = [
    SoilColor(hue: '10YR', value: '2', chroma: '1', name: 'Black'),
    SoilColor(hue: '10YR', value: '3', chroma: '1', name: 'Very dark gray'),
    SoilColor(hue: '10YR', value: '4', chroma: '1', name: 'Dark gray'),
    SoilColor(hue: '10YR', value: '5', chroma: '1', name: 'Gray'),
    SoilColor(hue: '10YR', value: '3', chroma: '2', name: 'Very dark grayish brown'),
    SoilColor(hue: '10YR', value: '4', chroma: '2', name: 'Dark grayish brown'),
    SoilColor(hue: '10YR', value: '4', chroma: '3', name: 'Brown'),
    SoilColor(hue: '10YR', value: '5', chroma: '3', name: 'Brown'),
    SoilColor(hue: '10YR', value: '5', chroma: '4', name: 'Yellowish brown'),
    SoilColor(hue: '10YR', value: '6', chroma: '4', name: 'Light yellowish brown'),
    SoilColor(hue: '7.5YR', value: '4', chroma: '4', name: 'Brown'),
    SoilColor(hue: '7.5YR', value: '5', chroma: '6', name: 'Strong brown'),
    SoilColor(hue: '5YR', value: '4', chroma: '6', name: 'Yellowish red'),
    SoilColor(hue: '2.5YR', value: '4', chroma: '6', name: 'Red'),
    SoilColor(hue: '10YR', value: '7', chroma: '3', name: 'Very pale brown'),
    SoilColor(hue: '10YR', value: '8', chroma: '2', name: 'Very pale brown'),
  ];
}

/// Inclusion types found in deposits
enum InclusionType {
  charcoal('Charcoal', Icons.local_fire_department),
  pottery('Pottery sherds', Icons.local_cafe),
  bone('Bone fragments', Icons.pets),
  shell('Shell', Icons.water),
  stone('Stone', Icons.terrain),
  metal('Metal', Icons.hardware),
  glass('Glass', Icons.wine_bar),
  tile('Tile/Brick', Icons.grid_view),
  mortar('Mortar/Plaster', Icons.format_paint),
  organic('Organic material', Icons.eco),
  cbm('CBM (ceramic building material)', Icons.roofing),
  flint('Worked flint', Icons.change_history),
  other('Other', Icons.more_horiz);

  final String label;
  final IconData icon;

  const InclusionType(this.label, this.icon);
}

/// Compaction level
enum Compaction {
  loose('Loose', 1),
  soft('Soft', 2),
  firm('Firm', 3),
  hard('Hard', 4),
  cemented('Cemented', 5);

  final String label;
  final int level;

  const Compaction(this.label, this.level);
}

/// An inclusion found within a context
class Inclusion {
  final InclusionType type;
  final String frequency; // rare, occasional, moderate, frequent, abundant
  final String? size; // small, medium, large
  final String? notes;

  Inclusion({
    required this.type,
    required this.frequency,
    this.size,
    this.notes,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'frequency': frequency,
        'size': size,
        'notes': notes,
      };

  factory Inclusion.fromJson(Map<String, dynamic> json) => Inclusion(
        type: InclusionType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => InclusionType.other,
        ),
        frequency: json['frequency'],
        size: json['size'],
        notes: json['notes'],
      );
}

/// Complete context sheet record
class ContextSheet {
  final String id;
  final String contextNumber; // e.g., "001", "102"
  final String? siteId;
  final String? trenchId;
  final ContextType type;
  final String? interpretation;
  final String? description;

  // Stratigraphic relationships
  final List<String>? above; // Context numbers this is above
  final List<String>? below; // Context numbers this is below
  final List<String>? sameas; // Same as (equivalent contexts)
  final List<String>? cuts; // Contexts this cuts
  final List<String>? cutBy; // Contexts this is cut by
  final List<String>? filledBy; // Fills in this cut
  final List<String>? fills; // Cut that this fills

  // Physical description
  final SoilType? soilType;
  final SoilColor? soilColor;
  final Compaction? compaction;
  final String? texture; // e.g., "fine", "coarse"
  final List<Inclusion>? inclusions;

  // Dimensions
  final double? lengthCm;
  final double? widthCm;
  final double? depthCm;
  final double? thickness;

  // Elevations (in meters, relative to site datum)
  final double? topElevation;
  final double? bottomElevation;

  // Recording info
  final DateTime recordedAt;
  final String? recordedBy;
  final DateTime? excavatedAt;
  final String? excavatedBy;

  // Sampling
  final bool soilSampleTaken;
  final bool flotationSampleTaken;
  final bool carbonSampleTaken;
  final String? sampleNotes;

  // Finds
  final List<String>? findingIds;
  final int? potterySherds;
  final int? boneFragments;
  final int? otherFinds;

  // Photos and drawings
  final List<String>? photoIds;
  final List<String>? drawingIds;
  final String? planNumber;
  final String? sectionNumber;

  // Notes
  final String? notes;
  final Map<String, dynamic>? metadata;

  // Status
  final bool isComplete;
  final bool needsReview;

  ContextSheet({
    required this.id,
    required this.contextNumber,
    this.siteId,
    this.trenchId,
    required this.type,
    this.interpretation,
    this.description,
    this.above,
    this.below,
    this.sameas,
    this.cuts,
    this.cutBy,
    this.filledBy,
    this.fills,
    this.soilType,
    this.soilColor,
    this.compaction,
    this.texture,
    this.inclusions,
    this.lengthCm,
    this.widthCm,
    this.depthCm,
    this.thickness,
    this.topElevation,
    this.bottomElevation,
    DateTime? recordedAt,
    this.recordedBy,
    this.excavatedAt,
    this.excavatedBy,
    this.soilSampleTaken = false,
    this.flotationSampleTaken = false,
    this.carbonSampleTaken = false,
    this.sampleNotes,
    this.findingIds,
    this.potterySherds,
    this.boneFragments,
    this.otherFinds,
    this.photoIds,
    this.drawingIds,
    this.planNumber,
    this.sectionNumber,
    this.notes,
    this.metadata,
    this.isComplete = false,
    this.needsReview = true,
  }) : recordedAt = recordedAt ?? DateTime.now();

  /// Get depth range string
  String? get depthRange {
    if (topElevation == null && bottomElevation == null) return null;
    final top = topElevation?.toStringAsFixed(2) ?? '?';
    final bottom = bottomElevation?.toStringAsFixed(2) ?? '?';
    return '$top m to $bottom m';
  }

  /// Get dimensions string
  String? get dimensionsString {
    final parts = <String>[];
    if (lengthCm != null) parts.add('L: ${lengthCm}cm');
    if (widthCm != null) parts.add('W: ${widthCm}cm');
    if (depthCm != null) parts.add('D: ${depthCm}cm');
    return parts.isEmpty ? null : parts.join(' × ');
  }

  /// Check if has stratigraphic relationships
  bool get hasRelationships =>
      (above?.isNotEmpty ?? false) ||
      (below?.isNotEmpty ?? false) ||
      (cuts?.isNotEmpty ?? false) ||
      (cutBy?.isNotEmpty ?? false);

  /// Get total finds count
  int get totalFinds =>
      (potterySherds ?? 0) + (boneFragments ?? 0) + (otherFinds ?? 0);

  Map<String, dynamic> toJson() => {
        'id': id,
        'contextNumber': contextNumber,
        'siteId': siteId,
        'trenchId': trenchId,
        'type': type.name,
        'interpretation': interpretation,
        'description': description,
        'above': above,
        'below': below,
        'sameas': sameas,
        'cuts': cuts,
        'cutBy': cutBy,
        'filledBy': filledBy,
        'fills': fills,
        'soilType': soilType?.name,
        'soilColor': soilColor?.toJson(),
        'compaction': compaction?.name,
        'texture': texture,
        'inclusions': inclusions?.map((i) => i.toJson()).toList(),
        'lengthCm': lengthCm,
        'widthCm': widthCm,
        'depthCm': depthCm,
        'thickness': thickness,
        'topElevation': topElevation,
        'bottomElevation': bottomElevation,
        'recordedAt': recordedAt.toIso8601String(),
        'recordedBy': recordedBy,
        'excavatedAt': excavatedAt?.toIso8601String(),
        'excavatedBy': excavatedBy,
        'soilSampleTaken': soilSampleTaken,
        'flotationSampleTaken': flotationSampleTaken,
        'carbonSampleTaken': carbonSampleTaken,
        'sampleNotes': sampleNotes,
        'findingIds': findingIds,
        'potterySherds': potterySherds,
        'boneFragments': boneFragments,
        'otherFinds': otherFinds,
        'photoIds': photoIds,
        'drawingIds': drawingIds,
        'planNumber': planNumber,
        'sectionNumber': sectionNumber,
        'notes': notes,
        'metadata': metadata,
        'isComplete': isComplete,
        'needsReview': needsReview,
      };

  factory ContextSheet.fromJson(Map<String, dynamic> json) => ContextSheet(
        id: json['id'],
        contextNumber: json['contextNumber'],
        siteId: json['siteId'],
        trenchId: json['trenchId'],
        type: ContextType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => ContextType.other,
        ),
        interpretation: json['interpretation'],
        description: json['description'],
        above: json['above'] != null ? List<String>.from(json['above']) : null,
        below: json['below'] != null ? List<String>.from(json['below']) : null,
        sameas: json['sameas'] != null ? List<String>.from(json['sameas']) : null,
        cuts: json['cuts'] != null ? List<String>.from(json['cuts']) : null,
        cutBy: json['cutBy'] != null ? List<String>.from(json['cutBy']) : null,
        filledBy: json['filledBy'] != null ? List<String>.from(json['filledBy']) : null,
        fills: json['fills'] != null ? List<String>.from(json['fills']) : null,
        soilType: json['soilType'] != null
            ? SoilType.values.firstWhere((s) => s.name == json['soilType'], orElse: () => SoilType.other)
            : null,
        soilColor: json['soilColor'] != null ? SoilColor.fromJson(json['soilColor']) : null,
        compaction: json['compaction'] != null
            ? Compaction.values.firstWhere((c) => c.name == json['compaction'], orElse: () => Compaction.firm)
            : null,
        texture: json['texture'],
        inclusions: json['inclusions'] != null
            ? (json['inclusions'] as List).map((i) => Inclusion.fromJson(i)).toList()
            : null,
        lengthCm: json['lengthCm']?.toDouble(),
        widthCm: json['widthCm']?.toDouble(),
        depthCm: json['depthCm']?.toDouble(),
        thickness: json['thickness']?.toDouble(),
        topElevation: json['topElevation']?.toDouble(),
        bottomElevation: json['bottomElevation']?.toDouble(),
        recordedAt: DateTime.parse(json['recordedAt']),
        recordedBy: json['recordedBy'],
        excavatedAt: json['excavatedAt'] != null ? DateTime.parse(json['excavatedAt']) : null,
        excavatedBy: json['excavatedBy'],
        soilSampleTaken: json['soilSampleTaken'] ?? false,
        flotationSampleTaken: json['flotationSampleTaken'] ?? false,
        carbonSampleTaken: json['carbonSampleTaken'] ?? false,
        sampleNotes: json['sampleNotes'],
        findingIds: json['findingIds'] != null ? List<String>.from(json['findingIds']) : null,
        potterySherds: json['potterySherds'],
        boneFragments: json['boneFragments'],
        otherFinds: json['otherFinds'],
        photoIds: json['photoIds'] != null ? List<String>.from(json['photoIds']) : null,
        drawingIds: json['drawingIds'] != null ? List<String>.from(json['drawingIds']) : null,
        planNumber: json['planNumber'],
        sectionNumber: json['sectionNumber'],
        notes: json['notes'],
        metadata: json['metadata'],
        isComplete: json['isComplete'] ?? false,
        needsReview: json['needsReview'] ?? true,
      );
}

/// Harris Matrix relationship for stratigraphic visualization
class HarrisRelationship {
  final String fromContext;
  final String toContext;
  final String relationshipType; // 'above', 'cuts', 'same_as', 'fills'

  HarrisRelationship({
    required this.fromContext,
    required this.toContext,
    required this.relationshipType,
  });

  Map<String, dynamic> toJson() => {
        'from': fromContext,
        'to': toContext,
        'type': relationshipType,
      };
}
