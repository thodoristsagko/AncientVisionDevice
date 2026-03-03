import 'package:flutter/material.dart';

/// Units of measurement
enum MeasurementUnit {
  millimeters('mm', 'Millimeters', 1.0),
  centimeters('cm', 'Centimeters', 10.0),
  meters('m', 'Meters', 1000.0),
  inches('in', 'Inches', 25.4),
  feet('ft', 'Feet', 304.8),
  grams('g', 'Grams', 1.0),
  kilograms('kg', 'Kilograms', 1000.0),
  pounds('lb', 'Pounds', 453.592);

  final String symbol;
  final String label;
  final double toMmOrGrams; // Conversion factor to base unit

  const MeasurementUnit(this.symbol, this.label, this.toMmOrGrams);
}

/// Type of measurement
enum MeasurementType {
  length('Length', Icons.straighten, Color(0xFF4682B4)),
  width('Width', Icons.swap_horiz, Color(0xFF32CD32)),
  height('Height', Icons.height, Color(0xFFFFD700)),
  depth('Depth', Icons.vertical_align_bottom, Color(0xFF8B4513)),
  thickness('Thickness', Icons.layers, Color(0xFF9370DB)),
  diameter('Diameter', Icons.radio_button_unchecked, Color(0xFF00CED1)),
  circumference('Circumference', Icons.change_history, Color(0xFFFF69B4)),
  weight('Weight', Icons.scale, Color(0xFFDC143C)),
  volume('Volume', Icons.view_in_ar, Color(0xFF2F4F4F)),
  area('Area', Icons.crop_square, Color(0xFF6B8E23)),
  other('Other', Icons.straighten, Color(0xFF808080));

  final String label;
  final IconData icon;
  final Color color;

  const MeasurementType(this.label, this.icon, this.color);
}

/// A single measurement record
class Measurement {
  final String id;
  final String? findingId;
  final String? siteId;
  final MeasurementType type;
  final double value;
  final MeasurementUnit unit;
  final double? uncertainty; // +/- error margin
  final DateTime measuredAt;
  final String? measuredBy;
  final String? tool; // Caliper, ruler, scale, etc.
  final String? notes;
  final bool isEstimate;

  Measurement({
    required this.id,
    this.findingId,
    this.siteId,
    required this.type,
    required this.value,
    required this.unit,
    this.uncertainty,
    DateTime? measuredAt,
    this.measuredBy,
    this.tool,
    this.notes,
    this.isEstimate = false,
  }) : measuredAt = measuredAt ?? DateTime.now();

  /// Get formatted value string
  String get valueString {
    String result = value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2);
    result += ' ${unit.symbol}';
    if (uncertainty != null) {
      result += ' ±${uncertainty!.toStringAsFixed(1)}';
    }
    if (isEstimate) {
      result += ' (est.)';
    }
    return result;
  }

  /// Convert to different unit
  double convertTo(MeasurementUnit targetUnit) {
    // First convert to base unit (mm or g)
    final baseValue = value * unit.toMmOrGrams;
    // Then convert to target unit
    return baseValue / targetUnit.toMmOrGrams;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'findingId': findingId,
        'siteId': siteId,
        'type': type.name,
        'value': value,
        'unit': unit.name,
        'uncertainty': uncertainty,
        'measuredAt': measuredAt.toIso8601String(),
        'measuredBy': measuredBy,
        'tool': tool,
        'notes': notes,
        'isEstimate': isEstimate,
      };

  factory Measurement.fromJson(Map<String, dynamic> json) => Measurement(
        id: json['id'],
        findingId: json['findingId'],
        siteId: json['siteId'],
        type: MeasurementType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => MeasurementType.other,
        ),
        value: (json['value'] as num).toDouble(),
        unit: MeasurementUnit.values.firstWhere(
          (u) => u.name == json['unit'],
          orElse: () => MeasurementUnit.centimeters,
        ),
        uncertainty: json['uncertainty']?.toDouble(),
        measuredAt: DateTime.parse(json['measuredAt']),
        measuredBy: json['measuredBy'],
        tool: json['tool'],
        notes: json['notes'],
        isEstimate: json['isEstimate'] ?? false,
      );
}

/// Complete dimensions set for an artifact
class ArtifactDimensions {
  final Measurement? length;
  final Measurement? width;
  final Measurement? height;
  final Measurement? depth;
  final Measurement? thickness;
  final Measurement? diameter;
  final Measurement? weight;
  final List<Measurement>? additionalMeasurements;

  ArtifactDimensions({
    this.length,
    this.width,
    this.height,
    this.depth,
    this.thickness,
    this.diameter,
    this.weight,
    this.additionalMeasurements,
  });

  /// Get all non-null measurements
  List<Measurement> get allMeasurements {
    final list = <Measurement>[];
    if (length != null) list.add(length!);
    if (width != null) list.add(width!);
    if (height != null) list.add(height!);
    if (depth != null) list.add(depth!);
    if (thickness != null) list.add(thickness!);
    if (diameter != null) list.add(diameter!);
    if (weight != null) list.add(weight!);
    if (additionalMeasurements != null) list.addAll(additionalMeasurements!);
    return list;
  }

  /// Get formatted dimensions string
  String get dimensionsString {
    final parts = <String>[];
    if (length != null) parts.add('L: ${length!.valueString}');
    if (width != null) parts.add('W: ${width!.valueString}');
    if (height != null) parts.add('H: ${height!.valueString}');
    if (diameter != null) parts.add('D: ${diameter!.valueString}');
    if (weight != null) parts.add('Wt: ${weight!.valueString}');
    return parts.join(' × ');
  }

  Map<String, dynamic> toJson() => {
        'length': length?.toJson(),
        'width': width?.toJson(),
        'height': height?.toJson(),
        'depth': depth?.toJson(),
        'thickness': thickness?.toJson(),
        'diameter': diameter?.toJson(),
        'weight': weight?.toJson(),
        'additionalMeasurements':
            additionalMeasurements?.map((m) => m.toJson()).toList(),
      };

  factory ArtifactDimensions.fromJson(Map<String, dynamic> json) =>
      ArtifactDimensions(
        length: json['length'] != null
            ? Measurement.fromJson(json['length'])
            : null,
        width:
            json['width'] != null ? Measurement.fromJson(json['width']) : null,
        height: json['height'] != null
            ? Measurement.fromJson(json['height'])
            : null,
        depth:
            json['depth'] != null ? Measurement.fromJson(json['depth']) : null,
        thickness: json['thickness'] != null
            ? Measurement.fromJson(json['thickness'])
            : null,
        diameter: json['diameter'] != null
            ? Measurement.fromJson(json['diameter'])
            : null,
        weight: json['weight'] != null
            ? Measurement.fromJson(json['weight'])
            : null,
        additionalMeasurements: json['additionalMeasurements'] != null
            ? (json['additionalMeasurements'] as List)
                .map((m) => Measurement.fromJson(m))
                .toList()
            : null,
      );
}
