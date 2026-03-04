import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Mini sparkline chart showing PPV history with dual threshold lines,
/// gradient fill, a pulsing current-value dot, and a max-value label.
class PpvSparkline extends StatefulWidget {
  final List<double> data;
  /// Legacy single-threshold param — kept for callers that still pass it.
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
  State<PpvSparkline> createState() => _PpvSparklineState();
}

class _PpvSparklineState extends State<PpvSparkline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  static const double _amberThreshold = 0.3; // mm/s
  static const double _redThreshold = 1.0;   // mm/s

  bool get _isExceedingThreshold =>
      widget.data.isNotEmpty &&
      widget.data.last > _amberThreshold;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.4).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (_isExceedingThreshold) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(PpvSparkline old) {
    super.didUpdateWidget(old);
    if (_isExceedingThreshold && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!_isExceedingThreshold && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0.6;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  /// Returns the color that represents the current PPV danger level.
  Color _levelColor(double ppv) {
    if (ppv >= _redThreshold) return const Color(0xFFE53935);
    if (ppv >= _amberThreshold) return const Color(0xFFFFB300);
    return const Color(0xFF43A047);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty) {
      return const Center(
        child: Text('No data', style: TextStyle(color: Colors.white54, fontSize: 12)),
      );
    }

    final currentPpv = widget.data.last;
    final dotColor = _levelColor(currentPpv);

    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, child) {
        return CustomPaint(
          painter: _SparklinePainter(
            data: widget.data,
            threshold: widget.threshold,
            lineColor: widget.lineColor,
            thresholdColor: widget.thresholdColor,
            dotColor: dotColor,
            pulseScale: _isExceedingThreshold ? _pulseAnim.value : 1.0,
            levelColor: _levelColor,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final double threshold;
  final Color lineColor;
  final Color thresholdColor;
  final Color dotColor;
  final double pulseScale;
  final Color Function(double) levelColor;

  static const double _amberThreshold = 0.3;
  static const double _redThreshold = 1.0;

  _SparklinePainter({
    required this.data,
    required this.threshold,
    required this.lineColor,
    required this.thresholdColor,
    required this.dotColor,
    required this.pulseScale,
    required this.levelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final maxData = data.reduce(math.max);
    // Always show at least up to 1.2× red threshold so lines are visible.
    final maxVal = math.max(maxData * 1.1, _redThreshold * 1.2);
    if (maxVal == 0) return;

    double yOf(double v) => size.height - (v / maxVal * size.height);
    double xOf(int i) => i / (data.length - 1).clamp(1, double.infinity) * size.width;

    // --- Draw threshold lines ---
    _drawDashedThresholdLine(
      canvas, size,
      y: yOf(_amberThreshold),
      color: const Color(0xFFFFB300),
      label: '0.3',
    );
    _drawDashedThresholdLine(
      canvas, size,
      y: yOf(_redThreshold),
      color: const Color(0xFFE53935),
      label: '1.0',
    );

    // --- Build data path ---
    final path = Path();
    path.moveTo(xOf(0), yOf(data[0]));
    for (var i = 1; i < data.length; i++) {
      path.lineTo(xOf(i), yOf(data[i]));
    }

    // --- Gradient fill under curve ---
    final fillPath = Path.from(path)
      ..lineTo(xOf(data.length - 1), size.height)
      ..lineTo(xOf(0), size.height)
      ..close();

    final gradientColor = levelColor(data.last);
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          gradientColor.withAlpha(77), // ~30% opacity at top
          gradientColor.withAlpha(0),  // transparent at bottom
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    // --- Stroke line ---
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // --- Max value label ---
    final maxIndex = data.indexOf(maxData);
    final peakX = xOf(maxIndex);
    final peakY = yOf(maxData);
    final maxLabel = maxData.toStringAsFixed(2);
    final maxTp = TextPainter(
      text: TextSpan(
        text: maxLabel,
        style: TextStyle(
          color: levelColor(maxData).withAlpha(230),
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Position label above peak, clamp to canvas bounds
    final labelX = (peakX - maxTp.width / 2).clamp(0.0, size.width - maxTp.width);
    final labelY = (peakY - maxTp.height - 4).clamp(0.0, size.height - maxTp.height);
    maxTp.paint(canvas, Offset(labelX, labelY));

    // --- Current value dot (with pulse) ---
    final lastX = xOf(data.length - 1);
    final lastY = yOf(data.last);
    const baseRadius = 4.5;
    final scaledRadius = baseRadius * pulseScale;

    // Outer glow ring when pulsing
    if (pulseScale > 0.7) {
      canvas.drawCircle(
        Offset(lastX, lastY),
        scaledRadius + 3,
        Paint()
          ..color = dotColor.withAlpha(60)
          ..style = PaintingStyle.fill,
      );
    }

    // Inner dot
    canvas.drawCircle(
      Offset(lastX, lastY),
      baseRadius,
      Paint()
        ..color = dotColor
        ..style = PaintingStyle.fill,
    );
    // White border
    canvas.drawCircle(
      Offset(lastX, lastY),
      baseRadius,
      Paint()
        ..color = Colors.white.withAlpha(180)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _drawDashedThresholdLine(
    Canvas canvas,
    Size size, {
    required double y,
    required Color color,
    required String label,
  }) {
    if (y < 0 || y > size.height) return;

    final paint = Paint()
      ..color = color.withAlpha(180)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    const dashWidth = 5.0;
    const dashGap = 4.0;
    // Leave right margin for label (~36px)
    const labelMargin = 36.0;
    var x = 0.0;
    while (x < size.width - labelMargin) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dashWidth, size.width - labelMargin), y),
        paint,
      );
      x += dashWidth + dashGap;
    }

    // Label on the right
    final tp = TextPainter(
      text: TextSpan(
        text: '$label mm/s',
        style: TextStyle(
          color: color.withAlpha(200),
          fontSize: 8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - tp.width - 1, y - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.data != data ||
      old.threshold != threshold ||
      old.pulseScale != pulseScale ||
      old.dotColor != dotColor;
}
