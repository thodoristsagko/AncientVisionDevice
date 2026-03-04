import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_styles.dart';

/// OnboardingScreen — multi-page introduction shown to first-time users.
///
/// Four pages: Welcome, How It Works, Safety Thresholds, Get Started.
/// Saves 'onboarding_seen' to SharedPreferences and navigates to '/' when done.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  static const int _pageCount = 4;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_seen', true);
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  void _skip() {
    _pageController.animateToPage(
      _pageCount - 1,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  void _nextPage() {
    if (_currentPage < _pageCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  Widget _buildDotIndicators() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pageCount, (index) {
        final isActive = index == _currentPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 20 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: isActive ? AppColors.accent : AppColors.textHint,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }

  // ── Page 1: Welcome ──────────────────────────────────────────────────────────
  Widget _buildWelcomePage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Shield icon with glow effect
          Container(
            width: 130,
            height: 130,
            decoration: BoxDecoration(
              color: AppColors.accent.withAlpha(25),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.accent.withAlpha(80), width: 2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withAlpha(40),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(
              Icons.security,
              size: 68,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 40),
          const Text(
            'AncientVision\nSafety Monitor',
            style: AppTextStyles.h1,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          const Text(
            'Protect archaeologists from\nsoil instability hazards',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppDecorations.card,
            child: const Text(
              'AncientVision monitors ground vibrations in real-time, '
              'detecting precursor signals that may indicate soil instability '
              'before an avalanche occurs. Keep your team safe.',
              style: AppTextStyles.body,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  // ── Page 2: How It Works ─────────────────────────────────────────────────────
  Widget _buildHowItWorksPage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Real-Time Vibration\nDetection', style: AppTextStyles.h2),
          const SizedBox(height: 8),
          const Text(
            'Your M5StickC Plus sensor detects micro-vibrations that precede '
            'soil avalanches. The AI model distinguishes between safe activity '
            '(footsteps, wind) and dangerous soil creep patterns.',
            style: AppTextStyles.subtitle,
          ),
          const SizedBox(height: 24),
          // Three bullet points for BLE, DSP, ML
          _buildFeaturePill(
            icon: Icons.bluetooth,
            color: AppColors.info,
            title: 'BLE Connection',
            description: 'Wireless data from M5StickC at 200 Hz via Bluetooth Low Energy',
          ),
          const SizedBox(height: 12),
          _buildFeaturePill(
            icon: Icons.equalizer,
            color: AppColors.accent,
            title: 'DSP Analysis',
            description: 'FFT, wavelet decomposition & kurtosis computed on-device in real-time',
          ),
          const SizedBox(height: 12),
          _buildFeaturePill(
            icon: Icons.psychology,
            color: AppColors.warning,
            title: 'ML Classification',
            description: 'Precursor classifier distinguishes soil creep, cracking & imminent failure',
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturePill({
    required IconData icon,
    required Color color,
    required String title,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(70)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.h4),
                const SizedBox(height: 3),
                Text(description, style: AppTextStyles.subtitle),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Page 3: Safety Thresholds ────────────────────────────────────────────────
  Widget _buildSafetyThresholdsPage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Understanding\nAlert Levels', style: AppTextStyles.h2),
          const SizedBox(height: 8),
          const Text(
            'The app uses three colour-coded alert levels based on '
            'peak particle velocity (PPV) in mm/s.',
            style: AppTextStyles.subtitle,
          ),
          const SizedBox(height: 20),

          // Visual threshold scale
          _buildThresholdScale(),

          const SizedBox(height: 20),

          // Alert level cards
          _buildAlertLevelCard(
            label: 'SAFE',
            range: '< 0.3 mm/s',
            description: 'Normal background vibration. Continue work as usual.',
            color: AppColors.success,
            icon: Icons.check_circle_outline,
          ),
          const SizedBox(height: 10),
          _buildAlertLevelCard(
            label: 'CAUTION',
            range: '0.3 – 1.0 mm/s',
            description: 'Elevated vibration. Stay alert and prepare to evacuate.',
            color: AppColors.warning,
            icon: Icons.warning_amber_outlined,
          ),
          const SizedBox(height: 10),
          _buildAlertLevelCard(
            label: 'CRITICAL',
            range: '> 1.0 mm/s',
            description: 'Imminent failure signal. Evacuate the site immediately.',
            color: AppColors.error,
            icon: Icons.crisis_alert,
          ),
          const SizedBox(height: 16),

          // DIN 4150-3 reference
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.overlay,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.menu_book_outlined, size: 14, color: AppColors.textHint),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Thresholds derived from DIN 4150-3 (heritage buildings standard)',
                    style: AppTextStyles.caption,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThresholdScale() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PPV Scale (mm/s)', style: AppTextStyles.caption),
          const SizedBox(height: 8),
          // Gradient bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 12,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.success, AppColors.warning, AppColors.error],
                  stops: [0.3, 0.55, 1.0],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Labels beneath bar
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('0', style: AppTextStyles.caption),
              Text('0.3', style: AppTextStyles.caption),
              Text('1.0', style: AppTextStyles.caption),
              Text('2.0+', style: AppTextStyles.caption),
            ],
          ),
          const SizedBox(height: 4),
          const Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('SAFE', style: TextStyle(color: AppColors.success, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
              Expanded(
                flex: 3,
                child: Text('CAUTION', style: TextStyle(color: AppColors.warning, fontSize: 10, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              ),
              Expanded(
                flex: 4,
                child: Text('CRITICAL', style: TextStyle(color: AppColors.error, fontSize: 10, fontWeight: FontWeight.bold), textAlign: TextAlign.end),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAlertLevelCard({
    required String label,
    required String range,
    required String description,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(90), width: 1.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        range,
                        style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(description, style: AppTextStyles.subtitle),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Page 4: Get Started ──────────────────────────────────────────────────────
  Widget _buildGetStartedPage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 108,
            height: 108,
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(25),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.success.withAlpha(80), width: 2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.success.withAlpha(40),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.rocket_launch_rounded,
              size: 54,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Ready to Deploy',
            style: AppTextStyles.h1,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            'Follow these steps to begin field monitoring',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          // Setup checklist
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppDecorations.card,
            child: const Column(
              children: [
                _SetupStep(
                  step: 1,
                  icon: Icons.power_settings_new,
                  text: 'Power on your M5StickC Plus 2 device',
                ),
                SizedBox(height: 12),
                _SetupStep(
                  step: 2,
                  icon: Icons.bluetooth_searching,
                  text: 'Open the Monitor tab and tap Connect',
                ),
                SizedBox(height: 12),
                _SetupStep(
                  step: 3,
                  icon: Icons.place,
                  text: 'Position the device at the excavation site',
                ),
                SizedBox(height: 12),
                _SetupStep(
                  step: 4,
                  icon: Icons.tune,
                  text: 'Run the calibration wizard to set local baseline',
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: AppSizes.buttonHeight + 4,
            child: ElevatedButton.icon(
              onPressed: _finish,
              icon: const Icon(Icons.check_circle, size: 22),
              label: const Text('Get Started', style: AppTextStyles.button),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.primaryDark,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: AppDecorations.screenBackground,
        child: SafeArea(
          child: Column(
            children: [
              // Top bar: page counter + Skip button (pages 1-3)
              SizedBox(
                height: 52,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox(width: 72), // balance
                      Text(
                        '${_currentPage + 1} / $_pageCount',
                        style: AppTextStyles.caption,
                      ),
                      if (_currentPage < _pageCount - 1)
                        TextButton(
                          onPressed: _skip,
                          child: const Text('Skip', style: AppTextStyles.accentText),
                        )
                      else
                        const SizedBox(width: 72),
                    ],
                  ),
                ),
              ),

              // Page content
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (page) {
                    setState(() => _currentPage = page);
                  },
                  children: [
                    _buildWelcomePage(),
                    _buildHowItWorksPage(),
                    _buildSafetyThresholdsPage(),
                    _buildGetStartedPage(),
                  ],
                ),
              ),

              // Bottom: dot indicators + Next/Finish button
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: Column(
                  children: [
                    _buildDotIndicators(),
                    const SizedBox(height: 20),
                    if (_currentPage < _pageCount - 1)
                      SizedBox(
                        width: double.infinity,
                        height: AppSizes.buttonHeight,
                        child: ElevatedButton(
                          onPressed: _nextPage,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: AppColors.primaryDark,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppSizes.borderRadius),
                            ),
                          ),
                          child: const Text('Next', style: AppTextStyles.button),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

/// Numbered setup step with icon and description — used on the Get Started page.
class _SetupStep extends StatelessWidget {
  final int step;
  final IconData icon;
  final String text;

  const _SetupStep({
    required this.step,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Numbered badge
        Container(
          width: 28,
          height: 28,
          decoration: const BoxDecoration(
            color: AppColors.accent,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$step',
              style: const TextStyle(
                color: AppColors.primaryDark,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Icon
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Icon(icon, size: 16, color: AppColors.accent),
        ),
        const SizedBox(width: 8),
        // Text
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(text, style: AppTextStyles.body),
          ),
        ),
      ],
    );
  }
}
