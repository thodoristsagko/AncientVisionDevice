import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

// ===================== SENSOR HISTORY GRAPH CARD =====================

enum _Metric { ppv, rms, crest, freq }

enum _TimeRange { min1, min5, min30 }

class SensorHistoryGraphCard extends StatefulWidget {
  /// Legacy history entries with 'vibration' and 'moisture' keys.
  final List<Map<String, dynamic>> sensorHistory;

  /// PPV history entries with 'ppv', 'rms', 'crest', 'freq' keys.
  /// When non-empty this source is used for the metric-toggle view.
  final List<Map<String, dynamic>> ppvHistory;

  const SensorHistoryGraphCard({
    super.key,
    required this.sensorHistory,
    this.ppvHistory = const [],
  });

  @override
  State<SensorHistoryGraphCard> createState() => _SensorHistoryGraphCardState();
}

class _SensorHistoryGraphCardState extends State<SensorHistoryGraphCard> {
  _Metric _metric = _Metric.ppv;
  _TimeRange _range = _TimeRange.min5;

  // Samples per second from safety_view (data arrives at 2 Hz).
  static const double _hz = 2.0;

  static const _metricColors = {
    _Metric.ppv: Color(0xFFEF5350),
    _Metric.rms: Color(0xFF42A5F5),
    _Metric.crest: Color(0xFFFFCA28),
    _Metric.freq: Color(0xFF66BB6A),
  };

  static const _metricLabels = {
    _Metric.ppv: 'PPV',
    _Metric.rms: 'RMS',
    _Metric.crest: 'Crest',
    _Metric.freq: 'Freq',
  };

  static const _metricUnits = {
    _Metric.ppv: 'mm/s',
    _Metric.rms: 'g',
    _Metric.crest: '',
    _Metric.freq: 'Hz',
  };

  static const _metricKeys = {
    _Metric.ppv: 'ppv',
    _Metric.rms: 'rms',
    _Metric.crest: 'crest',
    _Metric.freq: 'freq',
  };

  int get _maxSamples {
    switch (_range) {
      case _TimeRange.min1:
        return (60 * _hz).round();
      case _TimeRange.min5:
        return (300 * _hz).round();
      case _TimeRange.min30:
        return (1800 * _hz).round();
    }
  }

  List<Map<String, dynamic>> get _displayData {
    final src = widget.ppvHistory.isNotEmpty ? widget.ppvHistory : widget.sensorHistory;
    if (src.length <= _maxSamples) return src;
    return src.sublist(src.length - _maxSamples);
  }

  @override
  Widget build(BuildContext context) {
    final data = _displayData;
    final hasPpvData = widget.ppvHistory.isNotEmpty;
    final color = _metricColors[_metric]!;
    final unit = _metricUnits[_metric]!;

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
          // ── Header row ──────────────────────────────────────────────
          const Row(
            children: [
              Text(
                'Sensor History',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              Spacer(),
              Text('Live', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),

          // ── Metric toggle (only shown when PPV history is available) ─
          if (hasPpvData) ...[
            _buildMetricToggle(),
            const SizedBox(height: 8),
          ],

          // ── Time-range selector ──────────────────────────────────────
          _buildTimeRangeSelector(),
          const SizedBox(height: 10),

          // ── Legend (legacy mode) or metric label ─────────────────────
          if (!hasPpvData)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLegendItem(const Color(0xFF42A5F5), 'Moisture'),
                const SizedBox(width: 24),
                _buildLegendItem(const Color(0xFFEF5350), 'Vibration'),
              ],
            )
          else
            Row(
              children: [
                Container(
                  width: 18,
                  height: 4,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_metricLabels[_metric]} ($unit)',
                  style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          const SizedBox(height: 10),

          // ── Graph ────────────────────────────────────────────────────
          if (data.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  children: [
                    Icon(Icons.sensors_off_rounded, color: Colors.white.withAlpha(100), size: 32),
                    const SizedBox(height: 8),
                    Text(
                      'Waiting for sensor data...',
                      style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          else if (hasPpvData)
            // Enhanced PPV-mode graph with stats
            _buildPpvGraph(data, color, unit)
          else
            // Legacy moisture + vibration dual-line graph
            _buildLegacyGraph(data),
        ],
      ),
    );
  }

  // ── Metric toggle row ────────────────────────────────────────────────────
  Widget _buildMetricToggle() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _Metric.values.map((m) {
          final selected = m == _metric;
          final c = _metricColors[m]!;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => setState(() => _metric = m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: selected ? c.withAlpha(50) : Colors.white.withAlpha(12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected ? c : Colors.white.withAlpha(40),
                    width: selected ? 1.5 : 1,
                  ),
                ),
                child: Text(
                  _metricLabels[m]!,
                  style: TextStyle(
                    color: selected ? c : Colors.white.withAlpha(160),
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Time-range selector ──────────────────────────────────────────────────
  Widget _buildTimeRangeSelector() {
    const ranges = [_TimeRange.min1, _TimeRange.min5, _TimeRange.min30];
    const labels = ['1 min', '5 min', '30 min'];
    return Row(
      children: List.generate(ranges.length, (i) {
        final selected = _range == ranges[i];
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: () => setState(() => _range = ranges[i]),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? Colors.white.withAlpha(35) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? Colors.white.withAlpha(120) : Colors.white.withAlpha(40),
                ),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white.withAlpha(130),
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  // ── Enhanced PPV-mode graph ──────────────────────────────────────────────
  Widget _buildPpvGraph(List<Map<String, dynamic>> data, Color color, String unit) {
    // Compute stats for right-axis labels
    final key = _metricKeys[_metric]!;
    final values = data.map((e) => (e[key] as num?)?.toDouble() ?? 0.0).toList();
    final mean = values.isEmpty ? 0.0 : values.reduce((a, b) => a + b) / values.length;
    final variance = values.isEmpty
        ? 0.0
        : values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / values.length;
    final sigma = sqrt(variance);
    final maxVal = values.isEmpty ? 1.0 : values.reduce(max);
    final displayMax = maxVal <= 0 ? 1.0 : maxVal * 1.25;

    // Format a value for the right-axis label
    String fmt(double v) => v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left y-axis labels
        SizedBox(
          width: 36,
          height: 130,
          child: Stack(
            children: [
              Positioned(top: 0, right: 0, child: _axisLabel(fmt(displayMax))),
              Positioned(top: 55, right: 0, child: _axisLabel(fmt(displayMax / 2))),
              Positioned(bottom: 0, right: 0, child: _axisLabel('0')),
            ],
          ),
        ),
        const SizedBox(width: 4),
        // Graph
        Expanded(
          child: SizedBox(
            height: 130,
            child: CustomPaint(
              size: const Size(double.infinity, 130),
              painter: PpvGraphPainter(
                data: data,
                metricKey: key,
                color: color,
                mean: mean,
                sigma: sigma,
                displayMax: displayMax,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // Right-axis stat labels
        SizedBox(
          width: 46,
          height: 130,
          child: _buildRightAxisLabels(mean, sigma, displayMax, fmt, color, unit),
        ),
      ],
    );
  }

  Widget _buildRightAxisLabels(
      double mean, double sigma, double displayMax, String Function(double) fmt, Color color, String unit) {
    // Position each label proportionally within the 130px height
    const graphH = 130.0;
    const topPad = 8.0;
    const botPad = 4.0;
    const netH = graphH - topPad - botPad;

    double yFor(double v) => topPad + netH - (netH * (v / displayMax)).clamp(0.0, netH);

    final annotations = <_StatAnnotation>[
      _StatAnnotation(mean + sigma, 'μ+σ', Colors.white.withAlpha(150)),
      _StatAnnotation(mean, 'μ', Colors.white.withAlpha(200)),
      _StatAnnotation((mean - sigma).clamp(0, double.infinity), 'μ−σ', Colors.white.withAlpha(150)),
    ];

    return Stack(
      children: annotations.map((ann) {
        final y = yFor(ann.value) - 6; // shift up half text height
        return Positioned(
          top: y.clamp(0.0, graphH - 14),
          left: 0,
          right: 0,
          child: Text(
            '${fmt(ann.value)} ${unit.isEmpty ? '' : unit}\n${ann.label}',
            style: TextStyle(color: ann.color, fontSize: 7.5, height: 1.1),
            textAlign: TextAlign.left,
            maxLines: 2,
          ),
        );
      }).toList(),
    );
  }

  // ── Legacy dual-line graph ───────────────────────────────────────────────
  Widget _buildLegacyGraph(List<Map<String, dynamic>> data) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _axisLabel('100%'),
            const SizedBox(height: 28),
            _axisLabel('50%'),
            const SizedBox(height: 28),
            _axisLabel('0%'),
          ],
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 120,
            child: CustomPaint(
              size: const Size(double.infinity, 120),
              painter: SensorGraphPainter(data),
            ),
          ),
        ),
      ],
    );
  }

  Widget _axisLabel(String text) {
    return Text(text, style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9));
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

// ── Helper class for right-axis annotations ──────────────────────────────────
class _StatAnnotation {
  final double value;
  final String label;
  final Color color;
  const _StatAnnotation(this.value, this.label, this.color);
}

// ===================== PPV GRAPH PAINTER =====================
/// Draws a single-metric line with:
///   - Light grey horizontal grid lines
///   - Dashed lines for mean and mean±1σ
///   - Gradient fill under the curve
///   - A peak marker (yellow circle)
class PpvGraphPainter extends CustomPainter {
  final List<Map<String, dynamic>> data;
  final String metricKey;
  final Color color;
  final double mean;
  final double sigma;
  final double displayMax;

  const PpvGraphPainter({
    required this.data,
    required this.metricKey,
    required this.color,
    required this.mean,
    required this.sigma,
    required this.displayMax,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    const double topPad = 8.0;
    const double botPad = 4.0;
    final double netH = size.height - topPad - botPad;
    final double netW = size.width;

    // Helper: value → canvas Y
    double yFor(double v) => topPad + netH - (netH * (v / displayMax)).clamp(0.0, netH);

    // ── Grid lines ─────────────────────────────────────────────────────────
    final gridPaint = Paint()
      ..color = Colors.white.withAlpha(18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final y = topPad + (netH * i / 4);
      canvas.drawLine(Offset(0, y), Offset(netW, y), gridPaint);
    }

    // ── Statistical annotation lines (dashed) ──────────────────────────────
    final annotations = [
      _DashLine(mean + sigma, Colors.white.withAlpha(60)),
      _DashLine(mean, Colors.white.withAlpha(110)),
      _DashLine((mean - sigma).clamp(0, double.infinity), Colors.white.withAlpha(60)),
    ];

    for (final ann in annotations) {
      if (ann.value < 0 || ann.value > displayMax * 1.05) continue;
      _drawDashedLine(canvas, netW, yFor(ann.value), ann.color);
    }

    // ── Build points ────────────────────────────────────────────────────────
    final values = data.map((e) => (e[metricKey] as num?)?.toDouble() ?? 0.0).toList();
    final points = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      final x = netW * i / (values.length - 1).clamp(1, 999999);
      final y = yFor(values[i]);
      points.add(Offset(x, y));
    }

    if (points.length < 2) {
      // Single point
      canvas.drawCircle(points.first, 3, Paint()..color = color);
      return;
    }

    // ── Build smooth path ───────────────────────────────────────────────────
    final linePath = ui.Path();
    linePath.moveTo(points[0].dx, points[0].dy);
    for (int i = 0; i < points.length - 1; i++) {
      final cur = points[i];
      final nxt = points[i + 1];
      final mx = (cur.dx + nxt.dx) / 2;
      final my = (cur.dy + nxt.dy) / 2;
      linePath.quadraticBezierTo(cur.dx, cur.dy, mx, my);
    }
    linePath.lineTo(points.last.dx, points.last.dy);

    // ── Gradient fill ───────────────────────────────────────────────────────
    final fillPath = ui.Path.from(linePath);
    fillPath.lineTo(netW, topPad + netH);
    fillPath.lineTo(0, topPad + netH);
    fillPath.close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, topPad),
          Offset(0, topPad + netH),
          [color.withAlpha(70), color.withAlpha(8)],
        ),
    );

    // ── Glow + line ──────────────────────────────────────────────────────────
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color.withAlpha(45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4),
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // ── Peak marker ──────────────────────────────────────────────────────────
    int peakIdx = 0;
    for (int i = 1; i < values.length; i++) {
      if (values[i] > values[peakIdx]) peakIdx = i;
    }
    final peakPt = points[peakIdx];
    const peakColor = Color(0xFFFFD54F);
    canvas.drawCircle(
      peakPt,
      5,
      Paint()..color = Colors.black.withAlpha(120),
    );
    canvas.drawCircle(
      peakPt,
      4,
      Paint()..color = peakColor,
    );
    canvas.drawCircle(
      peakPt,
      4,
      Paint()
        ..color = peakColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _drawDashedLine(Canvas canvas, double width, double y, Color color) {
    const dashW = 6.0;
    const gapW = 4.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    double x = 0;
    while (x < width) {
      canvas.drawLine(Offset(x, y), Offset(min(x + dashW, width), y), paint);
      x += dashW + gapW;
    }
  }

  @override
  bool shouldRepaint(PpvGraphPainter oldDelegate) =>
      oldDelegate.data.length != data.length ||
      oldDelegate.metricKey != metricKey ||
      oldDelegate.mean != mean ||
      oldDelegate.displayMax != displayMax;
}

class _DashLine {
  final double value;
  final Color color;
  const _DashLine(this.value, this.color);
}

// ===================== LEGACY SENSOR GRAPH PAINTER =====================
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

    _drawSmoothLineWithFill(
      canvas, size, data, 'moisture', maxMoisture,
      moistureColor, topPadding, bottomPadding, leftPadding, graphWidth, graphHeight,
    );

    _drawSmoothLineWithFill(
      canvas, size, data, 'vibration', maxVibration,
      vibrationColor, topPadding, bottomPadding, leftPadding, graphWidth, graphHeight,
    );

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

    final linePath = ui.Path();
    linePath.moveTo(points[0].dx, points[0].dy);

    for (int i = 0; i < points.length - 1; i++) {
      final current = points[i];
      final next = points[i + 1];
      final midX = (current.dx + next.dx) / 2;
      final midY = (current.dy + next.dy) / 2;
      linePath.quadraticBezierTo(current.dx, current.dy, midX, midY);
    }
    linePath.lineTo(points.last.dx, points.last.dy);

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

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);

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
