import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/app_styles.dart';

/// Step-by-step calibration wizard for AncientVision vibration monitoring.
///
/// Walk the user through four stages:
///   1. Prepare   — place the device correctly
///   2. Baseline  — 30-second ambient capture with live countdown + noise display
///   3. Verify    — display captured noise floor and computed threshold
///   4. Complete  — confirmation with a large green checkmark and action buttons
///
/// Usage:
/// ```dart
/// final success = await Navigator.push<bool>(
///   context,
///   MaterialPageRoute(
///     builder: (_) => CalibrationWizardScreen(
///       onCalibrationStart: () => service.startCalibration(),
///       onCalibrationComplete: () => service.finishCalibration(),
///     ),
///   ),
/// );
/// ```
class CalibrationWizardScreen extends StatefulWidget {
  final VoidCallback? onCalibrationStart;
  final VoidCallback? onCalibrationComplete;

  const CalibrationWizardScreen({
    super.key,
    this.onCalibrationStart,
    this.onCalibrationComplete,
  });

  @override
  State<CalibrationWizardScreen> createState() =>
      _CalibrationWizardScreenState();
}

class _CalibrationWizardScreenState extends State<CalibrationWizardScreen>
    with SingleTickerProviderStateMixin {
  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------

  int _currentStep = 0; // 0..3
  static const int _totalSteps = 4;

  // Baseline capture (step 1)
  static const int _baselineDurationSeconds = 30;
  int _secondsRemaining = _baselineDurationSeconds;
  Timer? _countdownTimer;
  Timer? _noiseLevelTimer;
  bool _captureStarted = false;

  // Live noise floor reading (simulated during baseline capture).
  // In a real integration this comes from VibrationAnomalyService.instance.
  double _noiseLevel = 0.0;
  final _random = Random();

  // Simulated noise floor result shown on verify screen (step 2)
  // In a real integration these values come from the calibration service.
  double _noiseFloor = 0.0;
  double _computedThreshold = 0.0;

  // Animation controller for the progress icon on step 1
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _noiseLevelTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Navigation helpers
  // ------------------------------------------------------------------

  void _goNext() {
    if (_currentStep == 0) {
      // Transition from Prepare → Baseline: start capture
      _startBaselineCapture();
    } else if (_currentStep == 1) {
      // Should not be reachable — Next is disabled during capture
    } else if (_currentStep == 2) {
      // Verify → Complete: notify caller
      widget.onCalibrationComplete?.call();
    }

    if (_currentStep < _totalSteps - 1) {
      setState(() => _currentStep++);
    }
  }

  void _goBack() {
    if (_currentStep == 0) {
      Navigator.of(context).pop(false); // cancelled
      return;
    }
    // Show confirmation dialog when cancelling mid-calibration
    if (_currentStep == 1 || _currentStep == 2) {
      _showCancelConfirmation();
      return;
    }
    setState(() => _currentStep--);
  }

  Future<void> _showCancelConfirmation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        title: const Text(
          'Cancel Calibration?',
          style: AppTextStyles.h3,
        ),
        content: const Text(
          'Progress will be lost. The device will return to uncalibrated mode.',
          style: AppTextStyles.subtitle,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Continue Calibrating',
              style: AppTextStyles.accentText,
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.textPrimary,
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      if (_currentStep == 1) {
        _cancelBaselineCapture();
      }
      setState(() => _currentStep--);
    }
  }

  void _startBaselineCapture() {
    _captureStarted = true;
    _secondsRemaining = _baselineDurationSeconds;
    _noiseLevel = 0.005 + _random.nextDouble() * 0.01;
    widget.onCalibrationStart?.call();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsRemaining--;
      });
      if (_secondsRemaining <= 0) {
        timer.cancel();
        _noiseLevelTimer?.cancel();
        _onCaptureComplete();
      }
    });

    // Live noise floor update every second
    _noiseLevelTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _noiseLevel = 0.005 + _random.nextDouble() * 0.01;
      });
    });
  }

  void _cancelBaselineCapture() {
    _countdownTimer?.cancel();
    _noiseLevelTimer?.cancel();
    _captureStarted = false;
    _secondsRemaining = _baselineDurationSeconds;
    _noiseLevel = 0.0;
  }

  void _onCaptureComplete() {
    // In real usage the calibration service provides these values.
    // For the wizard we show plausible defaults derived from a 30-sample window.
    setState(() {
      _noiseFloor = 0.05; // mm/s — typical quiet site ambient
      _computedThreshold = (_noiseFloor * 6).clamp(0.1, 2.0);
      _currentStep = 2; // jump to Verify
    });
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_currentStep == 0 || _currentStep == 3) {
          Navigator.of(context).pop(false);
        } else {
          _showCancelConfirmation();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.primaryDark,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: AppColors.textSecondary),
            onPressed: () {
              if (_currentStep == 0 || _currentStep == 3) {
                Navigator.of(context).pop(false);
              } else {
                _showCancelConfirmation();
              }
            },
            tooltip: 'Cancel calibration',
          ),
          title: const Text('Calibration Wizard', style: AppTextStyles.h3),
          foregroundColor: AppColors.textPrimary,
        ),
        body: SafeArea(
          child: Column(
            children: [
              _buildStepIndicator(),
              Expanded(child: _buildStepContent()),
              _buildNavigationButtons(),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Step indicator — numbered circles with connecting lines
  // ------------------------------------------------------------------

  Widget _buildStepIndicator() {
    const stepLabels = ['Prepare', 'Baseline', 'Verify', 'Complete'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(_totalSteps * 2 - 1, (index) {
          if (index.isOdd) {
            // Connector line between circles
            final leftStep = index ~/ 2;
            final lineActive = leftStep < _currentStep;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: lineActive
                        ? const LinearGradient(
                            colors: [AppColors.accent, AppColors.accent],
                          )
                        : null,
                    color: lineActive ? null : AppColors.cardBorder,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            );
          }

          final step = index ~/ 2;
          final isDone = step < _currentStep;
          final isCurrent = step == _currentStep;

          return Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone
                      ? AppColors.accent
                      : isCurrent
                          ? Colors.transparent
                          : AppColors.cardBorder.withAlpha(80),
                  border: Border.all(
                    color: isDone
                        ? AppColors.accent
                        : isCurrent
                            ? AppColors.accent
                            : AppColors.cardBorder,
                    width: 2,
                  ),
                  boxShadow: isCurrent
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withAlpha(60),
                            blurRadius: 8,
                            spreadRadius: 1,
                          )
                        ]
                      : null,
                ),
                child: Center(
                  child: isDone
                      ? const Icon(
                          Icons.check,
                          size: 16,
                          color: AppColors.primaryDark,
                        )
                      : Text(
                          '${step + 1}',
                          style: AppTextStyles.buttonSmall.copyWith(
                            color: isCurrent
                                ? AppColors.accent
                                : AppColors.textSecondary,
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                stepLabels[step],
                style: AppTextStyles.caption.copyWith(
                  color: isDone || isCurrent
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight:
                      isCurrent ? FontWeight.bold : FontWeight.normal,
                  fontSize: 10,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Step content pages
  // ------------------------------------------------------------------

  Widget _buildStepContent() {
    return IndexedStack(
      index: _currentStep,
      children: [
        _buildPrepareStep(),
        _buildBaselineStep(),
        _buildVerifyStep(),
        _buildCompleteStep(),
      ],
    );
  }

  // Step 0: Prepare
  Widget _buildPrepareStep() {
    return _buildStepPage(
      icon: Icons.place,
      iconColor: AppColors.accent,
      title: 'Prepare Device',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _instructionItem(Icons.landscape, 'Place device on flat, stable ground.'),
          const SizedBox(height: 16),
          _instructionItem(Icons.people_outline, 'Ensure no people are walking nearby.'),
          const SizedBox(height: 16),
          _instructionItem(Icons.construction, 'Ensure no machinery is running.'),
          const SizedBox(height: 16),
          _instructionItem(Icons.timer, '30-second baseline capture will follow.'),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(25),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.warning.withAlpha(80)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: AppColors.warning, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Calibration captures background noise. '
                    'Any vibration during capture will affect accuracy.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.warning),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Step 1: Baseline capture
  Widget _buildBaselineStep() {
    final elapsed = _baselineDurationSeconds - _secondsRemaining;
    final progress = elapsed / _baselineDurationSeconds;

    return _buildStepPage(
      icon: Icons.graphic_eq,
      iconColor: AppColors.info,
      title: 'Capturing Baseline',
      body: Column(
        children: [
          const Text(
            'Capturing ambient vibration baseline...',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          // Animated countdown ring
          ScaleTransition(
            scale: _pulseAnimation,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 6,
                    backgroundColor: AppColors.cardBorder,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.info),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$_secondsRemaining',
                      style: AppTextStyles.h1.copyWith(
                        color: AppColors.info,
                        fontSize: 36,
                      ),
                    ),
                    Text(
                      'seconds',
                      style: AppTextStyles.caption.copyWith(color: AppColors.info),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Live noise floor display
          if (_captureStarted) ...[
            _buildNoiseDisplay(),
            const SizedBox(height: 20),
          ],
          LinearProgressIndicator(
            value: progress,
            backgroundColor: AppColors.cardBorder,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.info),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 12),
          Text(
            '${elapsed}s of ${_baselineDurationSeconds}s complete',
            style: AppTextStyles.caption,
            textAlign: TextAlign.center,
          ),
          if (!_captureStarted) ...[
            const SizedBox(height: 24),
            const Text(
              'Capture will begin automatically when you reach this step.',
              style: AppTextStyles.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  /// Live noise level widget shown during baseline capture.
  Widget _buildNoiseDisplay() {
    final noiseFmt = _noiseLevel.toStringAsFixed(4);
    // Colour-code: green if very quiet, amber if borderline
    final noiseColor = _noiseLevel < 0.008
        ? AppColors.success
        : _noiseLevel < 0.012
            ? AppColors.warning
            : AppColors.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: noiseColor.withAlpha(15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: noiseColor.withAlpha(70)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.waves, color: noiseColor, size: 18),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Current noise',
                style: AppTextStyles.caption,
              ),
              Text(
                '$noiseFmt g RMS',
                style: AppTextStyles.h4.copyWith(
                  color: noiseColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // Mini waveform bars (cosmetic)
          _buildMiniWaveform(noiseColor),
        ],
      ),
    );
  }

  Widget _buildMiniWaveform(Color color) {
    final heights = [0.4, 0.7, 1.0, 0.6, 0.8, 0.5, 0.9, 0.3, 0.6, 1.0];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: heights.map((h) {
        final barH = 4.0 + h * 16.0;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: 3,
            height: barH * (_noiseLevel / 0.015).clamp(0.2, 1.5),
            decoration: BoxDecoration(
              color: color.withAlpha(180),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }).toList(),
    );
  }

  // Step 2: Verify
  Widget _buildVerifyStep() {
    return _buildStepPage(
      icon: Icons.check_circle_outline,
      iconColor: AppColors.accent,
      title: 'Verify Results',
      body: Column(
        children: [
          const Text(
            'Baseline capture complete. Review the results below.',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _metricRow(
            icon: Icons.waves,
            label: 'Noise floor',
            value: '${_noiseFloor.toStringAsFixed(3)} mm/s',
            color: AppColors.info,
          ),
          const SizedBox(height: 16),
          _metricRow(
            icon: Icons.notifications_active,
            label: 'Alert threshold',
            value: '${_computedThreshold.toStringAsFixed(2)} mm/s',
            color: AppColors.accent,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.success.withAlpha(80)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: AppColors.success, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'The alert threshold is 6× the noise floor. '
                    'You can fine-tune this in Settings → Vibration Monitor.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.success),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Step 3: Complete
  Widget _buildCompleteStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Large green checkmark
          Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(30),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.success.withAlpha(100), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.success.withAlpha(50),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: AppColors.success,
                size: 72,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Heading
          const Text(
            'Calibration Complete!',
            style: AppTextStyles.h2,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),

          // Noise floor recorded
          _metricRow(
            icon: Icons.waves,
            label: 'Recorded noise floor',
            value: '${_noiseFloor.toStringAsFixed(3)} mm/s',
            color: AppColors.success,
          ),
          const SizedBox(height: 20),

          // Subtitle
          Container(
            padding: const EdgeInsets.all(14),
            decoration: AppDecorations.card,
            child: const Text(
              'Your device is now optimised for the current environment. '
              'Alert thresholds have been tuned to local ambient conditions.',
              style: AppTextStyles.subtitle,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 28),

          // Primary action: Start Monitoring
          SizedBox(
            height: AppSizes.buttonHeight,
            child: ElevatedButton.icon(
              onPressed: () {
                // Pop back to the safety view (root of the navigator stack)
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              icon: const Icon(Icons.monitor_heart, size: 20, color: AppColors.primaryDark),
              label: Text(
                'Start Monitoring',
                style: AppTextStyles.button.copyWith(color: AppColors.primaryDark),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadius),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Secondary action: Calibrate Again
          SizedBox(
            height: AppSizes.buttonHeight,
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _currentStep = 0;
                  _noiseFloor = 0.0;
                  _computedThreshold = 0.0;
                  _captureStarted = false;
                  _secondsRemaining = _baselineDurationSeconds;
                  _noiseLevel = 0.0;
                });
              },
              icon: const Icon(Icons.refresh, size: 18, color: AppColors.accent),
              label: Text(
                'Calibrate Again',
                style: AppTextStyles.button.copyWith(color: AppColors.accent),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.accent, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadius),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Navigation buttons
  // ------------------------------------------------------------------

  Widget _buildNavigationButtons() {
    final isCompleteStep = _currentStep == _totalSteps - 1;
    final isBaselineCapturing = _currentStep == 1 && _captureStarted && _secondsRemaining > 0;

    // Complete step has its own action buttons embedded in the page content
    if (isCompleteStep) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        children: [
          OutlinedButton(
            onPressed: _goBack,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.cardBorder),
              foregroundColor: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
            child: Text(
              _currentStep == 0 ? 'Cancel' : 'Back',
              style: AppTextStyles.button.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ElevatedButton(
              onPressed: isBaselineCapturing ? null : _goNext,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                disabledBackgroundColor: AppColors.cardBorder,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadius),
                ),
              ),
              child: Text(
                _currentStep == 0
                    ? 'Start Capture'
                    : isBaselineCapturing
                        ? 'Capturing...'
                        : 'Next',
                style: AppTextStyles.button.copyWith(
                  color: isBaselineCapturing
                      ? AppColors.textSecondary
                      : AppColors.primaryDark,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Shared page scaffold (used by steps 0, 1, 2 only)
  // ------------------------------------------------------------------

  Widget _buildStepPage({
    required IconData icon,
    required Color iconColor,
    required String title,
    required Widget body,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: iconColor.withAlpha(25),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 48),
            ),
          ),
          const SizedBox(height: 20),
          Text(title, style: AppTextStyles.h2, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          body,
        ],
      ),
    );
  }

  Widget _instructionItem(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.accent.withAlpha(25),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, color: AppColors.accent, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: AppTextStyles.body)),
      ],
    );
  }

  Widget _metricRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: AppTextStyles.subtitle)),
          Text(
            value,
            style: AppTextStyles.accentText.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
