import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Central service for Firestore cloud database operations
/// Hybrid approach: Cloud when logged in, local SharedPreferences when not
/// All user data is stored under users/{userId}/... in Firestore
class CloudDatabaseService {
  static final CloudDatabaseService _instance = CloudDatabaseService._internal();
  factory CloudDatabaseService() => _instance;
  CloudDatabaseService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

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
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('progress')
          .doc('stats')
          .set(data, SetOptions(merge: true));
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
  Future<void> saveDailyStats(String dateKey, Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('progress')
          .doc('daily')
          .collection('days')
          .doc(dateKey)
          .set(data, SetOptions(merge: true));
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
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('settings')
          .doc('app')
          .set(data, SetOptions(merge: true));
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
      return snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (e) {
      debugPrint('Error getting journal entries: $e');
      return [];
    }
  }

  /// Add journal entry
  Future<String?> addJournalEntry(Map<String, dynamic> data) async {
    if (userId == null) return null;
    try {
      final docRef = await _firestore
          .collection('users')
          .doc(userId)
          .collection('journal')
          .add(data);
      return docRef.id;
    } catch (e) {
      debugPrint('Error adding journal entry: $e');
      return null;
    }
  }

  /// Update journal entry
  Future<void> updateJournalEntry(String id, Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('journal')
          .doc(id)
          .update(data);
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
      return snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (e) {
      debugPrint('Error getting voice notes: $e');
      return [];
    }
  }

  /// Add voice note
  Future<String?> addVoiceNote(Map<String, dynamic> data) async {
    if (userId == null) return null;
    try {
      final docRef = await _firestore
          .collection('users')
          .doc(userId)
          .collection('voiceNotes')
          .add(data);
      return docRef.id;
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
      return snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (e) {
      debugPrint('Error getting weather logs: $e');
      return [];
    }
  }

  /// Add weather log
  Future<String?> addWeatherLog(Map<String, dynamic> data) async {
    if (userId == null) return null;
    try {
      final docRef = await _firestore
          .collection('users')
          .doc(userId)
          .collection('weatherLogs')
          .add(data);
      return docRef.id;
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
      return snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
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
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('settings')
          .doc('notifications')
          .set(data, SetOptions(merge: true));
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
      return snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (e) {
      debugPrint('Error getting notification history: $e');
      return [];
    }
  }

  /// Add notification to history
  Future<void> addNotification(Map<String, dynamic> data) async {
    if (userId == null) return;
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .add(data);
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
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('settings')
          .doc('preferences')
          .set(data, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error saving preferences: $e');
    }
  }

  // ============== UTILITY ==============

  /// Clear all user data (for logout/account deletion)
  Future<void> clearAllUserData() async {
    if (userId == null) return;
    try {
      // Delete subcollections
      final collections = ['progress', 'journal', 'voiceNotes', 'weatherLogs', 'notifications', 'settings'];
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
      final end = (i + batchLimit < docs.length) ? i + batchLimit : docs.length;
      for (int j = i; j < end; j++) {
        batch.delete(docs[j].reference);
      }
      await batch.commit();
    }
  }
}
