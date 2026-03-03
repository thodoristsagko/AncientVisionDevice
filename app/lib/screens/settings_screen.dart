// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/settings_service.dart';
import '../services/backup_service.dart';
import '../services/biometric_service.dart';
import '../services/coin/index.dart';
import '../services/gemini_coin_service.dart';
import '../utils/app_styles.dart';

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

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _settingsService.initialize();
    await _loadBiometricState();
    _hasNumistaKey = _coinService.hasApiKey;
    await _geminiService.initialize();
    _hasGeminiKey = _geminiService.hasApiKey;
    if (mounted) {
      setState(() => _isLoading = false);
    }
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

                    // === SENSOR ===
                    _buildSection('Sensor Connection', Icons.bluetooth, [
                      _buildSensorLockTile(),
                    ]),
                    const SizedBox(height: AppSpacing.xxxl),

                    // === ACTIONS ===
                    _buildResetButton(),
                    const SizedBox(height: AppSpacing.xxl),

                    // === APP INFO ===
                    _buildAppInfo(),
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

  Widget _buildResetButton() {
    return Center(
      child: OutlinedButton.icon(
        onPressed: _showResetConfirmation,
        icon: const Icon(Icons.restore, color: AppColors.warning, size: AppSizes.iconSmall),
        label: Text('Reset All Settings', style: AppTextStyles.button.copyWith(color: AppColors.warning)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: AppColors.warning),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildAppInfo() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: AppDecorations.section,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: AppDecorations.circleBadge(AppColors.accent),
            child: const Icon(Icons.explore, color: AppColors.accent, size: AppSizes.iconXLarge),
          ),
          const SizedBox(height: AppSpacing.md),
          const Text('AncientVision', style: AppTextStyles.h3),
          const Text('Version 1.0.0', style: AppTextStyles.subtitleSmall),
          const SizedBox(height: AppSpacing.sm),
          const Text('Archaeological Field Documentation', style: AppTextStyles.caption),
          const SizedBox(height: AppSpacing.xs),
          Text('FLL Competition 2024', style: AppTextStyles.accentText.copyWith(fontSize: 11)),
        ],
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
              if (mounted) {
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings reset to defaults', style: AppTextStyles.body)),
                );
              }
            },
            child: Text('Reset', style: AppTextStyles.button.copyWith(color: AppColors.warning)),
          ),
        ],
      ),
    );
  }
}
