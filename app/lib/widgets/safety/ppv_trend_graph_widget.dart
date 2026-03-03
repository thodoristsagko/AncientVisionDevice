import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';
import '../../services/ppv_prediction_service.dart';

// ===================== PPV TREND GRAPH (DIN 4150-3) =====================
class PPVTrendGraphCard extends StatelessWidget {
  final List<Map<String, dynamic>> ppvHistory;
  final PPVPrediction? prediction;
  final List<double> kalmanHistory;

  const PPVTrendGraphCard({
    super.key,
    required this.ppvHistory,
    this.prediction,
    this.kalmanHistory = const [],
  });

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
              Text('PPV Trend', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              Spacer(),
              Text('DIN 4150-3', style: TextStyle(color: Color(0xFFFF5722), fontSize: 9, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
              // Legend
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLegendItem(const Color(0xFFFF5722), 'PPV'),
                  const SizedBox(width: 16),
                  _buildLegendItem(const Color(0xFFE53935).withAlpha(150), '3 mm/s limit'),
                  const SizedBox(width: 16),
                  _buildLegendItem(const Color(0xFFFFC107).withAlpha(150), '2.5 mm/s cont.'),
                  if (prediction != null && prediction!.isTrendingUp) ...[
                    const SizedBox(width: 16),
                    _buildLegendItem(const Color(0xFFFF8F00).withAlpha(150), 'Prediction'),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              if (ppvHistory.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(Icons.timeline, color: Colors.white.withAlpha(100), size: 28),
                        const SizedBox(height: 6),
                        Text('Waiting for PPV data...', style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 12)),
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
                        Text('10', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                        const SizedBox(height: 18),
                        Text('5', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                        const SizedBox(height: 18),
                        Text('3', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                        const SizedBox(height: 18),
                        Text('0', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                      ],
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SizedBox(
                        height: 120,
                        child: CustomPaint(
                          size: const Size(double.infinity, 120),
                          painter: PPVGraphPainter(ppvHistory, prediction: prediction),
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
          width: 14, height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class PPVGraphPainter extends CustomPainter {
  final List<Map<String, dynamic>> data;
  final PPVPrediction? prediction;

  PPVGraphPainter(this.data, {this.prediction});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    const double maxPPV = 12.0; // Max Y-axis (mm/s)
    const double topPad = 4.0;
    const double botPad = 2.0;
    final double graphH = size.height - topPad - botPad;

    // Draw grid
    final gridPaint = Paint()
      ..color = Colors.white.withAlpha(15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (int i = 0; i <= 4; i++) {
      final y = topPad + graphH * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Draw DIN 4150-3 limit lines
    // 3 mm/s heritage limit (1-10 Hz)
    final limitY3 = topPad + graphH - (graphH * 3.0 / maxPPV);
    final limitPaint3 = Paint()
      ..color = const Color(0xFFE53935).withAlpha(120)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    _drawDashedLine(canvas, Offset(0, limitY3), Offset(size.width, limitY3), limitPaint3);

    // 2.5 mm/s continuous limit
    final limitY25 = topPad + graphH - (graphH * 2.5 / maxPPV);
    final limitPaint25 = Paint()
      ..color = const Color(0xFFFFC107).withAlpha(100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    _drawDashedLine(canvas, Offset(0, limitY25), Offset(size.width, limitY25), limitPaint25);

    // Draw PPV line
    if (data.length < 2) return;

    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final ppv = ((data[i]['ppv'] as num?)?.toDouble() ?? 0.0).clamp(0.0, maxPPV);
      final y = topPad + graphH - (graphH * ppv / maxPPV);
      points.add(Offset(x, y));
    }

    // Fill
    final fillPath = ui.Path();
    fillPath.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      fillPath.lineTo(points[i].dx, points[i].dy);
    }
    fillPath.lineTo(size.width, topPad + graphH);
    fillPath.lineTo(0, topPad + graphH);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, topPad),
        Offset(0, topPad + graphH),
        [const Color(0xFFFF5722).withAlpha(80), const Color(0xFFFF5722).withAlpha(10)],
      );
    canvas.drawPath(fillPath, fillPaint);

    // Line
    final linePath = ui.Path();
    linePath.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      linePath.lineTo(points[i].dx, points[i].dy);
    }

    final linePaint = Paint()
      ..color = const Color(0xFFFF5722)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(linePath, linePaint);

    // Glow
    final glowPaint = Paint()
      ..color = const Color(0xFFFF5722).withAlpha(40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
    canvas.drawPath(linePath, glowPaint);

    // Latest point dot
    if (points.isNotEmpty) {
      final last = points.last;
      canvas.drawCircle(last, 4, Paint()..color = const Color(0xFFFF5722));
      canvas.drawCircle(last, 4, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }

    // Draw prediction line (dashed, amber)
    if (prediction != null && prediction!.isTrendingUp && prediction!.predicted.isNotEmpty) {
      final predPoints = <Offset>[];
      final lastX = points.last.dx;
      final lastY = points.last.dy;
      predPoints.add(Offset(lastX, lastY));

      final predCount = prediction!.predicted.length;
      final extraWidth = size.width * 0.3; // Extend 30% beyond current data
      for (int i = 0; i < predCount; i++) {
        final px = lastX + extraWidth * (i + 1) / predCount;
        if (px > size.width) break;
        final ppv = prediction!.predicted[i].clamp(0.0, maxPPV);
        final py = topPad + graphH - (graphH * ppv / maxPPV);
        predPoints.add(Offset(px, py));
      }

      if (predPoints.length >= 2) {
        final predPaint = Paint()
          ..color = const Color(0xFFFF8F00).withAlpha(180)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round;
        _drawDashedLine(canvas, predPoints.first, predPoints.last, predPaint);
      }
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashWidth = 6.0;
    const dashSpace = 4.0;
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt(dx * dx + dy * dy);
    final unitX = dx / length;
    final unitY = dy / length;

    double drawn = 0;
    while (drawn < length) {
      final segEnd = (drawn + dashWidth).clamp(0.0, length);
      canvas.drawLine(
        Offset(start.dx + unitX * drawn, start.dy + unitY * drawn),
        Offset(start.dx + unitX * segEnd, start.dy + unitY * segEnd),
        paint,
      );
      drawn += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(PPVGraphPainter oldDelegate) =>
      oldDelegate.data.length != data.length || oldDelegate.prediction != prediction;
}
