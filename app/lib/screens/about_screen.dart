import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../utils/app_styles.dart';

/// AboutScreen — app info, device status, ML model details, open source notice,
/// and a safety notice. Accessible from Settings or the tools menu.
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
  Map<String, dynamic>? _classifierConfig;
  bool _configLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadMlConfig();
  }

  Future<void> _loadMlConfig() async {
    try {
      final raw = await rootBundle.loadString('assets/ml/precursor_classifier_config.json');
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _classifierConfig = parsed;
          _configLoaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _configLoaded = true);
      }
    }
  }

  Future<void> _shareDiagnosticReport() async {
    final firmware = widget.firmwareVersion ?? 'Unknown';
    final device = widget.deviceName ?? 'Not connected';
    final id = widget.deviceId ?? 'N/A';
    final modelVersion = _classifierConfig?['model_version'] as String? ?? 'Unknown';
    final connected = widget.isConnected ? 'Connected' : 'Disconnected';

    final report = '''AncientVision Diagnostic Report
================================
App Version   : 5.1.0
Device Name   : $device
Device ID     : $id
Connection    : $connected
Firmware      : $firmware
ML Model      : v$modelVersion
Generated     : ${DateTime.now().toIso8601String()}
''';

    await Share.share(report, subject: 'AncientVision Diagnostic Report');
  }

  // ── Section: App Info ────────────────────────────────────────────────────────
  Widget _buildAppInfoCard() {
    return _SectionCard(
      icon: Icons.info_outline,
      title: 'App Info',
      child: Column(
        children: const [
          _InfoRow(label: 'Application', value: 'AncientVision'),
          _InfoRow(label: 'Version', value: '5.1.0'),
          _InfoRow(label: 'Build Date', value: '2026-03-03'),
          _InfoRow(
            label: 'Description',
            value: 'Seismic precursor detection for archaeological site safety',
            multiLine: true,
          ),
        ],
      ),
    );
  }

  // ── Section: Device Info ─────────────────────────────────────────────────────
  Widget _buildDeviceInfoCard() {
    final firmware = widget.firmwareVersion ?? 'Not connected';
    final deviceName = widget.deviceName ?? 'Not connected';
    final deviceId = widget.deviceId ?? 'N/A';

    return _SectionCard(
      icon: Icons.developer_board,
      title: 'Device Info',
      child: Column(
        children: [
          _InfoRow(label: 'Firmware', value: firmware),
          _InfoRow(label: 'Device Name', value: deviceName),
          _InfoRow(label: 'Device ID', value: deviceId),
          _InfoRow(
            label: 'Status',
            value: widget.isConnected ? 'Connected' : 'Disconnected',
            valueColor: widget.isConnected ? AppColors.success : AppColors.error,
          ),
        ],
      ),
    );
  }

  // ── Section: ML Model ────────────────────────────────────────────────────────
  Widget _buildMlModelCard() {
    if (!_configLoaded) {
      return _SectionCard(
        icon: Icons.psychology,
        title: 'ML Model',
        child: const Padding(
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

    if (_classifierConfig == null) {
      return _SectionCard(
        icon: Icons.psychology,
        title: 'ML Model',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: const [
              Icon(Icons.warning_amber_outlined, color: AppColors.warning, size: 18),
              SizedBox(width: 8),
              Text('Config not available', style: AppTextStyles.subtitle),
            ],
          ),
        ),
      );
    }

    final version = _classifierConfig!['model_version'] as String? ?? 'Unknown';
    final inputDim = _classifierConfig!['input_dim'] as int? ?? 0;
    final outputDim = _classifierConfig!['output_dim'] as int? ?? 0;
    final classNames = (_classifierConfig!['class_names'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .join(', ') ??
        'Unknown';

    return _SectionCard(
      icon: Icons.psychology,
      title: 'ML Model',
      child: Column(
        children: [
          _InfoRow(label: 'Model', value: 'Precursor Classifier'),
          _InfoRow(label: 'Version', value: 'v$version'),
          _InfoRow(label: 'Input Features', value: '$inputDim'),
          _InfoRow(label: 'Output Classes', value: '$outputDim'),
          _InfoRow(label: 'Classes', value: classNames, multiLine: true),
        ],
      ),
    );
  }

  // ── Section: Open Source ─────────────────────────────────────────────────────
  Widget _buildOpenSourceCard() {
    final components = [
      (Icons.model_training, 'TensorFlow Lite', 'On-device ML inference engine'),
      (Icons.flutter_dash, 'Flutter', 'Cross-platform UI framework'),
      (Icons.memory, 'PlatformIO', 'Embedded firmware build system'),
      (Icons.bluetooth, 'flutter_blue_plus', 'BLE communication layer'),
    ];

    return _SectionCard(
      icon: Icons.code,
      title: 'Open Source',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This project uses the following open source technologies:',
            style: AppTextStyles.subtitle,
          ),
          const SizedBox(height: 12),
          ...components.map(
            (c) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Icon(c.$1, size: 18, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.$2, style: AppTextStyles.h4),
                        Text(c.$3, style: AppTextStyles.caption),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.health_and_safety, color: AppColors.error, size: 22),
              SizedBox(width: 10),
              Text('Safety Notice', style: AppTextStyles.h4),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
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
              _buildDeviceInfoCard(),
              const SizedBox(height: 14),
              _buildMlModelCard(),
              const SizedBox(height: 14),
              _buildOpenSourceCard(),
              const SizedBox(height: 14),
              _buildSafetyNoticeCard(),
              const SizedBox(height: 14),
              // Share diagnostic tile
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: AppDecorations.iconContainer(AppColors.info),
                  child: const Icon(Icons.share_outlined, color: AppColors.info, size: 22),
                ),
                title: const Text('Share Diagnostic Report', style: AppTextStyles.body),
                subtitle: const Text(
                  'Device ID, firmware version, model version',
                  style: AppTextStyles.caption,
                ),
                trailing: const Icon(Icons.chevron_right, color: AppColors.textHint),
                onTap: _shareDiagnosticReport,
              ),
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
