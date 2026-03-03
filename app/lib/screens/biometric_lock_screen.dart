import 'package:flutter/material.dart';
import '../services/biometric_service.dart';

/// Lock screen shown when biometric auth is required
class BiometricLockScreen extends StatefulWidget {
  final VoidCallback onBiometricSuccess;
  final Future<void> Function() onUsePassword;

  const BiometricLockScreen({
    super.key,
    required this.onBiometricSuccess,
    required this.onUsePassword,
  });

  @override
  State<BiometricLockScreen> createState() => BiometricLockScreenState();
}

class BiometricLockScreenState extends State<BiometricLockScreen> {
  String _biometricType = 'Biometric';
  String? _errorMessage;
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _loadBiometricType();
    // Auto-trigger authentication when lock screen appears
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleAuthenticate();
    });
  }

  Future<void> _loadBiometricType() async {
    final type = await BiometricService().getBiometricTypeName();
    if (mounted) {
      setState(() => _biometricType = type);
    }
  }

  Future<void> _handleAuthenticate() async {
    if (_isAuthenticating) return;
    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    final result = await BiometricService().authenticateWithFeedback();

    if (mounted) {
      setState(() => _isAuthenticating = false);
      if (result.success) {
        // Success - notify parent to hide lock and proceed to dashboard
        widget.onBiometricSuccess();
      } else if (result.error != null) {
        setState(() => _errorMessage = result.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0D3A39),
              Color(0xFF1C2523),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // Logo
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: const Icon(
                  Icons.account_balance,
                  size: 50,
                  color: Color(0xFF0D3A39),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'AncientVision',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Unlock with $_biometricType',
                style: TextStyle(
                  color: Colors.white.withAlpha(179),
                  fontSize: 16,
                ),
              ),
              const Spacer(),
              // Error message
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(50),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              ],
              // Fingerprint button
              GestureDetector(
                onTap: _isAuthenticating ? null : _handleAuthenticate,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(26),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFFFC107),
                      width: 2,
                    ),
                  ),
                  child: _isAuthenticating
                      ? const CircularProgressIndicator(
                          color: Color(0xFFFFC107),
                          strokeWidth: 2,
                        )
                      : const Icon(
                          Icons.fingerprint,
                          size: 48,
                          color: Color(0xFFFFC107),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isAuthenticating ? 'Authenticating...' : 'Tap to unlock',
                style: TextStyle(
                  color: Colors.white.withAlpha(153),
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              // Use PIN option
              TextButton(
                onPressed: widget.onUsePassword,
                child: const Text(
                  'Use PIN instead',
                  style: TextStyle(
                    color: Color(0xFFFFC107),
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
