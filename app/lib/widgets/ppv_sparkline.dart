import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Mini sparkline chart showing PPV history with a threshold line.
class PpvSparkline extends StatelessWidget {
  final List<double> data;
  final double threshold;
  final Color lineColor;
  final Color thresholdColor;
  final Color fillColor;

  const PpvSparkline({
    super.key,
    required this.data,
    required this.threshold,
    this.lineColor = Colors.white,
    this.thresholdColor = const Color(0xFFFFD54F),
    this.fillColor = const Color(0x33FFFFFF),
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const Center(
        child: Text('No data', style: TextStyle(color: Colors.white54, fontSize: 12)),
      );
    }

    return CustomPaint(
      painter: _SparklinePainter(
        data: data,
        threshold: threshold,
        lineColor: lineColor,
        thresholdColor: thresholdColor,
        fillColor: fillColor,
      ),
      size: Size.infinite,
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final double threshold;
  final Color lineColor;
  final Color thresholdColor;
  final Color fillColor;

  _SparklinePainter({
    required this.data,
    required this.threshold,
    required this.lineColor,
    required this.thresholdColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final maxVal = math.max(data.reduce(math.max), threshold * 1.2);
    final range = maxVal;
    if (range == 0) return;

    double yOf(double v) => size.height - (v / range * size.height);
    double xOf(int i) => i / (data.length - 1).clamp(1, double.infinity) * size.width;

    // Threshold dashed line
    final thresholdY = yOf(threshold);
    final threshPaint = Paint()
      ..color = thresholdColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dashWidth = 6.0;
    const dashGap = 4.0;
    var startX = 0.0;
    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, thresholdY),
        Offset(math.min(startX + dashWidth, size.width), thresholdY),
        threshPaint,
      );
      startX += dashWidth + dashGap;
    }

    // Threshold label
    final tp = TextPainter(
      text: TextSpan(
        text: '${threshold.toStringAsFixed(1)} mm/s',
        style: TextStyle(color: thresholdColor, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - tp.width - 2, thresholdY - tp.height - 2));

    // Data path
    final path = Path();
    path.moveTo(xOf(0), yOf(data[0]));
    for (var i = 1; i < data.length; i++) {
      path.lineTo(xOf(i), yOf(data[i]));
    }

    // Fill under curve
    final fillPath = Path.from(path)
      ..lineTo(xOf(data.length - 1), size.height)
      ..lineTo(xOf(0), size.height)
      ..close();
    canvas.drawPath(fillPath, Paint()..color = fillColor);

    // Stroke line
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // Current value dot
    final lastX = xOf(data.length - 1);
    final lastY = yOf(data.last);
    canvas.drawCircle(
      Offset(lastX, lastY),
      4,
      Paint()..color = data.last > threshold ? const Color(0xFFE53935) : lineColor,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.data != data || old.threshold != threshold;
}
