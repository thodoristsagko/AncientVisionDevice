import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';
import '../../services/vibration_anomaly_service.dart';

// ===================== ML ANOMALY INDICATOR =====================
class MLAnomalyIndicator extends StatelessWidget {
  final AnomalyResult result;
  final Map<String, double> features;
  final List<double> anomalyHistory;
  final String modelVersion;

  const MLAnomalyIndicator({
    super.key,
    required this.result,
    this.features = const {},
    this.anomalyHistory = const [],
    this.modelVersion = '4.0',
  });

  Color _getColor() {
    switch (result.level) {
      case AnomalyLevel.normal: return const Color(0xFF4CAF50);
      case AnomalyLevel.unusual: return const Color(0xFFFFC107);
      case AnomalyLevel.anomaly: return const Color(0xFFE53935);
      case AnomalyLevel.unknown: return Colors.grey;
    }
  }

  IconData _getIcon() {
    switch (result.level) {
      case AnomalyLevel.normal: return Icons.check_circle_outline;
      case AnomalyLevel.unusual: return Icons.help_outline;
      case AnomalyLevel.anomaly: return Icons.warning_rounded;
      case AnomalyLevel.unknown: return Icons.device_unknown;
    }
  }

  /// Compute per-feature contribution using absolute z-score.
  List<MapEntry<String, double>> _topContributors() {
    if (features.isEmpty) return [];

    // StandardScaler means/scales from vibration_scaler.json (v4.0)
    const means = {
      'rms': 0.00937, 'ppv': 0.2061, 'freq': 4.668, 'crest': 2.321,
      'centroid': 16.58, 'kurtosis': 3.25, 'stalta': 1.308,
      'arias': 0.00411, 'cav': 0.037, 'temp': 24.95,
    };
    const scales = {
      'rms': 0.00893, 'ppv': 0.1442, 'freq': 3.334, 'crest': 0.6517,
      'centroid': 8.118, 'kurtosis': 0.5421, 'stalta': 0.3652,
      'arias': 0.00368, 'cav': 0.02822, 'temp': 5.716,
    };

    final contributions = <MapEntry<String, double>>[];
    for (final entry in features.entries) {
      final m = means[entry.key] ?? 0.0;
      final s = scales[entry.key] ?? 1.0;
      final zScore = s > 0 ? ((entry.value - m) / s).abs() : 0.0;
      contributions.add(MapEntry(entry.key, zScore));
    }
    contributions.sort((a, b) => b.value.compareTo(a.value));
    return contributions.take(3).toList();
  }

  static const _featureLabels = {
    'rms': 'RMS', 'ppv': 'PPV', 'freq': 'Freq', 'crest': 'Crest',
    'centroid': 'Centroid', 'kurtosis': 'Kurtosis', 'stalta': 'STA/LTA',
    'arias': 'Arias', 'cav': 'CAV', 'temp': 'Temp',
  };

  @override
  Widget build(BuildContext context) {
    final color = _getColor();
    final topContribs = _topContributors();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  Icon(_getIcon(), color: color, size: 18),
                  const SizedBox(width: 8),
                  Text('Anomaly Detection', style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 12, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(modelVersion, style: TextStyle(color: modelVersion.contains('Rule') ? const Color(0xFFFFC107) : const Color(0xFFCE93D8), fontSize: 9, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Text(result.levelLabel, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 6),
              // Score bar
              Row(
                children: [
                  Text('Score: ', style: TextStyle(color: Colors.white.withAlpha(140), fontSize: 11)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        height: 10,
                        child: Stack(
                          children: [
                            Container(color: Colors.white.withAlpha(20)),
                            FractionallySizedBox(
                              widthFactor: result.score.clamp(0.0, 1.0),
                              child: Container(color: color),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(result.score * 100).toStringAsFixed(0)}%', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ),

              // Reconstruction error detail
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Reconstruction MSE: ', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10)),
                  Text(
                    result.rawError.toStringAsFixed(4),
                    style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 12),
                  Text('Features: ', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10)),
                  Text(
                    '${features.length}/10',
                    style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ],
              ),

              // Top feature contributors
              if (topContribs.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Top contributors (z-score)', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10)),
                const SizedBox(height: 4),
                Row(
                  children: topContribs.map((entry) {
                    final label = _featureLabels[entry.key] ?? entry.key;
                    final zScore = entry.value;
                    final barColor = zScore > 3.0
                        ? const Color(0xFFE53935)
                        : zScore > 2.0
                            ? const Color(0xFFFF9800)
                            : const Color(0xFF4CAF50);
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          children: [
                            Text(label, style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 9)),
                            const SizedBox(height: 2),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(
                                height: 8,
                                child: Stack(
                                  children: [
                                    Container(color: Colors.white.withAlpha(15)),
                                    FractionallySizedBox(
                                      widthFactor: (zScore / 5.0).clamp(0.0, 1.0),
                                      child: Container(color: barColor),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(zScore.toStringAsFixed(1), style: TextStyle(color: barColor, fontSize: 8, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],

              // Sparkline of recent anomaly scores
              if (anomalyHistory.length >= 2) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('Recent scores', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10)),
                    const Spacer(),
                    Text('${anomalyHistory.length} pts', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 40,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _AnomalySparklinePainter(anomalyHistory, color),
                  ),
                ),
              ],
            ],
          ),
    );
  }
}

class _AnomalySparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;

  _AnomalySparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final maxVal = data.reduce(max).clamp(0.01, double.infinity);
    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = size.height - (size.height * (data[i] / maxVal).clamp(0.0, 1.0));
      points.add(Offset(x, y));
    }

    // Fill under curve
    final fillPath = ui.Path();
    fillPath.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      fillPath.lineTo(points[i].dx, points[i].dy);
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.lineTo(0, size.height);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero, Offset(0, size.height),
        [color.withAlpha(60), color.withAlpha(10)],
      ));

    // Line
    final linePath = ui.Path();
    linePath.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      linePath.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(linePath, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round);

    // Latest point dot
    canvas.drawCircle(points.last, 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_AnomalySparklinePainter old) =>
      old.data.length != data.length || (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}
