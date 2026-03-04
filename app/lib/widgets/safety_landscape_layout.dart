import 'package:flutter/material.dart';
import '../services/vibration_anomaly_service.dart';
import 'anomaly_level_badge.dart';
import 'ppv_trend_chart.dart';

/// Landscape layout for the Safety View.
///
/// In landscape orientation the screen is too wide for a single-column layout.
/// This widget splits the view into:
///   - Left half: PPV value + anomaly badge (gauges)
///   - Right half: rolling PPV trend chart + key stats
///
/// Intended to be used inside an [OrientationBuilder] in safety_view.dart:
/// ```dart
/// OrientationBuilder(builder: (ctx, orientation) {
///   if (orientation == Orientation.landscape) {
///     return SafetyLandscapeLayout(ppv: ppv, level: level, ppvHistory: history);
///   }
///   return _portraitLayout();
/// })
/// ```
class SafetyLandscapeLayout extends StatelessWidget {
  /// Current peak particle velocity in mm/s.
  final double ppv;

  /// Current anomaly classification.
  final AnomalyLevel level;

  /// Rolling history of PPV samples (oldest first, newest last).
  final List<double> ppvHistory;

  /// Optional anomaly score 0-1.
  final double anomalyScore;

  /// Optional dominant frequency in Hz.
  final double dominantFreq;

  /// Optional session elapsed time.
  final Duration? sessionElapsed;

  /// Whether the BLE sensor is currently connected.
  final bool isConnected;

  const SafetyLandscapeLayout({
    super.key,
    required this.ppv,
    required this.level,
    required this.ppvHistory,
    this.anomalyScore = 0.0,
    this.dominantFreq = 0.0,
    this.sessionElapsed,
    this.isConnected = false,
  });

  // ── Colour helpers ──────────────────────────────────────────────────────────

  Color get _ppvColor {
    if (ppv >= 5.0) return const Color(0xFFD32F2F);
    if (ppv >= 3.0) return const Color(0xFFFF9800);
    if (ppv >= 0.3) return const Color(0xFFFFC107);
    return const Color(0xFF4CAF50);
  }

  String _formatElapsed(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D1B1A),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Left: gauges ────────────────────────────────────────────────
          Expanded(
            flex: 4,
            child: _buildGaugePanel(),
          ),
          // Vertical divider
          const VerticalDivider(
            color: Colors.white12,
            width: 1,
            thickness: 1,
          ),
          // ── Right: chart + stats ─────────────────────────────────────────
          Expanded(
            flex: 6,
            child: _buildChartPanel(),
          ),
        ],
      ),
    );
  }

  // ── Left panel ──────────────────────────────────────────────────────────────

  Widget _buildGaugePanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Connection dot
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isConnected ? Colors.green : Colors.red,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                isConnected ? 'Connected' : 'Disconnected',
                style: TextStyle(
                  color: isConnected ? Colors.green : Colors.red,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // PPV value
          Text(
            ppv.toStringAsFixed(3),
            style: TextStyle(
              color: _ppvColor,
              fontSize: 52,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            'mm/s PPV',
            style: TextStyle(
              color: Colors.white.withAlpha(160),
              fontSize: 13,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 20),

          // Anomaly badge
          AnomalyLevelBadge(level: level, large: true),
          const SizedBox(height: 16),

          // Anomaly score
          if (anomalyScore > 0)
            Text(
              'Score: ${(anomalyScore * 100).toStringAsFixed(1)}%',
              style: TextStyle(
                color: Colors.white.withAlpha(130),
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }

  // ── Right panel ─────────────────────────────────────────────────────────────

  Widget _buildChartPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Chart header
          const Text(
            'PPV History (60 samples)',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),

          // Trend chart — takes most vertical space
          Expanded(
            child: PpvTrendChart(
              values: ppvHistory,
              threshold: 0.3,
            ),
          ),

          const SizedBox(height: 8),

          // Stats row
          _buildStatsRow(),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final peakPpv =
        ppvHistory.isEmpty ? ppv : ppvHistory.reduce((a, b) => a > b ? a : b);
    return Row(
      children: [
        _StatChip(label: 'Peak', value: '${peakPpv.toStringAsFixed(3)} mm/s'),
        const SizedBox(width: 8),
        _StatChip(
          label: 'Freq',
          value: dominantFreq > 0
              ? '${dominantFreq.toStringAsFixed(1)} Hz'
              : '-- Hz',
        ),
        const SizedBox(width: 8),
        _StatChip(
          label: 'Session',
          value: _formatElapsed(sessionElapsed),
        ),
      ],
    );
  }
}

// ── Stat chip helper ──────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String label;
  final String value;

  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
