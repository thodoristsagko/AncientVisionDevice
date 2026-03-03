import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ancient_vision/services/alert_history_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AlertHistoryService', () {
    test('starts empty', () async {
      final svc = AlertHistoryService();
      final entries = await svc.load();
      expect(entries, isEmpty);
    });

    test('add stores an entry', () async {
      final svc = AlertHistoryService();
      await svc.add(level: 'warning', type: 'seismic', ppv: 3.5, message: 'Stop work');
      final entries = await svc.load();
      expect(entries.length, 1);
      expect(entries.first['level'], 'warning');
      expect(entries.first['ppv'], 3.5);
    });

    test('clear removes all entries', () async {
      final svc = AlertHistoryService();
      await svc.add(level: 'critical', type: 'impact', ppv: 12.0, message: 'Evacuate');
      await svc.clear();
      final entries = await svc.load();
      expect(entries, isEmpty);
    });

    test('max 100 entries (FIFO eviction)', () async {
      final svc = AlertHistoryService();
      for (int i = 0; i < 105; i++) {
        await svc.add(level: 'warning', type: 'seismic', ppv: i.toDouble(), message: 'msg $i');
      }
      final entries = await svc.load();
      expect(entries.length, 100);
      expect(entries.last['ppv'], 104.0);
    });
  });
}
