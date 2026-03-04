import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A rolling PPV (Peak Particle Velocity) line chart rendered with CustomPainter.
///
/// Shows the last [maxPoints] values as a line with a filled area.  The fill
/// colour changes based on proximity to [threshold]:
///   - below 80% of threshold → semi-transparent green
///   - 80–100% of threshold   → semi-transparent orange
///   - above threshold        → semi-transparent red
///
/// A dashed horizontal line is drawn at [threshold] when provided.
/// Min / max Y-axis labels are shown on the left edge.
class PpvTrendChart extends StatelessWidget {
  final List<double> values;
  final double? threshold;
  final int maxPoints;

  const PpvTrendChart({
    super.key,
    required this.values,
    this.threshold,
    this.maxPoints = 60,
  });

  @override
  Widget build(BuildContext context) {
    // Trim to the last maxPoints entries
    final display = values.length > maxPoints
        ? values.sublist(values.length - maxPoints)
        : values;

    if (display.isEmpty) {
      return SizedBox(
        height: 80,
        child: Center(
          child: Text(
            'No PPV data',
            style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 12),
          ),
        ),
      );
    }

    return SizedBox(
      height: 80,
      child: CustomPaint(
        painter: _PpvTrendPainter(
          values: display,
          threshold: threshold,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _PpvTrendPainter extends CustomPainter {
  final List<double> values;
  final double? threshold;

  const _PpvTrendPainter({required this.values, this.threshold});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final maxVal = math.max(
      values.reduce(math.max),
      threshold != null ? threshold! * 1.15 : 0.001,
    );
    final minVal = math.min(
      values.reduce(math.min),
      0.0,
    );
    final range = maxVal - minVal;
    if (range == 0) return;

    // Helpers
    double yOf(double v) =>
        size.height - ((v - minVal) / range * size.height).clamp(0.0, size.height);
    double xOf(int i) =>
        (i / (values.length - 1).clamp(1, double.infinity)) * size.width;

    // ── Determine fill colour based on current (last) value vs threshold ──────
    Color fillColor;
    Color lineColor;
    if (threshold != null) {
      final last = values.last;
      if (last > threshold!) {
        fillColor = Colors.red.withAlpha(60);
        lineColor = Colors.red;
      } else if (last >= threshold! * 0.8) {
        fillColor = Colors.orange.withAlpha(60);
        lineColor = Colors.orange;
      } else {
        fillColor = Colors.green.withAlpha(50);
        lineColor = const Color(0xFF4CAF50);
      }
    } else {
      fillColor = Colors.white.withAlpha(30);
      lineColor = Colors.white70;
    }

    // ── Build data path ────────────────────────────────────────────────────────
    final dataPath = Path();
    dataPath.moveTo(xOf(0), yOf(values[0]));
    for (var i = 1; i < values.length; i++) {
      dataPath.lineTo(xOf(i), yOf(values[i]));
    }

    // ── Filled area under the line ─────────────────────────────────────────────
    final fillPath = Path.from(dataPath)
      ..lineTo(xOf(values.length - 1), size.height)
      ..lineTo(xOf(0), size.height)
      ..close();

    canvas.drawPath(fillPath, Paint()..color = fillColor);

    // ── Threshold dashed line ──────────────────────────────────────────────────
    if (threshold != null) {
      final ty = yOf(threshold!);
      const dashW = 6.0;
      const gapW = 4.0;
      var x = 0.0;
      final dashPaint = Paint()
        ..color = Colors.amber.withAlpha(200)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, ty),
          Offset(math.min(x + dashW, size.width), ty),
          dashPaint,
        );
        x += dashW + gapW;
      }
    }

    // ── Data line ──────────────────────────────────────────────────────────────
    canvas.drawPath(
      dataPath,
      Paint()
        ..color = lineColor
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // ── Current value dot ──────────────────────────────────────────────────────
    final lastX = xOf(values.length - 1);
    final lastY = yOf(values.last);
    canvas.drawCircle(
      Offset(lastX, lastY),
      3.5,
      Paint()..color = lineColor,
    );

    // ── Y-axis labels (min / max) ──────────────────────────────────────────────
    _drawLabel(canvas, size, maxVal.toStringAsFixed(2), const Offset(2, 2));
    _drawLabel(
      canvas,
      size,
      minVal.toStringAsFixed(2),
      Offset(2, size.height - 14),
    );
  }

  void _drawLabel(Canvas canvas, Size size, String text, Offset offset) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withAlpha(160),
          fontSize: 9,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 50);
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _PpvTrendPainter old) =>
      old.values != values || old.threshold != threshold;
}
