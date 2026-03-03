import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import '../config/env_config.dart';
import '../services/auth_service.dart';
import '../services/export_service.dart';
import '../services/pdf_export_service.dart';
import '../services/local_storage_service.dart';
import 'field_journal_screen.dart';
import 'quick_capture_screen.dart';
import 'manual_entry_form_screen.dart';
import 'analytics_screen.dart';
import 'settings_screen.dart';
import 'help_screen.dart';
import 'admin_panel_screen.dart';
import 'ai_recognition_screen.dart';

class ToolsView extends StatelessWidget {
  const ToolsView({super.key});

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
                    const SizedBox(height: 24),
                    _buildFeaturedSection(context),

                    // === DOCUMENTATION (merged Field Work + Capture) ===
                      _buildCategoryHeader('Documentation'),
                      const SizedBox(height: 10),
                      _buildBigToolButton(
                        context,
                        icon: Icons.book_rounded,
                        title: 'Field Journal',
                        description: 'Daily logs, observations, and site notes',
                        color: const Color(0xFF795548),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const FieldJournalScreen()),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _buildToolGrid(context, [
                        ToolCard(
                          icon: Icons.edit_note_rounded,
                          title: 'Manual Entry',
                          description: 'Full recording form',
                          color: const Color(0xFFFFC107),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ManualEntryFormScreen()),
                          ),
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
                          color: const Color(0xFF00BCD4),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const AnalyticsScreen()),
                          ),
                        ),
                        ToolCard(
                          icon: Icons.file_download_rounded,
                          title: 'Export Data',
                          description: 'CSV, JSON, GeoJSON',
                          color: const Color(0xFF607D8B),
                          onTap: () => _showExportDialog(context),
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
                          color: const Color(0xFF455A64),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const SettingsScreen()),
                          ),
                        ),
                        ToolCard(
                          icon: Icons.help_outline_rounded,
                          title: 'Help & Guide',
                          description: 'Tutorials & FAQ',
                          color: const Color(0xFF3F51B5),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const HelpScreen()),
                          ),
                        ),
                      ]),
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
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AIRecognitionScreen()),
          ),
        ),
        HeroToolCard(
          icon: Icons.flash_on_rounded,
          color: const Color(0xFF2196F3),
          title: 'Quick Capture',
          subtitle: 'Record a finding in seconds',
          statusLabel: 'Instant',
          statusColor: const Color(0xFF2196F3),
          onTap: () async {
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
          onTap: () async {
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
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: color, size: 20),
          ],
        ),
      ),
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
  final VoidCallback onTap;

  const HeroToolCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.statusLabel,
    required this.statusColor,
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
  final Color color;
  final VoidCallback onTap;

  const ToolCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.badge,
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
          ],
        ),
      ),
    );
  }
}
