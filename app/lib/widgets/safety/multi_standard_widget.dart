import 'package:flutter/material.dart';
import '../../services/vibration_metrics_service.dart';

// ===================== MULTI-STANDARD CLASSIFICATION CARD =====================

/// Reference limits per standard / structure category (all in mm/s PPV).
class _StandardLimit {
  final String name;
  final String shortName;
  final double limit;
  const _StandardLimit(this.name, this.shortName, this.limit);
}

const _kStandardLimits = [
  _StandardLimit('SN 640 312a archaeological', 'SN arch.', 0.2),
  _StandardLimit('DIN 4150-3 heritage bldg', 'DIN herit.', 0.3),
  _StandardLimit('BS 7385-2 sensitive', 'BS sens.', 2.5),
  _StandardLimit('DIN 4150-3 residential', 'DIN resid.', 5.0),
];

class MultiStandardCard extends StatelessWidget {
  final List<StandardClassification> classifications;
  final double damageIndex;
  final double housnerSI;
  final bool isConnected;

  /// Current live PPV (mm/s) used for compliance bar and comparison rows.
  /// Pass 0 if not yet received.
  final double currentPpv;

  const MultiStandardCard({
    super.key,
    required this.classifications,
    required this.damageIndex,
    required this.housnerSI,
    required this.isConnected,
    this.currentPpv = 0.0,
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

  // ── Compliance helpers ──────────────────────────────────────────────────

  /// Returns the bar color based on fraction of limit used.
  Color _complianceColor(double fraction) {
    if (fraction >= 1.0) return const Color(0xFFE53935);   // over limit
    if (fraction >= 0.90) return const Color(0xFFE53935);  // >90% — red
    if (fraction >= 0.50) return const Color(0xFFFF9800);  // 50–90% — amber
    return const Color(0xFF4CAF50);                         // <50% — green
  }

  /// Number of standards the current PPV is compliant with (below limit).
  int get _compliantCount {
    int n = 0;
    for (final s in _kStandardLimits) {
      if (currentPpv < s.limit) n++;
    }
    return n;
  }

  Color get _summaryColor {
    final n = _compliantCount;
    if (n == _kStandardLimits.length) return const Color(0xFF4CAF50);
    if (n >= 2) return const Color(0xFFFF9800);
    return const Color(0xFFE53935);
  }

  @override
  Widget build(BuildContext context) {
    final bool hasData = classifications.isNotEmpty;
    final bool hasPpv = currentPpv > 0;

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
          const Text(
            'Multi-Standard Classification',
            style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),

          // ── Compliance summary ────────────────────────────────────────────
          if (hasPpv) ...[
            _buildComplianceSummary(),
            const SizedBox(height: 12),
          ],

          // ── DIN 4150-3 heritage compliance bar (primary / most strict) ────
          if (hasPpv) ...[
            _buildDinComplianceBar(),
            const SizedBox(height: 12),
          ],

          // ── Standard comparison rows ──────────────────────────────────────
          if (hasPpv) ...[
            _buildStandardComparisonSection(),
            const SizedBox(height: 14),
          ],

          // ── Existing 2×2 grid from classifications list ───────────────────
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
                Text(
                  '${housnerSI.toStringAsFixed(3)} mm/s-s',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Compliance summary badge ─────────────────────────────────────────────
  Widget _buildComplianceSummary() {
    final n = _compliantCount;
    final total = _kStandardLimits.length;
    final color = _summaryColor;
    final label = n == total
        ? 'Compliant with all $total standards'
        : 'Compliant with $n/$total standards';
    final icon = n == total ? Icons.verified_rounded : (n >= 2 ? Icons.warning_amber_rounded : Icons.dangerous_rounded);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(80), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  // ── DIN 4150-3 heritage bar (primary compliance bar) ─────────────────────
  Widget _buildDinComplianceBar() {
    const limit = 0.3; // mm/s — DIN 4150-3 heritage buildings
    final fraction = (currentPpv / limit).clamp(0.0, 1.5);
    final barFraction = fraction.clamp(0.0, 1.0);
    final color = _complianceColor(fraction);
    final pct = (fraction * 100).clamp(0, 999).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'DIN 4150-3 Heritage Limit',
              style: TextStyle(color: Colors.white.withAlpha(190), fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '${currentPpv.toStringAsFixed(2)} / ${limit.toStringAsFixed(1)} mm/s',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: color.withAlpha(40),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$pct%',
                style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            children: [
              // Background track
              Container(
                height: 9,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(18),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              // Fill
              FractionallySizedBox(
                widthFactor: barFraction,
                child: Container(
                  height: 9,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [BoxShadow(color: color.withAlpha(80), blurRadius: 4)],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Text('0', style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 8)),
            const Spacer(),
            Text('Limit: $limit mm/s', style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 8)),
          ],
        ),
      ],
    );
  }

  // ── Standard comparison rows ──────────────────────────────────────────────
  Widget _buildStandardComparisonSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Standard Comparison',
          style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        ..._kStandardLimits.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _buildComparisonRow(s),
            )),
      ],
    );
  }

  Widget _buildComparisonRow(_StandardLimit s) {
    final fraction = (currentPpv / s.limit).clamp(0.0, 1.5);
    final barFraction = fraction.clamp(0.0, 1.0);
    final color = _complianceColor(fraction);
    final pct = (fraction * 100).clamp(0, 999).toStringAsFixed(0);
    final isCompliant = currentPpv < s.limit;

    return Row(
      children: [
        // Standard name
        SizedBox(
          width: 88,
          child: Text(
            s.shortName,
            style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 6),
        // Progress bar
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(
                  height: 7,
                  color: Colors.white.withAlpha(18),
                ),
                FractionallySizedBox(
                  widthFactor: barFraction,
                  child: Container(
                    height: 7,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        // Percentage label
        SizedBox(
          width: 36,
          child: Text(
            '$pct%',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 4),
        // Tick / cross
        Icon(
          isCompliant ? Icons.check_circle_outline_rounded : Icons.cancel_outlined,
          color: color,
          size: 13,
        ),
      ],
    );
  }

  // ── Standard tile (original 2×2 grid) ────────────────────────────────────
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

  // ── Damage Index gauge ────────────────────────────────────────────────────
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
