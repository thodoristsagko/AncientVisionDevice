import 'dart:math';
import 'package:flutter/material.dart';
import '../../services/wavelet_service.dart';

// ===================== WAVELET ANALYSIS CARD =====================

/// Frequency-band labels for each DWT decomposition level.
/// At 200 Hz sample rate: D1=50-100Hz, D2=25-50Hz, D3=12-25Hz, A3=0-12Hz.
const _kBandLabels = {
  'D1': 'Level 1 (50-100 Hz)',
  'D2': 'Level 2 (25-50 Hz)',
  'D3': 'Level 3 (12-25 Hz)',
};

class WaveletAnalysisCard extends StatefulWidget {
  final Map<String, double> bandEnergy;
  final List<TransientEvent> transients;
  final bool transientFlash;
  final double bufferFill;

  const WaveletAnalysisCard({
    super.key,
    required this.bandEnergy,
    required this.transients,
    required this.transientFlash,
    this.bufferFill = 1.0,
  });

  @override
  State<WaveletAnalysisCard> createState() => _WaveletAnalysisCardState();
}

class _WaveletAnalysisCardState extends State<WaveletAnalysisCard> {
  /// Previous frame's per-band energies, keyed by band prefix (D1/D2/D3).
  Map<String, double> _prevEnergy = {};

  /// Returns a trend arrow and its color comparing [current] to [previous].
  ///
  /// Trend is significant only when the relative change exceeds 10%.
  ({String arrow, Color color}) _trend(double current, double previous) {
    if (previous <= 0) return (arrow: '', color: Colors.transparent);
    final delta = (current - previous) / previous;
    if (delta > 0.10) return (arrow: '↑', color: const Color(0xFFE53935));
    if (delta < -0.10) return (arrow: '↓', color: const Color(0xFF4CAF50));
    return (arrow: '→', color: Colors.white54);
  }

  @override
  void didUpdateWidget(WaveletAnalysisCard old) {
    super.didUpdateWidget(old);
    // Snapshot energies before the new frame replaces them.
    final prev = <String, double>{};
    for (final prefix in ['D1', 'D2', 'D3']) {
      final entry = old.bandEnergy.entries
          .where((e) => e.key.startsWith(prefix))
          .firstOrNull;
      if (entry != null) prev[prefix] = entry.value;
    }
    _prevEnergy = prev;
  }

  @override
  Widget build(BuildContext context) {
    // Extract detail-level energies (D1, D2, D3).
    final d1Entry = widget.bandEnergy.entries
        .where((e) => e.key.startsWith('D1'))
        .firstOrNull;
    final d2Entry = widget.bandEnergy.entries
        .where((e) => e.key.startsWith('D2'))
        .firstOrNull;
    final d3Entry = widget.bandEnergy.entries
        .where((e) => e.key.startsWith('D3'))
        .firstOrNull;

    final d1Energy = d1Entry?.value ?? 0.0;
    final d2Energy = d2Entry?.value ?? 0.0;
    final d3Energy = d3Entry?.value ?? 0.0;
    final totalEnergy = widget.bandEnergy.values.fold(0.0, (a, b) => a + b);
    final maxEnergy = [d1Energy, d2Energy, d3Energy].reduce(max);

    // Determine if any single band dominates (>60% of total energy).
    String? concentrationBand;
    String? concentrationBandHz;
    if (totalEnergy > 0) {
      if (d1Energy / totalEnergy > 0.60) {
        concentrationBand = d1Entry?.key ?? 'D1';
        concentrationBandHz = '50-100';
      } else if (d2Energy / totalEnergy > 0.60) {
        concentrationBand = d2Entry?.key ?? 'D2';
        concentrationBandHz = '25-50';
      } else if (d3Energy / totalEnergy > 0.60) {
        concentrationBand = d3Entry?.key ?? 'D3';
        concentrationBandHz = '12-25';
      }
    }

    final Color accentColor = widget.transientFlash
        ? const Color(0xFFFF5722)
        : const Color(0xFF7C4DFF);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
        border: widget.transientFlash
            ? Border.all(
                color: const Color(0xFFFF5722).withAlpha(150), width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Text('Wavelet Analysis',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('Haar DWT',
                  style: TextStyle(
                      color: accentColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 14),

          // Transient detection indicator
          if (widget.transientFlash) ...[
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFF5722).withAlpha(30),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: const Color(0xFFFF5722).withAlpha(100), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.flash_on_rounded,
                      color: Color(0xFFFF5722), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Transient detected! ${widget.transients.length} '
                      'event${widget.transients.length != 1 ? 's' : ''} '
                      '(Level ${widget.transients.isNotEmpty ? widget.transients.first.level : "-"})',
                      style: const TextStyle(
                          color: Color(0xFFFF5722),
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],

          // Energy concentration warning
          if (concentrationBand != null) ...[
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFFF9800).withAlpha(30),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: const Color(0xFFFF9800).withAlpha(100), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Color(0xFFFF9800), size: 15),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'Energy concentration in $concentrationBandHz Hz band',
                      style: const TextStyle(
                          color: Color(0xFFFF9800),
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Band energy horizontal bars with labels and trend arrows
          _buildBandBar(
            _kBandLabels['D1'] ?? (d1Entry?.key ?? 'D1: 50-100 Hz'),
            d1Energy,
            maxEnergy,
            totalEnergy,
            const Color(0xFF4CAF50),
            _trend(d1Energy, _prevEnergy['D1'] ?? 0),
          ),
          const SizedBox(height: 8),
          _buildBandBar(
            _kBandLabels['D2'] ?? (d2Entry?.key ?? 'D2: 25-50 Hz'),
            d2Energy,
            maxEnergy,
            totalEnergy,
            const Color(0xFFFF9800),
            _trend(d2Energy, _prevEnergy['D2'] ?? 0),
          ),
          const SizedBox(height: 8),
          _buildBandBar(
            _kBandLabels['D3'] ?? (d3Entry?.key ?? 'D3: 12-25 Hz'),
            d3Energy,
            maxEnergy,
            totalEnergy,
            const Color(0xFFFF5722),
            _trend(d3Energy, _prevEnergy['D3'] ?? 0),
          ),
          const SizedBox(height: 10),

          // Summary row
          Row(
            children: [
              _buildMiniStat('Total Energy', totalEnergy.toStringAsFixed(4)),
              const SizedBox(width: 12),
              _buildMiniStat('Transients', '${widget.transients.length}'),
              const SizedBox(width: 12),
              _buildMiniStat(
                  'Buffer', '${(widget.bufferFill * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBandBar(
    String label,
    double energy,
    double maxEnergy,
    double totalEnergy,
    Color color,
    ({String arrow, Color color}) trend,
  ) {
    final fraction =
        maxEnergy > 0 ? (energy / maxEnergy).clamp(0.0, 1.0) : 0.0;
    final percent = totalEnergy > 0 ? (energy / totalEnergy * 100) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: Colors.white.withAlpha(190), fontSize: 11)),
            ),
            // Trend arrow
            if (trend.arrow.isNotEmpty) ...[
              Text(
                trend.arrow,
                style: TextStyle(
                    color: trend.color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              '${percent.toStringAsFixed(0)}%  ${energy.toStringAsFixed(4)}',
              style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(20),
            borderRadius: BorderRadius.circular(4),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction,
            child: Container(
              decoration: BoxDecoration(
                gradient:
                    LinearGradient(colors: [color.withAlpha(200), color]),
                borderRadius: BorderRadius.circular(4),
                boxShadow: [BoxShadow(color: color.withAlpha(60), blurRadius: 4)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStat(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withAlpha(40), width: 1),
        ),
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: Colors.white.withAlpha(130), fontSize: 9)),
          ],
        ),
      ),
    );
  }
}
