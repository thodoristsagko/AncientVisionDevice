import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
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
    with TickerProviderStateMixin {
  // Icon/scale pulse (existing)
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Background color opacity pulse (CRITICAL only)
  late AnimationController _bgPulseController;
  late Animation<double> _bgOpacityAnimation;

  // Escalation timer — how long the alert has been active
  late Timer _elapsedTimer;
  int _elapsedSeconds = 0;

  // Auto-dismiss countdown (activates when level becomes SAFE)
  Timer? _autoDismissTimer;
  int _autoDismissCountdown = 5;
  bool _autoDismissActive = false;

  // Dismiss button visibility (delayed 3s to prevent accidental tap)
  bool _dismissButtonVisible = false;
  Timer? _dismissDelayTimer;

  @override
  void initState() {
    super.initState();

    // Scale pulse
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Background opacity heartbeat for CRITICAL (1s period, 0.85–0.95)
    _bgPulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _bgOpacityAnimation = Tween<double>(begin: 0.85, end: 0.95).animate(
      CurvedAnimation(parent: _bgPulseController, curve: Curves.easeInOut),
    );
    if (widget.level == 'critical') {
      _bgPulseController.repeat(reverse: true);
    }

    // Escalation timer — fires every second
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });

    // Dismiss button appears after 3 seconds
    _dismissDelayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _dismissButtonVisible = true);
    });
  }

  @override
  void didUpdateWidget(FullScreenAlertOverlay old) {
    super.didUpdateWidget(old);

    final wasCritical = old.level == 'critical';
    final isCritical = widget.level == 'critical';

    // Start/stop background heartbeat when level changes
    if (isCritical && !wasCritical) {
      _bgPulseController.repeat(reverse: true);
    } else if (!isCritical && wasCritical) {
      _bgPulseController.stop();
      _bgPulseController.value = 0.0;
    }

    // When level becomes SAFE, start auto-dismiss countdown
    if (!isCritical && wasCritical) {
      _startAutoDismiss();
    }

    // If level escalates back to CRITICAL, cancel auto-dismiss
    if (isCritical && !wasCritical) {
      _cancelAutoDismiss();
    }
  }

  void _startAutoDismiss() {
    _autoDismissCountdown = 5;
    _autoDismissActive = true;
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _autoDismissCountdown--;
        if (_autoDismissCountdown <= 0) {
          t.cancel();
          _autoDismissActive = false;
          widget.onDismiss();
        }
      });
    });
  }

  void _cancelAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    if (mounted) setState(() => _autoDismissActive = false);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _bgPulseController.dispose();
    _elapsedTimer.cancel();
    _autoDismissTimer?.cancel();
    _dismissDelayTimer?.cancel();
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

  String _formatElapsed(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  void _showCallHelpDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.emergency, color: Color(0xFFE53935), size: 24),
            SizedBox(width: 10),
            Text(
              'Emergency Steps',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _emergencyStep('1', 'Evacuate all personnel from the trench immediately.'),
            _emergencyStep('2', 'Move to a safe distance (>15 m from the edge).'),
            _emergencyStep('3', 'Call the site supervisor.'),
            _emergencyStep('4', 'Do not re-enter until cleared by a structural engineer.'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.phone, color: Colors.white),
                label: const Text(
                  'Call Emergency (112)',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                onPressed: () async {
                  final uri = Uri(scheme: 'tel', path: '112');
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  }
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _emergencyStep(String num, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Color(0xFFE53935),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                num,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCritical = widget.level == 'critical';
    final alertColor = isCritical ? const Color(0xFFE53935) : const Color(0xFFFFB300);
    final m = widget.metrics;
    final threshold = _getThresholdForFreq(m.freq);

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: _bgOpacityAnimation,
        builder: (context, child) {
          // Background: heartbeat opacity for CRITICAL, fixed otherwise
          final bgAlpha = isCritical
              ? (_bgOpacityAnimation.value * 255).round()
              : (0.88 * 255).round();
          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.5,
                colors: [
                  alertColor.withAlpha(bgAlpha),
                  Colors.black.withAlpha(230),
                  Colors.black.withAlpha(250),
                ],
              ),
            ),
            child: child,
          );
        },
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
                const SizedBox(height: 8),

                // Escalation time display
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(
                    color: alertColor.withAlpha(50),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: alertColor.withAlpha(100)),
                  ),
                  child: Text(
                    'Alert active for: ${_formatElapsed(_elapsedSeconds)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
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
                const SizedBox(height: 16),

                // Auto-dismiss countdown (shown when level returns to SAFE)
                if (_autoDismissActive)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.green.withAlpha(50),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.green.withAlpha(100)),
                      ),
                      child: Text(
                        'Auto-dismissing in ${_autoDismissCountdown}s...',
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                // Action buttons row
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      // ACKNOWLEDGE / Dismiss button (visible after 3s)
                      Expanded(
                        child: AnimatedOpacity(
                          opacity: _dismissButtonVisible ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 400),
                          child: IgnorePointer(
                            ignoring: !_dismissButtonVisible,
                            child: GestureDetector(
                              onTap: widget.onDismiss,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(30),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.check_circle, color: alertColor, size: 24),
                                        const SizedBox(width: 8),
                                        Text(
                                          'ACKNOWLEDGE',
                                          style: TextStyle(
                                            color: alertColor,
                                            fontSize: 15,
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
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // CALL HELP button
                      GestureDetector(
                        onTap: _showCallHelpDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE53935).withAlpha(220),
                            borderRadius: BorderRadius.circular(30),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(60),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.phone, color: Colors.white, size: 22),
                              SizedBox(width: 8),
                              Text(
                                'CALL HELP',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Hint: dismiss button is delayed
                if (!_dismissButtonVisible)
                  Text(
                    'Acknowledge button appears in ${3 - _elapsedSeconds.clamp(0, 3)}s',
                    style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 12),
                  ),

                const SizedBox(height: 16),
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
