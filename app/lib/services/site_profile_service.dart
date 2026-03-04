import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../services/location_service.dart';

// ---------------------------------------------------------------------------
// DeploymentRecord
// ---------------------------------------------------------------------------

/// A single monitoring session at an archaeological site.
class DeploymentRecord {
  final String id;
  final DateTime startTime;
  final DateTime? endTime;
  final String deviceId;
  final double peakPpv;
  final int alertCount;
  final int sampleCount;
  final String? notes;

  const DeploymentRecord({
    required this.id,
    required this.startTime,
    this.endTime,
    required this.deviceId,
    this.peakPpv = 0.0,
    this.alertCount = 0,
    this.sampleCount = 0,
    this.notes,
  });

  /// Duration of deployment, or null if still active.
  Duration? get duration => endTime?.difference(startTime);

  /// True when the deployment has no end time (still running).
  bool get isActive => endTime == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'deviceId': deviceId,
        'peakPpv': peakPpv,
        'alertCount': alertCount,
        'sampleCount': sampleCount,
        'notes': notes,
      };

  factory DeploymentRecord.fromJson(Map<String, dynamic> json) =>
      DeploymentRecord(
        id: json['id'] as String,
        startTime: DateTime.parse(json['startTime'] as String),
        endTime: json['endTime'] != null
            ? DateTime.parse(json['endTime'] as String)
            : null,
        deviceId: json['deviceId'] as String,
        peakPpv: (json['peakPpv'] as num).toDouble(),
        alertCount: (json['alertCount'] as num).toInt(),
        sampleCount: (json['sampleCount'] as num).toInt(),
        notes: json['notes'] as String?,
      );

  DeploymentRecord copyWith({
    String? id,
    DateTime? startTime,
    DateTime? endTime,
    String? deviceId,
    double? peakPpv,
    int? alertCount,
    int? sampleCount,
    String? notes,
    bool clearEndTime = false,
  }) =>
      DeploymentRecord(
        id: id ?? this.id,
        startTime: startTime ?? this.startTime,
        endTime: clearEndTime ? null : (endTime ?? this.endTime),
        deviceId: deviceId ?? this.deviceId,
        peakPpv: peakPpv ?? this.peakPpv,
        alertCount: alertCount ?? this.alertCount,
        sampleCount: sampleCount ?? this.sampleCount,
        notes: notes ?? this.notes,
      );
}

// ---------------------------------------------------------------------------
// SiteProfileWithHistory
// ---------------------------------------------------------------------------

/// Extended site profile with full deployment history.
class SiteProfileWithHistory {
  final String id;
  final String name;
  final String? description;
  final double? latitude;
  final double? longitude;
  final double? monitoringRadiusMeters;
  final List<DeploymentRecord> deployments;
  final DateTime createdAt;
  final DateTime? lastActiveAt;

  const SiteProfileWithHistory({
    required this.id,
    required this.name,
    this.description,
    this.latitude,
    this.longitude,
    this.monitoringRadiusMeters,
    this.deployments = const [],
    required this.createdAt,
    this.lastActiveAt,
  });

  // -------------------------------------------------------------------------
  // Derived properties
  // -------------------------------------------------------------------------

  bool get hasActiveDeployment => deployments.any((d) => d.isActive);

  DeploymentRecord? get activeDeployment {
    try {
      return deployments.firstWhere((d) => d.isActive);
    } catch (_) {
      return null;
    }
  }

  double get peakPpvAllTime => deployments.isEmpty
      ? 0.0
      : deployments.map((d) => d.peakPpv).reduce(max);

  int get totalDeployments => deployments.length;

  Duration get totalMonitoringTime => deployments.fold(
        Duration.zero,
        (acc, d) => acc + (d.duration ?? Duration.zero),
      );

  bool get hasCoordinates => latitude != null && longitude != null;

  // -------------------------------------------------------------------------
  // Serialisation
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'latitude': latitude,
        'longitude': longitude,
        'monitoringRadiusMeters': monitoringRadiusMeters,
        'deployments': deployments.map((d) => d.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'lastActiveAt': lastActiveAt?.toIso8601String(),
      };

  factory SiteProfileWithHistory.fromJson(Map<String, dynamic> json) =>
      SiteProfileWithHistory(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        latitude:
            json['latitude'] != null ? (json['latitude'] as num).toDouble() : null,
        longitude: json['longitude'] != null
            ? (json['longitude'] as num).toDouble()
            : null,
        monitoringRadiusMeters: json['monitoringRadiusMeters'] != null
            ? (json['monitoringRadiusMeters'] as num).toDouble()
            : null,
        deployments: (json['deployments'] as List<dynamic>? ?? [])
            .map((e) => DeploymentRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        lastActiveAt: json['lastActiveAt'] != null
            ? DateTime.parse(json['lastActiveAt'] as String)
            : null,
      );

  SiteProfileWithHistory copyWith({
    String? id,
    String? name,
    String? description,
    double? latitude,
    double? longitude,
    double? monitoringRadiusMeters,
    List<DeploymentRecord>? deployments,
    DateTime? createdAt,
    DateTime? lastActiveAt,
  }) =>
      SiteProfileWithHistory(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        monitoringRadiusMeters:
            monitoringRadiusMeters ?? this.monitoringRadiusMeters,
        deployments: deployments ?? this.deployments,
        createdAt: createdAt ?? this.createdAt,
        lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      );
}

// ---------------------------------------------------------------------------
// SiteProfileService
// ---------------------------------------------------------------------------

/// Singleton service managing archaeological site profiles with deployment
/// history. Persists data to SharedPreferences under [_prefsKey].
class SiteProfileService {
  static final SiteProfileService instance = SiteProfileService._();
  SiteProfileService._();

  static const String _prefsKey = 'site_profiles_v2';

  // In-memory cache — loaded lazily on first access.
  List<SiteProfileWithHistory>? _cache;

  final _uuid = const Uuid();

  // -------------------------------------------------------------------------
  // CRUD
  // -------------------------------------------------------------------------

  /// Returns all stored site profiles, ordered by [createdAt] descending.
  Future<List<SiteProfileWithHistory>> getSites() async {
    _cache ??= await _load();
    return List.unmodifiable(_cache!);
  }

  /// Creates a new site profile and persists it.
  Future<SiteProfileWithHistory> createSite({
    required String name,
    double? lat,
    double? lon,
    String? description,
    double? radiusMeters,
  }) async {
    final now = DateTime.now();
    final site = SiteProfileWithHistory(
      id: _uuid.v4(),
      name: name,
      description: description,
      latitude: lat,
      longitude: lon,
      monitoringRadiusMeters: radiusMeters,
      deployments: const [],
      createdAt: now,
    );

    _cache ??= await _load();
    _cache!.add(site);
    await _persist();
    debugPrint('[SiteProfileService] Created site "${site.name}" (${site.id})');
    return site;
  }

  /// Replaces an existing site profile in full.
  Future<void> updateSite(SiteProfileWithHistory site) async {
    _cache ??= await _load();
    final idx = _cache!.indexWhere((s) => s.id == site.id);
    if (idx == -1) {
      debugPrint('[SiteProfileService] updateSite: site ${site.id} not found.');
      return;
    }
    _cache![idx] = site;
    await _persist();
  }

  /// Deletes a site and all its deployment history.
  Future<void> deleteSite(String id) async {
    _cache ??= await _load();
    final before = _cache!.length;
    _cache!.removeWhere((s) => s.id == id);
    if (_cache!.length != before) await _persist();
  }

  // -------------------------------------------------------------------------
  // Deployment management
  // -------------------------------------------------------------------------

  /// Starts a new deployment on [siteId] and returns the created record.
  ///
  /// If the site already has an active deployment it is NOT replaced; the
  /// existing active deployment is returned instead to avoid double-starts.
  Future<DeploymentRecord> startDeployment({
    required String siteId,
    required String deviceId,
  }) async {
    _cache ??= await _load();
    final idx = _cache!.indexWhere((s) => s.id == siteId);
    if (idx == -1) {
      throw StateError('[SiteProfileService] startDeployment: site $siteId not found.');
    }

    final site = _cache![idx];

    // Guard: return existing active deployment if one exists.
    if (site.hasActiveDeployment) {
      debugPrint(
          '[SiteProfileService] Site ${site.name} already has active deployment.');
      return site.activeDeployment!;
    }

    final record = DeploymentRecord(
      id: _uuid.v4(),
      startTime: DateTime.now(),
      deviceId: deviceId,
    );

    final updatedDeployments = List<DeploymentRecord>.from(site.deployments)
      ..add(record);

    _cache![idx] = site.copyWith(
      deployments: updatedDeployments,
      lastActiveAt: record.startTime,
    );

    await _persist();
    debugPrint(
        '[SiteProfileService] Started deployment ${record.id} on site ${site.name}');
    return record;
  }

  /// Closes an active deployment, recording final metrics.
  Future<void> endDeployment({
    required String siteId,
    required String deploymentId,
    required double peakPpv,
    required int alertCount,
    required int sampleCount,
    String? notes,
  }) async {
    _cache ??= await _load();
    final siteIdx = _cache!.indexWhere((s) => s.id == siteId);
    if (siteIdx == -1) {
      debugPrint('[SiteProfileService] endDeployment: site $siteId not found.');
      return;
    }

    final site = _cache![siteIdx];
    final depIdx =
        site.deployments.indexWhere((d) => d.id == deploymentId);
    if (depIdx == -1) {
      debugPrint(
          '[SiteProfileService] endDeployment: deployment $deploymentId not found.');
      return;
    }

    final updatedDeployments =
        List<DeploymentRecord>.from(site.deployments);
    updatedDeployments[depIdx] = updatedDeployments[depIdx].copyWith(
      endTime: DateTime.now(),
      peakPpv: peakPpv,
      alertCount: alertCount,
      sampleCount: sampleCount,
      notes: notes,
    );

    _cache![siteIdx] = site.copyWith(deployments: updatedDeployments);
    await _persist();
    debugPrint(
        '[SiteProfileService] Ended deployment $deploymentId on site ${site.name} '
        '(peakPpv=$peakPpv, alerts=$alertCount)');
  }

  // -------------------------------------------------------------------------
  // Queries
  // -------------------------------------------------------------------------

  /// Returns the first site with an active deployment, or null if none.
  Future<SiteProfileWithHistory?> getActiveSite() async {
    final sites = await getSites();
    try {
      return sites.firstWhere((s) => s.hasActiveDeployment);
    } catch (_) {
      return null;
    }
  }

  /// Returns sites whose stored coordinates are within [radiusKm] kilometres
  /// of [location].  Sites without coordinates are excluded.
  Future<List<SiteProfileWithHistory>> getNearby(
    GpsLocation location, {
    double radiusKm = 10,
  }) async {
    final sites = await getSites();
    final radiusMeters = radiusKm * 1000.0;

    return sites.where((site) {
      if (!site.hasCoordinates) return false;
      final siteLocation = GpsLocation(
        latitude: site.latitude!,
        longitude: site.longitude!,
        accuracy: 0,
        timestamp: DateTime.now(),
      );
      return GpsLocation.distanceMeters(location, siteLocation) <=
          radiusMeters;
    }).toList();
  }

  // -------------------------------------------------------------------------
  // Persistence helpers
  // -------------------------------------------------------------------------

  Future<List<SiteProfileWithHistory>> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) =>
              SiteProfileWithHistory.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[SiteProfileService] _load error: $e');
      return [];
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(_cache!.map((s) => s.toJson()).toList());
      await prefs.setString(_prefsKey, encoded);
    } catch (e) {
      debugPrint('[SiteProfileService] _persist error: $e');
    }
  }

  /// Clears the in-memory cache (useful in tests).
  void clearCache() => _cache = null;
}
