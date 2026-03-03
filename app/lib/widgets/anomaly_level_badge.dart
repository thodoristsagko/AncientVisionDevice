import 'package:flutter/material.dart';
import '../services/vibration_anomaly_service.dart';

/// A coloured pill badge that displays the current [AnomalyLevel].
///
/// Size variants:
///   - small (default, [large]=false): compact badge for list items
///   - large ([large]=true): prominent badge for the main safety display
///
/// Level → visual mapping:
///   - normal  → green  "SAFE"
///   - unusual → orange "ANOMALY"
///   - anomaly → red    "CRITICAL" with animated pulsing border
///   - unknown → grey   "INIT"
class AnomalyLevelBadge extends StatefulWidget {
  final AnomalyLevel level;
  final bool large;

  const AnomalyLevelBadge({
    super.key,
    required this.level,
    this.large = false,
  });

  @override
  State<AnomalyLevelBadge> createState() => _AnomalyLevelBadgeState();
}

class _AnomalyLevelBadgeState extends State<AnomalyLevelBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.level == AnomalyLevel.anomaly) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant AnomalyLevelBadge old) {
    super.didUpdateWidget(old);
    if (widget.level == AnomalyLevel.anomaly) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
        _pulseController.value = 0.0;
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // ─── Styling helpers ────────────────────────────────────────────────────────

  _LevelStyle get _style {
    switch (widget.level) {
      case AnomalyLevel.normal:
        return const _LevelStyle(
          label: 'SAFE',
          background: Color(0xFF1B5E20),
          border: Color(0xFF4CAF50),
          text: Color(0xFFA5D6A7),
        );
      case AnomalyLevel.unusual:
        return const _LevelStyle(
          label: 'ANOMALY',
          background: Color(0xFF4A2900),
          border: Color(0xFFFFA726),
          text: Color(0xFFFFCC80),
        );
      case AnomalyLevel.anomaly:
        return const _LevelStyle(
          label: 'CRITICAL',
          background: Color(0xFF4A0000),
          border: Color(0xFFEF5350),
          text: Color(0xFFFF8A80),
          pulsing: true,
        );
      case AnomalyLevel.unknown:
        return const _LevelStyle(
          label: 'INIT',
          background: Color(0xFF2A2A2A),
          border: Color(0xFF757575),
          text: Color(0xFFBDBDBD),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _style;
    final isLarge = widget.large;

    final double hPad = isLarge ? 20.0 : 10.0;
    final double vPad = isLarge ? 10.0 : 5.0;
    final double fontSize = isLarge ? 16.0 : 11.0;
    final double borderRadius = isLarge ? 16.0 : 10.0;
    final double borderWidth = isLarge ? 2.0 : 1.5;

    Widget badge = Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      decoration: BoxDecoration(
        color: s.background,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: s.border, width: borderWidth),
      ),
      child: Text(
        s.label,
        style: TextStyle(
          color: s.text,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );

    // Pulsing animated border for CRITICAL level
    if (s.pulsing) {
      badge = AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Container(
            padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
            decoration: BoxDecoration(
              color: s.background,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: s.border.withAlpha(
                    (_pulseAnimation.value * 255).round().clamp(0, 255)),
                width: borderWidth + (_pulseAnimation.value * 1.5),
              ),
              boxShadow: [
                BoxShadow(
                  color: s.border.withAlpha(
                      (_pulseAnimation.value * 100).round().clamp(0, 255)),
                  blurRadius: 8 * _pulseAnimation.value,
                  spreadRadius: 2 * _pulseAnimation.value,
                ),
              ],
            ),
            child: Text(
              s.label,
              style: TextStyle(
                color: s.text,
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          );
        },
      );
    }

    return badge;
  }
}

class _LevelStyle {
  final String label;
  final Color background;
  final Color border;
  final Color text;
  final bool pulsing;

  const _LevelStyle({
    required this.label,
    required this.background,
    required this.border,
    required this.text,
    this.pulsing = false,
  });
}
