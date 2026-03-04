import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/widgets/battery_indicator.dart';

void main() {
  group('BatteryIndicator', () {
    testWidgets('renders without crashing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(voltage: 3.7, isCharging: false),
          ),
        ),
      );
      expect(find.byType(BatteryIndicator), findsOneWidget);
    });

    testWidgets('shows percentage text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(
              voltage: 3.7,
              isCharging: false,
              percentage: 75.0,
            ),
          ),
        ),
      );
      expect(find.text('75%'), findsOneWidget);
    });

    testWidgets('shows charging indicator when isCharging is true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(voltage: 3.7, isCharging: true),
          ),
        ),
      );
      // The bolt icon overlay is present when charging
      expect(
        find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.bolt,
        ),
        findsOneWidget,
      );
      // The lightning emoji text is also rendered
      expect(find.text('⚡'), findsOneWidget);
    });

    testWidgets('does not show charging indicator when isCharging is false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(voltage: 3.7, isCharging: false),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.bolt,
        ),
        findsNothing,
      );
      expect(find.text('⚡'), findsNothing);
    });

    testWidgets('shows full battery icon at high voltage', (tester) async {
      // voltage 4.2 → pct = 100 → Icons.battery_full
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(voltage: 4.2, isCharging: false),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.battery_full,
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows critical battery color at low percentage', (tester) async {
      // percentage 10 → pct ≤ 20 → Colors.red
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(
              voltage: 3.7,
              isCharging: false,
              percentage: 10.0,
            ),
          ),
        ),
      );
      // The percentage text should be rendered in red
      final percentageText = tester.widget<Text>(find.text('10%'));
      expect(percentageText.style?.color, equals(Colors.red));
    });

    testWidgets('percentage overrides voltage', (tester) async {
      // voltage 3.0 → pct ≈ 0%, but explicit percentage: 80.0 → shows "80%"
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(
              voltage: 3.0,
              isCharging: false,
              percentage: 80.0,
            ),
          ),
        ),
      );
      expect(find.text('80%'), findsOneWidget);
      // "0%" must NOT be shown
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('clamps percentage to 0-100', (tester) async {
      // percentage 150 is clamped to 100 → shows "100%"
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryIndicator(
              voltage: 3.7,
              isCharging: false,
              percentage: 150.0,
            ),
          ),
        ),
      );
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('150%'), findsNothing);
    });
  });
}
