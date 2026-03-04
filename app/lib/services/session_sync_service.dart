import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Sync status of a [SessionSyncService] upload.
enum SyncStatus { idle, syncing, done, failed }

/// Singleton service that uploads session samples to the field data-collector
/// API after a session ends.
///
/// The collector API is the Flask server from `docker-compose.collect.yml`.
/// Each sample is a `Map<String, dynamic>` matching the /collect endpoint
/// schema (the same format produced by `vibration_dsp_service.dart`):
///
/// ```json
/// {
///   "timestamp": "2026-03-04T12:00:00.000Z",
///   "ppv": 0.12,
///   "rms": 0.034,
///   "freq": 15.2,
///   "kurtosis": 3.1,
///   "stalta": 1.8,
///   "anomaly_score": 0.42,
///   "anomaly_level": "normal",
///   "precursor_pattern": null,
///   "confidence": 0.91
/// }
/// ```
///
/// Usage:
/// ```dart
/// await SessionSyncService.instance.syncSession(samples,
///     collectorUrl: 'http://192.168.1.100:8765');
/// ```
class SessionSyncService {
  static final SessionSyncService instance = SessionSyncService._();
  SessionSyncService._();

  SyncStatus _status = SyncStatus.idle;

  /// Current upload status.
  SyncStatus get status => _status;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Upload [samples] to the /collect endpoint on [collectorUrl].
  ///
  /// Posts each sample individually.  On failure, retries the entire batch
  /// once.  Updates [status] throughout.  Never throws.
  Future<void> syncSession(
    List<Map<String, dynamic>> samples, {
    String collectorUrl = 'http://192.168.1.100:8765',
  }) async {
    if (samples.isEmpty) {
      debugPrint('[SessionSyncService] No samples to sync.');
      return;
    }

    _status = SyncStatus.syncing;
    debugPrint(
      '[SessionSyncService] Starting sync of ${samples.length} samples '
      'to $collectorUrl',
    );

    try {
      final success = await _uploadAll(samples, collectorUrl);
      if (!success) {
        debugPrint('[SessionSyncService] First attempt failed — retrying once.');
        final retry = await _uploadAll(samples, collectorUrl);
        _status = retry ? SyncStatus.done : SyncStatus.failed;
      } else {
        _status = SyncStatus.done;
      }
    } catch (e) {
      debugPrint('[SessionSyncService] syncSession error: $e');
      _status = SyncStatus.failed;
    }

    debugPrint('[SessionSyncService] Sync finished with status: $_status');
  }

  /// Reset status back to idle (e.g., after BLE reconnect or new session).
  void reset() {
    _status = SyncStatus.idle;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// POST all [samples] to `$baseUrl/collect`.
  ///
  /// Returns true if all requests succeeded (HTTP 200/201), false otherwise.
  Future<bool> _uploadAll(
    List<Map<String, dynamic>> samples,
    String baseUrl,
  ) async {
    final uri = Uri.parse('$baseUrl/collect');
    int failures = 0;

    for (final sample in samples) {
      try {
        final response = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(sample),
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode != 200 && response.statusCode != 201) {
          failures++;
          debugPrint(
            '[SessionSyncService] HTTP ${response.statusCode} for sample '
            'ts=${sample["timestamp"]}',
          );
        }
      } catch (e) {
        failures++;
        debugPrint('[SessionSyncService] Request failed: $e');
      }
    }

    if (failures > 0) {
      debugPrint(
        '[SessionSyncService] $failures/${samples.length} samples failed.',
      );
    }
    return failures == 0;
  }
}
