import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../config/app_constants.dart';
import '../services/device_memory_service.dart';
import '../services/session_history_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../utils/app_styles.dart';

/// AboutScreen — app info, device status, ML model details, build info,
/// diagnostics export, third-party libraries, and a safety notice.
/// Accessible from Settings or the tools menu.
class AboutScreen extends StatefulWidget {
  /// Optional: pass the latest BLE-reported firmware version and device name.
  final String? firmwareVersion;
  final String? deviceName;
  final String? deviceId;
  final bool isConnected;

  const AboutScreen({
    super.key,
    this.firmwareVersion,
    this.deviceName,
    this.deviceId,
    this.isConnected = false,
  });

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  // ML config data
  Map<String, dynamic>? _classifierConfig;
  Map<String, dynamic>? _autoencoderConfig;
  bool _mlConfigLoaded = false;

  // Device memory data
  String? _savedDeviceName;
  String? _savedDeviceId;
  bool _deviceMemoryLoaded = false;

  // Session stats
  SessionRecord? _lastSession;
  bool _sessionLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadMlConfig();
    _loadDeviceMemory();
    _loadLastSession();
  }

  // ── Data loading ──────────────────────────────────────────────────────────────

  Future<void> _loadMlConfig() async {
    Map<String, dynamic>? classifier;
    Map<String, dynamic>? autoencoder;

    try {
      final raw = await rootBundle.loadString(
          'assets/ml/precursor_classifier_config.json');
      classifier = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}

    try {
      final raw = await rootBundle
          .loadString('assets/ml/vibration_model_config.json');
      autoencoder = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}

    if (mounted) {
      setState(() {
        _classifierConfig = classifier;
        _autoencoderConfig = autoencoder;
        _mlConfigLoaded = true;
      });
    }
  }

  Future<void> _loadDeviceMemory() async {
    final id = await DeviceMemoryService.instance.getLastDeviceId();
    final name = await DeviceMemoryService.instance.getLastDeviceName();
    if (mounted) {
      setState(() {
        _savedDeviceId = id;
        _savedDeviceName = name;
        _deviceMemoryLoaded = true;
      });
    }
  }

  Future<void> _loadLastSession() async {
    final sessions = await SessionHistoryService.instance.getSessions();
    if (mounted) {
      setState(() {
        _lastSession = sessions.isNotEmpty ? sessions.first : null;
        _sessionLoaded = true;
      });
    }
  }

  // ── Diagnostics export ───────────────────────────────────────────────────────

  Future<void> _shareDiagnosticReport() async {
    final firmware = widget.firmwareVersion ?? 'Unknown';
    final deviceName = widget.deviceName ??
        _savedDeviceName ??
        'Not connected';
    final deviceId = widget.deviceId ?? _savedDeviceId ?? 'N/A';
    final connected = widget.isConnected ? 'Connected' : 'Disconnected';

    final classifierVersion =
        _classifierConfig?['model_version'] as String? ?? 'Unknown';
    final autoencoderVersion =
        _autoencoderConfig?['model_version'] as String? ?? 'Unknown';
    final fingerprint =
        VibrationAnomalyService.instance.modelFingerprint;

    String sessionStats = 'No sessions recorded';
    if (_lastSession != null) {
      final s = _lastSession!;
      final dur = s.duration;
      sessionStats = 'Last session: ${s.start.toIso8601String()}\n'
          '  Duration: ${dur.inMinutes}m ${dur.inSeconds % 60}s\n'
          '  Samples: ${s.sampleCount}  Anomaly events: ${s.anomalyEvents}\n'
          '  Peak PPV: ${s.peakPpv.toStringAsFixed(3)} mm/s  '
          'Peak score: ${s.peakScore.toStringAsFixed(3)}';
    }

    final platform = kIsWeb
        ? 'Web'
        : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

    final report = '''AncientVision Diagnostic Report
================================
App Version        : 5.1.0
Platform           : $platform
Flutter            : 3.x.x
Device Name        : $deviceName
Device ID          : $deviceId
Connection         : $connected
Firmware           : $firmware
Precursor Model    : v$classifierVersion
Autoencoder Model  : v$autoencoderVersion
Model Fingerprint  : 0x$fingerprint
BLE Service UUID   : ${AppConstants.bleServiceUuid.substring(0, 8)}...
$sessionStats
Generated          : ${DateTime.now().toIso8601String()}
''';

    await Share.share(report, subject: 'AncientVision Diagnostic Report');
  }

  // ── Section builders ──────────────────────────────────────────────────────────

  Widget _buildAppInfoCard() {
    return const _SectionCard(
      icon: Icons.info_outline,
      title: 'App Info',
      child: Column(
        children: [
          _InfoRow(label: 'Application', value: 'AncientVision'),
          _InfoRow(label: 'Version', value: '5.1.0'),
          _InfoRow(label: 'Build Date', value: '2026-03-04'),
          _InfoRow(
            label: 'Description',
            value:
                'Seismic precursor detection for archaeological site safety',
            multiLine: true,
          ),
        ],
      ),
    );
  }

  // ── Section: ML Model ────────────────────────────────────────────────────────

  Widget _buildMlModelCard() {
    if (!_mlConfigLoaded) {
      return const _SectionCard(
        icon: Icons.psychology,
        title: 'ML Model',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                color: AppColors.accent,
                strokeWidth: 2,
              ),
            ),
          ),
        ),
      );
    }

    if (_classifierConfig == null && _autoencoderConfig == null) {
      return const _SectionCard(
        icon: Icons.psychology,
        title: 'ML Model',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.warning_amber_outlined,
                  color: AppColors.warning, size: 18),
              SizedBox(width: 8),
              Text('Model files not found', style: AppTextStyles.subtitle),
            ],
          ),
        ),
      );
    }

    final classifierVersion =
        _classifierConfig?['model_version'] as String? ?? 'Unknown';
    final autoencoderVersion =
        _autoencoderConfig?['model_version'] as String? ?? 'Unknown';
    final classifierInputDim =
        _classifierConfig?['input_dim'] as int? ?? 0;
    final autoencoderInputDim =
        _autoencoderConfig?['input_dim'] as int? ?? 0;
    final classNames =
        (_classifierConfig?['class_names'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .join(', ') ??
            'Unknown';

    // Git SHA from config (if present)
    final classifierSha =
        _classifierConfig?['git_sha'] as String? ?? '';
    final autoencoderSha =
        _autoencoderConfig?['git_sha'] as String? ?? '';

    // Created date
    final classifierDate =
        _classifierConfig?['created_at'] as String? ??
            _classifierConfig?['date'] as String? ??
            '—';
    final autoencoderDate =
        _autoencoderConfig?['created_at'] as String? ??
            _autoencoderConfig?['date'] as String? ??
            '—';

    // Model fingerprint from service
    final fingerprint =
        VibrationAnomalyService.instance.modelFingerprint;
    final fingerprintDisplay =
        fingerprint.isEmpty || fingerprint == '0' ? '—' : '0x$fingerprint';

    return _SectionCard(
      icon: Icons.psychology,
      title: 'ML Model',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Precursor classifier
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Precursor Classifier',
                style: AppTextStyles.subtitle
                    .copyWith(color: AppColors.accent)),
          ),
          _InfoRow(label: 'Version', value: 'v$classifierVersion'),
          if (classifierDate != '—')
            _InfoRow(label: 'Created', value: classifierDate),
          if (classifierSha.isNotEmpty)
            _InfoRow(
                label: 'Git SHA',
                value: classifierSha.length > 8
                    ? classifierSha.substring(0, 8)
                    : classifierSha),
          _InfoRow(label: 'Input dim', value: '$classifierInputDim'),
          _InfoRow(label: 'Classes', value: classNames, multiLine: true),

          const SizedBox(height: 10),
          AppWidgets.divider(),
          const SizedBox(height: 10),

          // Autoencoder
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Autoencoder',
                style: AppTextStyles.subtitle
                    .copyWith(color: AppColors.accent)),
          ),
          _InfoRow(label: 'Version', value: 'v$autoencoderVersion'),
          if (autoencoderDate != '—')
            _InfoRow(label: 'Created', value: autoencoderDate),
          if (autoencoderSha.isNotEmpty)
            _InfoRow(
                label: 'Git SHA',
                value: autoencoderSha.length > 8
                    ? autoencoderSha.substring(0, 8)
                    : autoencoderSha),
          _InfoRow(label: 'Input dim', value: '$autoencoderInputDim'),
          _InfoRow(
              label: 'Fingerprint',
              value: fingerprintDisplay),
        ],
      ),
    );
  }

  // ── Section: Connected Device ────────────────────────────────────────────────

  Widget _buildDeviceInfoCard() {
    // Prefer live widget params; fall back to last-seen from DeviceMemoryService
    final firmware = widget.firmwareVersion ?? 'Unknown';
    final deviceName = widget.deviceName ??
        (_deviceMemoryLoaded ? (_savedDeviceName ?? 'Never connected') : '…');
    final deviceId = widget.deviceId ??
        (_deviceMemoryLoaded ? (_savedDeviceId ?? 'N/A') : '…');

    // BLE UUID — first 8 chars of service UUID
    final blePrefix = AppConstants.bleServiceUuid.length >= 8
        ? '${AppConstants.bleServiceUuid.substring(0, 8)}…'
        : AppConstants.bleServiceUuid;

    return _SectionCard(
      icon: Icons.developer_board,
      title: 'Connected Device',
      child: Column(
        children: [
          _InfoRow(label: 'Device Name', value: deviceName),
          _InfoRow(label: 'Device ID', value: deviceId),
          _InfoRow(label: 'Firmware', value: firmware),
          _InfoRow(label: 'BLE Service', value: blePrefix),
          _InfoRow(
            label: 'Status',
            value: widget.isConnected ? 'Connected' : 'Disconnected',
            valueColor:
                widget.isConnected ? AppColors.success : AppColors.error,
          ),
        ],
      ),
    );
  }

  // ── Section: Build Information ───────────────────────────────────────────────

  Widget _buildBuildInfoCard() {
    final platform = kIsWeb
        ? 'Web'
        : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

    return _SectionCard(
      icon: Icons.build_outlined,
      title: 'Build Information',
      child: Column(
        children: [
          const _InfoRow(label: 'App Version', value: '5.1.0'),
          _InfoRow(label: 'Platform', value: platform, multiLine: true),
          const _InfoRow(label: 'Flutter', value: '3.x.x'),
          const _InfoRow(label: 'Dart', value: '3.x.x'),
        ],
      ),
    );
  }

  // ── Section: Quick Links ──────────────────────────────────────────────────────

  Widget _buildQuickLinksCard() {
    return _SectionCard(
      icon: Icons.link,
      title: 'Quick Links',
      child: Column(
        children: [
          _buildLinkTile(
            icon: Icons.code,
            label: 'View on GitHub',
            subtitle: 'Source code and release notes',
            url: 'https://github.com/ancientvision/app',
          ),
          _buildLinkTile(
            icon: Icons.bug_report_outlined,
            label: 'Report an Issue',
            subtitle: 'Submit a bug or feature request',
            url: 'https://github.com/ancientvision/app/issues',
          ),
          _buildLinkTile(
            icon: Icons.menu_book_outlined,
            label: 'Field Safety Manual',
            subtitle: 'Protocols for on-site safety',
            onTap: _showFieldSafetyManual,
          ),
        ],
      ),
    );
  }

  void _showLinkDialog(String title, String url) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        title: Text(title, style: AppTextStyles.h4),
        content: SelectableText(url, style: AppTextStyles.subtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close',
                style: AppTextStyles.button
                    .copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  void _showFieldSafetyManual() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        title: const Row(
          children: [
            Icon(Icons.menu_book_outlined,
                color: AppColors.accent, size: 20),
            SizedBox(width: 8),
            Text('Field Safety Manual', style: AppTextStyles.h4),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            'ANCIENTVISION FIELD SAFETY PROTOCOL\n\n'
            '1. DEVICE PLACEMENT\n'
            'Place the M5StickC Plus 2 on stable, undisturbed soil within '
            '5 m of the active excavation face. Avoid loose spoil piles '
            'and surfaces that vibrate independently of the ground.\n\n'
            '2. CALIBRATION\n'
            'Calibrate at the start of every monitoring session with '
            'the device stationary. Recalibrate after any sensor move.\n\n'
            '3. ALERT LEVELS\n'
            '• GREEN (SAFE): PPV < 0.3 mm/s — continue normally.\n'
            '• AMBER (CAUTION): PPV 0.3–1.0 mm/s — heightened '
            'monitoring, prepare evacuation.\n'
            '• RED (CRITICAL): PPV > 1.0 mm/s — EVACUATE IMMEDIATELY.\n\n'
            '4. EVACUATION\n'
            'On CRITICAL alert, all personnel leave the excavation zone '
            'without delay. Do not re-enter until a qualified '
            'geotechnical engineer clears the site.\n\n'
            '5. INCIDENT REPORTING\n'
            'Record PPV value, anomaly score, and time. Export the '
            'diagnostic report via the About screen and submit to the '
            'site supervisor.',
            style: AppTextStyles.subtitle.copyWith(height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close',
                style: AppTextStyles.button
                    .copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkTile({
    required IconData icon,
    required String label,
    required String subtitle,
    String? url,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AppColors.accent, size: AppSizes.iconMedium),
      title: Text(label, style: AppTextStyles.body),
      subtitle: Text(subtitle, style: AppTextStyles.caption),
      trailing: const Icon(Icons.chevron_right,
          color: AppColors.textSecondary),
      onTap: onTap ?? () => _showLinkDialog(label, url ?? ''),
    );
  }

  // ── Section: Diagnostics Export ──────────────────────────────────────────────

  Widget _buildDiagnosticsExportCard() {
    String sessionSummary = 'No sessions recorded';
    if (_sessionLoaded && _lastSession != null) {
      final s = _lastSession!;
      sessionSummary =
          '${s.anomalyEvents} anomaly events — peak PPV ${s.peakPpv.toStringAsFixed(2)} mm/s';
    }

    return _SectionCard(
      icon: Icons.upload_file,
      title: 'Diagnostics Export',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Collect and share a plain-text snapshot of device status, '
            'model info, and last session stats for remote support.',
            style: AppTextStyles.subtitle,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: 'Last session',
            value: _sessionLoaded ? sessionSummary : '…',
            multiLine: true,
          ),
          _InfoRow(
            label: 'Connectivity',
            value: widget.isConnected ? 'BLE connected' : 'BLE disconnected',
            valueColor:
                widget.isConnected ? AppColors.success : AppColors.textHint,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppSizes.borderRadius),
                ),
              ),
              icon: const Icon(Icons.share_outlined, size: 20),
              label: const Text('Export Diagnostics',
                  style: AppTextStyles.body),
              onPressed: _shareDiagnosticReport,
            ),
          ),
        ],
      ),
    );
  }

  // ── Section: Third Party Libraries ───────────────────────────────────────────

  Widget _buildThirdPartyCard() {
    const libraries = [
      (
        Icons.bluetooth,
        'flutter_blue_plus',
        'BLE communication with the M5StickC Plus 2 sensor'
      ),
      (
        Icons.model_training,
        'tflite_flutter',
        'On-device TFLite ML inference (autoencoder + classifier)'
      ),
      (
        Icons.share_outlined,
        'share_plus',
        'Cross-platform file and text sharing'
      ),
      (
        Icons.location_on_outlined,
        'geolocator',
        'GPS location for field journal entries'
      ),
      (
        Icons.cloud_outlined,
        'cloud_firestore',
        'Cloud database for session sync and findings'
      ),
      (
        Icons.save_alt_outlined,
        'shared_preferences',
        'Local persistence for device memory and session history'
      ),
      (
        Icons.flutter_dash,
        'Flutter',
        'Cross-platform UI framework (Google)'
      ),
      (
        Icons.memory,
        'PlatformIO',
        'Embedded firmware build system for ESP32'
      ),
    ];

    return _SectionCard(
      icon: Icons.code,
      title: 'Third Party Libraries',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This app uses the following open source packages:',
            style: AppTextStyles.subtitle,
          ),
          const SizedBox(height: 12),
          ...libraries.map(
            (lib) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(lib.$1, size: 18, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(lib.$2, style: AppTextStyles.h4),
                        Text(lib.$3, style: AppTextStyles.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Section: Safety Notice ───────────────────────────────────────────────────

  Widget _buildSafetyNoticeCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.error.withAlpha(15),
        borderRadius: BorderRadius.circular(AppSizes.borderRadiusLarge),
        border: Border.all(color: AppColors.error.withAlpha(120), width: 1.5),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.health_and_safety, color: AppColors.error, size: 22),
              SizedBox(width: 10),
              Text('Safety Notice', style: AppTextStyles.h4),
            ],
          ),
          SizedBox(height: 12),
          Text(
            'This device is a supplementary warning tool only. '
            'Always follow official evacuation procedures and '
            'the instructions of the site safety officer. '
            'Do not rely solely on this app for life-safety decisions.',
            style: AppTextStyles.body,
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('About', style: AppTextStyles.h3),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share diagnostic report',
            onPressed: _shareDiagnosticReport,
          ),
        ],
      ),
      body: Container(
        decoration: AppDecorations.screenBackground,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _buildAppInfoCard(),
              const SizedBox(height: 14),
              _buildMlModelCard(),
              const SizedBox(height: 14),
              _buildDeviceInfoCard(),
              const SizedBox(height: 14),
              _buildBuildInfoCard(),
              const SizedBox(height: 14),
              _buildQuickLinksCard(),
              const SizedBox(height: 14),
              _buildDiagnosticsExportCard(),
              const SizedBox(height: 14),
              _buildThirdPartyCard(),
              const SizedBox(height: 14),
              _buildSafetyNoticeCard(),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Internal helper widgets ───────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: AppSpacing.cardPadding,
      decoration: AppDecorations.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.accent, size: AppSizes.iconMedium),
              const SizedBox(width: AppSpacing.sm),
              Text(title, style: AppTextStyles.h4),
            ],
          ),
          const SizedBox(height: 12),
          AppWidgets.divider(),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool multiLine;
  final Color? valueColor;

  const _InfoRow({
    required this.label,
    required this.value,
    this.multiLine = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final valueStyle = AppTextStyles.body.copyWith(
      color: valueColor ?? AppColors.textPrimary,
    );

    if (multiLine) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppTextStyles.caption),
            const SizedBox(height: 2),
            Text(value, style: valueStyle),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: AppTextStyles.subtitle),
          ),
          Expanded(child: Text(value, style: valueStyle)),
        ],
      ),
    );
  }
}
