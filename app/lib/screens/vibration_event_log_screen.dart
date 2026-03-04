import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

/// Screen to view and export vibration safety alert history
class VibrationEventLogScreen extends StatefulWidget {
  const VibrationEventLogScreen({super.key});

  @override
  State<VibrationEventLogScreen> createState() =>
      _VibrationEventLogScreenState();
}

class _VibrationEventLogScreenState extends State<VibrationEventLogScreen> {
  // Filter state: null means "All"
  String? _levelFilter;

  // Search state
  bool _searchActive = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  static const _levels = ['SAFE', 'CAUTION', 'CRITICAL'];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Normalises a raw level string from Firestore to uppercase for comparison.
  static String _normalise(String raw) => raw.trim().toUpperCase();

  /// Returns true if the document matches the active level filter and search query.
  bool _matches(Map<String, dynamic> data) {
    final level = _normalise((data['level'] ?? '').toString());
    if (_levelFilter != null && level != _levelFilter) return false;
    if (_searchQuery.isNotEmpty) {
      final msg = (data['message'] ?? '').toString().toLowerCase();
      if (!msg.contains(_searchQuery.toLowerCase())) return false;
    }
    return true;
  }

  /// Export the currently-filtered events as a simple CSV via share_plus.
  Future<void> _exportFilteredCSV(
      BuildContext context, List<QueryDocumentSnapshot> allDocs) async {
    try {
      final filtered =
          allDocs.where((d) => _matches(d.data() as Map<String, dynamic>)).toList();

      if (filtered.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No events to export')),
          );
        }
        return;
      }

      final buffer = StringBuffer();
      buffer.writeln('timestamp,level,ppv,message,latitude,longitude');

      for (final doc in filtered) {
        final d = doc.data() as Map<String, dynamic>;
        final ts = d['timestamp'] as Timestamp?;
        final time = ts != null
            ? DateFormat('yyyy-MM-dd HH:mm:ss').format(ts.toDate())
            : 'Unknown';
        final level = _normalise((d['level'] ?? '').toString());
        final ppv = d['ppv']?.toStringAsFixed(3) ?? '';
        final message =
            '"${(d['message'] ?? '').toString().replaceAll('"', '""')}"';
        final lat = d['latitude']?.toString() ?? '';
        final lon = d['longitude']?.toString() ?? '';
        buffer.writeln('$time,$level,$ppv,$message,$lat,$lon');
      }

      final csvBytes = Uint8List.fromList(buffer.toString().codeUnits);
      await Share.shareXFiles(
        [
          XFile.fromData(
            csvBytes,
            mimeType: 'text/csv',
            name: 'vibration_events.csv',
          )
        ],
        subject: 'AncientVision Vibration Events',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Export failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildFilterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _FilterChip(
            label: 'All',
            selected: _levelFilter == null,
            color: Colors.white70,
            onTap: () => setState(() => _levelFilter = null),
          ),
          const SizedBox(width: 8),
          ..._levels.map((lvl) {
            final color = _chipColor(lvl);
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _FilterChip(
                label: lvl,
                selected: _levelFilter == lvl,
                color: color,
                onTap: () => setState(
                    () => _levelFilter = _levelFilter == lvl ? null : lvl),
              ),
            );
          }),
        ],
      ),
    );
  }

  Color _chipColor(String level) {
    switch (level.toUpperCase()) {
      case 'CRITICAL':
        return Colors.red;
      case 'CAUTION':
        return Colors.orange;
      case 'SAFE':
        return Colors.green;
      default:
        return Colors.white70;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D3A39),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: _searchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: const Color(0xFFFFC107),
                decoration: const InputDecoration(
                  hintText: 'Search messages…',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : const Text('Safety Alert History'),
        actions: [
          // Search toggle
          IconButton(
            icon: Icon(
              _searchActive ? Icons.close : Icons.search,
              color: Colors.white,
            ),
            tooltip: _searchActive ? 'Close search' : 'Search',
            onPressed: () {
              setState(() {
                _searchActive = !_searchActive;
                if (!_searchActive) {
                  _searchQuery = '';
                  _searchController.clear();
                }
              });
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('safety_alerts')
            .orderBy('timestamp', descending: true)
            .limit(100)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFFC107)),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading alerts: ${snapshot.error}',
                style: const TextStyle(color: Colors.white70),
              ),
            );
          }

          final allDocs = snapshot.data?.docs ?? [];

          // Empty data state (no docs at all)
          if (allDocs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline,
                      color: Colors.green, size: 64),
                  SizedBox(height: 16),
                  Text(
                    'No safety alerts recorded',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Alerts will appear here when vibration\nor moisture thresholds are exceeded',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          final filtered = allDocs
              .where((d) => _matches(d.data() as Map<String, dynamic>))
              .toList();

          return Column(
            children: [
              _StatsBar(docs: allDocs),
              _buildFilterChips(),
              // Export icon sits above the list — kept in a row for clarity
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 4),
                  child: TextButton.icon(
                    onPressed: () => _exportFilteredCSV(context, allDocs),
                    icon: const Icon(Icons.download,
                        color: Color(0xFFFFC107), size: 18),
                    label: const Text(
                      'Export CSV',
                      style: TextStyle(color: Color(0xFFFFC107), fontSize: 13),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.timeline_outlined,
                                color: Colors.white38, size: 56),
                            SizedBox(height: 16),
                            Text(
                              'No events match your filter',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 16),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final data = filtered[index].data()
                              as Map<String, dynamic>;
                          return _AlertTile(data: data);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Small styled filter chip used in the filter bar.
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.25) : Colors.white10,
          border: Border.all(
            color: selected ? color : Colors.white24,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? color : Colors.white54,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}


// ---------------------------------------------------------------------------
// Relative time helper
// ---------------------------------------------------------------------------

/// Returns a human-readable relative time string (e.g. "3 minutes ago").
String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return "$m ${m == 1 ? 'minute' : 'minutes'} ago";
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return "$h ${h == 1 ? 'hour' : 'hours'} ago";
  }
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays} days ago';
  return DateFormat('MMM d, yyyy').format(dt);
}

class _AlertTile extends StatelessWidget {
  final Map<String, dynamic> data;

  const _AlertTile({required this.data});

  Color _levelColor(String level) {
    switch (level.toUpperCase()) {
      case 'CRITICAL':
        return Colors.red;
      case 'CAUTION':
        return Colors.orange;
      case 'SAFE':
        return Colors.green;
      default:
        return Colors.white54;
    }
  }

  IconData _levelIcon(String level) {
    switch (level.toUpperCase()) {
      case 'CRITICAL':
        return Icons.error;
      case 'CAUTION':
        return Icons.warning_amber;
      case 'SAFE':
        return Icons.check_circle_outline;
      default:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawLevel = (data['level'] ?? 'unknown').toString();
    final level = rawLevel.trim().toUpperCase();
    final hazard = data['hazardType']?.toString() ?? '';
    final ppv = (data['ppv'] as num?)?.toDouble() ?? 0.0;
    final ts = data['timestamp'] as Timestamp?;
    final hasGps = data['latitude'] != null && data['longitude'] != null;

    final color = _levelColor(level);
    final icon = _levelIcon(level);

    final relTime = ts != null ? _relativeTime(ts.toDate()) : 'Unknown time';
    final absTime = ts != null
        ? DateFormat('MMM d, HH:mm:ss').format(ts.toDate())
        : 'Unknown';

    // Short GPS coordinates label if available
    String locationLabel = '';
    if (hasGps) {
      final lat = (data['latitude'] as num).toDouble();
      final lon = (data['longitude'] as num).toDouble();
      locationLabel =
          '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';
    }

    return Card(
      color: const Color(0xFF1C2523),
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _showDetails(context),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Level colour stripe
              Container(
                width: 8,
                height: 64,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Level badge + hazard type row
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: color.withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, color: color, size: 12),
                              const SizedBox(width: 4),
                              Text(
                                level,
                                style: TextStyle(
                                  color: color,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (hazard.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              hazard,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ] else
                          const Spacer(),
                        if (hasGps)
                          const Icon(Icons.location_on,
                              color: Colors.green, size: 14),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // PPV value prominently displayed
                    Text(
                      '${ppv.toStringAsFixed(2)} mm/s',
                      style: TextStyle(
                        color: color,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Relative time
                    Text(
                      relTime,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                    // Absolute timestamp
                    Text(
                      absTime,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                    // Short location if GPS is available
                    if (locationLabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.place_outlined,
                              color: Colors.green, size: 11),
                          const SizedBox(width: 3),
                          Text(
                            locationLabel,
                            style: const TextStyle(
                                color: Colors.green, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
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

  void _showDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final ts = data['timestamp'] as Timestamp?;
        final timeStr = ts != null
            ? DateFormat('yyyy-MM-dd HH:mm:ss').format(ts.toDate())
            : 'Unknown';

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${(data['level'] ?? 'unknown').toString().toUpperCase()} Alert',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(timeStr,
                  style: const TextStyle(color: Colors.white54)),
              const Divider(color: Colors.white24, height: 24),
              if (data['message'] != null)
                Text(
                  data['message'].toString(),
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              const SizedBox(height: 12),
              _detailRow('Hazard Type',
                  data['hazardType']?.toString() ?? 'N/A'),
              _detailRow('PPV',
                  '${data['ppv']?.toStringAsFixed(2) ?? 'N/A'} mm/s'),
              _detailRow('RMS',
                  '${data['rms']?.toStringAsFixed(4) ?? 'N/A'} g'),
              _detailRow('Frequency',
                  '${data['freq']?.toStringAsFixed(1) ?? 'N/A'} Hz'),
              _detailRow('Crest Factor',
                  data['crest']?.toStringAsFixed(1) ?? 'N/A'),
              if (data['kurtosis'] != null)
                _detailRow(
                    'Kurtosis', data['kurtosis'].toStringAsFixed(2)),
              if (data['staLta'] != null)
                _detailRow('STA/LTA', data['staLta'].toStringAsFixed(2)),
              if (data['latitude'] != null && data['longitude'] != null)
                _detailRow(
                    'Location',
                    '${data['latitude'].toStringAsFixed(6)}, '
                        '${data['longitude'].toStringAsFixed(6)}'),
              _detailRow(
                  'Device', data['deviceName']?.toString() ?? 'N/A'),
              if (data['assessment'] != null &&
                  data['assessment'].toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  data['assessment'].toString(),
                  style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      fontStyle: FontStyle.italic),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style:
                    const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _StatsBar — summary statistics row shown above the event list
// ---------------------------------------------------------------------------

/// Displays a summary row: total events, most common level, peak PPV, and
/// the time span covered by the loaded data.
class _StatsBar extends StatelessWidget {
  final List<QueryDocumentSnapshot> docs;

  const _StatsBar({required this.docs});

  @override
  Widget build(BuildContext context) {
    double peakPpv = 0;
    final levelCounts = <String, int>{};
    DateTime? oldest;
    DateTime? newest;

    for (final doc in docs) {
      final d = doc.data() as Map<String, dynamic>;
      final ppv = (d['ppv'] as num?)?.toDouble() ?? 0.0;
      if (ppv > peakPpv) peakPpv = ppv;

      final raw = (d['level'] ?? '').toString().trim().toUpperCase();
      levelCounts[raw] = (levelCounts[raw] ?? 0) + 1;

      final ts = d['timestamp'] as Timestamp?;
      if (ts != null) {
        final dt = ts.toDate();
        if (oldest == null || dt.isBefore(oldest)) oldest = dt;
        if (newest == null || dt.isAfter(newest)) newest = dt;
      }
    }

    // Most common level
    String mostCommon = '';
    int maxCount = 0;
    for (final entry in levelCounts.entries) {
      if (entry.value > maxCount) {
        maxCount = entry.value;
        mostCommon = entry.key;
      }
    }

    // Time span label
    String spanLabel = '';
    if (oldest != null && newest != null) {
      final span = newest.difference(oldest);
      if (span.inDays >= 1) {
        spanLabel = '${span.inDays}d span';
      } else if (span.inHours >= 1) {
        spanLabel = '${span.inHours}h span';
      } else {
        spanLabel = 'Last ${span.inMinutes}m';
      }
    }

    Color ppvColor = Colors.green;
    if (peakPpv >= 1.0) {
      ppvColor = Colors.red;
    } else if (peakPpv >= 0.3) {
      ppvColor = Colors.amber;
    }

    Color levelColor = Colors.white70;
    if (mostCommon == 'CRITICAL') levelColor = Colors.red;
    if (mostCommon == 'CAUTION') levelColor = Colors.orange;
    if (mostCommon == 'SAFE') levelColor = Colors.green;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2523),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          _statChip(
            icon: Icons.event_note_outlined,
            value: '${docs.length}',
            label: 'Events',
            color: Colors.blueAccent,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _statChip(
              icon: Icons.analytics_outlined,
              value: mostCommon.isEmpty ? '\u2014' : 'Mostly $mostCommon',
              label: 'Pattern',
              color: levelColor,
            ),
          ),
          const SizedBox(width: 6),
          _statChip(
            icon: Icons.speed_outlined,
            value: peakPpv.toStringAsFixed(2),
            label: 'Peak mm/s',
            color: ppvColor,
          ),
          if (spanLabel.isNotEmpty) ...[
            const SizedBox(width: 6),
            _statChip(
              icon: Icons.schedule_outlined,
              value: spanLabel,
              label: 'Range',
              color: Colors.tealAccent,
            ),
          ],
        ],
      ),
    );
  }

  Widget _statChip({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 9),
        ),
      ],
    );
  }
}
