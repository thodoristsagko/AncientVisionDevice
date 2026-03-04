import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/site_profile_service.dart';
import '../utils/app_styles.dart';

// ---------------------------------------------------------------------------
// Geology type enum with risk multipliers
// ---------------------------------------------------------------------------

enum GeologyType {
  archaeologicalMound,
  hillside,
  cliffEdge,
  urban,
  riverbank,
  other,
}

extension GeologyTypeX on GeologyType {
  String get label {
    switch (this) {
      case GeologyType.archaeologicalMound:
        return 'Archaeological mound';
      case GeologyType.hillside:
        return 'Hillside';
      case GeologyType.cliffEdge:
        return 'Cliff edge';
      case GeologyType.urban:
        return 'Urban';
      case GeologyType.riverbank:
        return 'Riverbank';
      case GeologyType.other:
        return 'Other';
    }
  }

  /// Risk multiplier relative to baseline.
  /// >1.0 = higher risk, 1.0 = baseline, <1.0 = lower risk.
  double get riskMultiplier {
    switch (this) {
      case GeologyType.archaeologicalMound:
        return 1.4; // Loose fill, burial mounds — high collapse risk
      case GeologyType.hillside:
        return 1.3; // Slope instability
      case GeologyType.cliffEdge:
        return 1.8; // Highest — shear face, no lateral support
      case GeologyType.urban:
        return 1.0; // Baseline — typically compacted soil / foundations
      case GeologyType.riverbank:
        return 1.5; // Saturated soil, undermining risk
      case GeologyType.other:
        return 1.0;
    }
  }

  Color get riskColor {
    final m = riskMultiplier;
    if (m >= 1.6) return AppColors.error;
    if (m >= 1.3) return AppColors.warning;
    return AppColors.success;
  }

  String get riskLabel {
    final m = riskMultiplier;
    if (m >= 1.6) return 'HIGH';
    if (m >= 1.3) return 'ELEVATED';
    return 'STANDARD';
  }

  IconData get icon {
    switch (this) {
      case GeologyType.archaeologicalMound:
        return Icons.terrain;
      case GeologyType.hillside:
        return Icons.landscape;
      case GeologyType.cliffEdge:
        return Icons.signal_cellular_alt;
      case GeologyType.urban:
        return Icons.location_city;
      case GeologyType.riverbank:
        return Icons.water;
      case GeologyType.other:
        return Icons.place;
    }
  }
}

// ---------------------------------------------------------------------------
// SharedPreferences keys for site-level metadata
// ---------------------------------------------------------------------------

String _hazardNotesKey(String siteId) => 'site_hazard_notes_$siteId';
String _geologyKey(String siteId) => 'site_geology_$siteId';

// ---------------------------------------------------------------------------
// SiteProfileScreen
// ---------------------------------------------------------------------------

/// Screen for managing all archaeological site profiles.
///
/// Features:
///   - List of sites with session count and last-active status
///   - Create / edit / delete sites
///   - Per-site geology type selection (with risk multiplier display)
///   - Per-site free-form hazard notes (persisted to SharedPreferences)
///   - "View historical data" with deployment count + peak PPV
class SiteProfileScreen extends StatefulWidget {
  const SiteProfileScreen({super.key});

  @override
  State<SiteProfileScreen> createState() => _SiteProfileScreenState();
}

class _SiteProfileScreenState extends State<SiteProfileScreen> {
  List<SiteProfileWithHistory> _sites = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final sites = await SiteProfileService.instance.getSites();
    if (mounted) {
      setState(() {
        _sites = List<SiteProfileWithHistory>.from(sites);
        _loading = false;
      });
    }
  }

  Future<void> _createSite() async {
    final result = await _showEditDialog(context, null);
    if (result != null && mounted) {
      await SiteProfileService.instance.createSite(
        name: result['name'] as String,
        description: result['description'],
      );
      await _load();
    }
  }

  Future<void> _editSite(SiteProfileWithHistory site) async {
    final result = await _showEditDialog(context, site);
    if (result != null && mounted) {
      final updated = site.copyWith(
        name: result['name'] as String,
        description: result['description'],
      );
      await SiteProfileService.instance.updateSite(updated);
      await _load();
    }
  }

  Future<void> _deleteSite(SiteProfileWithHistory site) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        title: const Text('Delete Site?', style: AppTextStyles.h3),
        content: Text(
          'Delete "${site.name}" and all its deployment history?\n\n'
          'This cannot be undone.',
          style: AppTextStyles.subtitle,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: AppTextStyles.accentText,
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.textPrimary,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await SiteProfileService.instance.deleteSite(site.id);
      // Also clean up per-site prefs
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_hazardNotesKey(site.id));
      await prefs.remove(_geologyKey(site.id));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Site Profiles', style: AppTextStyles.h3),
        foregroundColor: AppColors.textPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createSite,
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.primaryDark,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text(
          'New Site',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : _sites.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppColors.accent,
                  backgroundColor: AppColors.primaryDark,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: _sites.length,
                    itemBuilder: (context, index) {
                      return _SiteTile(
                        site: _sites[index],
                        onTap: () => _openDetail(context, _sites[index]),
                        onEdit: () => _editSite(_sites[index]),
                        onDelete: () => _deleteSite(_sites[index]),
                      );
                    },
                  ),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.accent.withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.add_location_alt_rounded,
              size: 56,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 20),
          const Text('No Sites Yet', style: AppTextStyles.h2),
          const SizedBox(height: 8),
          const Text(
            'Create a site profile to track deployments,\n'
            'hazard notes, and session history.',
            style: AppTextStyles.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _createSite,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.primaryDark,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
            icon: const Icon(Icons.add),
            label: const Text(
              'Create First Site',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _openDetail(BuildContext context, SiteProfileWithHistory site) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SiteDetailScreen(
          site: site,
          onUpdated: _load,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Create / edit dialog
  // -------------------------------------------------------------------------

  Future<Map<String, String?>?> _showEditDialog(
    BuildContext context,
    SiteProfileWithHistory? existing,
  ) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final formKey = GlobalKey<FormState>();

    return showDialog<Map<String, String?>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        title: Text(
          existing == null ? 'New Site' : 'Edit Site',
          style: AppTextStyles.h3,
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                autofocus: true,
                style: AppTextStyles.body,
                decoration: InputDecoration(
                  labelText: 'Site name',
                  labelStyle: AppTextStyles.caption,
                  filled: true,
                  fillColor: AppColors.cardBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.cardBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.cardBorder),
                  ),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Name required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: descCtrl,
                style: AppTextStyles.body,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Description (optional)',
                  labelStyle: AppTextStyles.caption,
                  filled: true,
                  fillColor: AppColors.cardBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.cardBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.cardBorder),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: AppTextStyles.accentText.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState?.validate() == true) {
                Navigator.pop(ctx, {
                  'name': nameCtrl.text.trim(),
                  'description': descCtrl.text.trim().isEmpty
                      ? null
                      : descCtrl.text.trim(),
                });
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.primaryDark,
            ),
            child: Text(existing == null ? 'Create' : 'Save'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Site tile
// ---------------------------------------------------------------------------

class _SiteTile extends StatelessWidget {
  final SiteProfileWithHistory site;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SiteTile({
    required this.site,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasActive = site.hasActiveDeployment;

    return Card(
      color: AppColors.primaryDark,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasActive
              ? AppColors.success.withAlpha(80)
              : AppColors.cardBorder,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accent.withAlpha(25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.landscape_rounded,
                  color: AppColors.accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            site.name,
                            style: AppTextStyles.h4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasActive) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.success.withAlpha(30),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: AppColors.success.withAlpha(80)),
                            ),
                            child: const Text(
                              'ACTIVE',
                              style: TextStyle(
                                color: AppColors.success,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (site.description != null && site.description!.isNotEmpty)
                      Text(
                        site.description!,
                        style: AppTextStyles.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.history, size: 12,
                            color: AppColors.textHint),
                        const SizedBox(width: 4),
                        Text(
                          '${site.totalDeployments} session${site.totalDeployments == 1 ? '' : 's'}',
                          style: AppTextStyles.caption.copyWith(
                              color: AppColors.textHint),
                        ),
                        if (site.peakPpvAllTime > 0) ...[
                          const SizedBox(width: 12),
                          const Icon(Icons.speed, size: 12,
                              color: AppColors.textHint),
                          const SizedBox(width: 4),
                          Text(
                            'Peak PPV ${site.peakPpvAllTime.toStringAsFixed(2)} mm/s',
                            style: AppTextStyles.caption.copyWith(
                                color: AppColors.textHint),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Actions
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
                color: AppColors.primaryDark,
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: Icon(Icons.edit, color: AppColors.accent),
                      title: Text('Edit', style: AppTextStyles.body),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline, color: AppColors.error),
                      title: Text('Delete', style: AppTextStyles.body),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ),
                ],
                onSelected: (v) {
                  if (v == 'edit') onEdit();
                  if (v == 'delete') onDelete();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Site detail screen
// ---------------------------------------------------------------------------

class _SiteDetailScreen extends StatefulWidget {
  final SiteProfileWithHistory site;
  final VoidCallback onUpdated;

  const _SiteDetailScreen({
    required this.site,
    required this.onUpdated,
  });

  @override
  State<_SiteDetailScreen> createState() => _SiteDetailScreenState();
}

class _SiteDetailScreenState extends State<_SiteDetailScreen> {
  GeologyType _geology = GeologyType.other;
  final _notesCtrl = TextEditingController();
  bool _notesDirty = false;
  bool _loadingPrefs = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final geologyIdx = prefs.getInt(_geologyKey(widget.site.id));
    final notes = prefs.getString(_hazardNotesKey(widget.site.id)) ?? '';
    if (mounted) {
      setState(() {
        if (geologyIdx != null &&
            geologyIdx >= 0 &&
            geologyIdx < GeologyType.values.length) {
          _geology = GeologyType.values[geologyIdx];
        }
        _notesCtrl.text = notes;
        _loadingPrefs = false;
      });
    }
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_geologyKey(widget.site.id), _geology.index);
    await prefs.setString(
        _hazardNotesKey(widget.site.id), _notesCtrl.text.trim());
    if (mounted) {
      setState(() {
        _notesDirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Site settings saved'),
          backgroundColor: AppColors.success,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final site = widget.site;

    return Scaffold(
      backgroundColor: AppColors.primary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(site.name, style: AppTextStyles.h3),
        foregroundColor: AppColors.textPrimary,
        actions: [
          if (_notesDirty)
            TextButton(
              onPressed: _savePrefs,
              child: const Text(
                'Save',
                style: AppTextStyles.accentText,
              ),
            ),
        ],
      ),
      body: _loadingPrefs
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Risk level card ────────────────────────────────────
                  _buildRiskCard(),
                  const SizedBox(height: 16),

                  // ── Geology selector ───────────────────────────────────
                  _buildGeologyCard(),
                  const SizedBox(height: 16),

                  // ── Hazard notes ───────────────────────────────────────
                  _buildHazardNotesCard(),
                  const SizedBox(height: 16),

                  // ── Historical data ────────────────────────────────────
                  _buildHistoricalDataCard(site),
                  const SizedBox(height: 16),

                  // ── Save button ────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    height: AppSizes.buttonHeight,
                    child: ElevatedButton.icon(
                      onPressed: _savePrefs,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.primaryDark,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppSizes.borderRadius),
                        ),
                      ),
                      icon: const Icon(Icons.save_rounded, size: 20),
                      label: const Text(
                        'Save Site Settings',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // ── Risk level summary card ──────────────────────────────────────────────

  Widget _buildRiskCard() {
    final riskColor = _geology.riskColor;
    final riskLabel = _geology.riskLabel;
    final multiplier = _geology.riskMultiplier;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: riskColor.withAlpha(15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: riskColor.withAlpha(60)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: riskColor.withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: Icon(_geology.icon, color: riskColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Risk Level',
                  style: AppTextStyles.caption.copyWith(
                    color: riskColor.withAlpha(180),
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      riskLabel,
                      style: TextStyle(
                        color: riskColor,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '(×${multiplier.toStringAsFixed(1)})',
                      style: AppTextStyles.subtitle.copyWith(color: riskColor),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Alert thresholds multiplied by ${multiplier.toStringAsFixed(1)}× for ${_geology.label.toLowerCase()}',
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Geology dropdown card ────────────────────────────────────────────────

  Widget _buildGeologyCard() {
    return _SectionCard(
      icon: Icons.terrain,
      iconColor: AppColors.info,
      title: 'Site Geology',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Select the terrain type. This adjusts the default risk multiplier '
            'applied to PPV alert thresholds at this site.',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 12),
          // Grid of geology options
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 2.8,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: GeologyType.values.map((g) {
              final isSelected = g == _geology;
              return GestureDetector(
                onTap: () => setState(() {
                  _geology = g;
                  _notesDirty = true;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? g.riskColor.withAlpha(30)
                        : AppColors.cardBackground,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? g.riskColor.withAlpha(100)
                          : AppColors.cardBorder,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(g.icon,
                          color: isSelected
                              ? g.riskColor
                              : AppColors.textSecondary,
                          size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          g.label,
                          style: TextStyle(
                            color: isSelected
                                ? g.riskColor
                                : AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ── Hazard notes card ────────────────────────────────────────────────────

  Widget _buildHazardNotesCard() {
    return _SectionCard(
      icon: Icons.warning_amber_rounded,
      iconColor: AppColors.warning,
      title: 'Site Hazard Notes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Record known hazards, access restrictions, or site-specific '
            'safety concerns. Notes are stored locally on this device.',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notesCtrl,
            maxLines: 4,
            style: AppTextStyles.body,
            onChanged: (_) => setState(() => _notesDirty = true),
            decoration: InputDecoration(
              hintText:
                  'e.g. Unstable slope on NW face. No entry after rain. '
                  'Site supervisor: Kostas +30 6945...',
              hintStyle: AppTextStyles.caption.copyWith(
                color: AppColors.textHint,
              ),
              filled: true,
              fillColor: AppColors.cardBackground,
              contentPadding: const EdgeInsets.all(12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.cardBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.cardBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: AppColors.accent,
                  width: 1.5,
                ),
              ),
            ),
          ),
          if (_notesDirty) ...[
            const SizedBox(height: 6),
            Text(
              'Unsaved changes — tap Save to persist.',
              style: AppTextStyles.caption.copyWith(color: AppColors.warning),
            ),
          ],
        ],
      ),
    );
  }

  // ── Historical data card ─────────────────────────────────────────────────

  Widget _buildHistoricalDataCard(SiteProfileWithHistory site) {
    final hasData = site.totalDeployments > 0;

    return _SectionCard(
      icon: Icons.history_rounded,
      iconColor: AppColors.success,
      title: 'Historical Data',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary metrics
          Row(
            children: [
              _HistoryStat(
                label: 'Sessions',
                value: '${site.totalDeployments}',
                icon: Icons.monitor_heart_rounded,
                color: AppColors.info,
              ),
              _HistoryStat(
                label: 'Total Time',
                value: _formatTotalTime(site.totalMonitoringTime),
                icon: Icons.timer_outlined,
                color: AppColors.accent,
              ),
              _HistoryStat(
                label: 'Peak PPV',
                value: hasData
                    ? '${site.peakPpvAllTime.toStringAsFixed(2)} mm/s'
                    : 'N/A',
                icon: Icons.speed_rounded,
                color: hasData ? _ppvColor(site.peakPpvAllTime) : AppColors.textHint,
              ),
            ],
          ),

          if (hasData) ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.cardBorder, height: 1),
            const SizedBox(height: 12),
            const Text(
              'Recent sessions',
              style: AppTextStyles.caption,
            ),
            const SizedBox(height: 8),
            // Last 5 deployments
            ...site.deployments.reversed
                .take(5)
                .map((dep) => _DeploymentRow(dep: dep)),
          ] else ...[
            const SizedBox(height: 12),
            Center(
              child: Text(
                'No sessions recorded at this site yet.',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTotalTime(Duration d) {
    if (d == Duration.zero) return '0m';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  Color _ppvColor(double ppv) {
    if (ppv < 0.3) return AppColors.success;
    if (ppv < 1.0) return AppColors.warning;
    return AppColors.error;
  }
}

// ---------------------------------------------------------------------------
// Reusable sub-widgets
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget child;

  const _SectionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.primaryDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: iconColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: iconColor, size: 18),
                ),
                const SizedBox(width: 10),
                Text(title, style: AppTextStyles.h4),
              ],
            ),
          ),
          const Divider(color: AppColors.cardBorder, height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _HistoryStat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _HistoryStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            label,
            style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _DeploymentRow extends StatelessWidget {
  final DeploymentRecord dep;

  const _DeploymentRow({required this.dep});

  @override
  Widget build(BuildContext context) {
    final dateStr = _formatDate(dep.startTime);
    final dur = dep.duration;
    final durStr = dur != null ? _formatDur(dur) : dep.isActive ? 'Active' : '—';
    final ppvColor = _ppvColor(dep.peakPpv);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 36,
            decoration: BoxDecoration(
              color: ppvColor,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dateStr, style: AppTextStyles.bodySmall),
                Text(
                  '$durStr  •  ${dep.alertCount} alert${dep.alertCount == 1 ? '' : 's'}  •  '
                  'PPV ${dep.peakPpv.toStringAsFixed(2)} mm/s',
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
          if (dep.isActive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
                border:
                    Border.all(color: AppColors.success.withAlpha(80)),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  color: AppColors.success,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  static String _formatDur(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}m';
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }

  static Color _ppvColor(double ppv) {
    if (ppv < 0.3) return AppColors.success;
    if (ppv < 1.0) return AppColors.warning;
    return AppColors.error;
  }
}
