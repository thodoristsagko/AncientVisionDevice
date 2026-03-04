import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/alert_data.dart';

/// Groups a run of consecutive alerts that share the same [AlertLevel].
class _AlertGroup {
  final AlertLevel level;
  final List<AlertData> alerts;

  _AlertGroup({required this.level, required this.alerts});

  int get count => alerts.length;
  AlertData get first => alerts.first;
  AlertData get last => alerts.last;
}

/// Compress a flat list of [AlertData] into consecutive same-level runs.
List<_AlertGroup> _groupAlerts(List<AlertData> alerts) {
  final groups = <_AlertGroup>[];
  for (final alert in alerts) {
    if (groups.isNotEmpty && groups.last.level == alert.level) {
      groups.last.alerts.add(alert);
    } else {
      groups.add(_AlertGroup(level: alert.level, alerts: [alert]));
    }
  }
  return groups;
}

/// Returns a human-readable relative time string for [timestamp].
/// Falls back to [fallback] when [timestamp] is null.
String _relativeTime(DateTime? timestamp, {String fallback = ''}) {
  if (timestamp == null) return fallback;
  final diff = DateTime.now().difference(timestamp);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

class SafetyAlertsCard extends StatelessWidget {
  final List<AlertData> alerts;

  const SafetyAlertsCard({super.key, required this.alerts});

  // ---------------------------------------------------------------------------
  // CSV export
  // ---------------------------------------------------------------------------

  Future<void> _exportCsv(BuildContext context) async {
    if (alerts.isEmpty) return;

    final buf = StringBuffer();
    buf.writeln('time,level,title,message');
    for (final a in alerts) {
      final ts = a.timestamp?.toIso8601String() ?? a.time;
      final level = a.level.name;
      final title = '"${a.title.replaceAll('"', '""')}"';
      final msg = '"${a.message.replaceAll('"', '""')}"';
      buf.writeln('$ts,$level,$title,$msg');
    }

    try {
      await Share.share(
        buf.toString(),
        subject: 'AncientVision Alert Log',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groups = _groupAlerts(alerts);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with export button
          Row(
            children: [
              const Text(
                'Alerts',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (alerts.isNotEmpty)
                GestureDetector(
                  onTap: () => _exportCsv(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.share, color: Colors.white.withAlpha(200), size: 13),
                        const SizedBox(width: 4),
                        Text(
                          'Export CSV',
                          style: TextStyle(
                            color: Colors.white.withAlpha(200),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          if (alerts.isEmpty)
            Text(
              'No alerts yet',
              style: TextStyle(color: Colors.white.withAlpha(153), fontSize: 12),
            )
          else
            ...groups.take(5).map((group) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _AlertGroupRow(group: group),
                )),
        ],
      ),
    );
  }
}

/// Renders a single grouped alert row.
///
/// When [group.count] > 1, the title is prefixed with the count
/// ("3x CAUTION: soil_creep pattern detected") and the relative
/// time shows the span from first to last alert in the group.
class _AlertGroupRow extends StatelessWidget {
  final _AlertGroup group;

  const _AlertGroupRow({required this.group});

  Color _dotColor() {
    switch (group.level) {
      case AlertLevel.critical:
        return const Color(0xFFE53935);
      case AlertLevel.warning:
        return const Color(0xFFFFB300);
      case AlertLevel.ok:
        return const Color(0xFF43A047);
    }
  }

  String get _displayTitle {
    final base = group.first.title;
    if (group.count == 1) return base;
    return '${group.count}x $base';
  }

  String get _displayTime {
    if (group.count == 1) {
      return _relativeTime(group.first.timestamp, fallback: group.first.time);
    }
    // Show span: "3m ago – just now" or just the latest time
    final latest = _relativeTime(group.last.timestamp, fallback: group.last.time);
    final oldest = _relativeTime(group.first.timestamp, fallback: group.first.time);
    if (oldest == latest) return latest;
    return '$oldest – $latest';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Time column
        SizedBox(
          width: 72,
          child: Text(
            _displayTime,
            style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 11),
          ),
        ),
        const SizedBox(width: 6),
        // Colored dot
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(color: _dotColor(), shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        // Title + message
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _displayTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  // Count badge for grouped alerts
                  if (group.count > 1)
                    Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: _dotColor().withAlpha(60),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _dotColor().withAlpha(120), width: 1),
                      ),
                      child: Text(
                        '${group.count}',
                        style: TextStyle(
                          color: _dotColor(),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                group.first.message,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Legacy row widget kept for callers that construct [AlertRow] directly.
class AlertRow extends StatelessWidget {
  final String time;
  final AlertLevel level;
  final String title;
  final String trench;
  final String message;

  /// Optional machine timestamp for relative-time display.
  final DateTime? timestamp;

  const AlertRow({
    super.key,
    required this.time,
    required this.level,
    required this.title,
    required this.trench,
    required this.message,
    this.timestamp,
  });

  Color _dotColor() {
    switch (level) {
      case AlertLevel.critical:
        return const Color(0xFFE53935);
      case AlertLevel.warning:
        return const Color(0xFFFFB300);
      case AlertLevel.ok:
        return const Color(0xFF43A047);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayTime = _relativeTime(timestamp, fallback: time);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(displayTime, style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 11)),
        const SizedBox(width: 10),
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(color: _dotColor(), shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$title • $trench',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(message, style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

class SafetyInsightCard extends StatelessWidget {
  const SafetyInsightCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Safety Thresholds',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 6),
          Text(
            '• Soil Moisture: 30-60% is safe range\n'
            '• Vibration: <0.3g stable, >0.8g critical\n'
            '• Connect M5StickC Plus 2 for live monitoring',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
