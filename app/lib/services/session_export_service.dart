import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'critical_event_log_service.dart';

/// Exports session data as a CSV file and shares it via the OS share sheet.
class SessionExportService {
  SessionExportService._();
  static final SessionExportService instance = SessionExportService._();

  /// Export a list of sensor data records to CSV and open the share sheet.
  ///
  /// [records] is a list of maps with keys: timestamp, ppv, rms, freq,
  ///   kurtosis, stalta, score, level, precursor, confidence
  Future<void> exportSession(List<Map<String, dynamic>> records) async {
    if (records.isEmpty) return;

    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final file = File('${dir.path}/session_$ts.csv');

    final headers = [
      'timestamp', 'ppv', 'rms', 'freq', 'kurtosis', 'stalta',
      'anomaly_score', 'anomaly_level', 'precursor_pattern', 'confidence'
    ];

    final buffer = StringBuffer();
    buffer.writeln(headers.join(','));
    for (final rec in records) {
      final row = headers.map((h) {
        final val = rec[h];
        if (val == null) return '';
        final s = val.toString();
        return s.contains(',') ? '"$s"' : s;
      }).join(',');
      buffer.writeln(row);
    }

    await file.writeAsString(buffer.toString());
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: 'AncientVision Session Data $ts',
    );
  }

  /// Export critical events log as CSV and share via OS share sheet.
  ///
  /// Returns the path of the exported file, or null on failure.
  Future<String?> exportCriticalEvents({String? siteName}) async {
    try {
      final csv = CriticalEventLogService.instance.exportAsCsv();
      if (csv.isEmpty || csv.split('\n').length < 2) {
        return null; // nothing to export
      }

      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 19);
      final siteTag =
          siteName != null ? '_${siteName.replaceAll(' ', '_')}' : '';
      final filename = 'ancientvision${siteTag}_events_$timestamp.csv';
      final file = File('${dir.path}/$filename');
      await file.writeAsString(csv);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject:
            'AncientVision Event Log${siteName != null ? " — $siteName" : ""}',
        text:
            'Exported ${CriticalEventLogService.instance.totalEvents} critical events',
      );

      return file.path;
    } catch (e) {
      debugPrint('[SessionExport] Export failed: $e');
      return null;
    }
  }

  /// Check if there is anything to export.
  bool get hasData => CriticalEventLogService.instance.totalEvents > 0;

  /// Total critical event count.
  int get eventCount => CriticalEventLogService.instance.totalEvents;
}
