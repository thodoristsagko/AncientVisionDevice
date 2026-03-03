import 'package:flutter/material.dart';
import '../../services/vibration_metrics_service.dart';

// ===================== MULTI-STANDARD CLASSIFICATION CARD =====================
class MultiStandardCard extends StatelessWidget {
  final List<StandardClassification> classifications;
  final double damageIndex;
  final double housnerSI;
  final bool isConnected;

  const MultiStandardCard({
    super.key,
    required this.classifications,
    required this.damageIndex,
    required this.housnerSI,
    required this.isConnected,
  });

  static Color _levelColor(String level) {
    switch (level) {
      case 'critical':
        return const Color(0xFFE53935);
      case 'warning':
        return const Color(0xFFFF9800);
      default:
        return const Color(0xFF4CAF50);
    }
  }

  static String _levelLabel(String level) {
    switch (level) {
      case 'critical':
        return 'CRITICAL';
      case 'warning':
        return 'WARNING';
      default:
        return 'SAFE';
    }
  }

  static IconData _levelIcon(String level) {
    switch (level) {
      case 'critical':
        return Icons.dangerous_rounded;
      case 'warning':
        return Icons.warning_rounded;
      default:
        return Icons.check_circle_rounded;
    }
  }

  static String _standardLabel(VibrationStandard std) {
    switch (std) {
      case VibrationStandard.din4150:
        return 'DIN 4150-3';
      case VibrationStandard.bs7385:
        return 'BS 7385-2';
      case VibrationStandard.fhwa:
        return 'FHWA';
      case VibrationStandard.sn640312a:
        return 'SN 640 312a';
    }
  }

  Color _damageColor() {
    if (damageIndex >= 1.0) return const Color(0xFFE53935);
    if (damageIndex >= 0.5) return const Color(0xFFFF9800);
    if (damageIndex >= 0.2) return const Color(0xFFFFC107);
    return const Color(0xFF4CAF50);
  }

  @override
  Widget build(BuildContext context) {
    final bool hasData = classifications.isNotEmpty;

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
          const Text('Multi-Standard Classification', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),

              if (!hasData)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      isConnected ? 'Waiting for vibration data...' : 'Connect sensor for classification',
                      style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 12),
                    ),
                  ),
                )
              else ...[
                // 2x2 grid of standards
                Row(
                  children: [
                    Expanded(child: _buildStandardTile(classifications[0])),
                    const SizedBox(width: 10),
                    Expanded(child: _buildStandardTile(classifications[1])),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _buildStandardTile(classifications[2])),
                    const SizedBox(width: 10),
                    Expanded(child: _buildStandardTile(classifications[3])),
                  ],
                ),
                const SizedBox(height: 14),

                // Damage Index gauge
                _buildDamageGauge(),
                const SizedBox(height: 10),

                // Housner SI
                Row(
                  children: [
                    Icon(Icons.speed, color: Colors.white.withAlpha(160), size: 16),
                    const SizedBox(width: 8),
                    Text('Housner SI: ', style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12)),
                    Text('${housnerSI.toStringAsFixed(3)} mm/s-s',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ],
          ),
    );
  }

  Widget _buildStandardTile(StandardClassification c) {
    final color = _levelColor(c.level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withAlpha(70), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_levelIcon(c.level), color: color, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _standardLabel(c.standard),
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _levelLabel(c.level),
            style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            'Limit: ${c.limit.toStringAsFixed(1)} mm/s',
            style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildDamageGauge() {
    final color = _damageColor();
    final fraction = damageIndex.clamp(0.0, 1.5) / 1.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Damage Index', style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12)),
            const Spacer(),
            Text(
              damageIndex.toStringAsFixed(3),
              style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withAlpha(40),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                damageIndex >= 1.0
                    ? 'FAILURE'
                    : damageIndex >= 0.5
                        ? 'WARNING'
                        : 'SAFE',
                style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700),
              ),
            ),
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
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF4CAF50),
                        Color(0xFFFFC107),
                        Color(0xFFFF9800),
                        Color(0xFFE53935),
                      ],
                      stops: [0.0, 0.33, 0.67, 1.0],
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FractionallySizedBox(
                    widthFactor: (1.0 - fraction).clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(160),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('0', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
            Text('0.5', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
            Text('1.0', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
            Text('1.5', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
          ],
        ),
      ],
    );
  }
}
