import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'connectivity_monitor_service.dart';

/// Central service for Firestore cloud database operations
/// Hybrid approach: Cloud when logged in, local SharedPreferences when not
/// All user data is stored under users/{userId}/... in Firestore
///
/// Connectivity health tracking:
/// Call `ConnectivityMonitorService.instance.recordFirestoreResult(success: …)`
/// after each write attempt so the health score and failure counter stay
/// accurate.  This is intentionally left to callers rather than wired
/// directly here to avoid a circular service dependency.  Example:
/// ```dart
/// await cloudDb.saveProgressStats(data);
/// ConnectivityMonitorService.instance.recordFirestoreResult(success: true);
/// ```
class CloudDatabaseService {
  static final CloudDatabaseService _instance =
      CloudDatabaseService._internal();
  factory CloudDatabaseService() => _instance;
  CloudDatabaseService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ============== RETRY QUEUE ==============

  /// In-memory retry queue for failed writes (max 50 items).
  final List<Map<String, dynamic>> _retryQueue = [];
  static const int _retryQueueMaxSize = 50;

  /// Number of items currently waiting for retry.
  int get retryQueueSize => _retryQueue.length;

  // ============== RATE LIMITING ==============

  int _writesThisSecond = 0;
  DateTime _secondStart = DateTime.now();
  static const int _maxWritesPerSecond = 10;

  // ============== UPLOAD STATISTICS ==============

  int _totalUploaded = 0;
  int _totalFailed = 0;

  /// Cumulative successful writes since app start.
  int get totalUploaded => _totalUploaded;

  /// Cumulative failed writes since app start.
  int get totalFailed => _totalFailed;

  /// Success rate: totalUploaded / (totalUploaded + totalFailed).
  /// Returns 0.0 if no writes have been attempted.
  double get successRate {
    final total = _totalUploaded + _totalFailed;
    if (total == 0) return 0.0;
    return _totalUploaded / total;
  }

  // ============== CORE WRITE HELPERS ==============

  /// Resets the writes-per-second counter when a new second has elapsed.
  void _tickRateWindow() {
    final now = DateTime.now();
    if (now.difference(_secondStart).inSeconds >= 1) {
      _secondStart = now;
      _writesThisSecond = 0;
    }
  }

  /// Returns true if a write token was consumed within the rate limit.
  bool _acquireWriteToken() {
    _tickRateWindow();
    if (_writesThisSecond >= _maxWritesPerSecond) {
      return false;
    }
    _writesThisSecond++;
    return true;
  }

  /// Waits until the current rate-limit window expires and resets the counter.
  Future<void> _waitForNextWindow() async {
    final ms =
        1000 - DateTime.now().difference(_secondStart).inMilliseconds;
    await Future<void>.delayed(Duration(milliseconds: ms.clamp(0, 1000)));
    _secondStart = DateTime.now();
    _writesThisSecond = 1; // count the write we are about to do
  }

  /// True when Firestore is likely reachable.
  bool get _networkAvailable =>
      ConnectivityMonitorService.instance.isNetworkConnected;

  /// Adds a failed write to the retry queue (drops oldest when full).
  void _enqueueRetry({
    required String collection,
    required String? docId,
    required Map<String, dynamic> data,
    required bool merge,
  }) {
    if (_retryQueue.length >= _retryQueueMaxSize) {
      _retryQueue.removeAt(0);
    }
    _retryQueue.add(<String, dynamic>{
      'collection': collection,
      'docId': docId,
      'data': data,
      'merge': merge,
    });
  }

  /// Attempts to flush the oldest queued item after a successful write.
  Future<void> _flushOneRetryItem() async {
    if (_retryQueue.isEmpty || !_networkAvailable) return;
    if (!_acquireWriteToken()) return;

    final item = _retryQueue.first;
    try {
      final collection = item['collection'] as String;
      final docId = item['docId'] as String?;
      final data = item['data'] as Map<String, dynamic>;
      final merge = (item['merge'] as bool?) ?? true;
      final colRef = _firestore.collection(collection);
      if (docId != null) {
        await colRef.doc(docId).set(data, SetOptions(merge: merge));
      } else {
        await colRef.add(data);
      }
      _retryQueue.removeAt(0);
      _totalUploaded++;
      if (kDebugMode) {
        debugPrint(
            '[CloudDatabaseService] Retry flush succeeded. '
            'Queue: ${_retryQueue.length}');
      }
    } catch (e) {
      // Keep item in queue for the next flush attempt.
      if (kDebugMode) {
        debugPrint('[CloudDatabaseService] Retry flush failed: $e');
      }
    }
  }

  /// Performs a Firestore set/merge with rate limiting, connection awareness,
  /// retry queue, and statistics tracking.
  Future<void> _safeSet(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> data, {
    bool merge = true,
  }) async {
    // Derive a collection path string for the retry queue entry.
    final parts = ref.path.split('/');
    final collectionPath = parts.take(parts.length - 1).join('/');

    if (!_networkAvailable) {
      _totalFailed++;
      _enqueueRetry(
        collection: collectionPath,
        docId: ref.id,
        data: data,
        merge: merge,
      );
      if (kDebugMode) {
        debugPrint(
            '[CloudDatabaseService] Offline — queued write to ${ref.path}');
      }
      return;
    }

    if (!_acquireWriteToken()) {
      await _waitForNextWindow();
    }

    try {
      await ref.set(data, SetOptions(merge: merge));
      _totalUploaded++;
      await _flushOneRetryItem();
    } catch (e) {
      _totalFailed++;
      _enqueueRetry(
        collection: collectionPath,
        docId: ref.id,
        data: data,
        merge: merge,
      );
      if (kDebugMode) {
        debugPrint(
            '[CloudDatabaseService] Write failed, queued for retry: $e');
      }
      rethrow;
    }
  }

  /// Performs a Firestore add with rate limiting, connection awareness,
  /// retry queue, and statistics tracking.
  Future<String?> _safeAdd(
    CollectionReference<Map<String, dynamic>> ref,
    Map<String, dynamic> data,
  ) async {
    if (!_networkAvailable) {
      _totalFailed++;
      _enqueueRetry(
        collection: ref.path,
        docId: null,
        data: data,
        merge: false,
      );
      if (kDebugMode) {
        debugPrint(
            '[CloudDatabaseService] Offline — queued add to ${ref.path}');
      }
      return null;
    }

    if (!_acquireWriteToken()) {
      await _waitForNextWindow();
    }

    try {
      final docRef = await ref.add(data);
      _totalUploaded++;
      await _flushOneRetryItem();
      return docRef.id;
    } catch (e) {
      _totalFailed++;
      _enqueueRetry(
        collection: ref.path,
        docId: null,
        data: data,
        merge: false,
      );
      if (kDebugMode) {
        debugPrint(
            '[CloudDatabaseService] Add failed, queued for retry: $e');
      }
      rethrow;
    }
  }

  // ============== BATCH UPLOAD ==============

  /// Uploads a list of items to Firestore using WriteBatch operations.
  ///
  /// Each item must contain a `_collection` key with the name of the
  /// subcollection under the current user's document.  An optional `_docId`
  /// key specifies the document ID; if absent, Firestore auto-generates one.
  /// All other keys are written as document fields.
  ///
  /// Batches are limited to 500 operations automatically.  Returns the total
  /// number of items successfully committed.
  Future<int> batchUpload(List<Map<String, dynamic>> items) async {
    if (userId == null || items.isEmpty) return 0;

    int written = 0;
    const batchLimit = 500;

    for (int i = 0; i < items.length; i += batchLimit) {
      final end =
          (i + batchLimit < items.length) ? i + batchLimit : items.length;
      final chunk = items.sublist(i, end);
      final batch = _firestore.batch();

      for (final item in chunk) {
        final collectionName = item['_collection'] as String?;
        if (collectionName == null) continue;
        final docId = item['_docId'] as String?;
        final data = Map<String, dynamic>.from(item)
          ..remove('_collection')
          ..remove('_docId');
        final colRef = _firestore
            .collection('users')
            .doc(userId)
            .collection(collectionName);
        final ref = docId != null ? colRef.doc(docId) : colRef.doc();
        batch.set(ref, data, SetOptions(merge: true));
      }

      try {
        await batch.commit();
        written += chunk.length;
        _totalUploaded += chunk.length;
        if (kDebugMode) {
          debugPrint(
              '[CloudDatabaseService] Batch commit: ${chunk.length} items');
        }
      } catch (e) {
        _totalFailed += chunk.length;
        if (kDebugMode) {
          debugPrint('[CloudDatabaseService] Batch commit failed: $e');
        }
        // Queue individual items for later retry.
        for (final item in chunk) {
          final collectionName = item['_collection'] as String?;
          if (collectionName == null) continue;
          final docId = item['_docId'] as String?;
          final data = Map<String, dynamic>.from(item)
            ..remove('_collection')
            ..remove('_docId');
          _enqueueRetry(
            collection: 'users/$userId/$collectionName',
            docId: docId,
            data: data,
            merge: true,
          );
        }
      }
    }
    return written;
  }

  // ============== IDENTITY HELPERS ==============

  /// Get current user ID (null if not logged in)
  String? get userId => _auth.currentUser?.uid;

  /// Check if user is logged in
  bool get isLoggedIn => _auth.currentUser != null;

  /// Check if we should use cloud storage (only when logged in)
  bool get useCloud => isLoggedIn;

  /// Get user document reference
  DocumentReference<Map<String, dynamic>>? get userDoc {
    if (userId == null) return null;
    return _firestore.collection('users').doc(userId);
  }

  /// Get a subcollection under the user's document
  CollectionReference<Map<String, dynamic>>? getUserCollection(String name) {
    if (userId == null) return null;
    return _firestore.collection('users').doc(userId).collection(name);
  }

  // ============== PROGRESS ==============

  /// Get progress stats document
  Future<Map<String, dynamic>?> getProgressStats() async {
    if (userId == null) return null;
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .collection('progress')
          .doc('stats')
          .get();
      return doc.data();
    } catch (e) {
      debugPrint('Error getting progress stats: $e');
      return null;
    }
  }

  /// Save progress stats
  Future<void> saveProgressStats(Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _safeSet(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('progress')
            .doc('stats'),
        data,
      );
    } catch (e) {
      debugPrint('Error saving progress stats: $e');
    }
  }

  /// Get daily stats for a specific date
  Future<Map<String, dynamic>?> getDailyStats(String dateKey) async {
    if (userId == null) return null;
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .collection('progress')
          .doc('daily')
          .collection('days')
          .doc(dateKey)
          .get();
      return doc.data();
    } catch (e) {
      debugPrint('Error getting daily stats: $e');
      return null;
    }
  }

  /// Save daily stats
  Future<void> saveDailyStats(
      String dateKey, Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _safeSet(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('progress')
            .doc('daily')
            .collection('days')
            .doc(dateKey),
        data,
      );
    } catch (e) {
      debugPrint('Error saving daily stats: $e');
    }
  }

  /// Get weekly stats (last 7 days)
  Future<List<Map<String, dynamic>>> getWeeklyStats() async {
    if (userId == null) return [];
    try {
      final now = DateTime.now();
      final weekAgo = now.subtract(const Duration(days: 7));

      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('progress')
          .doc('daily')
          .collection('days')
          .where('date', isGreaterThanOrEqualTo: weekAgo.toIso8601String())
          .orderBy('date')
          .get();

      return snapshot.docs.map((doc) => doc.data()).toList();
    } catch (e) {
      debugPrint('Error getting weekly stats: $e');
      return [];
    }
  }

  // ============== SETTINGS ==============

  /// Get app settings
  Future<Map<String, dynamic>?> getSettings() async {
    if (userId == null) return null;
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .collection('settings')
          .doc('app')
          .get();
      return doc.data();
    } catch (e) {
      debugPrint('Error getting settings: $e');
      return null;
    }
  }

  /// Save app settings
  Future<void> saveSettings(Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _safeSet(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('settings')
            .doc('app'),
        data,
      );
    } catch (e) {
      debugPrint('Error saving settings: $e');
    }
  }

  /// Listen to settings changes (for cross-device sync)
  Stream<Map<String, dynamic>?> settingsStream() {
    if (userId == null) return Stream.value(null);
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('settings')
        .doc('app')
        .snapshots()
        .map((doc) => doc.data());
  }

  // ============== JOURNAL ==============

  /// Get all journal entries
  Future<List<Map<String, dynamic>>> getJournalEntries() async {
    if (userId == null) return [];
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('journal')
          .orderBy('createdAt', descending: true)
          .get();
      return snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
    } catch (e) {
      debugPrint('Error getting journal entries: $e');
      return [];
    }
  }

  /// Add journal entry
  Future<String?> addJournalEntry(Map<String, dynamic> data) async {
    if (userId == null) return null;
    try {
      return await _safeAdd(
        _firestore.collection('users').doc(userId).collection('journal'),
        data,
      );
    } catch (e) {
      debugPrint('Error adding journal entry: $e');
      return null;
    }
  }

  /// Update journal entry
  Future<void> updateJournalEntry(
      String id, Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _safeSet(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('journal')
            .doc(id),
        data,
      );
    } catch (e) {
      debugPrint('Error updating journal entry: $e');
    }
  }

  /// Delete journal entry
  Future<void> deleteJournalEntry(String id) async {
    if (userId == null) return;
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('journal')
          .doc(id)
          .delete();
    } catch (e) {
      debugPrint('Error deleting journal entry: $e');
    }
  }

  // ============== VOICE NOTES ==============

  /// Get all voice notes
  Future<List<Map<String, dynamic>>> getVoiceNotes() async {
    if (userId == null) return [];
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('voiceNotes')
          .orderBy('createdAt', descending: true)
          .get();
      return snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
    } catch (e) {
      debugPrint('Error getting voice notes: $e');
      return [];
    }
  }

  /// Add voice note
  Future<String?> addVoiceNote(Map<String, dynamic> data) async {
    if (userId == null) return null;
    try {
      return await _safeAdd(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('voiceNotes'),
        data,
      );
    } catch (e) {
      debugPrint('Error adding voice note: $e');
      return null;
    }
  }

  // ============== WEATHER LOGS ==============

  /// Get all weather logs
  Future<List<Map<String, dynamic>>> getWeatherLogs({int? limit}) async {
    if (userId == null) return [];
    try {
      var query = _firestore
          .collection('users')
          .doc(userId)
          .collection('weatherLogs')
          .orderBy('timestamp', descending: true);

      if (limit != null) {
        query = query.limit(limit);
      }

      final snapshot = await query.get();
      return snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
    } catch (e) {
      debugPrint('Error getting weather logs: $e');
      return [];
    }
  }

  /// Add weather log
  Future<String?> addWeatherLog(Map<String, dynamic> data) async {
    if (userId == null) return null;
    try {
      return await _safeAdd(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('weatherLogs'),
        data,
      );
    } catch (e) {
      debugPrint('Error adding weather log: $e');
      return null;
    }
  }

  /// Delete weather log
  Future<void> deleteWeatherLog(String id) async {
    if (userId == null) return;
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('weatherLogs')
          .doc(id)
          .delete();
    } catch (e) {
      debugPrint('Error deleting weather log: $e');
    }
  }

  /// Get weather logs for date range
  Future<List<Map<String, dynamic>>> getWeatherLogsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    if (userId == null) return [];
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('weatherLogs')
          .where('timestamp', isGreaterThanOrEqualTo: start.toIso8601String())
          .where('timestamp', isLessThanOrEqualTo: end.toIso8601String())
          .orderBy('timestamp', descending: true)
          .get();
      return snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
    } catch (e) {
      debugPrint('Error getting weather logs for date range: $e');
      return [];
    }
  }

  // ============== NOTIFICATIONS ==============

  /// Get notification settings
  Future<Map<String, dynamic>?> getNotificationSettings() async {
    if (userId == null) return null;
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .collection('settings')
          .doc('notifications')
          .get();
      return doc.data();
    } catch (e) {
      debugPrint('Error getting notification settings: $e');
      return null;
    }
  }

  /// Save notification settings
  Future<void> saveNotificationSettings(Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _safeSet(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('settings')
            .doc('notifications'),
        data,
      );
    } catch (e) {
      debugPrint('Error saving notification settings: $e');
    }
  }

  /// Get notification history
  Future<List<Map<String, dynamic>>> getNotificationHistory() async {
    if (userId == null) return [];
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .orderBy('timestamp', descending: true)
          .limit(50)
          .get();
      return snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
    } catch (e) {
      debugPrint('Error getting notification history: $e');
      return [];
    }
  }

  /// Add notification to history
  Future<void> addNotification(Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _safeAdd(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('notifications'),
        data,
      );
    } catch (e) {
      debugPrint('Error adding notification: $e');
    }
  }

  /// Clear notification history
  Future<void> clearNotificationHistory() async {
    if (userId == null) return;
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .get();
      await _batchDelete(snapshot.docs);
    } catch (e) {
      debugPrint('Error clearing notification history: $e');
    }
  }

  // ============== PREFERENCES ==============

  /// Get user preferences (backup settings, etc.)
  Future<Map<String, dynamic>?> getPreferences() async {
    if (userId == null) return null;
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .collection('settings')
          .doc('preferences')
          .get();
      return doc.data();
    } catch (e) {
      debugPrint('Error getting preferences: $e');
      return null;
    }
  }

  /// Save user preferences
  Future<void> savePreferences(Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _safeSet(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('settings')
            .doc('preferences'),
        data,
      );
    } catch (e) {
      debugPrint('Error saving preferences: $e');
    }
  }

  // ============== UTILITY ==============

  /// Clear all user data (for logout/account deletion)
  Future<void> clearAllUserData() async {
    if (userId == null) return;
    try {
      final collections = [
        'progress',
        'journal',
        'voiceNotes',
        'weatherLogs',
        'notifications',
        'settings',
      ];
      for (final collection in collections) {
        final snapshot = await _firestore
            .collection('users')
            .doc(userId)
            .collection(collection)
            .get();
        await _batchDelete(snapshot.docs);
      }
      debugPrint('All user data cleared');
    } catch (e) {
      debugPrint('Error clearing user data: $e');
    }
  }

  /// Delete documents in chunks of 500 to respect Firestore batch limits
  Future<void> _batchDelete(List<QueryDocumentSnapshot> docs) async {
    const batchLimit = 500;
    for (int i = 0; i < docs.length; i += batchLimit) {
      final batch = _firestore.batch();
      final end =
          (i + batchLimit < docs.length) ? i + batchLimit : docs.length;
      for (int j = i; j < end; j++) {
        batch.delete(docs[j].reference);
      }
      await batch.commit();
    }
  }
}
