import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/session_history_service.dart';
import '../services/session_export_service.dart';

// ---------------------------------------------------------------------------
// Sort / filter enums
// ---------------------------------------------------------------------------

enum _SortOrder { dateNewest, dateOldest, ppvHighest }

enum _FilterMode { all, anomaliesOnly }

// ---------------------------------------------------------------------------
// Main screen
// ---------------------------------------------------------------------------

/// Screen showing a scrollable list of past monitoring sessions.
///
/// Sessions are loaded from [SessionHistoryService] (SharedPreferences).
/// Tap any tile to see full stats in a bottom sheet.
class SessionHistoryScreen extends StatefulWidget {
  const SessionHistoryScreen({super.key});

  @override
  State<SessionHistoryScreen> createState() => _SessionHistoryScreenState();
}

class _SessionHistoryScreenState extends State<SessionHistoryScreen> {
  List<SessionRecord> _sessions = [];
  bool _loading = true;
  _SortOrder _sortOrder = _SortOrder.dateNewest;
  _FilterMode _filterMode = _FilterMode.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await SessionHistoryService.instance.getSessions();
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    }
  }

  List<SessionRecord> get _displayedSessions {
    var list = _filterMode == _FilterMode.anomaliesOnly
        ? _sessions.where((s) => s.anomalyEvents > 0).toList()
        : List<SessionRecord>.from(_sessions);

    switch (_sortOrder) {
      case _SortOrder.dateNewest:
        list.sort((a, b) => b.start.compareTo(a.start));
      case _SortOrder.dateOldest:
        list.sort((a, b) => a.start.compareTo(b.start));
      case _SortOrder.ppvHighest:
        list.sort((a, b) => b.peakPpv.compareTo(a.peakPpv));
    }
    return list;
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: const Text(
          'Clear History',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Delete all recorded sessions? This cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await SessionHistoryService.instance.clearAll();
    if (mounted) {
      setState(() => _sessions = []);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session history cleared')),
      );
    }
  }

  Future<void> _deleteSession(SessionRecord record) async {
    // Re-load, remove the target, and re-save all remaining.
    final all = await SessionHistoryService.instance.getSessions();
    final remaining = all.where((s) => s.id != record.id).toList();
    await SessionHistoryService.instance.clearAll();
    for (final s in remaining.reversed) {
      await SessionHistoryService.instance.saveSession(s);
    }
    if (mounted) {
      setState(() => _sessions = remaining);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session deleted')),
      );
    }
  }

  void _showSortFilterMenu(BuildContext context) async {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final result = await showMenu<String>(
      context: context,
      position: position,
      color: const Color(0xFF1C2523),
      items: [
        const PopupMenuItem(
          enabled: false,
          child: Text('SORT BY',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
        ),
        PopupMenuItem(
          value: 'sort_date_newest',
          child: Row(children: [
            Icon(Icons.check,
                size: 16,
                color: _sortOrder == _SortOrder.dateNewest
                    ? const Color(0xFFFFC107)
                    : Colors.transparent),
            const SizedBox(width: 8),
            const Text('Date (newest first)',
                style: TextStyle(color: Colors.white)),
          ]),
        ),
        PopupMenuItem(
          value: 'sort_date_oldest',
          child: Row(children: [
            Icon(Icons.check,
                size: 16,
                color: _sortOrder == _SortOrder.dateOldest
                    ? const Color(0xFFFFC107)
                    : Colors.transparent),
            const SizedBox(width: 8),
            const Text('Date (oldest first)',
                style: TextStyle(color: Colors.white)),
          ]),
        ),
        PopupMenuItem(
          value: 'sort_ppv',
          child: Row(children: [
            Icon(Icons.check,
                size: 16,
                color: _sortOrder == _SortOrder.ppvHighest
                    ? const Color(0xFFFFC107)
                    : Colors.transparent),
            const SizedBox(width: 8),
            const Text('Peak PPV (highest first)',
                style: TextStyle(color: Colors.white)),
          ]),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          child: Text('FILTER',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
        ),
        PopupMenuItem(
          value: 'filter_all',
          child: Row(children: [
            Icon(Icons.check,
                size: 16,
                color: _filterMode == _FilterMode.all
                    ? const Color(0xFFFFC107)
                    : Colors.transparent),
            const SizedBox(width: 8),
            const Text('All sessions', style: TextStyle(color: Colors.white)),
          ]),
        ),
        PopupMenuItem(
          value: 'filter_anomalies',
          child: Row(children: [
            Icon(Icons.check,
                size: 16,
                color: _filterMode == _FilterMode.anomaliesOnly
                    ? const Color(0xFFFFC107)
                    : Colors.transparent),
            const SizedBox(width: 8),
            const Text('Only sessions with anomalies',
                style: TextStyle(color: Colors.white)),
          ]),
        ),
      ],
    );

    if (result == null || !mounted) return;
    setState(() {
      switch (result) {
        case 'sort_date_newest':
          _sortOrder = _SortOrder.dateNewest;
        case 'sort_date_oldest':
          _sortOrder = _SortOrder.dateOldest;
        case 'sort_ppv':
          _sortOrder = _SortOrder.ppvHighest;
        case 'filter_all':
          _filterMode = _FilterMode.all;
        case 'filter_anomalies':
          _filterMode = _FilterMode.anomaliesOnly;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayed = _displayedSessions;
    final hasFilterActive = _filterMode != _FilterMode.all ||
        _sortOrder != _SortOrder.dateNewest;

    return Scaffold(
      backgroundColor: const Color(0xFF0D3A39),
      appBar: AppBar(
        title: const Text('Session History'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              icon: Stack(
                children: [
                  const Icon(Icons.sort),
                  if (hasFilterActive)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFFC107),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              tooltip: 'Sort / Filter',
              onPressed: () => _showSortFilterMenu(ctx),
            ),
          ),
          if (_sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear all',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFFC107)),
            )
          : _sessions.isEmpty
              ? const _EmptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  color: const Color(0xFFFFC107),
                  backgroundColor: const Color(0xFF1C2523),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: displayed.isEmpty ? 1 : displayed.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _StatsCard(sessions: _sessions);
                      }
                      if (displayed.isEmpty) {
                        return const _FilterEmptyState();
                      }
                      final record = displayed[index - 1];
                      return _SessionTile(
                        record: record,
                        onTap: () => _showDetailSheet(context, record),
                      );
                    },
                  ),
                ),
    );
  }

  void _showDetailSheet(BuildContext context, SessionRecord record) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (ctx) => _SessionDetailSheet(
        record: record,
        onDelete: () {
          Navigator.pop(ctx);
          _deleteSession(record);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Statistics card
// ---------------------------------------------------------------------------

class _StatsCard extends StatelessWidget {
  final List<SessionRecord> sessions;

  const _StatsCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) return const SizedBox.shrink();

    Duration totalTime = Duration.zero;
    double highestPpv = 0;
    int totalAnomalies = 0;

    for (final s in sessions) {
      totalTime += s.duration;
      if (s.peakPpv > highestPpv) highestPpv = s.peakPpv;
      totalAnomalies += s.anomalyEvents;
    }

    final totalHours = totalTime.inHours;
    final totalMins = totalTime.inMinutes.remainder(60);
    final timeStr = totalHours > 0 ? '${totalHours}h ${totalMins}m' : '${totalMins}m';

    Color ppvColor = Colors.green;
    if (highestPpv >= 1.0) {
      ppvColor = Colors.red;
    } else if (highestPpv >= 0.3) {
      ppvColor = Colors.amber;
    }

    return Card(
      color: const Color(0xFF1C2523),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Overview',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _StatCell(
                  icon: Icons.history,
                  label: 'Sessions',
                  value: '${sessions.length}',
                  color: Colors.blueAccent,
                ),
                _StatCell(
                  icon: Icons.timer_outlined,
                  label: 'Total Time',
                  value: timeStr,
                  color: Colors.tealAccent,
                ),
                _StatCell(
                  icon: Icons.speed,
                  label: 'Peak PPV',
                  value: highestPpv.toStringAsFixed(2),
                  color: ppvColor,
                ),
                _StatCell(
                  icon: Icons.warning_amber_outlined,
                  label: 'Anomalies',
                  value: '$totalAnomalies',
                  color: totalAnomalies > 0 ? Colors.deepOrange : Colors.green,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCell({
    required this.icon,
    required this.label,
    required this.value,
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
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty states
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, color: Colors.white24, size: 72),
          SizedBox(height: 16),
          Text(
            'No sessions recorded yet',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          SizedBox(height: 8),
          Text(
            'Sessions will appear here after\nyou finish a monitoring session.',
            style: TextStyle(color: Colors.white54, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _FilterEmptyState extends StatelessWidget {
  const _FilterEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_alt_off, color: Colors.white24, size: 48),
            SizedBox(height: 12),
            Text(
              'No sessions match the current filter.',
              style: TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Session tile
// ---------------------------------------------------------------------------

/// Returns the threshold-aware PPV color.
/// green < 0.3 mm/s, amber 0.3–1.0, red > 1.0.
Color _ppvColor(double ppv) {
  if (ppv < 0.3) return Colors.green;
  if (ppv < 1.0) return Colors.amber;
  return Colors.red;
}

class _SessionTile extends StatelessWidget {
  final SessionRecord record;
  final VoidCallback onTap;

  const _SessionTile({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('MMM d, yyyy').format(record.start);
    final startStr = DateFormat('HH:mm').format(record.start);
    final endStr = DateFormat('HH:mm').format(record.end);
    final dur = record.duration;
    final durStr = dur.inMinutes >= 60
        ? '${dur.inHours}h ${dur.inMinutes.remainder(60)}m'
        : '${dur.inMinutes}m ${dur.inSeconds.remainder(60)}s';
    final ppvColor = _ppvColor(record.peakPpv);

    return Card(
      color: const Color(0xFF1C2523),
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // PPV color stripe
              Container(
                width: 6,
                height: 56,
                decoration: BoxDecoration(
                  color: ppvColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Date + time range
                    Row(
                      children: [
                        Text(
                          dateStr,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$startStr – $endStr ($durStr)',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Metrics row
                    Row(
                      children: [
                        _MetricChip(
                          label: 'PPV',
                          value: '${record.peakPpv.toStringAsFixed(2)} mm/s',
                          color: ppvColor,
                        ),
                        const SizedBox(width: 8),
                        _MetricChip(
                          label: 'Score',
                          value:
                              '${(record.peakScore * 100).toStringAsFixed(0)}%',
                          color: Colors.blueAccent,
                        ),
                        const SizedBox(width: 8),
                        _MetricChip(
                          label: 'Events',
                          value: '${record.anomalyEvents}',
                          color: record.anomalyEvents > 0
                              ? Colors.deepOrange
                              : Colors.green,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // PPV sparkline bar — 0 to 5 mm/s scale
                    _PpvSparkline(ppv: record.peakPpv),
                    const SizedBox(height: 4),
                    Text(
                      '${record.sampleCount} samples  •  ${record.deviceName}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white30),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PPV sparkline / progress bar
// ---------------------------------------------------------------------------

class _PpvSparkline extends StatelessWidget {
  final double ppv;

  const _PpvSparkline({required this.ppv});

  @override
  Widget build(BuildContext context) {
    // Scale: 0–5 mm/s, clamped to 1.0
    final fraction = (ppv / 5.0).clamp(0.0, 1.0);
    final color = _ppvColor(ppv);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  // Background track
                  Container(
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  // Filled portion
                  FractionallySizedBox(
                    widthFactor: fraction,
                    child: Container(
                      height: 5,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  // Threshold marker at 0.3 mm/s (6% of 5mm/s scale)
                  Positioned(
                    left: MediaQuery.of(context).size.width * 0.06,
                    child: Container(width: 1, height: 5, color: Colors.white24),
                  ),
                  // Threshold marker at 1.0 mm/s (20% of 5mm/s scale)
                  Positioned(
                    left: MediaQuery.of(context).size.width * 0.20,
                    child: Container(width: 1, height: 5, color: Colors.white24),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${ppv.toStringAsFixed(2)} mm/s',
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        const Row(
          children: [
            Text('0', style: TextStyle(color: Colors.white24, fontSize: 8)),
            Spacer(),
            Text('5 mm/s',
                style: TextStyle(color: Colors.white24, fontSize: 8)),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Metric chip
// ---------------------------------------------------------------------------

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(color: color.withValues(alpha: 0.8), fontSize: 10),
          ),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail bottom sheet
// ---------------------------------------------------------------------------

class _SessionDetailSheet extends StatelessWidget {
  final SessionRecord record;
  final VoidCallback onDelete;

  const _SessionDetailSheet({required this.record, required this.onDelete});

  String _riskLabel(int events) {
    if (events == 0) return 'SAFE';
    if (events <= 3) return 'CAUTION';
    return 'CRITICAL';
  }

  Color _riskColor(int events) {
    if (events == 0) return Colors.green;
    if (events <= 3) return Colors.amber;
    return Colors.red;
  }

  IconData _riskIcon(int events) {
    if (events == 0) return Icons.check_circle_outline;
    if (events <= 3) return Icons.warning_amber_outlined;
    return Icons.dangerous_outlined;
  }

  Future<void> _export(BuildContext context) async {
    try {
      // Build a minimal summary record for the export service.
      final records = [
        {
          'timestamp': record.start.toIso8601String(),
          'ppv': record.peakPpv,
          'rms': null,
          'freq': null,
          'kurtosis': null,
          'stalta': null,
          'anomaly_score': record.peakScore,
          'anomaly_level': _riskLabel(record.anomalyEvents),
          'precursor_pattern': null,
          'confidence': null,
        }
      ];
      await SessionExportService.instance.exportSession(records);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dur = record.duration;
    final durStr = dur.inMinutes >= 60
        ? '${dur.inHours}h ${dur.inMinutes.remainder(60)}m ${dur.inSeconds.remainder(60)}s'
        : '${dur.inMinutes}m ${dur.inSeconds.remainder(60)}s';

    final ppvColor = _ppvColor(record.peakPpv);
    final scoreColor = record.peakScore >= 0.8
        ? Colors.red
        : record.peakScore >= 0.5
            ? Colors.orange
            : Colors.green;

    // Nicely formatted: "Mon 3 Mar 2026, 14:23"
    final niceDate = DateFormat('EEE d MMM yyyy, HH:mm').format(record.start);

    final riskColor = _riskColor(record.anomalyEvents);
    final riskLabel = _riskLabel(record.anomalyEvents);
    final riskIcon = _riskIcon(record.anomalyEvents);

    return Padding(
      padding: EdgeInsets.only(
        top: 24,
        left: 24,
        right: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
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
          const SizedBox(height: 16),

          // Title row
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Session Details',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // Risk badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: riskColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: riskColor.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(riskIcon, size: 14, color: riskColor),
                    const SizedBox(width: 4),
                    Text(
                      riskLabel,
                      style: TextStyle(
                        color: riskColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (record.deviceName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              record.deviceName,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            niceDate,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
          const Divider(color: Colors.white24, height: 24),

          // Duration and samples
          _Row('Duration', durStr),
          _Row('Total Samples', '${record.sampleCount}'),

          const SizedBox(height: 8),

          // PPV with sparkline
          _Row(
            'Peak PPV',
            '${record.peakPpv.toStringAsFixed(3)} mm/s',
            valueColor: ppvColor,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 6),
            child: _PpvSparkline(ppv: record.peakPpv),
          ),

          _Row(
            'Peak Anomaly Score',
            '${(record.peakScore * 100).toStringAsFixed(1)}%',
            valueColor: scoreColor,
          ),

          const SizedBox(height: 8),

          // Anomaly events with warning icon
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 130,
                  child: Text(
                    'Anomaly Events',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
                if (record.anomalyEvents > 0)
                  Icon(Icons.warning_amber_rounded,
                      size: 16,
                      color: _riskColor(record.anomalyEvents)),
                if (record.anomalyEvents > 0) const SizedBox(width: 4),
                Text(
                  '${record.anomalyEvents}',
                  style: TextStyle(
                    color: record.anomalyEvents > 0
                        ? _riskColor(record.anomalyEvents)
                        : Colors.green,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),
          _Row('Session ID', record.id,
              valueStyle: const TextStyle(
                  color: Colors.white38, fontSize: 11, fontFamily: 'monospace')),

          const Divider(color: Colors.white24, height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _export(context),
                  icon: const Icon(Icons.share_outlined, size: 16),
                  label: const Text('Export'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blueAccent,
                    side: const BorderSide(color: Colors.blueAccent),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Delete'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared row widget
// ---------------------------------------------------------------------------

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final TextStyle? valueStyle;

  const _Row(this.label, this.value, {this.valueColor, this.valueStyle});

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = valueStyle ??
        TextStyle(
          color: valueColor ?? Colors.white,
          fontSize: 13,
          fontWeight:
              valueColor != null ? FontWeight.bold : FontWeight.normal,
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(value, style: effectiveStyle),
          ),
        ],
      ),
    );
  }
}
