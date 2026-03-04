import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/alert_escalation_service.dart';

void main() {
  // The service is a singleton. We call reset() in setUp so each test starts
  // from a clean state.
  setUp(() {
    AlertEscalationService.instance.reset();
  });

  group('AlertEscalationService — initial state', () {
    // -------------------------------------------------------------------------
    // 1. escalationCount starts at 0
    // -------------------------------------------------------------------------
    test('escalationCount starts at 0', () {
      expect(AlertEscalationService.instance.escalationCount, equals(0));
    });

    // -------------------------------------------------------------------------
    // 2. escalationHistory is empty initially
    // -------------------------------------------------------------------------
    test('escalationHistory is empty initially', () {
      expect(AlertEscalationService.instance.escalationHistory, isEmpty);
    });

    // -------------------------------------------------------------------------
    // 3. isFrequentlyEscalating returns false initially
    // -------------------------------------------------------------------------
    test('isFrequentlyEscalating returns false initially', () {
      expect(AlertEscalationService.instance.isFrequentlyEscalating, isFalse);
    });

    // -------------------------------------------------------------------------
    // 4. isCritical is false initially
    // -------------------------------------------------------------------------
    test('isCritical is false initially', () {
      expect(AlertEscalationService.instance.isCritical, isFalse);
    });

    // -------------------------------------------------------------------------
    // 5. anomalyDurationSeconds is 0 initially
    // -------------------------------------------------------------------------
    test('anomalyDurationSeconds is 0 initially', () {
      expect(AlertEscalationService.instance.anomalyDurationSeconds, equals(0));
    });

    // -------------------------------------------------------------------------
    // 6. isDeEscalationPending is false initially
    // -------------------------------------------------------------------------
    test('isDeEscalationPending is false initially', () {
      expect(AlertEscalationService.instance.isDeEscalationPending, isFalse);
    });

    // -------------------------------------------------------------------------
    // 7. deEscalationRemainingSeconds is 0 initially
    // -------------------------------------------------------------------------
    test('deEscalationRemainingSeconds is 0 initially', () {
      expect(AlertEscalationService.instance.deEscalationRemainingSeconds, equals(0));
    });
  });

  group('AlertEscalationService — reset()', () {
    // -------------------------------------------------------------------------
    // 8. reset clears history and all state
    // -------------------------------------------------------------------------
    test('reset clears history and escalation count', () {
      final svc = AlertEscalationService.instance;
      // Drive a transition: normal → anomaly by calling update(true) once.
      svc.update(true);
      // There should now be at least one history entry.
      expect(svc.escalationHistory, isNotEmpty);

      svc.reset();
      expect(svc.escalationHistory, isEmpty);
      expect(svc.escalationCount, equals(0));
      expect(svc.isCritical, isFalse);
    });

    // -------------------------------------------------------------------------
    // 9. reset allows fresh escalation counting after a previous session
    // -------------------------------------------------------------------------
    test('reset allows counting to restart from 0', () {
      final svc = AlertEscalationService.instance;
      svc.update(true); // normal→anomaly
      svc.reset();
      expect(svc.escalationCount, equals(0));
    });
  });

  group('AlertEscalationService — update() and history', () {
    // -------------------------------------------------------------------------
    // 10. update(true) records a history event (normal→anomaly)
    // -------------------------------------------------------------------------
    test('update(true) records an escalation event', () {
      final svc = AlertEscalationService.instance;
      svc.update(true);
      expect(svc.escalationHistory, isNotEmpty);
      expect(svc.escalationHistory.first.toLevel, equals('anomaly'));
    });

    // -------------------------------------------------------------------------
    // 11. escalationCount increments on each upward transition
    // -------------------------------------------------------------------------
    test('escalationCount increments on each upward transition', () {
      final svc = AlertEscalationService.instance;
      // normal → anomaly: one upward transition
      svc.update(true);
      expect(svc.escalationCount, equals(1));
    });

    // -------------------------------------------------------------------------
    // 12. update(false) after update(true) clears anomalySince
    // -------------------------------------------------------------------------
    test('update(false) clears alert when not in critical state', () {
      final svc = AlertEscalationService.instance;
      svc.update(true); // start anomaly
      svc.update(false); // clear anomaly
      // Not critical, so clears immediately.
      expect(svc.isCritical, isFalse);
      expect(svc.anomalyDurationSeconds, equals(0));
    });

    // -------------------------------------------------------------------------
    // 13. escalationHistory grows with each upward transition
    // -------------------------------------------------------------------------
    test('escalationHistory grows with multiple transitions', () {
      final svc = AlertEscalationService.instance;
      // Each call to update(true) from non-anomaly state records a transition.
      // After reset, current level is 'normal', so update(true) → 'anomaly'.
      svc.update(true);
      final countAfterFirst = svc.escalationHistory.length;
      // Clear anomaly (non-critical path), then escalate again.
      svc.update(false);
      svc.update(true);
      expect(svc.escalationHistory.length, greaterThan(countAfterFirst));
    });

    // -------------------------------------------------------------------------
    // 14. update returns false (not critical) before escalationSeconds elapses
    // -------------------------------------------------------------------------
    test('update returns false before escalationSeconds elapses', () {
      final svc = AlertEscalationService.instance;
      // A single update(true) call has elapsed < escalationSeconds.
      final result = svc.update(true);
      expect(result, isFalse);
    });

    // -------------------------------------------------------------------------
    // 15. EscalationEvent has correct fromLevel and toLevel fields
    // -------------------------------------------------------------------------
    test('EscalationEvent records correct fromLevel and toLevel', () {
      final svc = AlertEscalationService.instance;
      svc.update(true);
      final event = svc.escalationHistory.first;
      expect(event.fromLevel, equals('normal'));
      expect(event.toLevel, equals('anomaly'));
      expect(event.timestamp, isA<DateTime>());
    });
  });

  group('AlertEscalationService — isFrequentlyEscalating', () {
    // -------------------------------------------------------------------------
    // 16. isFrequentlyEscalating returns true after 3+ escalations within 5 min
    // -------------------------------------------------------------------------
    test('isFrequentlyEscalating returns true after 3 escalations within 5 min', () {
      final svc = AlertEscalationService.instance;
      // Drive 3 normal→anomaly transitions quickly (all within the 5-minute
      // rolling window since they all happen in the same test run).
      for (int i = 0; i < 3; i++) {
        svc.update(true);  // normal→anomaly (first time) or anomaly (subsequent)
        svc.update(false); // clear anomaly to allow next upward transition
      }
      // We should have at least 3 upward transitions recorded.
      expect(svc.isFrequentlyEscalating, isTrue);
    });

    // -------------------------------------------------------------------------
    // 17. isFrequentlyEscalating returns false after only 2 escalations
    // -------------------------------------------------------------------------
    test('isFrequentlyEscalating returns false after only 2 escalations', () {
      final svc = AlertEscalationService.instance;
      for (int i = 0; i < 2; i++) {
        svc.update(true);
        svc.update(false);
      }
      expect(svc.escalationCount, equals(2));
      expect(svc.isFrequentlyEscalating, isFalse);
    });
  });

  group('AlertEscalationService — constants', () {
    // -------------------------------------------------------------------------
    // 18. escalationSeconds constant is positive
    // -------------------------------------------------------------------------
    test('escalationSeconds is positive', () {
      expect(AlertEscalationService.escalationSeconds, greaterThan(0));
    });

    // -------------------------------------------------------------------------
    // 19. deEscalationSeconds constant is positive
    // -------------------------------------------------------------------------
    test('deEscalationSeconds is positive', () {
      expect(AlertEscalationService.deEscalationSeconds, greaterThan(0));
    });

    // -------------------------------------------------------------------------
    // 20. deEscalationSeconds > escalationSeconds (hysteresis window is longer)
    // -------------------------------------------------------------------------
    test('deEscalationSeconds > escalationSeconds (hysteresis window is longer)', () {
      expect(
        AlertEscalationService.deEscalationSeconds,
        greaterThan(AlertEscalationService.escalationSeconds),
      );
    });
  });
}
