import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/session_history_service.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D3A39),
      appBar: AppBar(
        title: const Text('Session History'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
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
              ? _EmptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  color: const Color(0xFFFFC107),
                  backgroundColor: const Color(0xFF1C2523),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _sessions.length,
                    itemBuilder: (context, index) {
                      return _SessionTile(
                        record: _sessions[index],
                        onTap: () => _showDetailSheet(context, _sessions[index]),
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
      builder: (ctx) => _SessionDetailSheet(record: record),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
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

// ---------------------------------------------------------------------------
// Session tile
// ---------------------------------------------------------------------------

class _SessionTile extends StatelessWidget {
  final SessionRecord record;
  final VoidCallback onTap;

  const _SessionTile({required this.record, required this.onTap});

  Color _ppvColor(double ppv) {
    if (ppv < 0.5) return Colors.green;
    if (ppv < 2.0) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        DateFormat('MMM d, yyyy').format(record.start);
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
                    // Date + device
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
                          value:
                              '${record.peakPpv.toStringAsFixed(2)} mm/s',
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
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(color: color.withOpacity(0.8), fontSize: 10),
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

  const _SessionDetailSheet({required this.record});

  Color _ppvColor(double ppv) {
    if (ppv < 0.5) return Colors.green;
    if (ppv < 2.0) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
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
          const Text(
            'Session Details',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (record.deviceName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              record.deviceName,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
          const Divider(color: Colors.white24, height: 24),
          _Row('Started', fmt.format(record.start)),
          _Row('Ended', fmt.format(record.end)),
          _Row('Duration', durStr),
          const SizedBox(height: 8),
          _Row(
            'Peak PPV',
            '${record.peakPpv.toStringAsFixed(3)} mm/s',
            valueColor: ppvColor,
          ),
          _Row(
            'Peak Score',
            '${(record.peakScore * 100).toStringAsFixed(1)}%',
            valueColor: scoreColor,
          ),
          const SizedBox(height: 8),
          _Row('Samples Collected', '${record.sampleCount}'),
          _Row(
            'Anomaly Events',
            '${record.anomalyEvents}',
            valueColor: record.anomalyEvents > 0 ? Colors.deepOrange : Colors.green,
          ),
          const SizedBox(height: 8),
          _Row('Session ID', record.id,
              valueStyle: const TextStyle(
                  color: Colors.white38, fontSize: 11, fontFamily: 'monospace')),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

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
