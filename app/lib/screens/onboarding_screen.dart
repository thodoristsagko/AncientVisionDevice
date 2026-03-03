import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_styles.dart';

/// OnboardingScreen — multi-page introduction shown to first-time users.
///
/// Four pages: Welcome, How It Works, Safety Levels, Get Started.
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
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.accent.withAlpha(30),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.accent.withAlpha(80), width: 2),
            ),
            child: const Icon(
              Icons.vibration,
              size: 64,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 40),
          const Text(
            'AncientVision',
            style: AppTextStyles.h1,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            'Seismic Safety for Archaeological Sites',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
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
    final steps = [
      (Icons.developer_board, 'Detect', 'M5StickC device measures ground vibrations at 200 Hz using its onboard IMU sensor.'),
      (Icons.bluetooth, 'Transmit', 'Raw acceleration data is sent wirelessly via Bluetooth Low Energy to your phone.'),
      (Icons.psychology, 'Analyse', 'AI models perform FFT, wavelet decomposition, and precursor classification in real-time.'),
      (Icons.notifications_active, 'Alert', 'Safety alerts are triggered immediately when hazardous vibration patterns are detected.'),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How It Works', style: AppTextStyles.h2),
          const SizedBox(height: 8),
          const Text('Four steps from sensor to safety', style: AppTextStyles.subtitle),
          const SizedBox(height: 28),
          ...steps.asMap().entries.map((entry) {
            final i = entry.key;
            final step = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withAlpha(25),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accent.withAlpha(60)),
                    ),
                    child: Center(
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(step.$1, color: AppColors.accent, size: 16),
                            const SizedBox(width: 6),
                            Text(step.$2, style: AppTextStyles.h4),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(step.$3, style: AppTextStyles.subtitle),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Page 3: Safety Levels ────────────────────────────────────────────────────
  Widget _buildSafetyLevelsPage() {
    final levels = [
      (
        'SAFE',
        'Normal vibration — continue work as usual.',
        AppColors.success,
        Icons.check_circle_outline,
      ),
      (
        'ANOMALY',
        'Elevated vibration detected. Stay alert and prepare to evacuate.',
        AppColors.warning,
        Icons.warning_amber_outlined,
      ),
      (
        'CRITICAL',
        'Imminent failure signal. Evacuate the site immediately.',
        AppColors.error,
        Icons.crisis_alert,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Safety Levels', style: AppTextStyles.h2),
          const SizedBox(height: 8),
          const Text(
            'The app uses three colour-coded alert levels',
            style: AppTextStyles.subtitle,
          ),
          const SizedBox(height: 28),
          ...levels.map((level) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: level.$3.withAlpha(20),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: level.$3.withAlpha(100), width: 1.5),
                ),
                child: Row(
                  children: [
                    Icon(level.$4, color: level.$3, size: 32),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            level.$1,
                            style: TextStyle(
                              color: level.$3,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(level.$2, style: AppTextStyles.subtitle),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
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
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(30),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.success.withAlpha(80), width: 2),
            ),
            child: const Icon(
              Icons.bluetooth_searching,
              size: 52,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'You\'re Ready!',
            style: AppTextStyles.h1,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            'Connect your AncientVision device via Bluetooth',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppDecorations.card,
            child: Column(
              children: const [
                _BulletPoint(
                  icon: Icons.power_settings_new,
                  text: 'Power on your M5StickC Plus 2 device',
                ),
                SizedBox(height: 10),
                _BulletPoint(
                  icon: Icons.bluetooth,
                  text: 'Open the Monitor tab and tap Connect',
                ),
                SizedBox(height: 10),
                _BulletPoint(
                  icon: Icons.place,
                  text: 'Position the device at the site — it will begin monitoring immediately',
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: AppSizes.buttonHeight + 4,
            child: ElevatedButton.icon(
              onPressed: _finish,
              icon: const Icon(Icons.bluetooth_connected, size: 22),
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
              // Top bar: Skip button (pages 1-3) or empty
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
                    _buildSafetyLevelsPage(),
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

/// Small helper widget for bullet points on page 4.
class _BulletPoint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _BulletPoint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.accent),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AppTextStyles.body)),
      ],
    );
  }
}
