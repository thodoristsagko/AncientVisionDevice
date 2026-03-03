import 'dart:math';
import 'package:flutter/material.dart';
import '../../services/wavelet_service.dart';

// ===================== WAVELET ANALYSIS CARD =====================
class WaveletAnalysisCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    // Extract detail-level energies (D1, D2, D3) and approximation
    final d1Entry = bandEnergy.entries.where((e) => e.key.startsWith('D1')).firstOrNull;
    final d2Entry = bandEnergy.entries.where((e) => e.key.startsWith('D2')).firstOrNull;
    final d3Entry = bandEnergy.entries.where((e) => e.key.startsWith('D3')).firstOrNull;

    final d1Energy = d1Entry?.value ?? 0.0;
    final d2Energy = d2Entry?.value ?? 0.0;
    final d3Energy = d3Entry?.value ?? 0.0;
    final totalEnergy = bandEnergy.values.fold(0.0, (a, b) => a + b);
    final maxEnergy = [d1Energy, d2Energy, d3Energy].reduce(max);

    final Color accentColor = transientFlash
        ? const Color(0xFFFF5722)
        : const Color(0xFF7C4DFF);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
        border: transientFlash
            ? Border.all(color: const Color(0xFFFF5722).withAlpha(150), width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Text('Wavelet Analysis', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('Haar DWT', style: TextStyle(color: accentColor, fontSize: 10, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 14),

              // Transient detection indicator
              if (transientFlash) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5722).withAlpha(30),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFF5722).withAlpha(100), width: 1),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.flash_on_rounded, color: Color(0xFFFF5722), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Transient detected! ${transients.length} event${transients.length != 1 ? 's' : ''} '
                          '(Level ${transients.isNotEmpty ? transients.first.level : "-"})',
                          style: const TextStyle(color: Color(0xFFFF5722), fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Band energy horizontal bars
              _buildBandBar(
                d1Entry?.key ?? 'D1: 50-100 Hz',
                d1Energy,
                maxEnergy,
                totalEnergy,
                const Color(0xFF4CAF50),
              ),
              const SizedBox(height: 8),
              _buildBandBar(
                d2Entry?.key ?? 'D2: 25-50 Hz',
                d2Energy,
                maxEnergy,
                totalEnergy,
                const Color(0xFFFF9800),
              ),
              const SizedBox(height: 8),
              _buildBandBar(
                d3Entry?.key ?? 'D3: 12-25 Hz',
                d3Energy,
                maxEnergy,
                totalEnergy,
                const Color(0xFFFF5722),
              ),
              const SizedBox(height: 10),

              // Summary row
              Row(
                children: [
                  _buildMiniStat('Total Energy', totalEnergy.toStringAsFixed(4)),
                  const SizedBox(width: 12),
                  _buildMiniStat('Transients', '${transients.length}'),
                  const SizedBox(width: 12),
                  _buildMiniStat('Buffer', '${(bufferFill * 100).toStringAsFixed(0)}%'),
                ],
              ),
            ],
          ),
    );
  }

  Widget _buildBandBar(String label, double energy, double maxEnergy, double totalEnergy, Color color) {
    final fraction = maxEnergy > 0 ? (energy / maxEnergy).clamp(0.0, 1.0) : 0.0;
    final percent = totalEnergy > 0 ? (energy / totalEnergy * 100) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(color: Colors.white.withAlpha(190), fontSize: 11)),
            ),
            Text(
              '${energy.toStringAsFixed(4)}  (${percent.toStringAsFixed(0)}%)',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
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
                gradient: LinearGradient(colors: [color.withAlpha(200), color]),
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
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 9)),
          ],
        ),
      ),
    );
  }
}
