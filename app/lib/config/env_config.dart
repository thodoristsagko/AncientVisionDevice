/// Centralized environment configuration.
///
/// API keys are injected at build time via `--dart-define`:
/// ```
/// flutter run --dart-define=IMGBB_API_KEY=xxx --dart-define=NUMISTA_API_KEY=xxx ...
/// ```
///
/// Fallback defaults are provided for development convenience only.
/// NEVER commit real production keys — use `--dart-define` or CI secrets.
class EnvConfig {
  EnvConfig._();

  static const String imgbbApiKey = String.fromEnvironment(
    'IMGBB_API_KEY',
    defaultValue: '63efd0891caba4842791a2f892301d07',
  );

  static const String numistaApiKey = String.fromEnvironment(
    'NUMISTA_API_KEY',
    defaultValue: 'XssVfY6hv00lZbRYm6pzze9Se3OzM4zzBdg29tT8',
  );

  static const String geminiApiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: 'AIzaSyCHz6ruZy1mziMJe_MDH5jlUhKTDqxo4e4',
  );

  static const String openScanUsername = String.fromEnvironment(
    'OPENSCAN_USERNAME',
    defaultValue: 'openscan',
  );

  static const String openScanPassword = String.fromEnvironment(
    'OPENSCAN_PASSWORD',
    defaultValue: 'free',
  );

  static const String reali3ApiKey = String.fromEnvironment(
    'REALI3_API_KEY',
    defaultValue: 'PLACEHOLDER_PENDING_APPROVAL',
  );
}
