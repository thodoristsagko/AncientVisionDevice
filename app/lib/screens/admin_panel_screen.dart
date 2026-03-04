import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_service.dart';
import '../services/export_service.dart';
import '../services/ml_anomaly_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../services/precursor_classifier_service.dart';
import '../services/background_service.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // ── Model info ──────────────────────────────────────────────────────────────
  Map<String, dynamic>? _autoencoderConfig;
  Map<String, dynamic>? _precursorConfig;
  int? _autoencoderFileSizeBytes;
  int? _precursorFileSizeBytes;
  bool _modelsLoading = true;

  // ── Pipeline health (SharedPreferences) ────────────────────────────────────
  String? _lastTrainingDate;
  String? _modelVersion;
  String? _pipelineStatus;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadModelInfo();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Data loading ─────────────────────────────────────────────────────────────

  Future<void> _loadModelInfo() async {
    if (!mounted) return;
    setState(() => _modelsLoading = true);

    // Load autoencoder config
    Map<String, dynamic>? autoencoderCfg;
    int? autoencoderSize;
    try {
      final cfgJson = await rootBundle
          .loadString('assets/ml/vibration_model_config.json');
      autoencoderCfg = jsonDecode(cfgJson) as Map<String, dynamic>;
    } catch (_) {}
    try {
      final bytes =
          await rootBundle.load('assets/ml/vibration_anomaly.tflite');
      autoencoderSize = bytes.lengthInBytes;
    } catch (_) {}

    // Load precursor classifier config
    Map<String, dynamic>? precursorCfg;
    int? precursorSize;
    try {
      final cfgJson = await rootBundle
          .loadString('assets/ml/precursor_classifier_config.json');
      precursorCfg = jsonDecode(cfgJson) as Map<String, dynamic>;
    } catch (_) {}
    try {
      final bytes =
          await rootBundle.load('assets/ml/precursor_classifier.tflite');
      precursorSize = bytes.lengthInBytes;
    } catch (_) {}

    // Load pipeline health from SharedPreferences
    String? lastTraining;
    String? modelVer;
    String? pipelineStatus;
    try {
      final prefs = await SharedPreferences.getInstance();
      lastTraining = prefs.getString('pipeline_last_training_date');
      modelVer = prefs.getString('pipeline_model_version');
      pipelineStatus = prefs.getString('pipeline_status');
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _autoencoderConfig = autoencoderCfg;
      _precursorConfig = precursorCfg;
      _autoencoderFileSizeBytes = autoencoderSize;
      _precursorFileSizeBytes = precursorSize;
      _lastTrainingDate = lastTraining;
      _modelVersion = modelVer;
      _pipelineStatus = pipelineStatus;
      _modelsLoading = false;
    });
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  String _formatBytes(int? bytes) {
    if (bytes == null) return 'N/A';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Color _getRoleColor(String role) {
    switch (role) {
      case 'admin':
        return const Color(0xFFF44336);
      case 'archeologist':
        return const Color(0xFFFFC107);
      case 'viewer':
      default:
        return const Color(0xFF4CAF50);
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D3A39), Color(0xFF1C2523)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Icon(Icons.admin_panel_settings,
                        color: Color(0xFFF44336), size: 28),
                    const SizedBox(width: 12),
                    const Text(
                      'Admin Panel',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white70),
                      tooltip: 'Refresh',
                      onPressed: _loadModelInfo,
                    ),
                  ],
                ),
              ),

              // Tab bar
              TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFFFFC107),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                tabs: const [
                  Tab(icon: Icon(Icons.people), text: 'Users'),
                  Tab(icon: Icon(Icons.memory), text: 'System'),
                ],
              ),

              // Tab content
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildUsersTab(),
                    _buildSystemTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Users tab ───────────────────────────────────────────────────────────────

  Widget _buildUsersTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: AuthService.getUsersStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Center(
            child: Text(
              'No users found',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }

        final users = snapshot.data!.docs;

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: users.length,
          itemBuilder: (context, index) {
            final userData =
                users[index].data() as Map<String, dynamic>;
            final uid = users[index].id;
            final email = userData['email'] ?? 'Unknown';
            final name = userData['fullName'] ?? email;
            final role = userData['role'] ?? 'viewer';
            final status = userData['status'] ?? 'active';
            final isCurrentUser =
                uid == AuthService.currentUser?.uid;

            return Card(
              color: Colors.white.withAlpha(26),
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: _getRoleColor(role).withAlpha(128),
                  width: 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: _getRoleColor(role),
                          radius: 20,
                          child: Text(
                            name.isNotEmpty
                                ? name[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isCurrentUser)
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.blue
                                            .withAlpha(77),
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'You',
                                        style: TextStyle(
                                            color: Colors.blue,
                                            fontSize: 10),
                                      ),
                                    ),
                                ],
                              ),
                              Text(
                                email,
                                style: TextStyle(
                                  color: Colors.white.withAlpha(153),
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        // Role badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color:
                                _getRoleColor(role).withAlpha(51),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: _getRoleColor(role),
                                width: 1),
                          ),
                          child: Text(
                            role.toUpperCase(),
                            style: TextStyle(
                              color: _getRoleColor(role),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Status badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: status == 'active'
                                ? Colors.green.withAlpha(51)
                                : Colors.red.withAlpha(51),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            status.toUpperCase(),
                            style: TextStyle(
                              color: status == 'active'
                                  ? Colors.green
                                  : Colors.red,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const Spacer(),
                        // Role change dropdown
                        if (!isCurrentUser)
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert,
                                color: Colors.white70),
                            color: const Color(0xFF1C2523),
                            onSelected: (newRole) =>
                                _changeUserRole(uid, email, newRole),
                            itemBuilder: (context) => [
                              _buildRoleMenuItem('admin', role),
                              _buildRoleMenuItem(
                                  'archeologist', role),
                              _buildRoleMenuItem('viewer', role),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  PopupMenuItem<String> _buildRoleMenuItem(
      String role, String currentRole) {
    final isSelected = role == currentRole;
    return PopupMenuItem(
      value: role,
      child: Row(
        children: [
          Icon(
            isSelected ? Icons.check_circle : Icons.circle_outlined,
            color: _getRoleColor(role),
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(
            role.toUpperCase(),
            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changeUserRole(
      String uid, String email, String newRole) async {
    final success = await AuthService.updateUserRole(uid, newRole);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Updated $email to $newRole'
                : 'Failed to update role',
          ),
          backgroundColor:
              success ? const Color(0xFF4CAF50) : Colors.red,
        ),
      );
    }
  }

  // ─── System tab ──────────────────────────────────────────────────────────────

  Widget _buildSystemTab() {
    return _modelsLoading
        ? const Center(
            child:
                CircularProgressIndicator(color: Color(0xFFFFC107)))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildModelInfoSection(),
              const SizedBox(height: 16),
              _buildPipelineHealthSection(),
              const SizedBox(height: 16),
              _buildRuntimeStatusSection(),
              const SizedBox(height: 24),
              _buildClearCalibrationButton(),
              const SizedBox(height: 12),
              _buildExportDebugLogButton(),
              const SizedBox(height: 32),
            ],
          );
  }

  // ── Model info ───────────────────────────────────────────────────────────────

  Widget _buildModelInfoSection() {
    final anomalyService = VibrationAnomalyService.instance;
    final precursorService = PrecursorClassifierService();

    final autoencoderVersion =
        _autoencoderConfig?['model_version'] as String? ?? 'N/A';
    final autoencoderFingerprint = anomalyService.isInitialized
        ? anomalyService.modelFingerprint
        : (_autoencoderConfig?['model_fingerprint'] as String? ?? 'N/A');
    final autoencoderThreshLow =
        (_autoencoderConfig?['thresholds']?['threshold_low'] as num?)
            ?.toStringAsFixed(3) ??
            'N/A';
    final autoencoderThreshHigh =
        (_autoencoderConfig?['thresholds']?['threshold_high'] as num?)
            ?.toStringAsFixed(3) ??
            'N/A';

    final precursorVersion =
        _precursorConfig?['model_version'] as String? ?? 'N/A';
    final precursorFingerprint = precursorService.isLoaded ? 'Loaded' : 'N/A';
    final precursorClasses = (_precursorConfig?['class_names'] as List?)
            ?.map((e) => e.toString())
            .join(', ') ??
        'N/A';

    return _AdminCard(
      title: 'Model Info',
      icon: Icons.model_training,
      iconColor: const Color(0xFF9C27B0),
      children: [
        const _SectionLabel('Autoencoder (Anomaly Detection)'),
        _InfoRow('Version', autoencoderVersion),
        _InfoRow('File size', _formatBytes(_autoencoderFileSizeBytes)),
        _InfoRow('Fingerprint', autoencoderFingerprint),
        _InfoRow('Loaded', anomalyService.isInitialized ? 'Yes' : 'No'),
        _InfoRow(
            'Rule-based fallback', anomalyService.isRuleBased ? 'Yes' : 'No'),
        _InfoRow('Threshold low', autoencoderThreshLow),
        _InfoRow('Threshold high', autoencoderThreshHigh),
        const SizedBox(height: 10),
        const _SectionLabel('Precursor Classifier'),
        _InfoRow('Version', precursorVersion),
        _InfoRow('File size', _formatBytes(_precursorFileSizeBytes)),
        _InfoRow('Fingerprint', precursorFingerprint),
        _InfoRow('Loaded', precursorService.isLoaded ? 'Yes' : 'No'),
        _InfoRow('Classes', precursorClasses),
        if (precursorService.lastError != null)
          _InfoRow('Last error', precursorService.lastError!,
              valueColor: const Color(0xFFEF5350)),
        const SizedBox(height: 10),
        const _SectionLabel('Score History Buffer'),
        _InfoRow(
          'Fill level',
          '${anomalyService.mlService.scoreHistory.length} / '
              '${MlAnomalyService.scoreHistoryCapacity}',
        ),
      ],
    );
  }

  // ── Pipeline health ───────────────────────────────────────────────────────────

  Widget _buildPipelineHealthSection() {
    return _AdminCard(
      title: 'Pipeline Health',
      icon: Icons.health_and_safety_outlined,
      iconColor: const Color(0xFF26A69A),
      children: [
        _InfoRow(
          'Last training date',
          _lastTrainingDate ?? 'Unknown — run trainer to update',
        ),
        _InfoRow(
          'Model version',
          _modelVersion ?? 'Unknown',
        ),
        _InfoRow(
          'Pipeline status',
          _pipelineStatus ?? 'Unknown',
        ),
        const SizedBox(height: 8),
        Text(
          'These values are written to SharedPreferences by the training '
          'pipeline (run_pipeline.py → docker-compose.train.yml). '
          'If unknown, the model has not been retrained on-device.',
          style: TextStyle(
            color: Colors.white.withAlpha(100),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  // ── Runtime status ────────────────────────────────────────────────────────────

  Widget _buildRuntimeStatusSection() {
    final bgManager = BackgroundServiceManager();
    final history = bgManager.statusHistory;
    final errorCount = bgManager.backgroundErrors;

    return _AdminCard(
      title: 'Runtime Status',
      icon: Icons.speed_outlined,
      iconColor: const Color(0xFFFFA726),
      children: [
        _InfoRow('Background errors', '$errorCount'),
        _InfoRow(
          'Service events',
          '${history.length} recorded (last 10 kept)',
        ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Most recent event:',
            style: TextStyle(
              color: Colors.white.withAlpha(140),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            history.last,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ],
    );
  }

  // ── Action buttons ────────────────────────────────────────────────────────────

  Widget _buildClearCalibrationButton() {
    return Center(
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1C2523),
          foregroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFFFF7043)),
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        icon: const Icon(Icons.delete_outline, color: Color(0xFFFF7043)),
        label: const Text(
          'Clear Calibration Data',
          style: TextStyle(
            color: Color(0xFFFF7043),
            fontWeight: FontWeight.bold,
          ),
        ),
        onPressed: _confirmClearCalibration,
      ),
    );
  }

  Future<void> _confirmClearCalibration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: const Text(
          'Clear Calibration Data?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This will reset the ML anomaly baseline and adaptive '
          'calibration. The system will re-calibrate on the next '
          'BLE session. This cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF7043),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Reset adaptive baseline and ML calibration samples.
      VibrationAnomalyService.instance.resetBaseline();
      VibrationAnomalyService.instance.mlService.cancelCalibration();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Calibration data cleared. Re-calibrating on next session.'),
            backgroundColor: Color(0xFF1C2523),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Clear failed: $e'),
            backgroundColor: Colors.red[900],
          ),
        );
      }
    }
  }

  Widget _buildExportDebugLogButton() {
    return Center(
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white54,
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
        icon: const Icon(Icons.share_outlined, size: 18),
        label: const Text('Export Debug Log'),
        onPressed: _exportDebugLog,
      ),
    );
  }

  Future<void> _exportDebugLog() async {
    try {
      final anomalyService = VibrationAnomalyService.instance;
      final precursorService = PrecursorClassifierService();
      final bgManager = BackgroundServiceManager();

      final autoencoderVersion =
          _autoencoderConfig?['model_version'] as String? ?? 'unknown';
      final precursorVersion =
          _precursorConfig?['model_version'] as String? ?? 'unknown';

      final platform = kIsWeb
          ? 'Web'
          : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

      final lines = <String>[
        'AncientVision Admin Debug Log',
        '=' * 40,
        'Generated: ${DateTime.now().toIso8601String()}',
        'Platform: $platform',
        '',
        '--- ML Models ---',
        'Autoencoder version      : $autoencoderVersion',
        'Autoencoder file size    : ${_formatBytes(_autoencoderFileSizeBytes)}',
        'Autoencoder fingerprint  : ${anomalyService.isInitialized ? anomalyService.modelFingerprint : "not loaded"}',
        'Autoencoder loaded       : ${anomalyService.isInitialized}',
        'Rule-based fallback      : ${anomalyService.isRuleBased}',
        '',
        'Precursor version        : $precursorVersion',
        'Precursor file size      : ${_formatBytes(_precursorFileSizeBytes)}',
        'Precursor loaded         : ${precursorService.isLoaded}',
        'Precursor last error     : ${precursorService.lastError ?? "none"}',
        '',
        '--- Pipeline Health ---',
        'Last training date       : ${_lastTrainingDate ?? "unknown"}',
        'Model version (prefs)    : ${_modelVersion ?? "unknown"}',
        'Pipeline status          : ${_pipelineStatus ?? "unknown"}',
        '',
        '--- Runtime ---',
        'Background errors        : ${bgManager.backgroundErrors}',
        '',
        '--- Service History (newest first) ---',
        ...bgManager.statusHistory.reversed,
      ];

      final content = lines.join('\n');

      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/ancientvision_debug_${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(content);

      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'AncientVision Debug Log',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red[900],
          ),
        );
      }
    }
  }
}

// ─── Reusable sub-widgets ─────────────────────────────────────────────────────

/// Card with a consistent dark background, icon header and arbitrary children.
class _AdminCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<Widget> children;

  const _AdminCard({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1C2523),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
          Divider(color: Colors.white.withAlpha(30), height: 1),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bold sub-section label inside an [_AdminCard].
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFFFC107),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Key–value row inside an [_AdminCard].
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withAlpha(160),
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Batch export format selection sheet
class BatchExportSheet extends StatelessWidget {
  final int selectedCount;

  const BatchExportSheet({super.key, required this.selectedCount});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C2523),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Title
          Row(
            children: [
              const Icon(Icons.file_download,
                  color: Color(0xFFFFC107), size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Batch Export',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '$selectedCount findings selected',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Format options
          const Text(
            'Select export format:',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 12),

          // JSON option
          _buildFormatOption(
            context,
            ExportFormat.json,
            Icons.code,
            'JSON',
            'Full data with all fields',
          ),
          const SizedBox(height: 8),

          // CSV option
          _buildFormatOption(
            context,
            ExportFormat.csv,
            Icons.table_chart,
            'CSV',
            'Spreadsheet compatible',
          ),
          const SizedBox(height: 8),

          // GeoJSON option
          _buildFormatOption(
            context,
            ExportFormat.geojson,
            Icons.map,
            'GeoJSON',
            'For mapping applications',
          ),
          const SizedBox(height: 8),

          // KML option
          _buildFormatOption(
            context,
            ExportFormat.kml,
            Icons.public,
            'KML',
            'For Google Earth',
          ),

          const SizedBox(height: 16),
          SafeArea(
            child: Container(),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatOption(
    BuildContext context,
    ExportFormat format,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(context, format),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFFFFC107), size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color: Colors.white.withValues(alpha: 0.4),
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
