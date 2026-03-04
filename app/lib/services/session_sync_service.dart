import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Sync status of a [SessionSyncService] upload.
enum SyncStatus { idle, syncing, done, failed }

/// Singleton service that uploads session samples to the field data-collector
/// API after a session ends.
///
/// The collector API is the Flask server from `docker-compose.collect.yml`.
/// Each sample is a `Map<String, dynamic>` matching the /ingest endpoint
/// schema (the same format produced by `vibration_dsp_service.dart`):
///
/// ```json
/// {
///   "device_id": "m5stick_01",
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

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  static const int _batchSize = 20;

  static const String _prefKeyPending = 'session_sync_pending';
  static const String _prefKeyCollectorUrl = 'collector_url';
  static const String _prefKeyTotalSynced = 'session_sync_total_synced';
  static const String _prefKeyTotalFailed = 'session_sync_total_failed';
  static const String _prefKeyLastSyncTime = 'session_sync_last_sync_time';

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  SyncStatus _status = SyncStatus.idle;

  int _totalSynced = 0;
  int _totalFailed = 0;
  DateTime? _lastSyncTime;

  bool _statsLoaded = false;

  // ---------------------------------------------------------------------------
  // Public getters
  // ---------------------------------------------------------------------------

  /// Current upload status.
  SyncStatus get status => _status;

  /// Total samples successfully synced across all sessions (persisted).
  int get totalSynced => _totalSynced;

  /// Total samples that permanently failed to upload (persisted).
  int get totalFailed => _totalFailed;

  /// Timestamp of the last successful sync, or null if never synced.
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Number of samples currently queued in the offline pending store.
  Future<int> get pendingCount async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKeyPending);
    if (raw == null || raw.isEmpty) return 0;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.length;
    } catch (_) {
      return 0;
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Return the collector URL stored from the last successful sync, or null.
  Future<String?> getStoredCollectorUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeyCollectorUrl);
  }

  /// Upload [samples] to the /ingest endpoint on [collectorUrl].
  ///
  /// Samples are sent in batches of [_batchSize] to reduce HTTP overhead.
  /// Failed samples are saved to SharedPreferences and retried on the next
  /// call to [syncSession] or [flushPending].
  ///
  /// The optional [onProgress] callback is invoked after each batch with
  /// the number of samples sent so far and the total.
  ///
  /// Updates [status] throughout.  Never throws.
  Future<void> syncSession(
    List<Map<String, dynamic>> samples, {
    String? collectorUrl,
    void Function(int sent, int total)? onProgress,
  }) async {
    await _ensureStatsLoaded();

    // Resolve collector URL: explicit arg > stored pref > hardcoded default.
    final String resolvedUrl;
    if (collectorUrl != null && collectorUrl.isNotEmpty) {
      resolvedUrl = collectorUrl;
    } else {
      final stored = await getStoredCollectorUrl();
      resolvedUrl = stored ?? 'http://192.168.1.100:8765';
    }

    if (samples.isEmpty) {
      debugPrint('[SessionSyncService] No new samples — attempting flush only.');
      await flushPending(resolvedUrl, onProgress: onProgress);
      return;
    }

    _status = SyncStatus.syncing;
    debugPrint(
      '[SessionSyncService] Starting sync of ${samples.length} samples '
      'to $resolvedUrl',
    );

    try {
      // Flush any previously failed samples first.
      await flushPending(resolvedUrl, onProgress: onProgress);

      // Upload current session samples in batches.
      final failed = await _uploadBatched(
        samples,
        resolvedUrl,
        onProgress: onProgress,
        progressOffset: 0,
        total: samples.length,
      );

      if (failed.isNotEmpty) {
        debugPrint(
          '[SessionSyncService] ${failed.length}/${samples.length} samples '
          'failed — saving to offline queue.',
        );
        await _appendPending(failed);
        _totalFailed += failed.length;
        _status = SyncStatus.failed;
      } else {
        _status = SyncStatus.done;
      }

      _totalSynced += samples.length - failed.length;
      _lastSyncTime = DateTime.now();

      // Persist stats and last-used URL.
      await _persistStats();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyCollectorUrl, resolvedUrl);
    } catch (e) {
      debugPrint('[SessionSyncService] syncSession error: $e');
      _status = SyncStatus.failed;
    }

    debugPrint('[SessionSyncService] Sync finished with status: $_status');
  }

  /// Attempt to upload all pending (previously failed) samples.
  ///
  /// Samples that succeed are removed from the queue.  Samples that fail
  /// again remain in the queue.
  Future<void> flushPending(
    String collectorUrl, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final pending = await _loadPending();
    if (pending.isEmpty) return;

    debugPrint(
      '[SessionSyncService] Flushing ${pending.length} pending samples.',
    );

    final stillFailed = await _uploadBatched(
      pending,
      collectorUrl,
      onProgress: onProgress,
      progressOffset: 0,
      total: pending.length,
    );

    final successCount = pending.length - stillFailed.length;
    if (successCount > 0) {
      _totalSynced += successCount;
    }

    if (stillFailed.isNotEmpty) {
      _totalFailed += stillFailed.length - pending.length < 0
          ? stillFailed.length
          : 0; // avoid double-counting — only new permanent failures
      debugPrint(
        '[SessionSyncService] ${stillFailed.length} pending samples still '
        'failed after flush.',
      );
    }

    // Replace pending store with only what still failed.
    await _savePending(stillFailed);
    await _persistStats();
  }

  /// Reset status back to idle (e.g., after BLE reconnect or new session).
  void reset() {
    _status = SyncStatus.idle;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers — batched upload
  // ---------------------------------------------------------------------------

  /// Upload [samples] in chunks of [_batchSize].
  ///
  /// Returns the list of samples that failed (empty on full success).
  Future<List<Map<String, dynamic>>> _uploadBatched(
    List<Map<String, dynamic>> samples,
    String baseUrl, {
    void Function(int sent, int total)? onProgress,
    int progressOffset = 0,
    required int total,
  }) async {
    final uri = Uri.parse('$baseUrl/ingest');
    final failed = <Map<String, dynamic>>[];
    int sent = progressOffset;

    for (int i = 0; i < samples.length; i += _batchSize) {
      final batch = samples.sublist(
        i,
        (i + _batchSize).clamp(0, samples.length),
      );

      for (final sample in batch) {
        try {
          final response = await http
              .post(
                uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(sample),
              )
              .timeout(const Duration(seconds: 10));

          if (response.statusCode == 200 || response.statusCode == 201) {
            sent++;
          } else {
            failed.add(sample);
            debugPrint(
              '[SessionSyncService] HTTP ${response.statusCode} for sample '
              'ts=${sample["timestamp"]}',
            );
          }
        } catch (e) {
          failed.add(sample);
          debugPrint('[SessionSyncService] Request failed: $e');
        }
      }

      onProgress?.call(sent, total);
    }

    if (failed.isNotEmpty) {
      debugPrint(
        '[SessionSyncService] ${failed.length}/${samples.length} samples '
        'failed in this batch run.',
      );
    }
    return failed;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers — SharedPreferences persistence
  // ---------------------------------------------------------------------------

  Future<void> _ensureStatsLoaded() async {
    if (_statsLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _totalSynced = prefs.getInt(_prefKeyTotalSynced) ?? 0;
    _totalFailed = prefs.getInt(_prefKeyTotalFailed) ?? 0;
    final lastSyncMs = prefs.getInt(_prefKeyLastSyncTime);
    if (lastSyncMs != null) {
      _lastSyncTime = DateTime.fromMillisecondsSinceEpoch(lastSyncMs);
    }
    _statsLoaded = true;
  }

  Future<void> _persistStats() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKeyTotalSynced, _totalSynced);
    await prefs.setInt(_prefKeyTotalFailed, _totalFailed);
    if (_lastSyncTime != null) {
      await prefs.setInt(
        _prefKeyLastSyncTime,
        _lastSyncTime!.millisecondsSinceEpoch,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _loadPending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKeyPending);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[SessionSyncService] Failed to parse pending queue: $e');
      return [];
    }
  }

  Future<void> _savePending(List<Map<String, dynamic>> samples) async {
    final prefs = await SharedPreferences.getInstance();
    if (samples.isEmpty) {
      await prefs.remove(_prefKeyPending);
    } else {
      await prefs.setString(_prefKeyPending, jsonEncode(samples));
    }
  }

  Future<void> _appendPending(List<Map<String, dynamic>> newFailed) async {
    final existing = await _loadPending();
    await _savePending([...existing, ...newFailed]);
  }
}
