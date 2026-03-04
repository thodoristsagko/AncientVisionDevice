import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/app_styles.dart';

/// Step-by-step calibration wizard for AncientVision vibration monitoring.
///
/// Walk the user through four stages:
///   1. Prepare   — place the device correctly
///   2. Baseline  — 30-second ambient capture with live countdown
///   3. Verify    — display captured noise floor and computed threshold
///   4. Complete  — confirmation with a large green checkmark
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
  bool _captureStarted = false;

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
    // Cancelling mid-capture resets the countdown
    if (_currentStep == 1) {
      _cancelBaselineCapture();
    }
    setState(() => _currentStep--);
  }

  void _startBaselineCapture() {
    _captureStarted = true;
    _secondsRemaining = _baselineDurationSeconds;
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
        _onCaptureComplete();
      }
    });
  }

  void _cancelBaselineCapture() {
    _countdownTimer?.cancel();
    _captureStarted = false;
    _secondsRemaining = _baselineDurationSeconds;
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
    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: AppColors.textSecondary),
          onPressed: () => Navigator.of(context).pop(false),
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
    );
  }

  // ------------------------------------------------------------------
  // Step indicator
  // ------------------------------------------------------------------

  Widget _buildStepIndicator() {
    const stepLabels = ['Prepare', 'Baseline', 'Verify', 'Complete'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Row(
        children: List.generate(_totalSteps * 2 - 1, (index) {
          if (index.isOdd) {
            // Connector line
            return Expanded(
              child: Container(
                height: 2,
                color: index ~/ 2 < _currentStep
                    ? AppColors.accent
                    : AppColors.cardBorder,
              ),
            );
          }
          final step = index ~/ 2;
          final isDone = step < _currentStep;
          final isCurrent = step == _currentStep;
          return Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone
                      ? AppColors.accent
                      : isCurrent
                          ? AppColors.accent.withAlpha(80)
                          : AppColors.cardBorder,
                  border: Border.all(
                    color:
                        isCurrent ? AppColors.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: isDone
                      ? const Icon(Icons.check, size: 16, color: AppColors.primaryDark)
                      : Text(
                          '${step + 1}',
                          style: AppTextStyles.buttonSmall.copyWith(
                            color: isCurrent
                                ? AppColors.accent
                                : AppColors.textSecondary,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                stepLabels[step],
                style: AppTextStyles.caption.copyWith(
                  color: isCurrent
                      ? AppColors.accent
                      : isDone
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                  fontWeight:
                      isCurrent ? FontWeight.bold : FontWeight.normal,
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
          const SizedBox(height: 32),
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
          const SizedBox(height: 32),
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
    return _buildStepPage(
      icon: Icons.check_circle,
      iconColor: AppColors.success,
      title: 'Calibration Complete',
      body: Column(
        children: [
          const SizedBox(height: 16),
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(25),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check,
              color: AppColors.success,
              size: 60,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Device ready for monitoring.',
            style: AppTextStyles.h3,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'The vibration sensor has been calibrated to the site\'s '
            'ambient conditions. Alerts will now be tuned to local noise.',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Navigation buttons
  // ------------------------------------------------------------------

  Widget _buildNavigationButtons() {
    final isLastStep = _currentStep == _totalSteps - 1;
    final isBaselineCapturing = _currentStep == 1 && _captureStarted && _secondsRemaining > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        children: [
          if (!isLastStep)
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
          if (!isLastStep) const SizedBox(width: 16),
          Expanded(
            child: isLastStep
                ? ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.check, size: 18, color: AppColors.primaryDark),
                    label: Text(
                      'Done',
                      style: AppTextStyles.button.copyWith(color: AppColors.primaryDark),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  )
                : ElevatedButton(
                    onPressed: isBaselineCapturing ? null : _goNext,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      disabledBackgroundColor: AppColors.cardBorder,
                      padding: const EdgeInsets.symmetric(vertical: 14),
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
  // Shared page scaffold
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
