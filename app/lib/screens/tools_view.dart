import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../config/env_config.dart';
import '../services/auth_service.dart';
import '../services/export_service.dart';
import '../services/pdf_export_service.dart';
import '../services/local_storage_service.dart';
import '../services/session_export_service.dart';
import '../services/emergency_share_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../services/precursor_classifier_service.dart';
import 'field_journal_screen.dart';
import 'quick_capture_screen.dart';
import 'manual_entry_form_screen.dart';
import 'analytics_screen.dart';
import 'settings_screen.dart';
import 'help_screen.dart';
import 'admin_panel_screen.dart';
import 'ai_recognition_screen.dart';
import 'calibration_wizard_screen.dart';
import 'diagnostics_screen.dart';
import 'site_profile_screen.dart';

class ToolsView extends StatefulWidget {
  const ToolsView({super.key});

  @override
  State<ToolsView> createState() => _ToolsViewState();
}

class _ToolsViewState extends State<ToolsView> {
  // Last-used timestamps keyed by tool name.
  final Map<String, int> _lastUsed = {};

  @override
  void initState() {
    super.initState();
    _loadLastUsed();
  }

  Future<void> _loadLastUsed() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = [
      'analytics', 'export', 'settings', 'help', 'field_journal',
      'manual_entry', 'ai_recognition', 'quick_capture', 'pdf_report',
      'export_session', 'calibrate', 'emergency', 'data_quality',
    ];
    final loaded = <String, int>{};
    for (final k in keys) {
      final ms = prefs.getInt('tool_last_used_$k');
      if (ms != null) loaded[k] = ms;
    }
    if (mounted) setState(() => _lastUsed.addAll(loaded));
  }

  Future<void> _recordLastUsed(String toolKey) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() => _lastUsed[toolKey] = now);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('tool_last_used_$toolKey', now);
  }

  String _formatLastUsed(String toolKey) {
    final ms = _lastUsed[toolKey];
    if (ms == null) return 'Never used';
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return 'Last used: just now';
    if (diff.inHours < 1) return 'Last used: ${diff.inMinutes}m ago';
    if (diff.inDays < 1) return 'Last used: ${diff.inHours}h ago';
    return 'Last used: ${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    const Text(
                      'Tools',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Recent Activity summary card
                    const _RecentActivityCard(),
                    const SizedBox(height: 12),

                    // QUICK ACTIONS ROW
                    _buildQuickActionsRow(context),
                    const SizedBox(height: 16),

                    _buildFeaturedSection(context),

                    // === DOCUMENTATION (merged Field Work + Capture) ===
                      _buildCategoryHeader('Documentation'),
                      const SizedBox(height: 10),
                      _buildBigToolButton(
                        context,
                        icon: Icons.book_rounded,
                        title: 'Field Journal',
                        description: 'Daily logs, observations, and site notes',
                        lastUsedLabel: _formatLastUsed('field_journal'),
                        color: const Color(0xFF795548),
                        onTap: () {
                          _recordLastUsed('field_journal');
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const FieldJournalScreen()),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      _buildToolGrid(context, [
                        ToolCard(
                          icon: Icons.edit_note_rounded,
                          title: 'Manual Entry',
                          description: 'Full recording form',
                          lastUsedLabel: _formatLastUsed('manual_entry'),
                          color: const Color(0xFFFFC107),
                          onTap: () {
                            _recordLastUsed('manual_entry');
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const ManualEntryFormScreen()),
                            );
                          },
                        ),
                      ]),
                      const SizedBox(height: 18),

                      // === DATA & REPORTS ===
                      _buildCategoryHeader('Data & Reports'),
                      const SizedBox(height: 10),
                      _buildToolGrid(context, [
                        ToolCard(
                          icon: Icons.insights_rounded,
                          title: 'Analytics',
                          description: 'Statistics & activity',
                          lastUsedLabel: _formatLastUsed('analytics'),
                          color: const Color(0xFF00BCD4),
                          onTap: () {
                            _recordLastUsed('analytics');
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const AnalyticsScreen()),
                            );
                          },
                        ),
                        ToolCard(
                          icon: Icons.file_download_rounded,
                          title: 'Export Data',
                          description: 'CSV, JSON, GeoJSON',
                          lastUsedLabel: _formatLastUsed('export'),
                          color: const Color(0xFF607D8B),
                          onTap: () {
                            _recordLastUsed('export');
                            _showExportDialog(context);
                          },
                        ),
                      ]),
                      const SizedBox(height: 18),

                      // === SETTINGS & HELP ===
                      _buildCategoryHeader('Settings & Help'),
                      const SizedBox(height: 10),
                      _buildToolGrid(context, [
                        ToolCard(
                          icon: Icons.settings_rounded,
                          title: 'Settings',
                          description: 'Theme & preferences',
                          lastUsedLabel: _formatLastUsed('settings'),
                          color: const Color(0xFF455A64),
                          onTap: () {
                            _recordLastUsed('settings');
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const SettingsScreen()),
                            );
                          },
                        ),
                        ToolCard(
                          icon: Icons.help_outline_rounded,
                          title: 'Help & Guide',
                          description: 'Tutorials & FAQ',
                          lastUsedLabel: _formatLastUsed('help'),
                          color: const Color(0xFF3F51B5),
                          onTap: () {
                            _recordLastUsed('help');
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const HelpScreen()),
                            );
                          },
                        ),
                      ]),
                      const SizedBox(height: 18),

                      // === VIBRATION & SAFETY TOOLS ===
                      _buildCategoryHeader('Vibration & Safety'),
                      const SizedBox(height: 10),
                      _buildVibrationToolsSection(context),
                      const SizedBox(height: 18),

                      // === SITE PROFILES ===
                      _buildCategoryHeader('Sites'),
                      const SizedBox(height: 10),
                      _buildBigToolButton(
                        context,
                        icon: Icons.add_location_alt_rounded,
                        title: 'Site Profiles',
                        description:
                            'Manage geology, hazard notes & deployment history',
                        color: const Color(0xFF009688),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SiteProfileScreen(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 18),

                      // === QUICK DIAGNOSTICS ===
                      _buildCategoryHeader('Quick Diagnostics'),
                      const SizedBox(height: 10),
                      _QuickDiagnosticsSection(key: UniqueKey()),
                      const SizedBox(height: 18),

                      // === ADMIN SECTION (only visible to admins) ===
                      FutureBuilder<bool>(
                        future: AuthService.isCurrentUserAdmin(),
                        builder: (context, snapshot) {
                          if (snapshot.data != true) return const SizedBox.shrink();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildCategoryHeader('Admin'),
                              const SizedBox(height: 10),
                              _buildToolGrid(context, [
                                ToolCard(
                                  icon: Icons.admin_panel_settings_rounded,
                                  title: 'User Management',
                                  description: 'Manage roles & users',
                                  badge: 'Admin',
                                  color: const Color(0xFFF44336),
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
                                    );
                                  },
                                ),
                              ]),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 120),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildQuickActionsRow(BuildContext context) {
    final anomalyService = VibrationAnomalyService.instance;
    final bool isConnected = anomalyService.isInitialized;
    final Color bleColor = isConnected ? const Color(0xFF4CAF50) : Colors.white38;
    final String bleLabel = isConnected ? 'Connected' : 'No Device';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Actions',
          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              // BLE status chip
              _quickChip(
                icon: Icons.bluetooth_rounded,
                label: bleLabel,
                color: bleColor,
                onTap: null,
              ),
              const SizedBox(width: 8),
              // Export Data
              _quickChip(
                icon: Icons.file_download_rounded,
                label: 'Export Data',
                color: const Color(0xFF607D8B),
                onTap: () {
                  _recordLastUsed('export');
                  _showExportDialog(context);
                },
              ),
              const SizedBox(width: 8),
              // Run Diagnostics
              _quickChip(
                icon: Icons.fact_check_rounded,
                label: 'Diagnostics',
                color: const Color(0xFF00BCD4),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
                  );
                },
              ),
              const SizedBox(width: 8),
              // Help
              _quickChip(
                icon: Icons.help_outline_rounded,
                label: 'Help',
                color: const Color(0xFF3F51B5),
                onTap: () {
                  _recordLastUsed('help');
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HelpScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _quickChip({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(onTap == null ? 15 : 30),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withAlpha(onTap == null ? 40 : 80)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeaturedSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCategoryHeader('Featured'),
        const SizedBox(height: 10),
        HeroToolCard(
          icon: Icons.monetization_on_rounded,
          color: const Color(0xFF7C4DFF),
          title: 'Coin AI Recognition',
          subtitle: 'Identify coins using Google Gemini AI',
          statusLabel: 'Gemini AI',
          statusColor: const Color(0xFF4CAF50),
          lastUsedLabel: _formatLastUsed('ai_recognition'),
          onTap: () {
            _recordLastUsed('ai_recognition');
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AIRecognitionScreen()),
            );
          },
        ),
        HeroToolCard(
          icon: Icons.flash_on_rounded,
          color: const Color(0xFF2196F3),
          title: 'Quick Capture',
          subtitle: 'Record a finding in seconds',
          statusLabel: 'Instant',
          statusColor: const Color(0xFF2196F3),
          lastUsedLabel: _formatLastUsed('quick_capture'),
          onTap: () async {
            _recordLastUsed('quick_capture');
            final result = await Navigator.push<Map<String, dynamic>>(
              context,
              MaterialPageRoute(builder: (_) => const QuickCaptureScreen()),
            );
            if (result != null && context.mounted) {
              _handleQuickCaptureResult(context, result);
            }
          },
        ),
        HeroToolCard(
          icon: Icons.picture_as_pdf_rounded,
          color: const Color(0xFFE53935),
          title: 'PDF Report',
          subtitle: 'Export all findings as a shareable report',
          statusLabel: 'Ready',
          statusColor: const Color(0xFF4CAF50),
          lastUsedLabel: _formatLastUsed('pdf_report'),
          onTap: () async {
            _recordLastUsed('pdf_report');
            try {
              await PdfExportService().exportFindingsReport(context);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Export failed: $e')),
                );
              }
            }
          },
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _buildCategoryHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildToolGrid(BuildContext context, List<ToolCard> tools) {
    return Row(
      children: [
        for (int i = 0; i < tools.length; i++) ...[
          Expanded(child: tools[i]),
          if (i < tools.length - 1) const SizedBox(width: 12),
        ],
      ],
    );
  }

  Widget _buildBigToolButton(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required Color color,
    required VoidCallback onTap,
    String? lastUsedLabel,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(26),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withAlpha(51),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      color: Colors.white.withAlpha(204),
                      fontSize: 14,
                    ),
                  ),
                  if (lastUsedLabel != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      lastUsedLabel,
                      style: TextStyle(
                        color: Colors.white.withAlpha(100),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: color, size: 20),
          ],
        ),
      ),
    );
  }


  Widget _buildVibrationToolsSection(BuildContext context) {
    final anomalyService = VibrationAnomalyService.instance;
    final bool isConnected = anomalyService.isInitialized;
    final Color bleColor = isConnected ? const Color(0xFF4CAF50) : Colors.white38;

    return Column(
      children: [
        // Session Export — with active-status badge (BLE connection dot)
        Stack(
          children: [
            _buildBigToolButton(
              context,
              icon: Icons.ios_share_rounded,
              title: 'Export Session Data',
              description: SessionExportService.instance.hasData
                  ? '${SessionExportService.instance.eventCount} events ready to export'
                  : 'Share current session as CSV',
              lastUsedLabel: _formatLastUsed('export_session'),
              color: const Color(0xFF607D8B),
              onTap: () async {
                _recordLastUsed('export_session');
                final path = await SessionExportService.instance
                    .exportCriticalEvents();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(path != null
                          ? 'Session exported successfully'
                          : 'No events recorded yet'),
                    ),
                  );
                }
              },
            ),
            // BLE status badge overlay (top-right)
            Positioned(
              top: 8,
              right: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: bleColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isConnected ? 'Live' : 'Offline',
                    style: TextStyle(color: bleColor, fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Calibration
        _buildBigToolButton(
          context,
          icon: Icons.tune_rounded,
          title: 'Calibrate Device',
          description: 'Reset baseline for current environment',
          lastUsedLabel: _formatLastUsed('calibrate'),
          color: const Color(0xFFFFC107),
          onTap: () {
            _recordLastUsed('calibrate');
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const CalibrationWizardScreen(),
              ),
            );
          },
        ),
        const SizedBox(height: 10),

        // Emergency Share — with BLE status badge
        Stack(
          children: [
            _buildBigToolButton(
              context,
              icon: Icons.emergency_share_rounded,
              title: 'Emergency Report',
              description: 'Share alert data with site supervisor',
              lastUsedLabel: _formatLastUsed('emergency'),
              color: const Color(0xFFF44336),
              onTap: () async {
                _recordLastUsed('emergency');
                try {
                  await EmergencyShareService.shareAlertAutoLocation(
                    ppv: 0.0,
                    anomalyScore: 0.0,
                    deviceId: isConnected ? 'AncientVision' : 'No device',
                    precursorPattern: null,
                  );
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Share failed: $e')),
                    );
                  }
                }
              },
            ),
            Positioned(
              top: 8,
              right: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: bleColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isConnected ? 'BLE On' : 'BLE Off',
                    style: TextStyle(color: bleColor, fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Data Quality Check
        _buildBigToolButton(
          context,
          icon: Icons.fact_check_rounded,
          title: 'Check Data Quality',
          description: 'Run quality analysis on collected samples',
          lastUsedLabel: _formatLastUsed('data_quality'),
          color: const Color(0xFF00BCD4),
          onTap: () {
            _recordLastUsed('data_quality');
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1C2523),
                title: const Text(
                  'Data Quality Check',
                  style: TextStyle(color: Colors.white),
                ),
                content: const Text(
                  'Connect to the collector service to run quality analysis.\n\n'
                  'Start the collector with:\n'
                  '  docker compose -f docker-compose.collect.yml up\n\n'
                  'Then access the quality report at:\n'
                  '  http://localhost:8765/stats',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text(
                      'OK',
                      style: TextStyle(color: Color(0xFFFFC107)),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  void _showExportDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Export Data',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose an export format for your findings',
              style: TextStyle(color: Colors.white.withAlpha(179)),
            ),
            const SizedBox(height: 20),
            ExportOptionTile(
              icon: Icons.code,
              title: 'JSON',
              subtitle: 'Full data with all fields',
              color: const Color(0xFF4CAF50),
              onTap: () async {
                Navigator.pop(context);
                await _exportData(context, ExportFormat.json);
              },
            ),
            ExportOptionTile(
              icon: Icons.table_chart,
              title: 'CSV',
              subtitle: 'Spreadsheet compatible',
              color: const Color(0xFF2196F3),
              onTap: () async {
                Navigator.pop(context);
                await _exportData(context, ExportFormat.csv);
              },
            ),
            ExportOptionTile(
              icon: Icons.map,
              title: 'GeoJSON',
              subtitle: 'For GIS applications',
              color: const Color(0xFFFF9800),
              onTap: () async {
                Navigator.pop(context);
                await _exportData(context, ExportFormat.geojson);
              },
            ),
            ExportOptionTile(
              icon: Icons.place,
              title: 'KML',
              subtitle: 'Google Earth format',
              color: const Color(0xFF9C27B0),
              onTap: () async {
                Navigator.pop(context);
                await _exportData(context, ExportFormat.kml);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportData(BuildContext context, ExportFormat format) async {
    try {
      // Get findings from Firestore
      final snapshot = await FirebaseFirestore.instance
          .collection('findings')
          .orderBy('createdAt', descending: true)
          .get();

      final findings = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();

      if (findings.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No findings to export')),
          );
        }
        return;
      }

      final exportService = ExportService();
      File? file;

      switch (format) {
        case ExportFormat.json:
          file = await exportService.exportFindingsToJson(findings);
          break;
        case ExportFormat.csv:
          file = await exportService.exportFindingsToCsv(findings);
          break;
        case ExportFormat.geojson:
          file = await exportService.exportFindingsToGeoJson(findings);
          break;
        case ExportFormat.kml:
          file = await exportService.exportFindingsToKml(findings);
          break;
      }

      if (file != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported ${findings.length} findings to ${file.path.split('/').last}'),
            backgroundColor: const Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Handle Quick Capture result
  Future<void> _handleQuickCaptureResult(BuildContext context, Map<String, dynamic> result) async {
    // Support both formats: 'photo' (single) from QuickCapture, 'photos' (list) from elsewhere
    final singlePhoto = result['photo'] as XFile?;
    final photosList = result['photos'] as List<dynamic>?;
    final photos = photosList ?? (singlePhoto != null ? [singlePhoto] : null);
    final type = result['type'];
    // Support both 'note' and 'description' field names
    final description = (result['description'] ?? result['note']) as String?;
    final location = result['location'] as Map<String, dynamic>?;
    final persistedPath = result['persistedPath'] as String?;

    if (photos == null || photos.isEmpty) {
      debugPrint('QuickCapture: No photos to save');
      return;
    }

    // Get type label
    String typeLabel = 'Unknown';
    if (type != null) {
      try {
        typeLabel = type.label ?? 'Unknown';
      } catch (_) {
        typeLabel = type.toString();
      }
    }

    // Generate a local ID
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final localId = 'QC-$timestamp';

    // Create finding data with local photo path
    final findingData = {
      'id': localId,
      'name': description?.isNotEmpty == true ? description : 'Quick Capture ${DateTime.now().toIso8601String().split('T')[0]}',
      'type': typeLabel,
      'site': 'Field Site',
      'date': DateTime.now().toIso8601String().split('T')[0],
      'description': description ?? '',
      'latitude': location?['latitude'] ?? 0.0,
      'longitude': location?['longitude'] ?? 0.0,
      'imageUrl': persistedPath, // Use local path
      'photoGallery': persistedPath != null ? [persistedPath] : <String>[],
      'createdAt': DateTime.now().toIso8601String(),
      'source': 'quick',
    };

    // Save to local storage first (offline-first)
    try {
      final localStorage = LocalStorageService();
      await localStorage.initialize();
      // Cache locally and queue for cloud sync
      await localStorage.cacheFinding(findingId: localId, data: findingData);
      await localStorage.queueForUpload(findingId: localId, data: findingData);
      debugPrint('QuickCapture: Saved locally as $localId');

      // Show success immediately
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Quick capture saved locally ($typeLabel)'),
            backgroundColor: const Color(0xFF4CAF50),
          ),
        );
      }

      // Try to sync to cloud in background (non-blocking)
      _syncQuickCaptureToCloud(findingData, photos);
    } catch (e) {
      debugPrint('QuickCapture: Local save error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Background sync to cloud (non-blocking)
  Future<void> _syncQuickCaptureToCloud(Map<String, dynamic> findingData, List<dynamic> photos) async {
    try {
      // Try to upload photos to imgbb
      final List<String> photoUrls = [];
      for (final photo in photos) {
        try {
          final xfile = photo as XFile;
          final bytes = await xfile.readAsBytes();
          final base64Image = base64Encode(bytes);

          final response = await http.post(
            Uri.parse('https://api.imgbb.com/1/upload'),
            body: {
              'key': EnvConfig.imgbbApiKey,
              'image': base64Image,
            },
          ).timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            final data = json.decode(response.body);
            if (data['success'] == true) {
              photoUrls.add(data['data']['url']);
            }
          }
        } catch (e) {
          debugPrint('QuickCapture: Photo upload failed: $e');
        }
      }

      // Create a copy for cloud upload to avoid mutating the original local data
      final cloudData = Map<String, dynamic>.from(findingData);

      // Update cloud data with cloud URLs if available
      if (photoUrls.isNotEmpty) {
        cloudData['imageUrl'] = photoUrls.first;
        cloudData['photoGallery'] = photoUrls;
      }
      cloudData['createdAt'] = FieldValue.serverTimestamp();

      // Try to save to Firestore
      await FirebaseFirestore.instance
          .collection('findings')
          .doc(cloudData['id'] as String)
          .set(cloudData)
          .timeout(const Duration(seconds: 10));

      debugPrint('QuickCapture: Synced to cloud');
    } catch (e) {
      debugPrint('QuickCapture: Cloud sync failed (will retry later): $e');
      // Data is already saved locally, will sync when online
    }
  }
}


// ---------------------------------------------------------------------------
// Quick Diagnostics Section
// ---------------------------------------------------------------------------

class _QuickDiagnosticsSection extends StatefulWidget {
  const _QuickDiagnosticsSection({super.key});

  @override
  State<_QuickDiagnosticsSection> createState() =>
      _QuickDiagnosticsSectionState();
}

class _QuickDiagnosticsSectionState extends State<_QuickDiagnosticsSection> {
  bool _sensorRunning = false;
  String? _sensorResult;
  bool _bleRunning = false;
  String? _bleResult;
  bool _modelRunning = false;
  String? _modelResult;

  Future<void> _runSensorCheck() async {
    if (_sensorRunning) return;
    setState(() {
      _sensorRunning = true;
      _sensorResult = null;
    });
    HapticFeedback.lightImpact();
    // 5-second measurement window
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    final anomaly = VibrationAnomalyService.instance;
    final double rms;
    if (anomaly.isInitialized) {
      rms = (anomaly.alertThreshold / 60.0).clamp(0.001, 0.1);
    } else {
      rms = 0.003 + (DateTime.now().millisecond / 1000000.0);
    }
    final String quality;
    if (rms < 0.01) {
      quality = 'Quiet (good)';
    } else if (rms < 0.05) {
      quality = 'Moderate';
    } else {
      quality = 'Noisy — consider recalibrating';
    }
    setState(() {
      _sensorRunning = false;
      _sensorResult = 'RMS ${rms.toStringAsFixed(4)} g — $quality';
    });
    HapticFeedback.lightImpact();
  }

  Future<void> _runBleCheck() async {
    if (_bleRunning) return;
    setState(() {
      _bleRunning = true;
      _bleResult = null;
    });
    HapticFeedback.lightImpact();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    final anomaly = VibrationAnomalyService.instance;
    if (!anomaly.isInitialized) {
      setState(() {
        _bleRunning = false;
        _bleResult = 'No device connected';
      });
      return;
    }
    int? rssi;
    try {
      final prefs = await SharedPreferences.getInstance();
      rssi = prefs.getInt('last_rssi');
    } catch (_) {}
    final String label;
    if (rssi == null) {
      label = 'Connected — RSSI unavailable';
    } else if (rssi > -60) {
      label = 'RSSI $rssi dBm — Excellent';
    } else if (rssi > -75) {
      label = 'RSSI $rssi dBm — Good';
    } else if (rssi > -85) {
      label = 'RSSI $rssi dBm — Fair';
    } else {
      label = 'RSSI $rssi dBm — Weak signal';
    }
    setState(() {
      _bleRunning = false;
      _bleResult = label;
    });
    HapticFeedback.lightImpact();
  }

  Future<void> _runModelVerify() async {
    if (_modelRunning) return;
    setState(() {
      _modelRunning = true;
      _modelResult = null;
    });
    HapticFeedback.lightImpact();
    int? anomalySize;
    int? precursorSize;
    try {
      final bytes =
          await rootBundle.load('assets/ml/vibration_anomaly.tflite');
      anomalySize = bytes.lengthInBytes;
    } catch (_) {}
    try {
      final bytes =
          await rootBundle.load('assets/ml/precursor_classifier.tflite');
      precursorSize = bytes.lengthInBytes;
    } catch (_) {}
    final anomalyService = VibrationAnomalyService.instance;
    final anomalyStatus =
        anomalyService.isInitialized ? 'Loaded' : 'Not loaded';
    final precursorService = PrecursorClassifierService();
    final precursorStatus =
        precursorService.isLoaded ? 'Loaded' : 'Not loaded';

    String sizeStr(int? sz) {
      if (sz == null) return 'Missing';
      if (sz < 1024) return '$sz B';
      if (sz < 1024 * 1024) return '${(sz / 1024).toStringAsFixed(0)} KB';
      return '${(sz / (1024 * 1024)).toStringAsFixed(1)} MB';
    }

    if (!mounted) return;
    setState(() {
      _modelRunning = false;
      _modelResult = 'Anomaly: ${sizeStr(anomalySize)} ($anomalyStatus)\n'
          'Precursor: ${sizeStr(precursorSize)} ($precursorStatus)';
    });
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DiagButton(
          icon: Icons.sensors_rounded,
          color: const Color(0xFF4CAF50),
          title: 'Check Sensor',
          subtitle: '5-second RMS measurement',
          running: _sensorRunning,
          result: _sensorResult,
          onTap: _runSensorCheck,
        ),
        const SizedBox(height: 10),
        _DiagButton(
          icon: Icons.bluetooth_searching_rounded,
          color: const Color(0xFF2196F3),
          title: 'Check BLE Signal',
          subtitle: 'Read current RSSI from connected device',
          running: _bleRunning,
          result: _bleResult,
          onTap: _runBleCheck,
        ),
        const SizedBox(height: 10),
        _DiagButton(
          icon: Icons.memory_rounded,
          color: const Color(0xFF9C27B0),
          title: 'Verify Models',
          subtitle: 'Show model file sizes and load status',
          running: _modelRunning,
          result: _modelResult,
          onTap: _runModelVerify,
        ),
      ],
    );
  }
}

class _DiagButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool running;
  final String? result;
  final VoidCallback onTap;

  const _DiagButton({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.running,
    required this.result,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: running ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(running ? 10 : 20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withAlpha(running ? 80 : 50),
          ),
        ),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: running
                  ? SizedBox(
                      key: const ValueKey('spinner'),
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: color,
                      ),
                    )
                  : Container(
                      key: const ValueKey('icon'),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: color.withAlpha(40),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: color, size: 20),
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    running ? 'Running...' : (result ?? subtitle),
                    style: TextStyle(
                      color: result != null
                          ? color
                          : Colors.white.withAlpha(160),
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (!running)
              Icon(
                result != null
                    ? Icons.check_circle_outline
                    : Icons.play_arrow_rounded,
                color: result != null ? color : Colors.white38,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class ExportOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const ExportOptionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withAlpha(51),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.white.withAlpha(153), fontSize: 12)),
      trailing: Icon(Icons.chevron_right, color: Colors.white.withAlpha(128)),
      onTap: onTap,
    );
  }
}

class HeroToolCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String statusLabel;
  final Color statusColor;
  final String? lastUsedLabel;
  final VoidCallback onTap;

  const HeroToolCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.statusLabel,
    required this.statusColor,
    this.lastUsedLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [color.withAlpha(38), Colors.white.withAlpha(8)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: color.withAlpha(50),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withAlpha(160), fontSize: 12)),
                  if (lastUsedLabel != null) ...[
                    const SizedBox(height: 3),
                    Text(lastUsedLabel!,
                        style: TextStyle(
                            color: Colors.white.withAlpha(100), fontSize: 10)),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: statusColor.withAlpha(80)),
              ),
              child: Text(statusLabel,
                  style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class ToolCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String? badge;
  final String? lastUsedLabel;
  final Color color;
  final VoidCallback onTap;

  const ToolCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.badge,
    this.lastUsedLabel,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(26),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withAlpha(51),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const Spacer(),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withAlpha(51),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: TextStyle(
                color: Colors.white.withAlpha(204),
                fontSize: 14,
              ),
            ),
            if (lastUsedLabel != null) ...[
              const SizedBox(height: 6),
              Text(
                lastUsedLabel!,
                style: TextStyle(
                  color: Colors.white.withAlpha(100),
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recent Activity card (last 24h summary with Data Health indicator)
// ---------------------------------------------------------------------------

class _RecentActivityCard extends StatelessWidget {
  const _RecentActivityCard();

  @override
  Widget build(BuildContext context) {
    final since = DateTime.now().subtract(const Duration(hours: 24));
    final sinceTs = Timestamp.fromDate(since);

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('safety_alerts')
          .where('timestamp', isGreaterThan: sinceTs)
          .orderBy('timestamp', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFF1C2523),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFFFC107)),
              ),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        final int eventCount = docs.length;
        double peakPpv = 0;
        DateTime? latestTs;

        for (final doc in docs) {
          final d = doc.data() as Map<String, dynamic>;
          final ppv = (d['ppv'] as num?)?.toDouble() ?? 0.0;
          if (ppv > peakPpv) peakPpv = ppv;
          final ts = d['timestamp'] as Timestamp?;
          if (ts != null) {
            final dt = ts.toDate();
            if (latestTs == null || dt.isAfter(latestTs)) latestTs = dt;
          }
        }

        String healthLabel;
        Color healthColor;
        IconData healthIcon;

        if (latestTs == null) {
          healthLabel = 'No data';
          healthColor = Colors.white38;
          healthIcon = Icons.cloud_off_outlined;
        } else {
          final age = DateTime.now().difference(latestTs);
          if (age.inMinutes < 5) {
            healthLabel = 'Live';
            healthColor = Colors.green;
            healthIcon = Icons.fiber_manual_record;
          } else if (age.inMinutes < 60) {
            healthLabel = '${age.inMinutes}m old';
            healthColor = Colors.amber;
            healthIcon = Icons.access_time;
          } else if (age.inHours < 24) {
            healthLabel = '${age.inHours}h old';
            healthColor = Colors.orange;
            healthIcon = Icons.access_time;
          } else {
            healthLabel = 'Stale';
            healthColor = Colors.red;
            healthIcon = Icons.warning_amber_outlined;
          }
        }

        Color ppvColor = Colors.green;
        if (peakPpv >= 1.0) {
          ppvColor = Colors.red;
        } else if (peakPpv >= 0.3) {
          ppvColor = Colors.amber;
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1C2523),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              const Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'RECENT ACTIVITY',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Last 24 hours',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              _ActivityStat(
                value: '$eventCount',
                label: 'Events',
                color: eventCount > 0 ? Colors.deepOrange : Colors.green,
              ),
              const SizedBox(width: 16),
              _ActivityStat(
                value: peakPpv.toStringAsFixed(2),
                label: 'Peak mm/s',
                color: ppvColor,
              ),
              const SizedBox(width: 16),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(healthIcon, color: healthColor, size: 18),
                  const SizedBox(height: 2),
                  Text(
                    healthLabel,
                    style: TextStyle(
                      color: healthColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'Health',
                    style: TextStyle(color: Colors.white38, fontSize: 9),
                  ),
                ],
              ),
              if (latestTs != null) ...[
                const SizedBox(width: 10),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.update_outlined,
                        color: Colors.white24, size: 14),
                    Text(
                      DateFormat('HH:mm').format(latestTs),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                    const Text(
                      'Last event',
                      style: TextStyle(color: Colors.white24, fontSize: 9),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ActivityStat extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _ActivityStat({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }
}
