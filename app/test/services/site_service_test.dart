import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ancient_vision/services/site_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SiteService', () {
    test('getSites returns empty list initially', () async {
      final svc = SiteService();
      expect(await svc.getSites(), isEmpty);
    });

    test('addSite stores a site', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      expect(await svc.getSites(), contains('Kalapodi'));
    });

    test('setActiveSite persists active site', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      await svc.setActiveSite('Kalapodi');
      expect(await svc.getActiveSite(), 'Kalapodi');
    });

    test('removeSite removes from list', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      await svc.removeSite('Kalapodi');
      expect(await svc.getSites(), isEmpty);
    });

    test('removeSite clears activeSite if it was the active one', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      await svc.setActiveSite('Kalapodi');
      await svc.removeSite('Kalapodi');
      expect(await svc.getActiveSite(), '');
    });
  });
}
