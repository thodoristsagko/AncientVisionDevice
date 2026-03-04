// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import '../models/finding_model.dart';
import '../services/local_storage_service.dart';
import '../services/critical_event_log_service.dart';
import 'finding_details_page.dart';
import 'findings_map_screen.dart';
import 'quick_capture_screen.dart';
import 'ai_recognition_screen.dart';
import 'manual_entry_form_screen.dart';
import '../widgets/finding_detail_card.dart';
import '../config/env_config.dart';
import '../services/site_service.dart';

class FindingsView extends StatefulWidget {
  const FindingsView({super.key});

  @override
  State<FindingsView> createState() => FindingsViewState();
}

class FindingsViewState extends State<FindingsView> {
  List<Finding> _findings = [];
  List<Finding> _filteredFindings = [];
  bool _isLoading = true;
  bool _isDemoMode = false;
  int _selectedIndex = 0;
  final TextEditingController _searchController = TextEditingController();
  FindingSource? _selectedSource; // null means "All"

  // Filter chips visibility
  bool _showFilters = false;
  bool _showSignificantOnly = false;

  // Sort options: 'date_desc', 'date_asc', 'type_az', 'risk'
  String _sortMode = 'date_desc';

  // Type category filter: null = All
  String? _typeCategory; // 'artifact', 'structure', 'anomaly', 'note'

  // Bulk selection mode
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  // Risk events: timestamps of critical events loaded from CriticalEventLogService
  List<DateTime> _criticalEventTimestamps = [];

  final _siteService = SiteService();
  String _activeSite = '';

  @override
  void initState() {
    super.initState();
    _loadFindings();
    _siteService.getActiveSite().then((s) {
      if (mounted) setState(() => _activeSite = s);
    });
    _loadCriticalEvents();
  }

  Future<void> _loadCriticalEvents() async {
    try {
      final events = await CriticalEventLogService.instance.loadEvents();
      if (mounted) {
        setState(() {
          _criticalEventTimestamps = events.map((e) => e.timestamp).toList();
        });
      }
    } catch (_) {
      // Non-critical; silently ignore
    }
  }

  /// Returns true if this finding was recorded within 5 minutes of any critical event.
  bool _recordedDuringAnomaly(Finding f) {
    if (f.isSignificant) return true;
    if (_criticalEventTimestamps.isEmpty) return false;
    try {
      final findingDate = DateTime.parse(f.date);
      return _criticalEventTimestamps.any((ts) =>
          ts.difference(findingDate).abs() < const Duration(minutes: 5));
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterFindings(String query) {
    setState(() {
      // Start with all findings
      var filtered = _findings.toList();

      // Filter by source if selected
      if (_selectedSource != null) {
        filtered = filtered.where((f) => f.source == _selectedSource).toList();
      }

      if (_showSignificantOnly) {
        filtered = filtered.where((f) => f.isSignificant).toList();
      }

      // Type category filter
      if (_typeCategory != null) {
        filtered = filtered.where((f) => _matchesTypeCategory(f.type, _typeCategory!)).toList();
      }

      // Filter by search query — includes description/notes now
      if (query.isNotEmpty) {
        final searchLower = query.toLowerCase();
        filtered = filtered.where((f) {
          return f.name.toLowerCase().contains(searchLower) ||
              f.type.toLowerCase().contains(searchLower) ||
              f.site.toLowerCase().contains(searchLower) ||
              f.id.toLowerCase().contains(searchLower) ||
              f.description.toLowerCase().contains(searchLower);
        }).toList();
      }

      // Sort
      switch (_sortMode) {
        case 'date_asc':
          filtered.sort((a, b) => a.date.compareTo(b.date));
        case 'type_az':
          filtered.sort((a, b) => a.type.compareTo(b.type));
        case 'risk':
          // significant findings first
          filtered.sort((a, b) {
            if (a.isSignificant == b.isSignificant) return 0;
            return a.isSignificant ? -1 : 1;
          });
        default: // 'date_desc'
          filtered.sort((a, b) => b.date.compareTo(a.date));
      }

      _filteredFindings = filtered;
      if (_filteredFindings.isNotEmpty && _selectedIndex >= _filteredFindings.length) {
        _selectedIndex = 0;
      }
    });
  }

  /// Map finding type string to a broad category chip.
  bool _matchesTypeCategory(String type, String category) {
    final t = type.toLowerCase();
    switch (category) {
      case 'artifact':
        return t.contains('coin') || t.contains('pottery') || t.contains('ceramic') ||
            t.contains('metal') || t.contains('tool') || t.contains('bone') ||
            t.contains('jewelry') || t.contains('glass') || t.contains('fragment') ||
            t.contains('sherd') || t.contains('sculpture') || t.contains('statue');
      case 'structure':
        return t.contains('wall') || t.contains('floor') || t.contains('building') ||
            t.contains('arch') || t.contains('column') || t.contains('feature') ||
            t.contains('pit') || t.contains('trench') || t.contains('grave');
      case 'anomaly':
        return t.contains('anomaly') || t.contains('vibration') || t.contains('seismic') ||
            t.contains('hazard') || t.contains('crack') || t.contains('soil');
      case 'note':
        return t.contains('note') || t.contains('observation') || t.contains('photo') ||
            t.contains('sample') || t.contains('unknown') || t.contains('other');
      default:
        return true;
    }
  }

  void _setSourceFilter(FindingSource? source) {
    setState(() {
      _selectedSource = source;
    });
    _filterFindings(_searchController.text);
  }

  Widget _buildSourceChip(FindingSource? source, String label, IconData icon) {
    final isSelected = _selectedSource == source;
    final color = source?.color ?? const Color(0xFFFFC107);

    return GestureDetector(
      onTap: () => _setSourceFilter(source),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.white.withAlpha(26),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : Colors.white.withAlpha(51),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : Colors.white.withAlpha(179),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white.withAlpha(179),
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeCategoryChip(String? category, String label) {
    final isSelected = _typeCategory == category;
    const color = Color(0xFF00BCD4);
    return GestureDetector(
      onTap: () {
        setState(() => _typeCategory = category);
        _filterFindings(_searchController.text);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.white.withAlpha(26),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : Colors.white.withAlpha(51),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white.withAlpha(179),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  void _showSortMenu(BuildContext context) {
    final options = <String, String>{
      'date_desc': 'Date (Newest first)',
      'date_asc': 'Date (Oldest first)',
      'type_az': 'Type (A–Z)',
      'risk': 'Risk level (Significant first)',
    };
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sort findings',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...options.entries.map((e) => ListTile(
              title: Text(e.value, style: const TextStyle(color: Colors.white)),
              trailing: _sortMode == e.key
                  ? const Icon(Icons.check, color: Color(0xFFFFC107))
                  : null,
              onTap: () {
                setState(() => _sortMode = e.key);
                Navigator.pop(context);
                _filterFindings(_searchController.text);
              },
            )),
          ],
        ),
      ),
    );
  }

  Future<void> _exportCsv(BuildContext context) async {
    if (_filteredFindings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No findings to export')),
      );
      return;
    }

    final buffer = StringBuffer();
    // Header
    buffer.writeln('ID,Name,Type,Site,Date,Description,Latitude,Longitude,Significant,Source');
    // Rows
    String csvEsc(String s) => '"${s.replaceAll('"', '""')}"';
    for (final f in _filteredFindings) {
      buffer.writeln([
        csvEsc(f.id),
        csvEsc(f.name),
        csvEsc(f.type),
        csvEsc(f.site),
        csvEsc(f.date),
        csvEsc(f.description),
        f.latitude.toStringAsFixed(7),
        f.longitude.toStringAsFixed(7),
        f.isSignificant ? 'Yes' : 'No',
        csvEsc(f.source.label),
      ].join(','));
    }

    final csv = buffer.toString();
    await Share.share(
      csv,
      subject: 'AncientVision Findings Export — ${DateTime.now().toIso8601String().split('T')[0]}',
    );
  }

  Future<void> _exportJson(BuildContext context) async {
    if (_filteredFindings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No findings to export')),
      );
      return;
    }

    final jsonList = _filteredFindings.map((f) => {
      'id': f.id,
      'name': f.name,
      'type': f.type,
      'site': f.site,
      'date': f.date,
      'description': f.description,
      'latitude': f.latitude,
      'longitude': f.longitude,
      'isSignificant': f.isSignificant,
      'recordedDuringAnomaly': _recordedDuringAnomaly(f),
      'source': f.source.label,
      'imageUrl': f.imageUrl,
      'model3dUrl': f.model3dUrl,
    }).toList();

    final jsonString = const JsonEncoder.withIndent('  ').convert({
      'exported': DateTime.now().toIso8601String(),
      'count': jsonList.length,
      'findings': jsonList,
    });

    await Share.share(
      jsonString,
      subject: 'AncientVision Findings JSON — ${DateTime.now().toIso8601String().split('T')[0]}',
    );
  }

  void _showExportMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Export findings',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.table_chart_rounded, color: Color(0xFF4CAF50)),
              title: const Text('Export as CSV', style: TextStyle(color: Colors.white)),
              subtitle: Text(
                '${_filteredFindings.length} rows',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(context);
                _exportCsv(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.data_object_rounded, color: Color(0xFF2196F3)),
              title: const Text('Export as JSON', style: TextStyle(color: Colors.white)),
              subtitle: Text(
                '${_filteredFindings.length} findings + risk flags',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(context);
                _exportJson(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedIds.clear();
    });
  }

  void _toggleFindingSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(_filteredFindings.map((f) => f.id));
    });
  }

  Future<void> _deleteSelected(BuildContext context) async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: const Text('Delete findings', style: TextStyle(color: Colors.white)),
        content: Text(
          'Delete $count finding${count == 1 ? '' : 's'}? This cannot be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ids = Set<String>.from(_selectedIds);
    for (final id in ids) {
      try {
        await FirebaseFirestore.instance.collection('findings').doc(id).delete();
      } catch (e) {
        debugPrint('Delete $id failed: $e');
      }
    }

    if (mounted) {
      setState(() {
        _findings.removeWhere((f) => ids.contains(f.id));
        _selectedIds.clear();
        _selectionMode = false;
      });
      _filterFindings(_searchController.text);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted $count finding${count == 1 ? '' : 's'}'),
          backgroundColor: const Color(0xFF4CAF50),
        ),
      );
    }
  }

  void showAddOptions(BuildContext context) {
    if (_isDemoMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Demo mode — connect to save findings')),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
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
            const Text(
              'Add Finding',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            // Quick Capture option
            _buildAddOption(
              icon: Icons.flash_on_rounded,
              title: 'Quick Capture',
              subtitle: 'Snap a photo and save instantly',
              color: const Color(0xFF2196F3),
              onTap: () async {
                Navigator.pop(context);
                final result = await Navigator.push<Map<String, dynamic>>(
                  context,
                  MaterialPageRoute(builder: (_) => const QuickCaptureScreen()),
                );
                if (result != null && context.mounted) {
                  _handleQuickCaptureResult(context, result);
                }
              },
            ),
            const SizedBox(height: 10),
            // Manual Entry option
            _buildAddOption(
              icon: Icons.edit_note_rounded,
              title: 'Manual Entry',
              subtitle: 'Full archaeological recording form',
              color: const Color(0xFFFFC107),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManualEntryFormScreen()),
                );
              },
            ),
            const SizedBox(height: 10),
            // Coin Recognition option
            _buildAddOption(
              icon: Icons.auto_awesome_rounded,
              title: 'Coin Recognition',
              subtitle: 'AI-powered coin identification',
              color: const Color(0xFF7C4DFF),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AIRecognitionScreen()),
                );
              },
            ),
            const SizedBox(height: 16),
            SafeArea(child: Container()),
          ],
        ),
      ),
    );
  }

  Widget _buildAddOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(26),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withAlpha(38)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withAlpha(51),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
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
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withAlpha(153),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color: Colors.white.withAlpha(102),
                size: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSiteSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C2523),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: FutureBuilder<List<String>>(
          future: _siteService.getSites(),
          builder: (ctx, snap) {
            final sites = snap.data ?? [];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Select Site',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ...sites.map((s) => ListTile(
                  title: Text(s, style: const TextStyle(color: Colors.white)),
                  trailing: _activeSite == s
                      ? const Icon(Icons.check, color: Color(0xFFFFC107))
                      : null,
                  onTap: () async {
                    await _siteService.setActiveSite(s);
                    if (mounted) setState(() => _activeSite = s);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                )),
                const Divider(color: Colors.white12),
                ListTile(
                  leading: const Icon(Icons.add, color: Color(0xFFFFC107)),
                  title: const Text('New site…', style: TextStyle(color: Color(0xFFFFC107))),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final name = await _showNewSiteDialog(context);
                    if (name != null && name.isNotEmpty) {
                      await _siteService.addSite(name);
                      await _siteService.setActiveSite(name);
                      if (mounted) setState(() => _activeSite = name);
                    }
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<String?> _showNewSiteDialog(BuildContext context) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: const Text('New Site', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Site name (e.g. Kalapodi Trench A)',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add', style: TextStyle(color: Color(0xFFFFC107))),
          ),
        ],
      ),
    );
  }

  Future<void> _loadDemoFindings() async {
    try {
      final raw = await rootBundle.loadString('assets/data/demo_findings.json');
      final list = jsonDecode(raw) as List;
      final findings = list.map((data) => Finding(
        id: data['id'] as String,
        name: data['name'] as String,
        type: data['type'] as String,
        site: (data['site'] as String?) ?? '',
        date: data['date'] as String,
        description: (data['description'] as String?) ?? '',
        latitude: (data['latitude'] ?? 0.0).toDouble(),
        longitude: (data['longitude'] ?? 0.0).toDouble(),
        source: FindingSource.fromString(data['source'] as String?),
        photoGallery: const [],
        isSignificant: (data['isSignificant'] as bool?) ?? false,
      )).toList();
      setState(() {
        _findings = findings;
        _filteredFindings = findings;
        _isLoading = false;
        _isDemoMode = true;
      });
    } catch (e) {
      debugPrint('Error loading demo findings: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load demo data')),
        );
      }
    }
  }

  Future<void> _loadFindings() async {
    debugPrint('=== _loadFindings called ===');
    try {
      // First try with ordering, then fallback without if no results
      var snapshot = await FirebaseFirestore.instance
          .collection('findings')
          .orderBy('createdAt', descending: true)
          .limit(20)
          .get()
          .timeout(const Duration(seconds: 10));

      // If no results with ordering, try without (for docs missing createdAt)
      if (snapshot.docs.isEmpty) {
        debugPrint('No documents with createdAt, trying without ordering...');
        snapshot = await FirebaseFirestore.instance
            .collection('findings')
            .limit(20)
            .get()
            .timeout(const Duration(seconds: 10));
      }
      debugPrint('Firestore returned ${snapshot.docs.length} documents');

      final findings = snapshot.docs.map((doc) {
        final data = doc.data();
        debugPrint('Loading finding ${doc.id}');
        // Parse photoGallery from Firestore
        List<String> gallery = [];
        if (data['photoGallery'] != null) {
          gallery = List<String>.from(data['photoGallery']);
        }
        return Finding(
          id: doc.id,
          name: data['name'] ?? '',
          type: data['type'] ?? '',
          site: data['site'] ?? '',
          date: data['date'] ?? '',
          description: data['description'] ?? '',
          latitude: (data['latitude'] ?? 0.0).toDouble(),
          longitude: (data['longitude'] ?? 0.0).toDouble(),
          imageUrl: data['imageUrl'],
          photoGallery: gallery,
          model3dUrl: data['model3dUrl'],
          source: FindingSource.fromString(data['source']),
          // Coin fields
          denomination: data['denomination'],
          mint: data['mint'],
          ruler: data['ruler'],
          obverseLegend: data['obverseLegend'],
          reverseLegend: data['reverseLegend'],
          dieAxis: data['dieAxis'],
          obverseDescription: data['obverseDescription'],
          reverseDescription: data['reverseDescription'],
          // Fragment fields
          vesselPart: data['vesselPart'],
          wareType: data['wareType'],
          decorationStyle: data['decorationStyle'],
          fabricColorInt: data['fabricColorInt'],
          fabricColorExt: data['fabricColorExt'],
          rimDiameter: data['rimDiameter']?.toDouble(),
          wallThickness: data['wallThickness']?.toDouble(),
          surfaceTreatment: data['surfaceTreatment'],
          // Context fields
          locusNumber: data['locusNumber'],
          soilType: data['soilType'],
          matrixDescription: data['matrixDescription'],
          harrisPosition: data['harrisPosition'],
          associatedFeatures: data['associatedFeatures'] != null
              ? List<String>.from(data['associatedFeatures'])
              : null,
          isSignificant: data['isSignificant'] ?? false,
        );
      }).toList();

      setState(() {
        _findings = findings;
        _filteredFindings = findings;
        _isLoading = false;
        if (_findings.isNotEmpty && _selectedIndex >= _findings.length) {
          _selectedIndex = 0;
        }
      });
    } catch (e) {
      debugPrint('Error loading findings: $e');
      if (mounted) {
        await _loadDemoFindings();
      }
    }
  }

  Widget _sourceBadge(FindingSource source) {
    final label = source == FindingSource.manual
        ? 'Manual'
        : source == FindingSource.photo
            ? 'AI'
            : 'Quick';
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: source.color.withAlpha(40),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: source.color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(source.icon, color: source.color, size: 9),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  color: source.color,
                  fontSize: 9,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _filteredFindings.isNotEmpty ? _filteredFindings[_selectedIndex] : null;

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
        child: RefreshIndicator(
          onRefresh: _loadFindings,
          color: const Color(0xFFFFC107),
          backgroundColor: const Color(0xFF0D3A39),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _filteredFindings.isEmpty && !_isLoading
                            ? 'Findings'
                            : 'Findings (${_filteredFindings.length})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    // Selection-mode toggle
                    GestureDetector(
                      onTap: _toggleSelectionMode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _selectionMode
                              ? const Color(0xFFF44336).withAlpha(51)
                              : Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _selectionMode
                                ? const Color(0xFFF44336).withAlpha(128)
                                : Colors.white.withAlpha(51),
                          ),
                        ),
                        child: Text(
                          _selectionMode ? 'Cancel' : 'Select',
                          style: TextStyle(
                            color: _selectionMode
                                ? const Color(0xFFF44336)
                                : Colors.white.withAlpha(179),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Bulk-action bar (visible when in selection mode)
                if (_selectionMode) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF44336).withAlpha(30),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFF44336).withAlpha(80)),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${_selectedIds.length} selected',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _selectAll,
                          child: const Text('Select all',
                              style: TextStyle(color: Color(0xFFFFC107), fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _selectedIds.isEmpty
                              ? null
                              : () => _deleteSelected(context),
                          child: Text(
                            'Delete',
                            style: TextStyle(
                              color: _selectedIds.isEmpty
                                  ? Colors.white38
                                  : const Color(0xFFF44336),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),

                // SEARCH BAR
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(26),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withAlpha(51),
                      width: 1,
                    ),
                  ),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _filterFindings,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search by name, type, site, or ID...',
                      hintStyle: TextStyle(
                        color: Colors.white.withAlpha(102),
                        fontSize: 14,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: Colors.white.withAlpha(128),
                        size: 20,
                      ),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? GestureDetector(
                              onTap: () {
                                _searchController.clear();
                                _filterFindings('');
                              },
                              child: Icon(
                                Icons.clear_rounded,
                                color: Colors.white.withAlpha(128),
                                size: 20,
                              ),
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Toolbar row: filter toggle + sort + export
                Row(
                  children: [
                    // Filter toggle button
                    GestureDetector(
                      onTap: () => setState(() => _showFilters = !_showFilters),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _showFilters || _selectedSource != null
                              ? const Color(0xFFFFC107).withAlpha(51)
                              : Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _selectedSource != null
                                ? const Color(0xFFFFC107).withAlpha(128)
                                : Colors.white.withAlpha(51),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.filter_list_rounded,
                              color: _selectedSource != null
                                  ? const Color(0xFFFFC107)
                                  : Colors.white.withAlpha(179),
                              size: 18,
                            ),
                            if (_selectedSource != null) ...[
                              const SizedBox(width: 4),
                              Text(
                                _selectedSource!.label,
                                style: const TextStyle(
                                  color: Color(0xFFFFC107),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Significant filter toggle
                    GestureDetector(
                      onTap: () {
                        setState(() => _showSignificantOnly = !_showSignificantOnly);
                        _filterFindings(_searchController.text);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _showSignificantOnly
                              ? const Color(0xFFFFC107).withAlpha(51)
                              : Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _showSignificantOnly
                                ? const Color(0xFFFFC107).withAlpha(128)
                                : Colors.white.withAlpha(51),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_rounded,
                              color: _showSignificantOnly
                                  ? const Color(0xFFFFC107)
                                  : Colors.white.withAlpha(179),
                              size: 18,
                            ),
                            if (_showSignificantOnly) ...[
                              const SizedBox(width: 4),
                              const Text(
                                'Significant',
                                style: TextStyle(
                                  color: Color(0xFFFFC107),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Sort button
                    GestureDetector(
                      onTap: () => _showSortMenu(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _sortMode != 'date_desc'
                              ? const Color(0xFFFFC107).withAlpha(51)
                              : Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _sortMode != 'date_desc'
                                ? const Color(0xFFFFC107).withAlpha(128)
                                : Colors.white.withAlpha(51),
                            width: 1,
                          ),
                        ),
                        child: Icon(
                          Icons.sort_rounded,
                          color: _sortMode != 'date_desc'
                              ? const Color(0xFFFFC107)
                              : Colors.white.withAlpha(179),
                          size: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Export button (CSV or JSON)
                    GestureDetector(
                      onTap: () => _showExportMenu(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.white.withAlpha(51),
                            width: 1,
                          ),
                        ),
                        child: Icon(
                          Icons.download_rounded,
                          color: Colors.white.withAlpha(179),
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),

                // Collapsible filter chips (source + type category)
                if (_showFilters) ...[
                  const SizedBox(height: 10),
                  // Source filter row
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildSourceChip(null, 'All', Icons.list_alt),
                        const SizedBox(width: 8),
                        ...FindingSource.values.map((source) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _buildSourceChip(source, source.label, source.icon),
                        )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Type category filter row
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildTypeCategoryChip(null, 'All'),
                        const SizedBox(width: 8),
                        _buildTypeCategoryChip('artifact', 'Artifact'),
                        const SizedBox(width: 8),
                        _buildTypeCategoryChip('structure', 'Structure'),
                        const SizedBox(width: 8),
                        _buildTypeCategoryChip('anomaly', 'Anomaly'),
                        const SizedBox(width: 8),
                        _buildTypeCategoryChip('note', 'Note'),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),

                // Site selector chip
                GestureDetector(
                  onTap: () => _showSiteSelector(context),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(20),
                      border: _activeSite.isNotEmpty
                          ? Border.all(color: Colors.white.withAlpha(50))
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _activeSite.isNotEmpty
                              ? Icons.location_on_rounded
                              : Icons.add_location_alt_rounded,
                          color: _activeSite.isNotEmpty
                              ? const Color(0xFFFFC107)
                              : Colors.white54,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _activeSite.isNotEmpty ? _activeSite : 'Set site',
                          style: TextStyle(
                            color: _activeSite.isNotEmpty ? Colors.white70 : Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        if (_activeSite.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.expand_more, color: Colors.white38, size: 14),
                        ],
                      ],
                    ),
                  ),
                ),

              // Show loading or empty state
              if (_isLoading)
                Container(
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFFC107)),
                  ),
                )
              else if (_findings.isEmpty)
                Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.explore_outlined, color: const Color(0xFFFFC107).withAlpha(150), size: 48),
                      const SizedBox(height: 16),
                      const Text('No findings yet', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text('Tap + to add your first discovery', style: TextStyle(color: Colors.white.withAlpha(140), fontSize: 13)),
                    ],
                  ),
                )
              else ...[
                if (_isDemoMode)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFC107).withAlpha(40),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFFC107).withAlpha(100)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.wifi_off_rounded, color: Color(0xFFFFC107), size: 14),
                        SizedBox(width: 6),
                        Text('Demo Mode — offline sample data',
                            style: TextStyle(color: Color(0xFFFFC107), fontSize: 12)),
                      ],
                    ),
                  ),
                // No-results empty state (when search/filter matches nothing)
                if (_filteredFindings.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(18),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.search_off_rounded, color: Colors.white.withAlpha(100), size: 48),
                        const SizedBox(height: 16),
                        const Text(
                          'No findings match',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Try a different search term or clear the filters',
                          style: TextStyle(color: Colors.white.withAlpha(140), fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _typeCategory = null;
                              _selectedSource = null;
                              _showSignificantOnly = false;
                            });
                            _filterFindings('');
                          },
                          child: const Text(
                            'Clear all filters',
                            style: TextStyle(color: Color(0xFFFFC107)),
                          ),
                        ),
                      ],
                    ),
                  ),
                // RECENT FINDINGS TABLE WITH SWIPE TO DELETE
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      ..._filteredFindings.asMap().entries.map((entry) {
                            final index = entry.key;
                            final f = entry.value;
                            final isRowSelected = index == _selectedIndex;
                            final isBulkSelected = _selectedIds.contains(f.id);
                            final typeColor = Finding.getTypeColor(f.type);
                            final hasRisk = _recordedDuringAnomaly(f);

                            return GestureDetector(
                              key: Key(f.id),
                              onTap: () {
                                if (_selectionMode) {
                                  _toggleFindingSelection(f.id);
                                } else {
                                  setState(() => _selectedIndex = index);
                                }
                              },
                              child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: isBulkSelected
                                        ? const Color(0xFFF44336).withAlpha(40)
                                        : isRowSelected
                                            ? const Color(0xFFFFC107).withAlpha(51)
                                            : Colors.white.withAlpha(13),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isBulkSelected
                                          ? const Color(0xFFF44336).withAlpha(150)
                                          : isRowSelected
                                              ? const Color(0xFFFFC107).withAlpha(128)
                                              : Colors.transparent,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      // Bulk selection checkbox
                                      if (_selectionMode) ...[
                                        Icon(
                                          isBulkSelected
                                              ? Icons.check_circle_rounded
                                              : Icons.radio_button_unchecked_rounded,
                                          color: isBulkSelected
                                              ? const Color(0xFFF44336)
                                              : Colors.white38,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      // Type color indicator
                                      Container(
                                        width: 4,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: typeColor,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      // Finding info
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  f.id,
                                                  style: TextStyle(
                                                    color: Colors.white.withAlpha(128),
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    f.name,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${f.type} • ${f.site} • ${f.date}',
                                              style: TextStyle(
                                                color: Colors.white.withAlpha(153),
                                                fontSize: 11,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Risk badge (red/amber) — shown when recorded during anomaly
                                      if (hasRisk)
                                        Container(
                                          margin: const EdgeInsets.only(right: 6),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: f.isSignificant
                                                ? const Color(0xFFF44336).withAlpha(50)
                                                : const Color(0xFFFF9800).withAlpha(50),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(
                                              color: f.isSignificant
                                                  ? const Color(0xFFF44336).withAlpha(150)
                                                  : const Color(0xFFFF9800).withAlpha(150),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                f.isSignificant
                                                    ? Icons.warning_rounded
                                                    : Icons.notification_important_rounded,
                                                color: f.isSignificant
                                                    ? const Color(0xFFF44336)
                                                    : const Color(0xFFFF9800),
                                                size: 9,
                                              ),
                                              const SizedBox(width: 3),
                                              Text(
                                                f.isSignificant ? 'RISK' : 'ALERT',
                                                style: TextStyle(
                                                  color: f.isSignificant
                                                      ? const Color(0xFFF44336)
                                                      : const Color(0xFFFF9800),
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      _sourceBadge(f.source),
                                      // 3D model indicator
                                      if (f.model3dUrl != null)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF7C4DFF).withAlpha(77),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Text(
                                            '3D',
                                            style: TextStyle(
                                              color: Color(0xFF7C4DFF),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      if (!_selectionMode) ...[
                                        const SizedBox(width: 8),
                                        GestureDetector(
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) => FindingDetailsPage(finding: f),
                                              ),
                                            );
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFFC107).withAlpha(51),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: const Icon(
                                              Icons.arrow_forward_ios_rounded,
                                              color: Color(0xFFFFC107),
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                            );
                          }).toList(),
                        ],
                      ),
                ),

                const SizedBox(height: 12),

                // MAP
                Container(
                  height: (MediaQuery.of(context).size.height * 0.25).clamp(200.0, 350.0),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: FindingsMap(findings: _filteredFindings, selectedIndex: _selectedIndex),
                ),

                const SizedBox(height: 16),

                // LATEST FINDING DETAIL PANEL
                if (selected != null) FindingDetailCard(finding: selected),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// Handle Quick Capture result - save to Firestore with source 'quick'
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
    'site': (result['site'] as String?)?.isNotEmpty == true ? result['site'] as String : 'Field Site',
    'date': DateTime.now().toIso8601String().split('T')[0],
    'description': description ?? '',
    'latitude': location?['latitude'] ?? 0.0,
    'longitude': location?['longitude'] ?? 0.0,
    'imageUrl': persistedPath, // Use local path
    'photoGallery': persistedPath != null ? [persistedPath] : <String>[],
    'createdAt': DateTime.now().toIso8601String(),
    'source': 'quick',
    'isSignificant': result['isSignificant'] ?? false,
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
