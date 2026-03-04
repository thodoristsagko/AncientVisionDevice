import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'critical_event_log_service.dart';
import 'session_history_service.dart';

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

  // ---------------------------------------------------------------------------
  // Session-scoped CSV export (P51)
  // ---------------------------------------------------------------------------

  /// Fetches all [CriticalEvent] entries that fall within the time range of
  /// the session identified by [sessionId], builds a CSV with columns:
  ///   timestamp, ppv_mm_s, level, lat, lon, notes
  /// and writes it to a temp file.
  ///
  /// Returns the file path on success, or null if the session cannot be found
  /// or no events exist for that session.
  Future<String?> exportSessionCsv(String sessionId) async {
    try {
      // Look up the session record to get start / end times.
      final sessions = await SessionHistoryService.instance.getSessions();
      final sessionIndex = sessions.indexWhere((s) => s.id == sessionId);
      if (sessionIndex == -1) {
        debugPrint('[SessionExport] exportSessionCsv: session $sessionId not found');
        return null;
      }
      final session = sessions[sessionIndex];

      // Fetch critical events that fall within this session window.
      final events = await CriticalEventLogService.instance
          .getEventsBetween(session.start, session.end);

      // Build the CSV — include a header row even if no events exist so the
      // file is always a valid CSV that can be opened in a spreadsheet.
      final buffer = StringBuffer();
      buffer.writeln('timestamp,ppv_mm_s,level,lat,lon,notes');

      for (final ev in events) {
        final level = ev.ppv >= 1.0
            ? 'CRITICAL'
            : ev.ppv >= 0.3
                ? 'WARNING'
                : 'SAFE';
        final lat = ev.location?.latitude.toStringAsFixed(7) ?? '';
        final lon = ev.location?.longitude.toStringAsFixed(7) ?? '';
        // notes = cluster count if > 1, empty otherwise.
        final notes = ev.count > 1 ? 'cluster:${ev.count}' : '';

        buffer.writeln([
          ev.timestamp.toUtc().toIso8601String(),
          ev.ppv.toStringAsFixed(4),
          level,
          lat,
          lon,
          notes,
        ].join(','));
      }

      final dir = await getTemporaryDirectory();
      final safeId = sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final file = File('${dir.path}/session_${safeId}_events.csv');
      await file.writeAsString(buffer.toString());

      debugPrint('[SessionExport] exportSessionCsv: wrote ${events.length} events to ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[SessionExport] exportSessionCsv failed: $e');
      return null;
    }
  }

  /// Calls [exportSessionCsv] then opens the OS share sheet.
  ///
  /// Shows a debug message if the export fails or the session has no events.
  Future<void> shareSessionCsv(String sessionId) async {
    try {
      final path = await exportSessionCsv(sessionId);
      if (path == null) {
        debugPrint('[SessionExport] shareSessionCsv: nothing to share for $sessionId');
        return;
      }
      await Share.shareXFiles(
        [XFile(path, mimeType: 'text/csv')],
        subject: 'AncientVision Session Export',
      );
    } catch (e) {
      debugPrint('[SessionExport] shareSessionCsv failed: $e');
    }
  }
}
