import 'package:flutter/material.dart';

/// Centralised theme definitions for the AncientVision app.
///
/// Use [AppTheme.light] and [AppTheme.dark] directly, or obtain the correct
/// one at runtime via [AppTheme.forBrightness].
class AppTheme {
  AppTheme._();

  // ── Shared palette ──────────────────────────────────────────────────────────

  /// Gold accent used across both themes.
  static const Color accent = Color(0xFFFFC107);

  /// Danger / CRITICAL colour (red) — safety-critical UI must use this.
  static const Color critical = Color(0xFFD32F2F);

  /// Warning colour.
  static const Color warning = Color(0xFFFF9800);

  /// Safe / OK colour.
  static const Color safe = Color(0xFF4CAF50);

  // ── Dark theme ──────────────────────────────────────────────────────────────

  /// Dark teal primary — main brand colour.
  static const Color _darkPrimary = Color(0xFF00695C);

  /// Scaffold background in dark mode.
  static const Color _darkScaffold = Color(0xFF0D1B1A);

  /// Card / surface background in dark mode.
  static const Color _darkSurface = Color(0xFF1C2523);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: _darkPrimary,
          secondary: accent,
          surface: _darkSurface,
          error: critical,
          onPrimary: Colors.white,
          onSecondary: Colors.black,
          onSurface: Colors.white,
          onError: Colors.white,
        ),
        scaffoldBackgroundColor: _darkScaffold,
        cardColor: _darkSurface,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D3A39),
          foregroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.black87,
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: accent,
          foregroundColor: Colors.black87,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? accent : Colors.grey,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? accent.withAlpha(120)
                : Colors.white24,
          ),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white, fontSize: 16),
          bodyMedium: TextStyle(color: Colors.white, fontSize: 14),
          bodySmall: TextStyle(color: Colors.white70, fontSize: 12),
          titleLarge: TextStyle(
              color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          titleMedium: TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          titleSmall: TextStyle(
              color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500),
          labelLarge: TextStyle(color: Colors.white, fontSize: 14),
          labelMedium: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        dividerColor: Colors.white12,
        iconTheme: const IconThemeData(color: Colors.white70),
      );

  // ── Light theme ─────────────────────────────────────────────────────────────

  static const Color _lightPrimary = Color(0xFF00897B);
  static const Color _lightScaffold = Color(0xFFF5F5F5);
  static const Color _lightSurface = Colors.white;

  static ThemeData get light => ThemeData(
        brightness: Brightness.light,
        useMaterial3: true,
        colorScheme: ColorScheme.light(
          primary: _lightPrimary,
          secondary: accent,
          surface: _lightSurface,
          error: critical,
          onPrimary: Colors.white,
          onSecondary: Colors.black,
          onSurface: Colors.black87,
          onError: Colors.white,
          surfaceContainerHighest: Colors.grey[200]!,
        ),
        scaffoldBackgroundColor: _lightScaffold,
        cardColor: _lightSurface,
        appBarTheme: const AppBarTheme(
          backgroundColor: _lightPrimary,
          foregroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _lightPrimary,
            foregroundColor: Colors.white,
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: _lightPrimary,
          foregroundColor: Colors.white,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? _lightPrimary : null,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? _lightPrimary.withAlpha(120)
                : null,
          ),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.black87, fontSize: 16),
          bodyMedium: TextStyle(color: Colors.black87, fontSize: 14),
          bodySmall: TextStyle(color: Colors.black54, fontSize: 12),
          titleLarge: TextStyle(
              color: Colors.black87,
              fontSize: 20,
              fontWeight: FontWeight.bold),
          titleMedium: TextStyle(
              color: Colors.black87,
              fontSize: 16,
              fontWeight: FontWeight.w600),
          titleSmall: TextStyle(
              color: Colors.black54,
              fontSize: 14,
              fontWeight: FontWeight.w500),
          labelLarge: TextStyle(color: Colors.black87, fontSize: 14),
          labelMedium: TextStyle(color: Colors.black54, fontSize: 12),
        ),
        dividerColor: Colors.black12,
        iconTheme: const IconThemeData(color: Colors.black54),
      );

  // ── Convenience helper ───────────────────────────────────────────────────────

  /// Returns [dark] or [light] based on the current platform brightness.
  static ThemeData forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}
