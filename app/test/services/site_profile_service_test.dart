import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ancient_vision/services/site_profile_service.dart';
import 'package:ancient_vision/services/location_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Reset singleton cache between tests.
    SiteProfileService.instance.clearCache();
  });

  // ---------------------------------------------------------------------------
  // DeploymentRecord unit tests
  // ---------------------------------------------------------------------------

  group('DeploymentRecord', () {
    test('isActive is true when endTime is null', () {
      final rec = DeploymentRecord(
        id: 'r1',
        startTime: DateTime(2026, 3, 1, 8),
        deviceId: 'dev-A',
      );
      expect(rec.isActive, isTrue);
      expect(rec.duration, isNull);
    });

    test('isActive is false after endTime is set', () {
      final start = DateTime(2026, 3, 1, 8);
      final end = DateTime(2026, 3, 1, 10);
      final rec = DeploymentRecord(
        id: 'r1',
        startTime: start,
        endTime: end,
        deviceId: 'dev-A',
        peakPpv: 1.5,
        alertCount: 3,
        sampleCount: 1000,
      );
      expect(rec.isActive, isFalse);
      expect(rec.duration, const Duration(hours: 2));
    });

    test('toJson / fromJson round-trip', () {
      final start = DateTime(2026, 3, 1, 8);
      final end = DateTime(2026, 3, 1, 10, 30);
      final rec = DeploymentRecord(
        id: 'abc',
        startTime: start,
        endTime: end,
        deviceId: 'dev-B',
        peakPpv: 2.3,
        alertCount: 5,
        sampleCount: 500,
        notes: 'test notes',
      );
      final restored = DeploymentRecord.fromJson(rec.toJson());
      expect(restored.id, rec.id);
      expect(restored.startTime, rec.startTime);
      expect(restored.endTime, rec.endTime);
      expect(restored.deviceId, rec.deviceId);
      expect(restored.peakPpv, rec.peakPpv);
      expect(restored.alertCount, rec.alertCount);
      expect(restored.sampleCount, rec.sampleCount);
      expect(restored.notes, rec.notes);
      expect(restored.isActive, isFalse);
    });

    test('copyWith endTime clears when clearEndTime=true', () {
      final rec = DeploymentRecord(
        id: 'r',
        startTime: DateTime(2026),
        endTime: DateTime(2026, 1, 2),
        deviceId: 'dev-C',
      );
      final cleared = rec.copyWith(clearEndTime: true);
      expect(cleared.isActive, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // SiteProfileWithHistory unit tests
  // ---------------------------------------------------------------------------

  group('SiteProfileWithHistory', () {
    SiteProfileWithHistory makeSite({
      List<DeploymentRecord> deployments = const [],
    }) =>
        SiteProfileWithHistory(
          id: 's1',
          name: 'Kalapodi',
          createdAt: DateTime(2026, 1, 1),
          deployments: deployments,
        );

    test('peakPpvAllTime returns 0.0 for empty deployments', () {
      expect(makeSite().peakPpvAllTime, 0.0);
    });

    test('peakPpvAllTime returns max across deployments', () {
      final deploys = [
        DeploymentRecord(
          id: 'd1',
          startTime: DateTime(2026),
          endTime: DateTime(2026, 1, 2),
          deviceId: 'x',
          peakPpv: 1.2,
        ),
        DeploymentRecord(
          id: 'd2',
          startTime: DateTime(2026, 2),
          endTime: DateTime(2026, 2, 2),
          deviceId: 'x',
          peakPpv: 3.7,
        ),
        DeploymentRecord(
          id: 'd3',
          startTime: DateTime(2026, 3),
          endTime: DateTime(2026, 3, 2),
          deviceId: 'x',
          peakPpv: 0.5,
        ),
      ];
      expect(makeSite(deployments: deploys).peakPpvAllTime, 3.7);
    });

    test('totalMonitoringTime sums completed deployment durations', () {
      final deploys = [
        DeploymentRecord(
          id: 'd1',
          startTime: DateTime(2026, 1, 1, 8),
          endTime: DateTime(2026, 1, 1, 10),
          deviceId: 'x',
        ),
        DeploymentRecord(
          id: 'd2',
          startTime: DateTime(2026, 1, 2, 8),
          endTime: DateTime(2026, 1, 2, 11),
          deviceId: 'x',
        ),
        // Active — not counted
        DeploymentRecord(
          id: 'd3',
          startTime: DateTime(2026, 1, 3, 8),
          deviceId: 'x',
        ),
      ];
      final site = makeSite(deployments: deploys);
      expect(site.totalMonitoringTime, const Duration(hours: 5));
    });

    test('hasActiveDeployment and activeDeployment', () {
      final active = DeploymentRecord(
        id: 'da',
        startTime: DateTime(2026, 3),
        deviceId: 'dev',
      );
      final site = makeSite(deployments: [active]);
      expect(site.hasActiveDeployment, isTrue);
      expect(site.activeDeployment?.id, 'da');
    });

    test('activeDeployment returns null when all deployments are closed', () {
      final closed = DeploymentRecord(
        id: 'dc',
        startTime: DateTime(2026),
        endTime: DateTime(2026, 1, 2),
        deviceId: 'dev',
      );
      final site = makeSite(deployments: [closed]);
      expect(site.hasActiveDeployment, isFalse);
      expect(site.activeDeployment, isNull);
    });

    test('toJson / fromJson round-trip', () {
      final site = SiteProfileWithHistory(
        id: 'xyz',
        name: 'Delphi',
        description: 'Oracle site',
        latitude: 38.4824,
        longitude: 22.5013,
        monitoringRadiusMeters: 200.0,
        deployments: const [],
        createdAt: DateTime(2026, 1, 15),
        lastActiveAt: DateTime(2026, 2, 1),
      );
      final restored = SiteProfileWithHistory.fromJson(site.toJson());
      expect(restored.id, site.id);
      expect(restored.name, site.name);
      expect(restored.description, site.description);
      expect(restored.latitude, site.latitude);
      expect(restored.longitude, site.longitude);
      expect(restored.monitoringRadiusMeters, site.monitoringRadiusMeters);
      expect(restored.createdAt, site.createdAt);
      expect(restored.lastActiveAt, site.lastActiveAt);
    });
  });

  // ---------------------------------------------------------------------------
  // SiteProfileService integration tests
  // ---------------------------------------------------------------------------

  group('SiteProfileService', () {
    final svc = SiteProfileService.instance;

    test('getSites returns empty list initially', () async {
      expect(await svc.getSites(), isEmpty);
    });

    test('createSite adds to getSites()', () async {
      final site = await svc.createSite(name: 'Olympia');
      final all = await svc.getSites();
      expect(all.length, 1);
      expect(all.first.id, site.id);
      expect(all.first.name, 'Olympia');
    });

    test('createSite with coordinates stores them', () async {
      final site = await svc.createSite(
        name: 'Mycenae',
        lat: 37.7306,
        lon: 22.7565,
        description: 'Bronze Age citadel',
        radiusMeters: 500.0,
      );
      expect(site.hasCoordinates, isTrue);
      expect(site.latitude, closeTo(37.7306, 0.0001));
      expect(site.longitude, closeTo(22.7565, 0.0001));
      expect(site.description, 'Bronze Age citadel');
      expect(site.monitoringRadiusMeters, 500.0);
    });

    test('data persists across service cache clears (SharedPreferences)', () async {
      await svc.createSite(name: 'Epidaurus');
      svc.clearCache(); // force reload from prefs on next call
      final all = await svc.getSites();
      expect(all.any((s) => s.name == 'Epidaurus'), isTrue);
    });

    test('updateSite replaces the record', () async {
      final site = await svc.createSite(name: 'Corinth');
      final updated = site.copyWith(description: 'Updated description');
      await svc.updateSite(updated);
      final all = await svc.getSites();
      expect(all.first.description, 'Updated description');
    });

    test('deleteSite removes the record', () async {
      final site = await svc.createSite(name: 'Nemea');
      await svc.deleteSite(site.id);
      final all = await svc.getSites();
      expect(all.any((s) => s.id == site.id), isFalse);
    });

    // -----------------------------------------------------------------------
    // Deployment tests
    // -----------------------------------------------------------------------

    test('startDeployment sets hasActiveDeployment = true', () async {
      final site = await svc.createSite(name: 'Marathon');
      await svc.startDeployment(siteId: site.id, deviceId: 'dev-001');
      final all = await svc.getSites();
      final loaded = all.firstWhere((s) => s.id == site.id);
      expect(loaded.hasActiveDeployment, isTrue);
      expect(loaded.activeDeployment?.deviceId, 'dev-001');
    });

    test('startDeployment returns existing active deployment when already active', () async {
      final site = await svc.createSite(name: 'Thermopylae');
      final first = await svc.startDeployment(
          siteId: site.id, deviceId: 'dev-001');
      final second = await svc.startDeployment(
          siteId: site.id, deviceId: 'dev-002');
      expect(second.id, first.id); // same deployment returned
      final all = await svc.getSites();
      final loaded = all.firstWhere((s) => s.id == site.id);
      expect(loaded.deployments.length, 1); // only one deployment created
    });

    test('endDeployment closes the deployment and records metrics', () async {
      final site = await svc.createSite(name: 'Delos');
      final dep = await svc.startDeployment(
          siteId: site.id, deviceId: 'dev-999');

      await svc.endDeployment(
        siteId: site.id,
        deploymentId: dep.id,
        peakPpv: 2.5,
        alertCount: 7,
        sampleCount: 3600,
        notes: 'Mild seismic activity detected',
      );

      final all = await svc.getSites();
      final loaded = all.firstWhere((s) => s.id == site.id);
      expect(loaded.hasActiveDeployment, isFalse);

      final closed = loaded.deployments.first;
      expect(closed.isActive, isFalse);
      expect(closed.peakPpv, 2.5);
      expect(closed.alertCount, 7);
      expect(closed.sampleCount, 3600);
      expect(closed.notes, 'Mild seismic activity detected');
      expect(closed.endTime, isNotNull);
    });

    test('peakPpvAllTime updates after endDeployment', () async {
      final site = await svc.createSite(name: 'Delphi');
      final dep = await svc.startDeployment(
          siteId: site.id, deviceId: 'dev-A');
      await svc.endDeployment(
        siteId: site.id,
        deploymentId: dep.id,
        peakPpv: 4.2,
        alertCount: 2,
        sampleCount: 100,
      );
      final all = await svc.getSites();
      final loaded = all.firstWhere((s) => s.id == site.id);
      expect(loaded.peakPpvAllTime, closeTo(4.2, 0.001));
    });

    test('getActiveSite returns the site with an active deployment', () async {
      final s1 = await svc.createSite(name: 'Site A');
      final s2 = await svc.createSite(name: 'Site B');
      await svc.startDeployment(siteId: s2.id, deviceId: 'dev-X');

      final active = await svc.getActiveSite();
      expect(active, isNotNull);
      expect(active!.id, s2.id);
      // s1 should not interfere
      expect(active.id, isNot(s1.id));
    });

    test('getActiveSite returns null when no active deployment', () async {
      await svc.createSite(name: 'Idle Site');
      expect(await svc.getActiveSite(), isNull);
    });

    // -----------------------------------------------------------------------
    // getNearby tests
    // -----------------------------------------------------------------------

    test('getNearby returns only sites within radius', () async {
      // Athens: 37.9838° N, 23.7275° E
      // Corinth: ~78 km from Athens
      // Acropolis: essentially same point as Athens

      await svc.createSite(
        name: 'Near Athens',
        lat: 37.990,
        lon: 23.730,
      );
      await svc.createSite(
        name: 'Corinth (far)',
        lat: 37.9403,
        lon: 22.9319, // ~78 km from Athens
      );
      await svc.createSite(
        name: 'No Coords',
        // no lat/lon
      );

      final athens = GpsLocation(
        latitude: 37.9838,
        longitude: 23.7275,
        accuracy: 5.0,
        timestamp: DateTime.now(),
      );

      // 10 km radius — should include Near Athens only
      final nearby10 = await svc.getNearby(athens, radiusKm: 10);
      expect(nearby10.map((s) => s.name), contains('Near Athens'));
      expect(nearby10.map((s) => s.name), isNot(contains('Corinth (far)')));
      expect(nearby10.map((s) => s.name), isNot(contains('No Coords')));

      // 100 km radius — should include both located sites
      final nearby100 = await svc.getNearby(athens, radiusKm: 100);
      expect(nearby100.map((s) => s.name), contains('Near Athens'));
      expect(nearby100.map((s) => s.name), contains('Corinth (far)'));
      expect(nearby100.map((s) => s.name), isNot(contains('No Coords')));
    });

    test('getNearby returns empty list when no sites in range', () async {
      await svc.createSite(name: 'Distant Site', lat: 0.0, lon: 0.0);

      final athens = GpsLocation(
        latitude: 37.9838,
        longitude: 23.7275,
        accuracy: 5.0,
        timestamp: DateTime.now(),
      );

      final nearby = await svc.getNearby(athens, radiusKm: 10);
      expect(nearby, isEmpty);
    });

    test('getNearby returns empty list when there are no sites at all', () async {
      final loc = GpsLocation(
        latitude: 37.9838,
        longitude: 23.7275,
        accuracy: 5.0,
        timestamp: DateTime.now(),
      );
      expect(await svc.getNearby(loc), isEmpty);
    });
  });
}
