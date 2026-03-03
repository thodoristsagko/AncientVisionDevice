import 'package:flutter/material.dart';
import '../services/biometric_service.dart';
import '../services/background_service.dart';
import 'biometric_lock_screen.dart';
import '../main.dart';

/// Gate that checks if biometric lock should be shown
class BiometricGate extends StatefulWidget {
  const BiometricGate({super.key});

  @override
  State<BiometricGate> createState() => BiometricGateState();
}

class BiometricGateState extends State<BiometricGate> with WidgetsBindingObserver {
  bool _isChecking = true;
  bool _showBiometricLock = false;
  bool _wasInBackground = false;
  DateTime? _backgroundTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBiometric();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      // App going to background
      _wasInBackground = true;
      _backgroundTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _wasInBackground) {
      // App returning from background - check if we need to re-authenticate
      _wasInBackground = false;
      _checkBiometricOnResume();
    }
  }

  Future<void> _checkBiometricOnResume() async {
    // Only require re-auth if app was in background for more than 30 seconds
    if (_backgroundTime != null) {
      final elapsed = DateTime.now().difference(_backgroundTime!);
      debugPrint('App resumed after ${elapsed.inSeconds} seconds in background');
      if (elapsed.inSeconds > 30) {
        debugPrint('Over 30 seconds - checking biometric lock...');
        final biometricService = BiometricService();
        final shouldShow = await biometricService.shouldShowBiometricLock();
        debugPrint('Should show biometric lock on resume: $shouldShow');
        if (shouldShow && mounted) {
          setState(() => _showBiometricLock = true);
        }
      }
    }
  }

  Future<void> _checkBiometric() async {
    final biometricService = BiometricService();

    // Debug: Check biometric state
    final isSupported = await biometricService.isDeviceSupported();
    final canCheck = await biometricService.canCheckBiometrics();
    final isEnrolled = await biometricService.isEnrolled();
    final isEnabled = await biometricService.isEnabled();
    debugPrint('Biometric check: supported=$isSupported, canCheck=$canCheck, enrolled=$isEnrolled, enabled=$isEnabled');

    // Auto-enroll biometrics if device supports it but user hasn't enrolled yet
    // This makes quick unlock available by default for convenience
    if (isSupported && canCheck && !isEnrolled) {
      debugPrint('Auto-enrolling biometrics for quick unlock...');
      await biometricService.autoEnroll();
    }

    final shouldShow = await biometricService.shouldShowBiometricLock();
    debugPrint('Should show biometric lock: $shouldShow');

    if (mounted) {
      setState(() {
        _showBiometricLock = shouldShow;
        _isChecking = false;
      });

      // If no biometric lock needed, start background service directly
      if (!shouldShow) {
        _startBackgroundService();
      }
      // If biometric needed, the lock screen will auto-trigger authentication
    }
  }

  Future<void> _startBackgroundService() async {
    await BackgroundServiceManager().startService();
  }

  Future<void> _usePassword() async {
    final biometricService = BiometricService();
    final hasPin = await biometricService.hasPin();

    if (!hasPin) {
      // No PIN set - show PIN setup dialog
      if (mounted) {
        await _showPinSetupDialog();
      }
    } else {
      // PIN exists - show PIN entry dialog
      if (mounted) {
        await _showPinEntryDialog();
      }
    }
  }

  Future<void> _showPinSetupDialog() async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    String? errorText;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1C2523),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Set Up PIN',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Create a 4-8 digit PIN for quick access when biometrics are unavailable.',
                style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 14),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  labelText: 'Enter PIN',
                  labelStyle: TextStyle(color: Colors.white.withAlpha(179)),
                  counterText: '',
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withAlpha(77)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFFFC107)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  labelText: 'Confirm PIN',
                  labelStyle: TextStyle(color: Colors.white.withAlpha(179)),
                  counterText: '',
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withAlpha(77)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFFFC107)),
                  ),
                ),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  errorText!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                'Cancel',
                style: TextStyle(color: Colors.white.withAlpha(179)),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFC107),
                foregroundColor: const Color(0xFF0D3A39),
              ),
              onPressed: () async {
                final pin = pinController.text;
                final confirm = confirmController.text;

                if (pin.length < 4) {
                  setDialogState(() => errorText = 'PIN must be at least 4 digits');
                  return;
                }
                if (pin != confirm) {
                  setDialogState(() => errorText = 'PINs do not match');
                  return;
                }

                final result = await BiometricService().setupPin(pin);
                if (result.success) {
                  if (context.mounted) Navigator.pop(context, true);
                } else {
                  setDialogState(() => errorText = result.error);
                }
              },
              child: const Text('Save PIN'),
            ),
          ],
        ),
      ),
    );

    if (result == true && mounted) {
      setState(() => _showBiometricLock = false);
      _startBackgroundService();
    }
  }

  Future<void> _showPinEntryDialog() async {
    final pinController = TextEditingController();
    String? errorText;
    int attempts = 0;
    const maxAttempts = 5;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1C2523),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Enter PIN',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Enter your PIN to unlock AncientVision',
                style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 14),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  labelText: 'PIN',
                  labelStyle: TextStyle(color: Colors.white.withAlpha(179)),
                  counterText: '',
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withAlpha(77)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFFFC107)),
                  ),
                ),
                onSubmitted: (_) async {
                  final pin = pinController.text;
                  final result = await BiometricService().verifyPin(pin);

                  if (result.success) {
                    if (context.mounted) Navigator.pop(context, true);
                  } else {
                    attempts++;
                    if (attempts >= maxAttempts) {
                      if (context.mounted) {
                        Navigator.pop(context, false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Too many attempts. Try biometrics or restart the app.'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    } else {
                      setDialogState(() {
                        errorText = '${result.error}. ${maxAttempts - attempts} attempts left.';
                        pinController.clear();
                      });
                    }
                  }
                },
              ),
              if (errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  errorText!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                'Cancel',
                style: TextStyle(color: Colors.white.withAlpha(179)),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFC107),
                foregroundColor: const Color(0xFF0D3A39),
              ),
              onPressed: () async {
                final pin = pinController.text;
                final result = await BiometricService().verifyPin(pin);

                if (result.success) {
                  if (context.mounted) Navigator.pop(context, true);
                } else {
                  attempts++;
                  if (attempts >= maxAttempts) {
                    if (context.mounted) {
                      Navigator.pop(context, false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Too many attempts. Try biometrics or restart the app.'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  } else {
                    setDialogState(() {
                      errorText = '${result.error}. ${maxAttempts - attempts} attempts left.';
                      pinController.clear();
                    });
                  }
                }
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );

    if (result == true && mounted) {
      setState(() => _showBiometricLock = false);
      _startBackgroundService();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFFFC107)),
        ),
      );
    }

    if (_showBiometricLock) {
      return BiometricLockScreen(
        onBiometricSuccess: () {
          setState(() => _showBiometricLock = false);
          _startBackgroundService();
        },
        onUsePassword: _usePassword,
      );
    }

    return const DashboardScreen();
  }
}
