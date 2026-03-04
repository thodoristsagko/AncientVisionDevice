import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key that records whether the user has dismissed the
/// safety-view tutorial.  Identical key used in photogrammetry for consistency.
const String kTutorialSeenKey = 'tutorial_seen';

// ── Step data ─────────────────────────────────────────────────────────────────

class _TutorialStep {
  final String title;
  final String description;
  final IconData icon;

  const _TutorialStep({
    required this.title,
    required this.description,
    required this.icon,
  });
}

const List<_TutorialStep> _kSteps = [
  _TutorialStep(
    title: 'PPV Gauge',
    description:
        'This shows Peak Particle Velocity — the instantaneous ground '
        'vibration in mm/s. Values above 0.3 mm/s are flagged by DIN 4150-3.',
    icon: Icons.speed,
  ),
  _TutorialStep(
    title: 'Anomaly Badge',
    description:
        'The badge colour changes when a risk is detected. '
        'Green = safe, amber = unusual, red = CRITICAL — evacuate immediately.',
    icon: Icons.warning_amber_rounded,
  ),
  _TutorialStep(
    title: 'Trend Chart',
    description:
        'A rolling 60-sample history of PPV values. Rising trends over '
        'many readings indicate worsening site conditions.',
    icon: Icons.show_chart,
  ),
  _TutorialStep(
    title: 'Session Timer',
    description:
        'Shows how long active monitoring has been running this session. '
        'Data is logged continuously while the timer is counting.',
    icon: Icons.timer_outlined,
  ),
];

// ── Public widget ─────────────────────────────────────────────────────────────

/// A full-screen tutorial overlay that walks the user through the key elements
/// of the Safety View in four steps.
///
/// Rendered as a [Stack] child — place it on top of the safety content.
/// The background is semi-transparent dark with a spotlight cut-out painted
/// via [CustomPainter] and [BlendMode.dstOut].
///
/// ```dart
/// if (_showTutorial)
///   TutorialOverlay(onDismiss: () => setState(() => _showTutorial = false))
/// ```
class TutorialOverlay extends StatefulWidget {
  /// Called when the user taps "Got it" on the final step or the skip button.
  final VoidCallback onDismiss;

  const TutorialOverlay({super.key, required this.onDismiss});

  // ── Static helpers ──────────────────────────────────────────────────────────

  /// Returns true if the tutorial has already been seen (persisted in prefs).
  static Future<bool> hasBeenSeen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kTutorialSeenKey) ?? false;
  }

  /// Marks the tutorial as seen so it will not auto-show again.
  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kTutorialSeenKey, true);
  }

  /// Resets the tutorial seen flag (useful for testing).
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kTutorialSeenKey);
  }

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay>
    with SingleTickerProviderStateMixin {
  int _step = 0;
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _advance() async {
    if (_step < _kSteps.length - 1) {
      await _fadeCtrl.reverse();
      if (!mounted) return;
      setState(() => _step++);
      _fadeCtrl.forward();
    } else {
      _dismiss();
    }
  }

  void _dismiss() {
    TutorialOverlay.markSeen();
    widget.onDismiss();
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final step = _kSteps[_step];
    final size = MediaQuery.of(context).size;

    // Spotlight position — cycle through four screen quadrants.
    final spotlightOffsets = [
      Offset(size.width * 0.5, size.height * 0.25),  // top-centre (PPV gauge)
      Offset(size.width * 0.5, size.height * 0.40),  // mid-top (anomaly badge)
      Offset(size.width * 0.5, size.height * 0.60),  // mid-bottom (chart)
      Offset(size.width * 0.5, size.height * 0.80),  // bottom (timer)
    ];
    final spotlight = spotlightOffsets[_step];

    return FadeTransition(
      opacity: _fadeAnim,
      child: Stack(
        children: [
          // ── Dimmed background with spotlight cutout ──────────────────────
          CustomPaint(
            size: Size.infinite,
            painter: _SpotlightPainter(
              center: spotlight,
              radius: 90,
            ),
          ),
          // ── Absorb taps on the dimmed area (but not the card) ───────────
          Positioned.fill(
            child: GestureDetector(
              onTap: _advance,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // ── Info card ────────────────────────────────────────────────────
          Positioned(
            left: 24,
            right: 24,
            bottom: size.height * 0.12,
            child: GestureDetector(
              // Prevent the background tap handler from swallowing taps on the card.
              onTap: () {},
              behavior: HitTestBehavior.opaque,
              child: _InfoCard(
                step: _step,
                totalSteps: _kSteps.length,
                icon: step.icon,
                title: step.title,
                description: step.description,
                isLast: _step == _kSteps.length - 1,
                onNext: _advance,
                onSkip: _dismiss,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Spotlight painter ─────────────────────────────────────────────────────────

/// Paints a semi-transparent dark overlay with a circular transparent cutout
/// at [center], using [BlendMode.dstOut] so the content below shows through.
class _SpotlightPainter extends CustomPainter {
  final Offset center;
  final double radius;

  const _SpotlightPainter({required this.center, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    // Save layer required for dstOut blend mode to work correctly.
    canvas.saveLayer(Offset.zero & size, Paint());

    // Dark overlay
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xCC000000),
    );

    // Spotlight cutout — BlendMode.dstOut erases the overlay where drawn.
    final gradient = RadialGradient(
      colors: [
        Colors.white,
        Colors.white.withAlpha(0),
      ],
      stops: const [0.6, 1.0],
    );

    final spotPaint = Paint()
      ..shader = gradient.createShader(
        Rect.fromCircle(center: center, radius: radius * 1.4),
      )
      ..blendMode = BlendMode.dstOut;

    canvas.drawCircle(center, radius * 1.4, spotPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.center != center || old.radius != radius;
}

// ── Info card ─────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final int step;
  final int totalSteps;
  final IconData icon;
  final String title;
  final String description;
  final bool isLast;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _InfoCard({
    required this.step,
    required this.totalSteps,
    required this.icon,
    required this.title,
    required this.description,
    required this.isLast,
    required this.onNext,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    const cardColor = Color(0xFF1C2523);
    const accent = Color(0xFFFFC107);
    const textWhite = TextStyle(color: Colors.white);
    const textSub = TextStyle(color: Colors.white70, fontSize: 13);

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withAlpha(80)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(120),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Step indicator row
            Row(
              children: [
                Icon(icon, color: accent, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: textWhite.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // Skip button
                TextButton(
                  onPressed: onSkip,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Skip',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Description
            Text(description, style: textSub),
            const SizedBox(height: 20),

            // Progress dots + action button
            Row(
              children: [
                // Dots
                Row(
                  children: List.generate(totalSteps, (i) {
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 4),
                      width: i == step ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == step ? accent : Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }),
                ),
                const Spacer(),
                // Next / Got it button
                ElevatedButton(
                  onPressed: onNext,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                    isLast ? 'Got it' : 'Next',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
