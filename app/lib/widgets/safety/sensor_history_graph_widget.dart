import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class SensorHistoryGraphCard extends StatelessWidget {
  final List<Map<String, dynamic>> sensorHistory;

  const SensorHistoryGraphCard({super.key, required this.sensorHistory});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text('Sensor History', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              Spacer(),
              Text('Live', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
              // Legend row with improved styling
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLegendItem(const Color(0xFF42A5F5), 'Moisture'),
                  const SizedBox(width: 24),
                  _buildLegendItem(const Color(0xFFEF5350), 'Vibration'),
                ],
              ),
              const SizedBox(height: 12),
              if (sensorHistory.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(30),
                    child: Column(
                      children: [
                        Icon(Icons.sensors_off_rounded, color: Colors.white.withAlpha(100), size: 32),
                        const SizedBox(height: 8),
                        Text('Waiting for sensor data...', style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 13)),
                      ],
                    ),
                  ),
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Y-axis labels
                    Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('100%', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                        const SizedBox(height: 28),
                        Text('50%', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                        const SizedBox(height: 28),
                        Text('0%', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 120,
                        child: CustomPaint(
                          size: const Size(double.infinity, 120),
                          painter: SensorGraphPainter(sensorHistory),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 4,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
            boxShadow: [BoxShadow(color: color.withAlpha(100), blurRadius: 4)],
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class SensorGraphPainter extends CustomPainter {
  final List<Map<String, dynamic>> data;

  SensorGraphPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    const double leftPadding = 0;
    const double rightPadding = 0;
    const double topPadding = 8.0;
    const double bottomPadding = 4.0;
    final double graphWidth = size.width - leftPadding - rightPadding;
    final double graphHeight = size.height - topPadding - bottomPadding;

    // Draw subtle grid lines
    final gridPaint = Paint()
      ..color = Colors.white.withAlpha(20)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final y = topPadding + (graphHeight * i / 4);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width - rightPadding, y), gridPaint);
    }

    // Max values for scaling
    const double maxVibration = 1.0;
    const double maxMoisture = 100.0;

    // Colors
    const moistureColor = Color(0xFF42A5F5);
    const vibrationColor = Color(0xFFEF5350);

    // Draw moisture area fill and line
    _drawSmoothLineWithFill(
      canvas, size, data, 'moisture', maxMoisture,
      moistureColor, topPadding, bottomPadding, leftPadding, graphWidth, graphHeight,
    );

    // Draw vibration area fill and line (scaled to percentage)
    _drawSmoothLineWithFill(
      canvas, size, data, 'vibration', maxVibration,
      vibrationColor, topPadding, bottomPadding, leftPadding, graphWidth, graphHeight,
    );

    // Draw data points
    _drawDataPoints(canvas, data, 'moisture', maxMoisture, moistureColor, topPadding, leftPadding, graphWidth, graphHeight);
    _drawDataPoints(canvas, data, 'vibration', maxVibration, vibrationColor, topPadding, leftPadding, graphWidth, graphHeight);
  }

  void _drawSmoothLineWithFill(
    Canvas canvas, Size size, List<Map<String, dynamic>> data, String key, double maxValue,
    Color color, double topPadding, double bottomPadding, double leftPadding, double graphWidth, double graphHeight,
  ) {
    if (data.length < 2) return;

    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = leftPadding + (graphWidth * i / (data.length - 1));
      final value = (data[i][key] as num?)?.toDouble() ?? 0.0;
      final y = topPadding + graphHeight - (graphHeight * value / maxValue);
      points.add(Offset(x, y));
    }

    // Create smooth path using quadratic bezier curves
    final linePath = ui.Path();
    linePath.moveTo(points[0].dx, points[0].dy);

    for (int i = 0; i < points.length - 1; i++) {
      final current = points[i];
      final next = points[i + 1];
      final midX = (current.dx + next.dx) / 2;
      final midY = (current.dy + next.dy) / 2;

      if (i == 0) {
        linePath.quadraticBezierTo(current.dx, current.dy, midX, midY);
      } else {
        linePath.quadraticBezierTo(current.dx, current.dy, midX, midY);
      }
    }
    linePath.lineTo(points.last.dx, points.last.dy);

    // Draw gradient fill
    final fillPath = ui.Path.from(linePath);
    fillPath.lineTo(leftPadding + graphWidth, topPadding + graphHeight);
    fillPath.lineTo(leftPadding, topPadding + graphHeight);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, topPadding),
        Offset(0, topPadding + graphHeight),
        [color.withAlpha(80), color.withAlpha(10)],
      );
    canvas.drawPath(fillPath, fillPaint);

    // Draw line
    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);

    // Draw glow effect
    final glowPaint = Paint()
      ..color = color.withAlpha(50)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4);
    canvas.drawPath(linePath, glowPaint);
  }

  void _drawDataPoints(
    Canvas canvas, List<Map<String, dynamic>> data, String key, double maxValue,
    Color color, double topPadding, double leftPadding, double graphWidth, double graphHeight,
  ) {
    final dotPaint = Paint()..color = color;
    final dotBorderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Only draw dots at first, last, and a few middle points to avoid clutter
    final indicesToDraw = <int>{0, data.length - 1};
    if (data.length > 4) {
      indicesToDraw.add(data.length ~/ 2);
    }

    for (final i in indicesToDraw) {
      final x = leftPadding + (graphWidth * i / (data.length - 1));
      final value = (data[i][key] as num?)?.toDouble() ?? 0.0;
      final y = topPadding + graphHeight - (graphHeight * value / maxValue);

      canvas.drawCircle(Offset(x, y), 4, dotPaint);
      canvas.drawCircle(Offset(x, y), 4, dotBorderPaint);
    }
  }

  @override
  bool shouldRepaint(SensorGraphPainter oldDelegate) => oldDelegate.data.length != data.length;
}
