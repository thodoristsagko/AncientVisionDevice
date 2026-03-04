import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/widgets/anomaly_level_badge.dart';
import 'package:ancient_vision/services/vibration_anomaly_service.dart';

void main() {
  group('AnomalyLevelBadge', () {
    testWidgets('renders without crashing for each AnomalyLevel', (tester) async {
      for (final level in AnomalyLevel.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AnomalyLevelBadge(level: level),
            ),
          ),
        );
        expect(find.byType(AnomalyLevelBadge), findsOneWidget,
            reason: 'Failed to render for level: $level');
        // Allow animations to settle
        await tester.pump(const Duration(milliseconds: 100));
      }
    });

    testWidgets('shows correct label text for normal', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.normal),
          ),
        ),
      );
      expect(find.text('SAFE'), findsOneWidget);
    });

    testWidgets('shows correct label text for anomaly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.anomaly),
          ),
        ),
      );
      // Allow the pulsing animation to initialise
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('CRITICAL'), findsOneWidget);
    });

    testWidgets('shows correct label text for unknown', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.unknown),
          ),
        ),
      );
      expect(find.text('INIT'), findsOneWidget);
    });

    testWidgets('badge color changes based on level', (tester) async {
      // Test normal level — background should be the dark green 0xFF1B5E20
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.normal),
          ),
        ),
      );
      final normalContainer = tester.widget<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color ==
                  const Color(0xFF1B5E20),
        ),
      );
      expect(normalContainer, isNotNull);

      // Test unusual level — background should be dark amber 0xFF4A2900
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.unusual),
          ),
        ),
      );
      final unusualContainer = tester.widget<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color ==
                  const Color(0xFF4A2900),
        ),
      );
      expect(unusualContainer, isNotNull);
    });

    testWidgets('large mode renders larger font than default', (tester) async {
      // Pump small (default) badge
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.normal),
          ),
        ),
      );
      final smallText = tester.widget<Text>(find.text('SAFE'));
      final smallFontSize = smallText.style?.fontSize;

      // Pump large badge
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.normal, large: true),
          ),
        ),
      );
      final largeText = tester.widget<Text>(find.text('SAFE'));
      final largeFontSize = largeText.style?.fontSize;

      expect(largeFontSize, greaterThan(smallFontSize!));
    });

    testWidgets('shows correct label text for unusual', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnomalyLevelBadge(level: AnomalyLevel.unusual),
          ),
        ),
      );
      expect(find.text('ANOMALY'), findsOneWidget);
    });
  });
}
