import 'package:flutter/material.dart';

enum FindingSource {
  manual('Manual Entry', Icons.edit_note, Color(0xFFFFC107)),
  photo('Coin Recognition', Icons.auto_awesome, Color(0xFFFF9800)),
  quick('Quick Capture', Icons.flash_on, Color(0xFF2196F3));

  final String label;
  final IconData icon;
  final Color color;

  const FindingSource(this.label, this.icon, this.color);

  static FindingSource fromString(String? source) {
    switch (source?.toLowerCase()) {
      case 'photo':
      case 'photo_capture':
        return FindingSource.photo;
      case 'quick':
      case 'quick_capture':
        return FindingSource.quick;
      case 'manual':
      case 'manual_entry':
      default:
        return FindingSource.manual;
    }
  }
}

class Finding {
  final String id;
  final String name;
  final String type;
  final String site;
  final String date;
  final String description;
  final double latitude;
  final double longitude;
  final String? imageUrl;
  final List<String> photoGallery;
  final String? model3dUrl;
  final FindingSource source;

  // Coin-specific fields
  final String? denomination;
  final String? mint;
  final String? ruler;
  final String? obverseLegend;
  final String? reverseLegend;
  final int? dieAxis;
  final String? obverseDescription;
  final String? reverseDescription;

  // Fragment-specific fields
  final String? vesselPart;
  final String? wareType;
  final String? decorationStyle;
  final String? fabricColorInt;
  final String? fabricColorExt;
  final double? rimDiameter;
  final double? wallThickness;
  final String? surfaceTreatment;

  // Context fields
  final String? locusNumber;
  final String? soilType;
  final String? matrixDescription;
  final String? harrisPosition;
  final List<String>? associatedFeatures;
  final bool isSignificant;

  const Finding({
    required this.id,
    required this.name,
    required this.type,
    required this.site,
    required this.date,
    required this.description,
    required this.latitude,
    required this.longitude,
    this.imageUrl,
    this.photoGallery = const [],
    this.model3dUrl,
    this.source = FindingSource.manual,
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
    // Context fields
    this.locusNumber,
    this.soilType,
    this.matrixDescription,
    this.harrisPosition,
    this.associatedFeatures,
    this.isSignificant = false,
  });

  /// Check if this is a coin finding
  bool get isCoin => type.toLowerCase().contains('coin');

  /// Check if this is a fragment/sherd finding
  bool get isFragment => type.toLowerCase().contains('fragment') || type.toLowerCase().contains('sherd');

  // Get color based on finding type for map markers
  static Color getTypeColor(String type) {
    final typeLower = type.toLowerCase();
    if (typeLower.contains('pottery') || typeLower.contains('ceramic')) {
      return const Color(0xFFE57373); // Red
    } else if (typeLower.contains('coin') || typeLower.contains('metal')) {
      return const Color(0xFFFFD54F); // Gold
    } else if (typeLower.contains('statue') || typeLower.contains('sculpture')) {
      return const Color(0xFF81C784); // Green
    } else if (typeLower.contains('tool') || typeLower.contains('weapon')) {
      return const Color(0xFF64B5F6); // Blue
    } else if (typeLower.contains('bone') || typeLower.contains('fossil')) {
      return const Color(0xFFFFFFFF); // White
    } else if (typeLower.contains('jewelry') || typeLower.contains('ornament')) {
      return const Color(0xFFBA68C8); // Purple
    }
    return const Color(0xFFFFC107); // Default amber
  }
}
