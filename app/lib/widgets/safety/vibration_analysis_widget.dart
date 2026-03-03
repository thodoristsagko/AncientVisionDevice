import 'package:flutter/material.dart';

// ===================== VIBRATION ANALYSIS CARD (v2.0) =====================
class VibrationAnalysisCard extends StatelessWidget {
  final double ppv, rms, dominantFreq, crestFactor;
  final double ppvSmoothed, ppvPeakHold, kurtosis, staLtaRatio, centroid;
  final double arias, cav, temp; // v4.0 fields
  final double dwt1, dwt2, dwt3; // v4.0 wavelet fields
  final String hazardType, hazardLabel;
  final String damageAssessment;
  final Color ppvColor;
  final bool isConnected;
  final VoidCallback? onHistoryTap;

  const VibrationAnalysisCard({
    super.key,
    required this.ppv, required this.rms, required this.dominantFreq,
    required this.crestFactor, required this.hazardType, required this.hazardLabel,
    required this.ppvColor, required this.isConnected,
    this.ppvSmoothed = 0, this.ppvPeakHold = 0, this.kurtosis = 0,
    this.staLtaRatio = 0, this.centroid = 0, this.damageAssessment = '',
    this.arias = 0, this.cav = 0, this.temp = 0, // v4.0 defaults
    this.dwt1 = 0, this.dwt2 = 0, this.dwt3 = 0,
    this.onHistoryTap,
  });

  String _getFreqBandLabel() {
    if (dominantFreq <= 0) return '--';
    if (dominantFreq <= 1.0) return 'Sub-Hz (wind/ambient)';
    if (dominantFreq <= 5.0) return '1-5 Hz (footsteps/sway)';
    if (dominantFreq <= 10.0) return '1-10 Hz (seismic band)';
    if (dominantFreq <= 50.0) return '10-50 Hz (machinery)';
    return '50-100 Hz (structural)';
  }

  Color _getFreqBandColor() {
    if (dominantFreq <= 0) return Colors.grey;
    if (dominantFreq <= 5.0) return const Color(0xFF4CAF50);
    if (dominantFreq <= 10.0) return const Color(0xFFFF5722);
    if (dominantFreq <= 50.0) return const Color(0xFFFF9800);
    return const Color(0xFFFFC107);
  }

  @override
  Widget build(BuildContext context) {
    final bool hasData = ppv > 0 || rms > 0;

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
          // Header
          Row(
            children: [
              const Text('Vibration Analysis', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(hazardLabel, style: TextStyle(color: ppvColor, fontSize: 10, fontWeight: FontWeight.w700)),
              if (onHistoryTap != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onHistoryTap,
                  child: Icon(Icons.history, color: Colors.white.withAlpha(180), size: 20),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),

              if (!hasData)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      isConnected ? 'Waiting for v2.0 firmware data...' : 'Connect sensor for analysis',
                      style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 12),
                    ),
                  ),
                )
              else ...[
                // PPV Gauge Bar (smoothed value, with peak hold)
                _buildGaugeRow('PPV', ppvSmoothed > 0 ? ppvSmoothed : ppv, 'mm/s', 15.0, ppvColor),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Peak (5s): ${ppvPeakHold.toStringAsFixed(1)} mm/s',
                    style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 10),
                  ),
                ),
                const SizedBox(height: 10),

                // DIN 4150-3 threshold markers
                _buildDINThresholdBar(),
                const SizedBox(height: 14),

                // Metrics grid - row 1
                Row(
                  children: [
                    _buildMetricTile('RMS', '${rms.toStringAsFixed(4)}g', Icons.show_chart),
                    const SizedBox(width: 10),
                    _buildMetricTile('Crest', crestFactor.toStringAsFixed(1), Icons.bolt),
                    const SizedBox(width: 10),
                    _buildMetricTile('Freq', '${dominantFreq.toStringAsFixed(0)}Hz', Icons.graphic_eq),
                  ],
                ),
                const SizedBox(height: 8),

                // Metrics grid - row 2 (v3.0 features)
                Row(
                  children: [
                    _buildMetricTile('Kurt', kurtosis.toStringAsFixed(1), Icons.assessment,
                      valueColor: kurtosis > 6 ? const Color(0xFFFF5722) : kurtosis > 3 ? const Color(0xFFFF9800) : null),
                    const SizedBox(width: 10),
                    _buildMetricTile('STA/LTA', staLtaRatio.toStringAsFixed(1), Icons.sensors,
                      valueColor: staLtaRatio > 4.0 ? const Color(0xFFFF5722) : staLtaRatio > 2.0 ? const Color(0xFFFF9800) : null),
                    const SizedBox(width: 10),
                    _buildMetricTile('Cent', '${centroid.toStringAsFixed(0)}Hz', Icons.center_focus_strong),
                  ],
                ),
                const SizedBox(height: 8),

                // Metrics grid - row 3 (v4.0 features) - only show if any v4.0 data present
                if (hasData) ...[
                  Row(
                    children: [
                      _buildMetricTile('Arias', arias.toStringAsFixed(4), Icons.tsunami,
                        valueColor: arias > 0.01 ? const Color(0xFFFF9800) : null),
                      const SizedBox(width: 10),
                      _buildMetricTile('CAV', '${cav.toStringAsFixed(3)}g·s', Icons.speed,
                        valueColor: cav > 0.16 ? const Color(0xFFFF5722) : cav > 0.1 ? const Color(0xFFFF9800) : null),
                      const SizedBox(width: 10),
                      _buildMetricTile('Temp', '${temp.toStringAsFixed(1)}°C', Icons.thermostat),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],

                // DWT levels (v4.0) - only show if non-zero
                if (dwt1 > 0 || dwt2 > 0 || dwt3 > 0) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2196F3).withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF2196F3).withAlpha(60), width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.graphic_eq, color: Color(0xFF2196F3), size: 14),
                            SizedBox(width: 6),
                            Text('Wavelet Decomposition (DWT)',
                              style: TextStyle(color: Color(0xFF2196F3), fontSize: 11, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(child: _buildDwtBar('D1 (50-100Hz)', dwt1, const Color(0xFF4CAF50))),
                            const SizedBox(width: 8),
                            Expanded(child: _buildDwtBar('D2 (25-50Hz)', dwt2, const Color(0xFFFF9800))),
                            const SizedBox(width: 8),
                            Expanded(child: _buildDwtBar('D3 (12-25Hz)', dwt3, const Color(0xFFFF5722))),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 2),

                // Frequency band indicator
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _getFreqBandColor().withAlpha(25),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _getFreqBandColor().withAlpha(60), width: 1),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.waves, color: _getFreqBandColor(), size: 16),
                      const SizedBox(width: 8),
                      Text(
                        _getFreqBandLabel(),
                        style: TextStyle(color: _getFreqBandColor(), fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),

                // Damage assessment
                if (damageAssessment.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    damageAssessment,
                    style: TextStyle(
                      color: Colors.white.withAlpha(160),
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ],
          ),
    );
  }

  Widget _buildGaugeRow(String label, double value, String unit, double maxValue, Color color) {
    final fraction = (value / maxValue).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12)),
            const Spacer(),
            Text('${value.toStringAsFixed(1)} $unit', style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(20),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [color.withAlpha(200), color]),
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: [BoxShadow(color: color.withAlpha(80), blurRadius: 6)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDINThresholdBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DIN 4150-3 Thresholds', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10)),
        const SizedBox(height: 4),
        SizedBox(
          height: 20,
          child: Row(
            children: [
              _buildThresholdSegment('Safe', 0.3 / 15.0, const Color(0xFF4CAF50)),
              _buildThresholdSegment('', (2.5 - 0.3) / 15.0, const Color(0xFFFFC107)),
              _buildThresholdSegment('3mm/s', (3.0 - 2.5) / 15.0, const Color(0xFFFF9800)),
              _buildThresholdSegment('Heritage', (8.0 - 3.0) / 15.0, const Color(0xFFFF5722)),
              _buildThresholdSegment('10mm/s', (10.0 - 8.0) / 15.0, const Color(0xFFE53935)),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFB71C1C).withAlpha(150),
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                  child: const Center(child: Text('DMG', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w600))),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThresholdSegment(String label, double fraction, Color color) {
    return Expanded(
      flex: (fraction * 100).round().clamp(1, 100),
      child: Container(
        decoration: BoxDecoration(color: color.withAlpha(120)),
        child: Center(
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.w600), overflow: TextOverflow.clip, maxLines: 1),
        ),
      ),
    );
  }

  Widget _buildMetricTile(String label, String value, IconData icon, {Color? valueColor}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(40), width: 1),
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.white.withAlpha(150), size: 16),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(color: valueColor ?? Colors.white, fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis, maxLines: 1),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildDwtBar(String label, double value, Color color) {
    const maxDwt = 0.01; // Typical max DWT energy
    final fraction = (value / maxDwt).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 9)),
        const SizedBox(height: 3),
        Container(
          height: 6,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(30),
            borderRadius: BorderRadius.circular(3),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(value.toStringAsFixed(4), style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
