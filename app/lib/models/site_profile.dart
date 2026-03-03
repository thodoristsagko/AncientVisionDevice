import 'dart:convert';

/// Persisted calibration profile for a specific archaeological site.
class SiteProfile {
  final String name;
  final DateTime createdAt;
  final String modelVersion;
  final List<double> scalerMean;
  final List<double> scalerStd;
  final double thresholdLow;
  final double thresholdHigh;
  final int sampleCount;
  final double ppvCoefficientOfVariation;

  const SiteProfile({
    required this.name,
    required this.createdAt,
    required this.modelVersion,
    required this.scalerMean,
    required this.scalerStd,
    required this.thresholdLow,
    required this.thresholdHigh,
    required this.sampleCount,
    required this.ppvCoefficientOfVariation,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'modelVersion': modelVersion,
    'scalerMean': scalerMean,
    'scalerStd': scalerStd,
    'thresholdLow': thresholdLow,
    'thresholdHigh': thresholdHigh,
    'sampleCount': sampleCount,
    'ppvCoefficientOfVariation': ppvCoefficientOfVariation,
  };

  factory SiteProfile.fromJson(Map<String, dynamic> json) => SiteProfile(
    name: json['name'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    modelVersion: json['modelVersion'] as String,
    scalerMean: (json['scalerMean'] as List).map((e) => (e as num).toDouble()).toList(),
    scalerStd: (json['scalerStd'] as List).map((e) => (e as num).toDouble()).toList(),
    thresholdLow: (json['thresholdLow'] as num).toDouble(),
    thresholdHigh: (json['thresholdHigh'] as num).toDouble(),
    sampleCount: json['sampleCount'] as int,
    ppvCoefficientOfVariation: (json['ppvCoefficientOfVariation'] as num).toDouble(),
  );

  String encode() => jsonEncode(toJson());
  static SiteProfile decode(String s) => SiteProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);

  bool get needsRecalibration => modelVersion != '5.0';
  bool get highVarianceWarning => ppvCoefficientOfVariation > 0.5;
}
