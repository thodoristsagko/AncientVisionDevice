import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for handling biometric authentication (fingerprint, face, PIN)
class BiometricService {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  final LocalAuthentication _localAuth = LocalAuthentication();

  static const String _enrolledKey = 'biometric_enrolled';
  static const String _enabledKey = 'biometric_enabled';
  static const String _pinHashKey = 'app_pin_hash';
  static const String _pinSaltKey = 'app_pin_salt';

  /// Check if device supports any form of biometric authentication
  Future<bool> isDeviceSupported() async {
    try {
      return await _localAuth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// Check if biometrics are available and enrolled on device
  Future<bool> canCheckBiometrics() async {
    try {
      return await _localAuth.canCheckBiometrics;
    } on PlatformException {
      return false;
    }
  }

  /// Get list of available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  /// Check if user has enrolled biometric auth in the app
  Future<bool> isEnrolled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enrolledKey) ?? false;
  }

  /// Check if biometric auth is enabled in settings
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true; // Default enabled if enrolled
  }

  /// Enroll user for biometric authentication
  Future<bool> enroll() async {
    // First verify biometrics work
    final success = await authenticate(reason: 'Verify your identity to enable quick unlock');
    if (success) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enrolledKey, true);
      await prefs.setBool(_enabledKey, true);
      return true;
    }
    return false;
  }

  /// Auto-enroll biometrics without requiring initial authentication
  /// Used to enable quick unlock by default when device supports biometrics
  Future<void> autoEnroll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enrolledKey, true);
    await prefs.setBool(_enabledKey, true);
  }

  /// Disable biometric authentication
  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
  }

  /// Enable biometric authentication (if already enrolled)
  Future<void> enable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
  }

  /// Completely remove biometric enrollment
  Future<void> unenroll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_enrolledKey);
    await prefs.remove(_enabledKey);
  }

  /// Authenticate user with biometrics
  /// Returns a tuple of (success, errorMessage)
  Future<({bool success, String? error})> authenticateWithFeedback({
    String reason = 'Authenticate to access AncientVision',
  }) async {
    try {
      final isSupported = await isDeviceSupported();
      if (!isSupported) {
        return (success: false, error: 'Biometric not supported on this device');
      }

      final canCheck = await canCheckBiometrics();
      if (!canCheck) {
        return (success: false, error: 'No biometrics enrolled on device');
      }

      final result = await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // Allow PIN/pattern as fallback
          useErrorDialogs: true,
        ),
      );

      return (success: result, error: result ? null : 'Authentication cancelled');
    } on PlatformException catch (e) {
      // Handle specific errors with user-friendly messages
      String errorMessage;
      switch (e.code) {
        case 'NotAvailable':
          errorMessage = 'Biometric not available';
          break;
        case 'NotEnrolled':
          errorMessage = 'No biometrics enrolled on device';
          break;
        case 'LockedOut':
          errorMessage = 'Too many attempts. Try again later';
          break;
        case 'PermanentlyLockedOut':
          errorMessage = 'Biometric locked. Use device credentials';
          break;
        default:
          errorMessage = 'Authentication failed';
      }
      return (success: false, error: errorMessage);
    }
  }

  /// Authenticate user with biometrics (simple bool return for backward compatibility)
  Future<bool> authenticate({String reason = 'Authenticate to access AncientVision'}) async {
    final result = await authenticateWithFeedback(reason: reason);
    return result.success;
  }

  /// Get a user-friendly name for the primary biometric type
  Future<String> getBiometricTypeName() async {
    final biometrics = await getAvailableBiometrics();

    if (biometrics.contains(BiometricType.face)) {
      return 'Face ID';
    } else if (biometrics.contains(BiometricType.fingerprint)) {
      return 'Fingerprint';
    } else if (biometrics.contains(BiometricType.iris)) {
      return 'Iris';
    } else if (biometrics.contains(BiometricType.strong) ||
               biometrics.contains(BiometricType.weak)) {
      return 'Biometric';
    }
    return 'PIN/Pattern';
  }

  /// Check if biometric should be shown on app start
  Future<bool> shouldShowBiometricLock() async {
    final enrolled = await isEnrolled();
    final enabled = await isEnabled();
    final supported = await isDeviceSupported();

    return enrolled && enabled && supported;
  }

  // ==================== PIN Authentication ====================

  /// Generate a cryptographically secure random salt for PIN hashing
  String _generateSalt() {
    final secureRandom = math.Random.secure();
    final saltBytes = List<int>.generate(16, (_) => secureRandom.nextInt(256));
    return sha256.convert(saltBytes).toString().substring(0, 16);
  }

  /// Hash a PIN with salt using SHA-256
  String _hashPin(String pin, String salt) {
    final saltedPin = '$salt$pin';
    final bytes = utf8.encode(saltedPin);
    return sha256.convert(bytes).toString();
  }

  /// Check if user has set up a PIN
  Future<bool> hasPin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_pinHashKey) && prefs.containsKey(_pinSaltKey);
  }

  /// Set up a new PIN for the user
  /// PIN must be 4-8 digits
  Future<({bool success, String? error})> setupPin(String pin) async {
    // Validate PIN format
    if (pin.length < 4 || pin.length > 8) {
      return (success: false, error: 'PIN must be 4-8 digits');
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(pin)) {
      return (success: false, error: 'PIN must contain only numbers');
    }

    try {
      final salt = _generateSalt();
      final hash = _hashPin(pin, salt);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pinSaltKey, salt);
      await prefs.setString(_pinHashKey, hash);

      return (success: true, error: null);
    } catch (e) {
      return (success: false, error: 'Failed to save PIN');
    }
  }

  /// Verify entered PIN against stored hash
  Future<({bool success, String? error})> verifyPin(String pin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedHash = prefs.getString(_pinHashKey);
      final storedSalt = prefs.getString(_pinSaltKey);

      if (storedHash == null || storedSalt == null) {
        return (success: false, error: 'No PIN set up');
      }

      final enteredHash = _hashPin(pin, storedSalt);

      if (enteredHash == storedHash) {
        return (success: true, error: null);
      } else {
        return (success: false, error: 'Incorrect PIN');
      }
    } catch (e) {
      return (success: false, error: 'Verification failed');
    }
  }

  /// Clear the stored PIN
  Future<void> clearPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pinHashKey);
    await prefs.remove(_pinSaltKey);
  }

  /// Check if app should show lock screen (biometric or PIN)
  Future<bool> shouldShowLockScreen() async {
    final hasPinSet = await hasPin();
    final shouldShowBiometric = await shouldShowBiometricLock();
    return hasPinSet || shouldShowBiometric;
  }
}
