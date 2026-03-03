import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

/// Screen to view and export vibration safety alert history
class VibrationEventLogScreen extends StatelessWidget {
  const VibrationEventLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D3A39),
      appBar: AppBar(
        title: const Text('Safety Alert History'),
        backgroundColor: Colors.transparent,
        elevation: 0,
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

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.green, size: 64),
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

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              return _AlertTile(data: data);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _exportCSV(context),
        backgroundColor: const Color(0xFFFFC107),
        icon: const Icon(Icons.file_download, color: Colors.black),
        label: const Text('Export CSV', style: TextStyle(color: Colors.black)),
      ),
    );
  }

  Future<void> _exportCSV(BuildContext context) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('safety_alerts')
          .orderBy('timestamp', descending: true)
          .limit(500)
          .get();

      if (snapshot.docs.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No alerts to export')),
          );
        }
        return;
      }

      final buffer = StringBuffer();
      buffer.writeln('Timestamp,Level,Hazard Type,Message,PPV (mm/s),RMS (g),Frequency (Hz),Crest Factor,Kurtosis,STA/LTA,Latitude,Longitude,Device,Assessment');

      for (final doc in snapshot.docs) {
        final d = doc.data();
        final ts = d['timestamp'] as Timestamp?;
        final time = ts != null
            ? DateFormat('yyyy-MM-dd HH:mm:ss').format(ts.toDate())
            : 'Unknown';

        buffer.writeln([
          time,
          d['level'] ?? '',
          d['hazardType'] ?? '',
          '"${(d['message'] ?? '').toString().replaceAll('"', '""')}"',
          d['ppv']?.toStringAsFixed(2) ?? '',
          d['rms']?.toStringAsFixed(4) ?? '',
          d['freq']?.toStringAsFixed(1) ?? '',
          d['crest']?.toStringAsFixed(1) ?? '',
          d['kurtosis']?.toStringAsFixed(2) ?? '',
          d['staLta']?.toStringAsFixed(2) ?? '',
          d['latitude']?.toStringAsFixed(6) ?? '',
          d['longitude']?.toStringAsFixed(6) ?? '',
          d['deviceName'] ?? '',
          '"${(d['assessment'] ?? '').toString().replaceAll('"', '""')}"',
        ].join(','));
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/safety_alerts_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
      await file.writeAsString(buffer.toString());

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'AncientVision Safety Alert Log',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}

class _AlertTile extends StatelessWidget {
  final Map<String, dynamic> data;

  const _AlertTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final level = data['level']?.toString() ?? 'unknown';
    final hazard = data['hazardType']?.toString() ?? '';
    final ppv = data['ppv']?.toDouble() ?? 0.0;
    final ts = data['timestamp'] as Timestamp?;
    final hasGps = data['latitude'] != null && data['longitude'] != null;

    final isCritical = level == 'critical';
    final color = isCritical ? Colors.red : Colors.orange;
    final timeStr = ts != null
        ? DateFormat('MMM d, HH:mm:ss').format(ts.toDate())
        : 'Unknown time';

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
              Container(
                width: 8,
                height: 48,
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
                    Row(
                      children: [
                        Icon(
                          isCritical ? Icons.error : Icons.warning_amber,
                          color: color,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          level.toUpperCase(),
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        if (hazard.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            hazard,
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                        const Spacer(),
                        if (hasGps)
                          const Icon(Icons.location_on, color: Colors.green, size: 14),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'PPV: ${ppv.toStringAsFixed(1)} mm/s',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    Text(
                      timeStr,
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
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
              Text(timeStr, style: const TextStyle(color: Colors.white54)),
              const Divider(color: Colors.white24, height: 24),
              if (data['message'] != null)
                Text(
                  data['message'].toString(),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              const SizedBox(height: 12),
              _detailRow('Hazard Type', data['hazardType']?.toString() ?? 'N/A'),
              _detailRow('PPV', '${data['ppv']?.toStringAsFixed(2) ?? 'N/A'} mm/s'),
              _detailRow('RMS', '${data['rms']?.toStringAsFixed(4) ?? 'N/A'} g'),
              _detailRow('Frequency', '${data['freq']?.toStringAsFixed(1) ?? 'N/A'} Hz'),
              _detailRow('Crest Factor', data['crest']?.toStringAsFixed(1) ?? 'N/A'),
              if (data['kurtosis'] != null)
                _detailRow('Kurtosis', data['kurtosis'].toStringAsFixed(2)),
              if (data['staLta'] != null)
                _detailRow('STA/LTA', data['staLta'].toStringAsFixed(2)),
              if (data['latitude'] != null && data['longitude'] != null)
                _detailRow('Location', '${data['latitude'].toStringAsFixed(6)}, ${data['longitude'].toStringAsFixed(6)}'),
              _detailRow('Device', data['deviceName']?.toString() ?? 'N/A'),
              if (data['assessment'] != null && data['assessment'].toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  data['assessment'].toString(),
                  style: const TextStyle(color: Colors.white60, fontSize: 12, fontStyle: FontStyle.italic),
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
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
