import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/widgets/ppv_sparkline.dart';

void main() {
  group('PpvSparkline', () {
    testWidgets('renders CustomPaint with data', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 60,
              child: PpvSparkline(
                data: [0.1, 0.5, 1.0, 2.0, 4.5, 3.0, 1.5],
                threshold: 3.0,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(PpvSparkline), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('renders empty state with no data', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 60,
              child: PpvSparkline(
                data: [],
                threshold: 3.0,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(PpvSparkline), findsOneWidget);
    });
  });
}
