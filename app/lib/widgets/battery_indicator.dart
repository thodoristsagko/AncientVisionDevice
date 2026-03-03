import 'package:flutter/material.dart';

/// A compact battery status indicator widget.
///
/// Shows a battery icon filled proportionally, coloured by charge level, with
/// an optional charging lightning bolt overlay and a text percentage label.
///
/// Uses only Flutter built-in Material icons — no external packages required.
class BatteryIndicator extends StatelessWidget {
  /// Raw battery voltage in volts (LiPo range 3.0 V – 4.2 V).
  final double voltage;

  /// Whether a charger is currently connected.
  final bool isCharging;

  /// Optional pre-computed percentage (0–100).  When provided, [voltage] is
  /// ignored for the fill level calculation.
  final double? percentage;

  const BatteryIndicator({
    super.key,
    required this.voltage,
    required this.isCharging,
    this.percentage,
  });

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static const double _vMin = 3.0;
  static const double _vMax = 4.2;

  /// Percentage 0–100 derived from voltage or the explicit [percentage] field.
  double get _pct {
    if (percentage != null) {
      return percentage!.clamp(0.0, 100.0);
    }
    final clamped = voltage.clamp(_vMin, _vMax);
    return ((clamped - _vMin) / (_vMax - _vMin)) * 100.0;
  }

  Color _color(double pct) {
    if (pct > 50) return Colors.green;
    if (pct >= 20) return Colors.amber;
    return Colors.red;
  }

  /// Selects the most appropriate built-in battery icon for the fill level.
  IconData _batteryIcon(double pct) {
    if (pct > 90) return Icons.battery_full;
    if (pct > 80) return Icons.battery_6_bar;
    if (pct > 65) return Icons.battery_5_bar;
    if (pct > 50) return Icons.battery_4_bar;
    if (pct > 35) return Icons.battery_3_bar;
    if (pct > 20) return Icons.battery_2_bar;
    if (pct > 10) return Icons.battery_1_bar;
    return Icons.battery_0_bar;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final pct = _pct;
    final color = _color(pct);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Battery icon with optional charging overlay
        Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              _batteryIcon(pct),
              color: color,
              size: 28,
            ),
            if (isCharging)
              Icon(
                Icons.bolt,
                color: Colors.white.withValues(alpha: 0.9),
                size: 14,
              ),
          ],
        ),
        const SizedBox(width: 4),
        // Percentage text
        Text(
          '${pct.round()}%',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        // Small charging indicator text
        if (isCharging) ...[
          const SizedBox(width: 2),
          Text(
            '⚡',
            style: TextStyle(
              fontSize: 11,
              color: Colors.amber[700],
            ),
          ),
        ],
      ],
    );
  }
}
