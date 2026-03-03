import 'package:flutter/material.dart';

/// Site types for archaeological excavations
enum SiteType {
  excavation('Excavation', Icons.construction, Color(0xFF8B4513)),
  survey('Survey', Icons.explore, Color(0xFF4682B4)),
  rescue('Rescue Excavation', Icons.warning_amber, Color(0xFFFF8C00)),
  underwater('Underwater', Icons.water, Color(0xFF00CED1)),
  urban('Urban Archaeology', Icons.location_city, Color(0xFF696969)),
  landscape('Landscape', Icons.landscape, Color(0xFF228B22)),
  cemetery('Cemetery/Burial', Icons.account_balance, Color(0xFF2F4F4F)),
  settlement('Settlement', Icons.home, Color(0xFFA0522D)),
  sanctuary('Sanctuary/Temple', Icons.temple_hindu, Color(0xFF9932CC)),
  industrial('Industrial', Icons.factory, Color(0xFF434343)),
  other('Other', Icons.place, Color(0xFF808080));

  final String label;
  final IconData icon;
  final Color color;

  const SiteType(this.label, this.icon, this.color);
}

/// Represents an archaeological site
class Site {
  final String id;
  final String name;
  final String? description;
  final SiteType type;
  final double latitude;
  final double longitude;
  final double? areaSize; // in square meters
  final DateTime createdAt;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? director;
  final List<String> teamMembers;
  final String? permitNumber;
  final String? institution;
  final String? country;
  final String? region;
  final List<String>? periods; // historical periods represented
  final Map<String, dynamic>? metadata;
  final bool isActive;

  Site({
    required this.id,
    required this.name,
    this.description,
    required this.type,
    required this.latitude,
    required this.longitude,
    this.areaSize,
    DateTime? createdAt,
    this.startDate,
    this.endDate,
    this.director,
    this.teamMembers = const [],
    this.permitNumber,
    this.institution,
    this.country,
    this.region,
    this.periods,
    this.metadata,
    this.isActive = true,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Calculate duration of excavation
  int? get durationDays {
    if (startDate == null) return null;
    final end = endDate ?? DateTime.now();
    return end.difference(startDate!).inDays;
  }

  /// Get formatted location string
  String get locationString =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

  /// Get formatted area string
  String? get areaString {
    if (areaSize == null) return null;
    if (areaSize! >= 10000) {
      return '${(areaSize! / 10000).toStringAsFixed(2)} ha';
    }
    return '${areaSize!.toStringAsFixed(1)} m²';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'type': type.name,
        'latitude': latitude,
        'longitude': longitude,
        'areaSize': areaSize,
        'createdAt': createdAt.toIso8601String(),
        'startDate': startDate?.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'director': director,
        'teamMembers': teamMembers,
        'permitNumber': permitNumber,
        'institution': institution,
        'country': country,
        'region': region,
        'periods': periods,
        'metadata': metadata,
        'isActive': isActive,
      };

  factory Site.fromJson(Map<String, dynamic> json) => Site(
        id: json['id'],
        name: json['name'],
        description: json['description'],
        type: SiteType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => SiteType.other,
        ),
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        areaSize: json['areaSize']?.toDouble(),
        createdAt: DateTime.parse(json['createdAt']),
        startDate: json['startDate'] != null
            ? DateTime.parse(json['startDate'])
            : null,
        endDate: json['endDate'] != null
            ? DateTime.parse(json['endDate'])
            : null,
        director: json['director'],
        teamMembers: json['teamMembers'] != null
            ? List<String>.from(json['teamMembers'])
            : [],
        permitNumber: json['permitNumber'],
        institution: json['institution'],
        country: json['country'],
        region: json['region'],
        periods: json['periods'] != null
            ? List<String>.from(json['periods'])
            : null,
        metadata: json['metadata'],
        isActive: json['isActive'] ?? true,
      );

  Site copyWith({
    String? id,
    String? name,
    String? description,
    SiteType? type,
    double? latitude,
    double? longitude,
    double? areaSize,
    DateTime? createdAt,
    DateTime? startDate,
    DateTime? endDate,
    String? director,
    List<String>? teamMembers,
    String? permitNumber,
    String? institution,
    String? country,
    String? region,
    List<String>? periods,
    Map<String, dynamic>? metadata,
    bool? isActive,
  }) =>
      Site(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        type: type ?? this.type,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        areaSize: areaSize ?? this.areaSize,
        createdAt: createdAt ?? this.createdAt,
        startDate: startDate ?? this.startDate,
        endDate: endDate ?? this.endDate,
        director: director ?? this.director,
        teamMembers: teamMembers ?? this.teamMembers,
        permitNumber: permitNumber ?? this.permitNumber,
        institution: institution ?? this.institution,
        country: country ?? this.country,
        region: region ?? this.region,
        periods: periods ?? this.periods,
        metadata: metadata ?? this.metadata,
        isActive: isActive ?? this.isActive,
      );
}

/// Site statistics summary
class SiteStatistics {
  final int totalFindings;
  final int findingsToday;
  final int findingsThisWeek;
  final Map<String, int> findingsByType;
  final Map<String, int> findingsByPeriod;
  final int photosCount;
  final int reconstructionsCount;
  final DateTime? lastActivity;

  SiteStatistics({
    this.totalFindings = 0,
    this.findingsToday = 0,
    this.findingsThisWeek = 0,
    this.findingsByType = const {},
    this.findingsByPeriod = const {},
    this.photosCount = 0,
    this.reconstructionsCount = 0,
    this.lastActivity,
  });

  Map<String, dynamic> toJson() => {
        'totalFindings': totalFindings,
        'findingsToday': findingsToday,
        'findingsThisWeek': findingsThisWeek,
        'findingsByType': findingsByType,
        'findingsByPeriod': findingsByPeriod,
        'photosCount': photosCount,
        'reconstructionsCount': reconstructionsCount,
        'lastActivity': lastActivity?.toIso8601String(),
      };
}
