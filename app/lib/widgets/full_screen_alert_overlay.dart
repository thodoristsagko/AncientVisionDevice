import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show AlertMetrics;
import 'ppv_sparkline.dart';

/// Full-screen alert overlay with sensor metrics and actionable guidance.
class FullScreenAlertOverlay extends StatefulWidget {
  final String message;
  final String level;
  final AlertMetrics metrics;
  final VoidCallback onDismiss;

  const FullScreenAlertOverlay({
    super.key,
    required this.message,
    required this.level,
    required this.metrics,
    required this.onDismiss,
  });

  @override
  State<FullScreenAlertOverlay> createState() => _FullScreenAlertOverlayState();
}

class _FullScreenAlertOverlayState extends State<FullScreenAlertOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _getActionGuidance() {
    switch (widget.metrics.hazardType) {
      case 'seismic':
        return 'EVACUATE THE TRENCH\nMove to safe distance (>15m). Do not re-enter until cleared.';
      case 'machinery':
        return 'STOP ALL EQUIPMENT\nInspect vibration source before resuming work.';
      case 'impact':
        return 'CHECK FOR STRUCTURAL DAMAGE\nDo not resume until inspected by engineer.';
      case 'moisture_high':
        return 'COLLAPSE RISK — EXIT TRENCH\nAssess drainage before re-entry.';
      case 'cav_damage':
        return 'CUMULATIVE DAMAGE THRESHOLD\nStructural assessment required before continuing.';
      case 'structural':
        return 'EVACUATE IMMEDIATELY\nStructural damage risk. Do not re-enter.';
      case 'dwt_transient':
        return 'HIGH-FREQUENCY TRANSIENT DETECTED\nIdentify source before resuming.';
      case 'continuous':
        return 'CONTINUOUS VIBRATION EXCEEDS LIMIT\nReduce vibration source or evacuate.';
      case 'source_change':
        return 'VIBRATION SOURCE CHANGED\nIdentify new source and assess risk.';
      default:
        return widget.level == 'critical'
            ? 'EVACUATE THE TRENCH IMMEDIATELY\nFollow emergency protocol.'
            : 'Check conditions and take appropriate action.';
    }
  }

  double _getThresholdForFreq(double freq) {
    if (freq <= 10) return 3.0;
    if (freq <= 50) return 5.0;
    return 8.0;
  }

  @override
  Widget build(BuildContext context) {
    final isCritical = widget.level == 'critical';
    final alertColor = isCritical ? const Color(0xFFE53935) : const Color(0xFFFFB300);
    final m = widget.metrics;
    final threshold = _getThresholdForFreq(m.freq);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.5,
            colors: [
              alertColor.withAlpha(200),
              Colors.black.withAlpha(230),
              Colors.black.withAlpha(250),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Pulsing icon
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseAnimation.value,
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: alertColor.withAlpha(60),
                          boxShadow: [
                            BoxShadow(
                              color: alertColor.withAlpha(100),
                              blurRadius: 30,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: Icon(
                          isCritical ? Icons.warning_rounded : Icons.error_outline,
                          size: 56,
                          color: Colors.white,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),

                // Title
                Text(
                  isCritical ? 'CRITICAL ALERT' : 'WARNING',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 12),

                // Alert message
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    widget.message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),

                // WHY THIS TRIGGERED
                if (m.ppv > 0 || m.staLta > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(25),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withAlpha(50)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'WHY THIS TRIGGERED',
                                style: TextStyle(
                                  color: alertColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 10),
                              if (m.ppv > 0) _metricRow(
                                'PPV',
                                '${m.ppv.toStringAsFixed(1)} mm/s',
                                'limit: ${threshold.toStringAsFixed(1)}',
                                m.ppv > threshold,
                              ),
                              if (m.freq > 0) _metricRow(
                                'Frequency',
                                '${m.freq.toStringAsFixed(1)} Hz',
                                m.freq <= 10 ? 'seismic band' : m.freq <= 50 ? 'machinery band' : 'high-freq',
                                false,
                              ),
                              if (m.staLta > 2.0) _metricRow(
                                'STA/LTA',
                                m.staLta.toStringAsFixed(1),
                                'trigger: 4.0',
                                m.staLta > 4.0,
                              ),
                              if (m.kurtosis > 3.0) _metricRow(
                                'Kurtosis',
                                m.kurtosis.toStringAsFixed(1),
                                m.kurtosis > 6 ? 'severe impact' : 'impact',
                                true,
                              ),
                              if (m.crestFactor > 5.0) _metricRow(
                                'Crest Factor',
                                m.crestFactor.toStringAsFixed(1),
                                'impulsive',
                                true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),

                // PPV SPARKLINE
                if (m.ppvHistory.length >= 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(25),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withAlpha(50)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PPV — LAST ${m.ppvHistory.length} READINGS',
                                style: TextStyle(
                                  color: alertColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 80,
                                child: PpvSparkline(
                                  data: m.ppvHistory,
                                  threshold: threshold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),

                // ACTION GUIDANCE
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: alertColor.withAlpha(40),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: alertColor.withAlpha(120)),
                    ),
                    child: Text(
                      _getActionGuidance(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Timestamp
                Text(
                  'Detected at ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}',
                  style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 14),
                ),
                const SizedBox(height: 24),

                // ACKNOWLEDGE button
                GestureDetector(
                  onTap: widget.onDismiss,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(230),
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(60),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle, color: alertColor, size: 26),
                            const SizedBox(width: 10),
                            Text(
                              'ACKNOWLEDGE',
                              style: TextStyle(
                                color: alertColor,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metricRow(String label, String value, String context, bool exceeded) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            exceeded ? Icons.arrow_upward : Icons.remove,
            color: exceeded ? const Color(0xFFFF5252) : Colors.white70,
            size: 14,
          ),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          Text(
            value,
            style: TextStyle(
              color: exceeded ? const Color(0xFFFF5252) : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($context)',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class CurrentAlertBanner extends StatelessWidget {
  final String level;
  final String message;

  const CurrentAlertBanner({super.key, required this.level, required this.message});

  @override
  Widget build(BuildContext context) {
    final isCritical = level == 'critical';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isCritical ? Colors.red.withAlpha(77) : Colors.orange.withAlpha(77),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isCritical ? Colors.red : Colors.orange, width: 2),
      ),
      child: Row(
        children: [
          Icon(
            isCritical ? Icons.warning_rounded : Icons.info_outline,
            color: isCritical ? Colors.red : Colors.orange,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCritical ? 'CRITICAL ALERT' : 'WARNING',
                  style: TextStyle(
                    color: isCritical ? Colors.red : Colors.orange,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(message, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
