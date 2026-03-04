import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ancient_vision/services/session_sync_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Reset all in-memory state of the [SessionSyncService] singleton between
/// tests by calling [reset] and clearing SharedPreferences.
Future<void> _resetService() async {
  SharedPreferences.setMockInitialValues({});
  final svc = SessionSyncService.instance;
  svc.reset();
  // Force reload of persisted stats on next use by resetting the loaded flag
  // via the public API surface only (re-init via cleared prefs).
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() async {
    await _resetService();
  });

  group('SessionSyncService — initial state', () {
    test('status starts as idle', () {
      expect(SessionSyncService.instance.status, SyncStatus.idle);
    });

    test('totalSynced starts at 0', () {
      expect(SessionSyncService.instance.totalSynced, 0);
    });

    test('totalFailed starts at 0', () {
      expect(SessionSyncService.instance.totalFailed, 0);
    });

    test('lastSyncTime starts as null', () {
      expect(SessionSyncService.instance.lastSyncTime, isNull);
    });

    test('pendingCount returns 0 when no pending samples', () async {
      final count = await SessionSyncService.instance.pendingCount;
      expect(count, 0);
    });
  });

  group('SessionSyncService — getStoredCollectorUrl', () {
    test('returns null when not set', () async {
      final url = await SessionSyncService.instance.getStoredCollectorUrl();
      expect(url, isNull);
    });
  });

  group('SessionSyncService — reset', () {
    test('reset sets status back to idle after manual mutation check', () {
      final svc = SessionSyncService.instance;
      // Status begins idle; reset should keep it idle.
      svc.reset();
      expect(svc.status, SyncStatus.idle);
    });
  });

  group('SessionSyncService — syncSession with empty list', () {
    test('syncSession with empty list does not change status from idle',
        () async {
      final svc = SessionSyncService.instance;
      // Pass an empty list — the service should not transition away from idle
      // because with no samples it just attempts a pending flush and returns.
      // Since there are no pending samples either (fresh prefs), the status
      // stays idle the whole time.
      await svc.syncSession([]);
      expect(svc.status, SyncStatus.idle);
    });
  });
}
