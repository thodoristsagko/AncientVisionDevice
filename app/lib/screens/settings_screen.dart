// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/calibration_wizard_screen.dart';
import '../services/alert_history_service.dart';
import '../services/session_history_service.dart';
import '../services/settings_service.dart';
import '../services/backup_service.dart';
import '../services/biometric_service.dart';
import '../services/coin/index.dart';
import '../services/gemini_coin_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../utils/app_styles.dart';

// Vibration monitor prefs keys
const String _kBlePrefixKey = 'vibmon_ble_prefix';
const String _kPpvThresholdKey = 'vibmon_ppv_threshold';
const String _kInferenceFreqKey = 'vibmon_inference_freq';

// Data management prefs keys
const String _kDataRetentionDaysKey = 'data_retention_days';
const String _kExportFormatKey = 'export_format';

// Calibration prefs keys
const String _kLastCalibrationTimeKey = 'last_calibration_time';

// Notification prefs keys
const String _kNotificationsEnabledKey = 'notificationsEnabled';
const String _kAlertSoundEnabledKey = 'alertSoundEnabled';
const String _kNotifCriticalSoundKey = 'notif_critical_sound';
const String _kNotifVibrationKey = 'notif_vibration';
const String _kNotifCooldownMinutesKey = 'notif_cooldown_minutes';

// BLE prefs keys
const String _kAutoConnectKey = 'autoConnect';
const String _kScanTimeoutSecondsKey = 'scanTimeoutSeconds';

// Data / collector prefs keys
const String _kAutoUploadKey = 'autoUpload';
const String _kCollectorUrlKey = 'collectorUrl';

/// Settings Screen - Simplified for essential features
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settingsService = SettingsService();
  final _backupService = BackupService();
  final _biometricService = BiometricService();
  final _coinService = CoinIdentificationService();
  final _geminiService = GeminiCoinService();
  bool _isLoading = true;
  bool _biometricSupported = false;
  bool _biometricEnrolled = false;
  bool _biometricEnabled = false;
  String _biometricType = 'Biometric';
  bool _hasNumistaKey = false;
  bool _hasGeminiKey = false;

  // Vibration monitor settings (Task 8)
  final _blePrefixController = TextEditingController(text: 'ancientvision');
  double _ppvAlertThreshold = 0.3;
  String _inferenceFreq = '2Hz';

  // Calibration settings
  String? _lastCalibrationTime;

  // Notification settings
  bool _notificationsEnabled = true;
  bool _alertSoundEnabled = true;
  bool _notifCriticalSound = true;
  bool _notifVibration = true;
  int _notifCooldownMinutes = 5;

  // BLE settings
  bool _autoConnect = true;
  int _scanTimeoutSeconds = 10;

  // Data / collector settings
  bool _autoUpload = false;
  String _collectorUrl = 'http://192.168.1.100:8765';

  // Data management settings
  int _dataRetentionDays = 30;
  String _exportFormat = 'csv';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _blePrefixController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    await _settingsService.initialize();
    await _loadBiometricState();
    _hasNumistaKey = _coinService.hasApiKey;
    await _geminiService.initialize();
    _hasGeminiKey = _geminiService.hasApiKey;
    await _loadVibmonSettings();
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadVibmonSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _blePrefixController.text = prefs.getString(_kBlePrefixKey) ?? 'ancientvision';
    _ppvAlertThreshold = prefs.getDouble(_kPpvThresholdKey) ?? 0.3;
    _inferenceFreq = prefs.getString(_kInferenceFreqKey) ?? '2Hz';

    // Calibration settings
    _lastCalibrationTime = prefs.getString(_kLastCalibrationTimeKey);

    // Notification settings
    _notificationsEnabled = prefs.getBool(_kNotificationsEnabledKey) ?? true;
    _alertSoundEnabled = prefs.getBool(_kAlertSoundEnabledKey) ?? true;
    _notifCriticalSound = prefs.getBool(_kNotifCriticalSoundKey) ?? true;
    _notifVibration = prefs.getBool(_kNotifVibrationKey) ?? true;
    _notifCooldownMinutes = prefs.getInt(_kNotifCooldownMinutesKey) ?? 5;

    // BLE settings
    _autoConnect = prefs.getBool(_kAutoConnectKey) ?? true;
    _scanTimeoutSeconds = prefs.getInt(_kScanTimeoutSecondsKey) ?? 10;

    // Data / collector settings
    _autoUpload = prefs.getBool(_kAutoUploadKey) ?? false;
    _collectorUrl = prefs.getString(_kCollectorUrlKey) ?? 'http://192.168.1.100:8765';

    // Data management settings
    _dataRetentionDays = prefs.getInt(_kDataRetentionDaysKey) ?? 30;
    _exportFormat = prefs.getString(_kExportFormatKey) ?? 'csv';
  }

  Future<void> _saveVibmonSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBlePrefixKey, _blePrefixController.text.trim());
    await prefs.setDouble(_kPpvThresholdKey, _ppvAlertThreshold);
    await prefs.setString(_kInferenceFreqKey, _inferenceFreq);

    // Apply to the running anomaly service immediately (no app restart needed)
    final anomalyService = VibrationAnomalyService.instance;
    anomalyService.setAlertThreshold(_ppvAlertThreshold);
    const hzMap = {'1Hz': 1.0, '2Hz': 2.0, '5Hz': 5.0};
    anomalyService.setMaxInferenceHz(hzMap[_inferenceFreq] ?? 2.0);
  }

  Future<void> _loadBiometricState() async {
    _biometricSupported = await _biometricService.isDeviceSupported();
    _biometricEnrolled = await _biometricService.isEnrolled();
    _biometricEnabled = await _biometricService.isEnabled();
    _biometricType = await _biometricService.getBiometricTypeName();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Settings', style: AppTextStyles.h3),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: Container(
        decoration: AppDecorations.screenBackground,
        child: SafeArea(
          child: _isLoading
              ? AppWidgets.loading()
              : ListView(
                  padding: AppSpacing.screenPadding,
                  children: [
                    // === SECURITY (Most Important) ===
                    if (_biometricSupported) ...[
                      _buildSection('Security', Icons.security, [_buildBiometricTile()]),
                      const SizedBox(height: AppSpacing.xxl),
                    ],

                    // === DATA & SYNC ===
                    _buildSection('Data & Sync', Icons.cloud_sync, [
                      _buildSwitchTile(
                        'Auto Sync',
                        'Sync data automatically when online',
                        _settingsService.settings.autoSync,
                        Icons.sync,
                        (value) => _updateSetting('autoSync', value),
                      ),
                      _buildSwitchTile(
                        'Compress Images',
                        'Reduce storage usage',
                        _settingsService.settings.compressImages,
                        Icons.photo_size_select_large,
                        (value) => _updateSetting('compressImages', value),
                      ),
                      _buildBackupTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === 3D CAPTURE ===
                    _buildSection('3D Capture', Icons.view_in_ar, [
                      _buildSwitchTile(
                        'Cloud Processing',
                        'Better 3D models (requires internet)',
                        _settingsService.settings.useCloudProcessing,
                        Icons.cloud,
                        (value) => _updateSetting('useCloudProcessing', value),
                      ),
                      _buildSliderTile(
                        'Max Photos per Scan',
                        _settingsService.settings.maxPhotosPerScan.toDouble(),
                        16,
                        100,
                        Icons.camera_alt,
                        (value) => _updateSetting('maxPhotosPerScan', value.toInt()),
                      ),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === COIN RECOGNITION ===
                    _buildSection('Coin Recognition', Icons.monetization_on, [
                      _buildGeminiApiTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildNumistaApiTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === DISPLAY ===
                    _buildSection('Display', Icons.display_settings, [
                      _buildThemeModeTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildSwitchTile(
                        'Show GPS Coordinates',
                        'Display location on findings',
                        _settingsService.settings.showGpsCoordinates,
                        Icons.location_on,
                        (value) => _updateSetting('showGpsCoordinates', value),
                      ),
                      _buildSwitchTile(
                        'Night Vision Mode',
                        'Red filter to preserve night vision at sites',
                        _settingsService.settings.nightMode,
                        Icons.nightlight_round,
                        (value) => _updateSetting('nightMode', value),
                      ),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === VIBRATION MONITOR ===
                    _buildSection('Vibration Monitor', Icons.sensors, [
                      _buildVibmonBlePrefixTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildVibmonPpvThresholdTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildVibmonInferenceFreqTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === NOTIFICATIONS ===
                    _buildSection('Notifications', Icons.notifications_active, [
                      _buildNotificationsEnabledTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildAlertSoundTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildCriticalAlertSoundTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildVibrationOnAlertTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildAlertCooldownTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === BLUETOOTH ===
                    _buildSection('Bluetooth', Icons.bluetooth_searching, [
                      _buildAutoConnectTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildScanTimeoutTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === DATA ===
                    _buildSection('Data', Icons.storage, [
                      _buildAutoUploadTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildCollectorUrlTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildDataRetentionTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildExportFormatTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === SENSOR ===
                    _buildSection('Sensor Connection', Icons.bluetooth, [
                      _buildSensorLockTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === SENSOR CALIBRATION ===
                    _buildSection('Sensor Calibration', Icons.tune, [
                      _buildCalibrationWizardTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildSendCalibrateTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildLastCalibrationTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxl),

                    // === DATA & PRIVACY ===
                    _buildSection('Data & Privacy', Icons.privacy_tip, [
                      _buildExportSettingsTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildClearSessionHistoryTile(),
                      const Divider(height: 1, color: Colors.white12),
                      _buildClearAlertHistoryTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxxl),

                    // === ACTIONS ===
                    _buildResetButton(),
                    const SizedBox(height: AppSpacing.xxl),

                    // === APP INFO ===
                    _buildAppInfoSection(),
                    const SizedBox(height: 80),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildSection(String title, IconData icon, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppWidgets.sectionHeader(title, icon),
        const SizedBox(height: AppSpacing.md),
        Container(
          decoration: AppDecorations.card,
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildSwitchTile(
    String title,
    String subtitle,
    bool value,
    IconData icon,
    Function(bool) onChanged,
  ) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: Text(title, style: AppTextStyles.body),
      subtitle: Text(subtitle, style: AppTextStyles.subtitleSmall),
      trailing: Switch(
        value: value,
        activeColor: AppColors.accent,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildSliderTile(
    String title,
    double value,
    double min,
    double max,
    IconData icon,
    Function(double) onChanged,
  ) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: Text(title, style: AppTextStyles.body),
      subtitle: Row(
        children: [
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: (max - min).toInt(),
              activeColor: AppColors.accent,
              inactiveColor: AppColors.cardBorder,
              onChanged: onChanged,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppSizes.borderRadiusSmall),
            ),
            child: Text(
              '${value.toInt()}',
              style: AppTextStyles.buttonSmall.copyWith(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVibmonBlePrefixTile() {
    return ListTile(
      leading: const Icon(Icons.bluetooth_searching, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('BLE Device Name Prefix', style: AppTextStyles.body),
      subtitle: Text(
        'Filter: "${_blePrefixController.text}"',
        style: AppTextStyles.subtitleSmall,
      ),
      trailing: const Icon(Icons.edit, color: AppColors.textSecondary, size: 18),
      onTap: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.primaryDark,
            title: const Text('BLE Device Name Prefix', style: AppTextStyles.h3),
            content: TextField(
              controller: _blePrefixController,
              style: AppTextStyles.body,
              decoration: InputDecoration(
                labelText: 'Prefix filter',
                labelStyle: AppTextStyles.subtitleSmall,
                hintText: 'e.g. ancientvision',
                hintStyle: AppTextStyles.caption,
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: AppColors.cardBorder),
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: AppColors.accent),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () async {
                  await _saveVibmonSettings();
                  if (mounted) setState(() {});
                  Navigator.pop(ctx);
                },
                child: Text('Save', style: AppTextStyles.button.copyWith(color: AppColors.accent)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildVibmonPpvThresholdTile() {
    return ListTile(
      leading: const Icon(Icons.speed, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('PPV Alert Threshold', style: AppTextStyles.body),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_ppvAlertThreshold.toStringAsFixed(2)} mm/s',
            style: AppTextStyles.subtitleSmall,
          ),
          Slider(
            value: _ppvAlertThreshold,
            min: 0.1,
            max: 5.0,
            divisions: 49,
            activeColor: AppColors.accent,
            inactiveColor: AppColors.cardBorder,
            onChanged: (value) async {
              setState(() => _ppvAlertThreshold = value);
              await _saveVibmonSettings();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildThemeModeTile() {
    return ListTile(
      leading: const Icon(Icons.brightness_medium, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Theme', style: AppTextStyles.body),
      subtitle: Text(
        'App appearance: ${_settingsService.settings.themeMode.label}',
        style: AppTextStyles.subtitleSmall,
      ),
      trailing: DropdownButton<AppThemeMode>(
        value: _settingsService.settings.themeMode,
        dropdownColor: AppColors.primaryDark,
        underline: const SizedBox.shrink(),
        style: AppTextStyles.body,
        items: AppThemeMode.values
            .map(
              (m) => DropdownMenuItem(
                value: m,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(m.icon, color: AppColors.accent, size: 18),
                    const SizedBox(width: 6),
                    Text(m.label),
                  ],
                ),
              ),
            )
            .toList(),
        onChanged: (value) async {
          if (value != null) {
            await _updateSetting('themeMode', value);
          }
        },
      ),
    );
  }

  Widget _buildVibmonInferenceFreqTile() {
    const freqOptions = ['1Hz', '2Hz', '5Hz'];
    return ListTile(
      leading: const Icon(Icons.psychology, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Inference Frequency Limit', style: AppTextStyles.body),
      subtitle: Text('Max ML inference rate: $_inferenceFreq', style: AppTextStyles.subtitleSmall),
      trailing: DropdownButton<String>(
        value: _inferenceFreq,
        dropdownColor: AppColors.primaryDark,
        underline: const SizedBox.shrink(),
        style: AppTextStyles.body,
        items: freqOptions.map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
        onChanged: (value) async {
          if (value != null) {
            setState(() => _inferenceFreq = value);
            await _saveVibmonSettings();
          }
        },
      ),
    );
  }

  Widget _buildSensorLockTile() {
    final lockedMac = _settingsService.settings.lockedSensorMac;
    final isLocked = lockedMac.isNotEmpty;

    return ListTile(
      leading: Icon(
        isLocked ? Icons.lock : Icons.lock_open,
        color: isLocked ? AppColors.accent : AppColors.textSecondary,
        size: AppSizes.iconMedium,
      ),
      title: Text(
        isLocked ? 'Locked to: $lockedMac' : 'Not locked (connects to any sensor)',
        style: AppTextStyles.body,
      ),
      subtitle: Text(
        isLocked
            ? 'Only connects to this device'
            : 'Tap to lock to currently connected sensor',
        style: AppTextStyles.subtitleSmall,
      ),
      trailing: isLocked
          ? TextButton(
              onPressed: () {
                _updateSetting('lockedSensorMac', '');
              },
              child: const Text('Unlock'),
            )
          : TextButton(
              onPressed: () {
                // Try to find currently connected device
                try {
                  final devices = FlutterBluePlus.connectedDevices;
                  if (devices.isNotEmpty) {
                    final mac = devices.first.remoteId.str;
                    _updateSetting('lockedSensorMac', mac);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Locked to $mac'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No sensor connected. Connect first, then lock.'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: const Text('Lock'),
            ),
    );
  }

  Widget _buildBackupTile() {
    return ListTile(
      leading: const Icon(Icons.backup, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Backup & Restore', style: AppTextStyles.body),
      subtitle: const Text('Save or restore your data', style: AppTextStyles.subtitleSmall),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: _showBackupDialog,
    );
  }

  Widget _buildBiometricTile() {
    if (!_biometricEnrolled) {
      return Container(
        margin: const EdgeInsets.all(AppSpacing.md),
        decoration: AppDecorations.highlightCard,
        child: ListTile(
          leading: const Icon(Icons.fingerprint, color: AppColors.accent, size: AppSizes.iconLarge),
          title: Text('Enable $_biometricType', style: AppTextStyles.body.copyWith(fontWeight: FontWeight.bold)),
          subtitle: const Text('Quick unlock for faster access', style: AppTextStyles.subtitleSmall),
          trailing: ElevatedButton(
            onPressed: () async {
              final success = await _biometricService.enroll();
              if (success && mounted) {
                await _loadBiometricState();
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Quick unlock enabled!', style: AppTextStyles.body),
                    backgroundColor: AppColors.success,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text('Setup', style: AppTextStyles.buttonSmall.copyWith(color: AppColors.primary)),
          ),
        ),
      );
    }

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.fingerprint, color: AppColors.accent, size: AppSizes.iconMedium),
          title: Text('$_biometricType Unlock', style: AppTextStyles.body),
          subtitle: Text(
            _biometricEnabled ? 'Enabled' : 'Disabled',
            style: AppTextStyles.subtitleSmall.copyWith(
              color: _biometricEnabled ? AppColors.success : AppColors.textSecondary,
            ),
          ),
          trailing: Switch(
            value: _biometricEnabled,
            activeColor: AppColors.accent,
            onChanged: (value) async {
              if (value) {
                await _biometricService.enable();
              } else {
                await _biometricService.disable();
              }
              await _loadBiometricState();
              if (mounted) setState(() {});
            },
          ),
        ),
        if (_biometricEnabled)
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, bottom: 12),
            child: GestureDetector(
              onTap: _showRemoveBiometricConfirmation,
              child: Text('Remove quick unlock', style: AppTextStyles.subtitleSmall.copyWith(color: AppColors.error)),
            ),
          ),
      ],
    );
  }

  Widget _buildGeminiApiTile() {
    return ListTile(
      leading: Icon(
        _hasGeminiKey ? Icons.check_circle : Icons.auto_awesome,
        color: _hasGeminiKey ? AppColors.success : AppColors.textSecondary,
        size: AppSizes.iconMedium,
      ),
      title: const Text('Gemini AI Key', style: AppTextStyles.body),
      subtitle: Text(
        _hasGeminiKey ? 'Connected - AI coin identification' : 'Add key for smart recognition',
        style: AppTextStyles.subtitleSmall.copyWith(
          color: _hasGeminiKey ? AppColors.success : AppColors.textSecondary,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: _showGeminiApiDialog,
    );
  }

  void _showGeminiApiDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge)),
        title: const Text('Gemini AI API Key', style: AppTextStyles.h3),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Get a FREE API key from Google AI Studio to enable AI-powered coin identification.',
              style: AppTextStyles.subtitle,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: AppTextStyles.body,
              decoration: InputDecoration(
                labelText: 'API Key',
                labelStyle: AppTextStyles.subtitleSmall,
                hintText: 'Enter your Gemini API key',
                hintStyle: AppTextStyles.caption,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadiusSmall),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadiusSmall),
                  borderSide: const BorderSide(color: AppColors.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadiusSmall),
                  borderSide: const BorderSide(color: AppColors.accent),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Free: 15 requests/minute\nGet key: aistudio.google.com/apikey',
              style: AppTextStyles.caption.copyWith(color: AppColors.accent),
            ),
          ],
        ),
        actions: [
          if (_hasGeminiKey)
            TextButton(
              onPressed: () async {
                await _geminiService.clearApiKey();
                Navigator.pop(context);
                setState(() => _hasGeminiKey = false);
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('API key removed')),
                  );
                }
              },
              child: Text('Remove', style: AppTextStyles.button.copyWith(color: AppColors.error)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              final key = controller.text.trim();
              if (key.isNotEmpty) {
                await _geminiService.setApiKey(key);
                Navigator.pop(context);
                setState(() => _hasGeminiKey = true);
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(
                      content: Text('API key saved! AI coin recognition enabled.'),
                      backgroundColor: AppColors.success,
                    ),
                  );
                }
              }
            },
            child: Text('Save', style: AppTextStyles.button.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  Widget _buildNumistaApiTile() {
    return ListTile(
      leading: Icon(
        _hasNumistaKey ? Icons.check_circle : Icons.key,
        color: _hasNumistaKey ? AppColors.success : AppColors.textSecondary,
        size: AppSizes.iconMedium,
      ),
      title: const Text('Numista API Key', style: AppTextStyles.body),
      subtitle: Text(
        _hasNumistaKey ? 'Connected - Real coin database' : 'Add key for better recognition',
        style: AppTextStyles.subtitleSmall.copyWith(
          color: _hasNumistaKey ? AppColors.success : AppColors.textSecondary,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: _showNumistaApiDialog,
    );
  }

  void _showNumistaApiDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge)),
        title: const Text('Numista API Key', style: AppTextStyles.h3),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Get a FREE API key from numista.com to enable real coin database lookups.',
              style: AppTextStyles.subtitle,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: AppTextStyles.body,
              decoration: InputDecoration(
                labelText: 'API Key',
                labelStyle: AppTextStyles.subtitleSmall,
                hintText: 'Enter your Numista API key',
                hintStyle: AppTextStyles.caption,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadiusSmall),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadiusSmall),
                  borderSide: const BorderSide(color: AppColors.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadiusSmall),
                  borderSide: const BorderSide(color: AppColors.accent),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Free: 2,000 requests/month\nGet key: numista.com/api',
              style: AppTextStyles.caption.copyWith(color: AppColors.accent),
            ),
          ],
        ),
        actions: [
          if (_hasNumistaKey)
            TextButton(
              onPressed: () {
                _coinService.clearApiKey();
                Navigator.pop(context);
                setState(() => _hasNumistaKey = false);
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('API key removed')),
                  );
                }
              },
              child: Text('Remove', style: AppTextStyles.button.copyWith(color: AppColors.error)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              final key = controller.text.trim();
              if (key.isNotEmpty) {
                _coinService.setApiKey(key);
                Navigator.pop(context);
                setState(() => _hasNumistaKey = true);
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(
                      content: Text('API key saved! Coin recognition enhanced.'),
                      backgroundColor: AppColors.success,
                    ),
                  );
                }
              }
            },
            child: Text('Save', style: AppTextStyles.button.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  void _showRemoveBiometricConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge)),
        title: const Text('Remove Quick Unlock?', style: AppTextStyles.h3),
        content: const Text('You will need to sign in with your password next time.', style: AppTextStyles.subtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _biometricService.unenroll();
              await _loadBiometricState();
              if (mounted) {
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Quick unlock removed', style: AppTextStyles.body)),
                );
              }
            },
            child: Text('Remove', style: AppTextStyles.button.copyWith(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationsEnabledTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.notifications, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Critical alert notifications', style: AppTextStyles.body),
      subtitle: const Text('OS-level alerts for hazard events', style: AppTextStyles.subtitleSmall),
      value: _notificationsEnabled,
      activeColor: AppColors.accent,
      onChanged: (value) async {
        setState(() => _notificationsEnabled = value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kNotificationsEnabledKey, value);
      },
    );
  }

  Widget _buildAlertSoundTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.volume_up, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Alert sound', style: AppTextStyles.body),
      subtitle: const Text('Play sound with critical alerts', style: AppTextStyles.subtitleSmall),
      value: _alertSoundEnabled,
      activeColor: AppColors.accent,
      onChanged: (value) async {
        setState(() => _alertSoundEnabled = value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kAlertSoundEnabledKey, value);
      },
    );
  }

  Widget _buildAutoConnectTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.bluetooth_connected, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Auto-connect to last device', style: AppTextStyles.body),
      subtitle: const Text('Reconnect automatically on app start', style: AppTextStyles.subtitleSmall),
      value: _autoConnect,
      activeColor: AppColors.accent,
      onChanged: (value) async {
        setState(() => _autoConnect = value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kAutoConnectKey, value);
      },
    );
  }

  Widget _buildScanTimeoutTile() {
    const options = [5, 10, 30];
    return ListTile(
      leading: const Icon(Icons.timer, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('BLE scan timeout', style: AppTextStyles.body),
      subtitle: const Text('How long to scan before stopping', style: AppTextStyles.subtitleSmall),
      trailing: DropdownButton<int>(
        value: _scanTimeoutSeconds,
        dropdownColor: AppColors.primaryDark,
        underline: const SizedBox.shrink(),
        style: AppTextStyles.body,
        items: options
            .map((s) => DropdownMenuItem(value: s, child: Text('${s}s')))
            .toList(),
        onChanged: (value) async {
          if (value != null) {
            setState(() => _scanTimeoutSeconds = value);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(_kScanTimeoutSecondsKey, value);
          }
        },
      ),
    );
  }

  Widget _buildAutoUploadTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.cloud_upload, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Auto-upload sessions', style: AppTextStyles.body),
      subtitle: const Text('Send session data to collector after each session', style: AppTextStyles.subtitleSmall),
      value: _autoUpload,
      activeColor: AppColors.accent,
      onChanged: (value) async {
        setState(() => _autoUpload = value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kAutoUploadKey, value);
      },
    );
  }

  Widget _buildCollectorUrlTile() {
    return ListTile(
      leading: const Icon(Icons.dns, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Collector URL', style: AppTextStyles.body),
      subtitle: Text(
        _collectorUrl,
        style: AppTextStyles.subtitleSmall,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.edit, color: AppColors.textSecondary, size: 18),
      onTap: () {
        final controller = TextEditingController(text: _collectorUrl);
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.primaryDark,
            title: const Text('Collector URL', style: AppTextStyles.h3),
            content: TextField(
              controller: controller,
              style: AppTextStyles.body,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'URL',
                labelStyle: AppTextStyles.subtitleSmall,
                hintText: 'http://192.168.1.100:8765',
                hintStyle: AppTextStyles.caption,
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: AppColors.cardBorder),
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: AppColors.accent),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () async {
                  final url = controller.text.trim();
                  if (url.isNotEmpty) {
                    setState(() => _collectorUrl = url);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString(_kCollectorUrlKey, url);
                  }
                  Navigator.pop(ctx);
                },
                child: Text('Save', style: AppTextStyles.button.copyWith(color: AppColors.accent)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDataRetentionTile() {
    const options = <int>[7, 30, 90, -1]; // -1 = Forever
    String label(int days) => days == -1 ? 'Forever' : '$days days';
    return ListTile(
      leading: const Icon(Icons.calendar_today, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Keep field data', style: AppTextStyles.body),
      subtitle: const Text('How long to retain recorded session data', style: AppTextStyles.subtitleSmall),
      trailing: DropdownButton<int>(
        value: options.contains(_dataRetentionDays) ? _dataRetentionDays : 30,
        dropdownColor: AppColors.primaryDark,
        underline: const SizedBox.shrink(),
        style: AppTextStyles.body,
        items: options.map((d) => DropdownMenuItem(value: d, child: Text(label(d)))).toList(),
        onChanged: (value) async {
          if (value != null) {
            setState(() => _dataRetentionDays = value);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(_kDataRetentionDaysKey, value);
          }
        },
      ),
    );
  }

  Widget _buildExportFormatTile() {
    return ListTile(
      leading: const Icon(Icons.file_download, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Session export format', style: AppTextStyles.body),
      subtitle: Text(
        _exportFormat == 'csv' ? 'CSV — spreadsheet compatible' : 'JSON — structured data',
        style: AppTextStyles.subtitleSmall,
      ),
      trailing: DropdownButton<String>(
        value: _exportFormat,
        dropdownColor: AppColors.primaryDark,
        underline: const SizedBox.shrink(),
        style: AppTextStyles.body,
        items: const [
          DropdownMenuItem(value: 'csv', child: Text('CSV')),
          DropdownMenuItem(value: 'json', child: Text('JSON')),
        ],
        onChanged: (value) async {
          if (value != null) {
            setState(() => _exportFormat = value);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_kExportFormatKey, value);
          }
        },
      ),
    );
  }

  // =========================================================================
  // SENSOR CALIBRATION TILES
  // =========================================================================

  Widget _buildCalibrationWizardTile() {
    return ListTile(
      leading: const Icon(Icons.science, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Run Calibration Wizard', style: AppTextStyles.body),
      subtitle: const Text('Step-by-step sensor baseline setup', style: AppTextStyles.subtitleSmall),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CalibrationWizardScreen()),
        );
      },
    );
  }

  Widget _buildSendCalibrateTile() {
    return ListTile(
      leading: const Icon(Icons.send, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Send CALIBRATE command', style: AppTextStyles.body),
      subtitle: const Text('Trigger firmware re-calibration over BLE', style: AppTextStyles.subtitleSmall),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: () async {
        final devices = FlutterBluePlus.connectedDevices;
        if (devices.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connect to device first'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }
        try {
          final device = devices.first;
          final services = await device.discoverServices();
          bool sent = false;
          for (final svc in services) {
            for (final char in svc.characteristics) {
              if (char.properties.write || char.properties.writeWithoutResponse) {
                await char.write(const Utf8Encoder().convert('CALIBRATE'));
                sent = true;
                break;
              }
            }
            if (sent) break;
          }
          if (sent) {
            final now = DateTime.now().toIso8601String();
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_kLastCalibrationTimeKey, now);
            if (mounted) {
              setState(() => _lastCalibrationTime = now);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('CALIBRATE command sent'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No writable BLE characteristic found'),
                backgroundColor: Colors.red,
              ),
            );
          }
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      },
    );
  }

  Widget _buildLastCalibrationTile() {
    String subtitle;
    if (_lastCalibrationTime == null) {
      subtitle = 'Never';
    } else {
      try {
        final dt = DateTime.parse(_lastCalibrationTime!).toLocal();
        subtitle = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        subtitle = _lastCalibrationTime!;
      }
    }
    return ListTile(
      leading: const Icon(Icons.history, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Last calibration', style: AppTextStyles.body),
      subtitle: Text(subtitle, style: AppTextStyles.subtitleSmall),
    );
  }

  // =========================================================================
  // ENHANCED NOTIFICATION TILES
  // =========================================================================

  Widget _buildCriticalAlertSoundTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.volume_up, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Critical alert sound', style: AppTextStyles.body),
      subtitle: const Text('Play loud sound for critical hazard alerts', style: AppTextStyles.subtitleSmall),
      value: _notifCriticalSound,
      activeColor: AppColors.accent,
      onChanged: (value) async {
        setState(() => _notifCriticalSound = value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kNotifCriticalSoundKey, value);
      },
    );
  }

  Widget _buildVibrationOnAlertTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.vibration, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Vibration on alert', style: AppTextStyles.body),
      subtitle: const Text('Haptic feedback when alert triggers', style: AppTextStyles.subtitleSmall),
      value: _notifVibration,
      activeColor: AppColors.accent,
      onChanged: (value) async {
        setState(() => _notifVibration = value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kNotifVibrationKey, value);
      },
    );
  }

  Widget _buildAlertCooldownTile() {
    const options = [1, 5, 10, 30];
    return ListTile(
      leading: const Icon(Icons.timelapse, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Alert cooldown', style: AppTextStyles.body),
      subtitle: const Text('Minimum time between repeated alerts', style: AppTextStyles.subtitleSmall),
      trailing: DropdownButton<int>(
        value: _notifCooldownMinutes,
        dropdownColor: AppColors.primaryDark,
        underline: const SizedBox.shrink(),
        style: AppTextStyles.body,
        items: options
            .map((m) => DropdownMenuItem(value: m, child: Text('${m}m')))
            .toList(),
        onChanged: (value) async {
          if (value != null) {
            setState(() => _notifCooldownMinutes = value);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(_kNotifCooldownMinutesKey, value);
          }
        },
      ),
    );
  }

  // =========================================================================
  // DATA & PRIVACY TILES
  // =========================================================================

  Widget _buildExportSettingsTile() {
    return ListTile(
      leading: const Icon(Icons.ios_share, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Export app settings', style: AppTextStyles.body),
      subtitle: const Text('Share all settings as JSON', style: AppTextStyles.subtitleSmall),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final keys = prefs.getKeys();
          final Map<String, dynamic> allPrefs = {};
          for (final key in keys) {
            final val = prefs.get(key);
            allPrefs[key] = val;
          }
          final json = const JsonEncoder.withIndent('  ').convert(allPrefs);
          await Share.share(json, subject: 'AncientVision Settings Export');
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
          );
        }
      },
    );
  }

  Widget _buildClearSessionHistoryTile() {
    return ListTile(
      leading: const Icon(Icons.delete_sweep, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Clear session history', style: AppTextStyles.body),
      subtitle: const Text('Remove all recorded vibration sessions', style: AppTextStyles.subtitleSmall),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.primaryDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge)),
            title: const Text('Clear Session History?', style: AppTextStyles.h3),
            content: const Text(
              'All recorded sessions will be permanently deleted.',
              style: AppTextStyles.subtitle,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  try {
                    await SessionHistoryService.instance.clearAll();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Session history cleared'),
                          backgroundColor: AppColors.success,
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
                child: Text('Clear', style: AppTextStyles.button.copyWith(color: AppColors.error)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildClearAlertHistoryTile() {
    return ListTile(
      leading: const Icon(Icons.notifications_off, color: AppColors.textSecondary, size: AppSizes.iconMedium),
      title: const Text('Clear alert history', style: AppTextStyles.body),
      subtitle: const Text('Remove all recorded hazard alerts', style: AppTextStyles.subtitleSmall),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.primaryDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge)),
            title: const Text('Clear Alert History?', style: AppTextStyles.h3),
            content: const Text(
              'All recorded alerts will be permanently deleted.',
              style: AppTextStyles.subtitle,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  try {
                    await AlertHistoryService().clear();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Alert history cleared'),
                          backgroundColor: AppColors.success,
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
                child: Text('Clear', style: AppTextStyles.button.copyWith(color: AppColors.error)),
              ),
            ],
          ),
        );
      },
    );
  }

  // =========================================================================
  // APP INFO SECTION
  // =========================================================================

  Widget _buildAppInfoSection() {
    return _buildSection('About', Icons.info_outline, [
      const ListTile(
        leading: Icon(Icons.tag, color: AppColors.textSecondary, size: AppSizes.iconMedium),
        title: Text('Version', style: AppTextStyles.body),
        subtitle: Text('1.0.0+docker-experiment', style: AppTextStyles.subtitleSmall),
      ),
      const Divider(height: 1, color: Colors.white12),
      const ListTile(
        leading: Icon(Icons.code, color: AppColors.textSecondary, size: AppSizes.iconMedium),
        title: Text('Branch', style: AppTextStyles.body),
        subtitle: Text('docker-experiment', style: AppTextStyles.subtitleSmall),
      ),
      const Divider(height: 1, color: Colors.white12),
      ListTile(
        leading: const Icon(Icons.gavel, color: AppColors.textSecondary, size: AppSizes.iconMedium),
        title: const Text('Open Source Licenses', style: AppTextStyles.body),
        subtitle: const Text('Third-party library acknowledgements', style: AppTextStyles.subtitleSmall),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        onTap: () {
          showLicensePage(
            context: context,
            applicationName: 'AncientVision',
            applicationVersion: '1.0.0+docker-experiment',
          );
        },
      ),
    ]);
  }

  Widget _buildResetButton() {
    return Center(
      child: TextButton.icon(
        onPressed: _showResetConfirmation,
        icon: const Icon(Icons.restore, color: AppColors.error, size: AppSizes.iconSmall),
        label: Text('Reset all settings to defaults', style: AppTextStyles.button.copyWith(color: AppColors.error)),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.error,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
    );
  }

  Future<void> _updateSetting(String key, dynamic value) async {
    await _settingsService.updateSetting(key, value);
    if (mounted) setState(() {});
  }

  void _showBackupDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: AppDecorations.bottomSheet,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: AppDecorations.iconContainer(AppColors.success),
                child: const Icon(Icons.backup, color: AppColors.success),
              ),
              title: const Text('Create Backup', style: AppTextStyles.body),
              subtitle: const Text('Save all your data', style: AppTextStyles.subtitleSmall),
              onTap: () async {
                Navigator.pop(context);
                final backup = await _backupService.createBackup(data: {
                  'timestamp': DateTime.now().toIso8601String(),
                });
                if (backup != null && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Backup created: ${backup.filename}', style: AppTextStyles.body),
                      backgroundColor: AppColors.success,
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: AppDecorations.iconContainer(AppColors.info),
                child: const Icon(Icons.restore, color: AppColors.info),
              ),
              title: const Text('Restore Backup', style: AppTextStyles.body),
              subtitle: const Text('Load from a backup file', style: AppTextStyles.subtitleSmall),
              onTap: () async {
                Navigator.pop(context);
                final backups = await _backupService.listBackups();
                if (backups.isEmpty) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No backups found', style: AppTextStyles.body)),
                    );
                  }
                } else {
                  _showBackupList(backups);
                }
              },
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }

  void _showBackupList(List<BackupInfo> backups) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: AppDecorations.bottomSheet,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select Backup', style: AppTextStyles.h3),
            const SizedBox(height: AppSpacing.lg),
            ...backups.take(5).map((backup) => ListTile(
              leading: const Icon(Icons.folder, color: AppColors.accent),
              title: Text(backup.filename, style: AppTextStyles.body),
              subtitle: Text('${backup.dateString} - ${backup.sizeString}', style: AppTextStyles.subtitleSmall),
              onTap: () async {
                Navigator.pop(context);
                final data = await _backupService.restoreBackup(backup.path);
                if (data != null && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Backup restored successfully', style: AppTextStyles.body),
                      backgroundColor: AppColors.success,
                    ),
                  );
                }
              },
            )),
          ],
        ),
      ),
    );
  }

  void _showResetConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge)),
        title: const Text('Reset Settings?', style: AppTextStyles.h3),
        content: const Text('All settings will return to their default values.', style: AppTextStyles.subtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _settingsService.resetToDefaults();
              // Reset new SharedPreferences-backed settings to defaults
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(_kNotificationsEnabledKey, true);
              await prefs.setBool(_kAlertSoundEnabledKey, true);
              await prefs.setBool(_kNotifCriticalSoundKey, true);
              await prefs.setBool(_kNotifVibrationKey, true);
              await prefs.setInt(_kNotifCooldownMinutesKey, 5);
              await prefs.setBool(_kAutoConnectKey, true);
              await prefs.setInt(_kScanTimeoutSecondsKey, 10);
              await prefs.setBool(_kAutoUploadKey, false);
              await prefs.setString(_kCollectorUrlKey, 'http://192.168.1.100:8765');
              await prefs.setInt(_kDataRetentionDaysKey, 30);
              await prefs.setString(_kExportFormatKey, 'csv');
              if (mounted) {
                setState(() {
                  _notificationsEnabled = true;
                  _alertSoundEnabled = true;
                  _notifCriticalSound = true;
                  _notifVibration = true;
                  _notifCooldownMinutes = 5;
                  _autoConnect = true;
                  _scanTimeoutSeconds = 10;
                  _autoUpload = false;
                  _collectorUrl = 'http://192.168.1.100:8765';
                  _dataRetentionDays = 30;
                  _exportFormat = 'csv';
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings reset to defaults', style: AppTextStyles.body)),
                );
              }
            },
            child: Text('Reset', style: AppTextStyles.button.copyWith(color: AppColors.error)),
          ),
        ],
      ),
    );
  }
}
