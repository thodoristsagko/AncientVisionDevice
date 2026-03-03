import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing local push notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Notification channel for Android
  static const String _channelId = 'ancient_vision_channel';
  static const String _channelName = 'AncientVision Notifications';
  static const String _channelDescription = 'Notifications for 3D reconstruction status';

  // Notification IDs
  static const int processingCompleteId = 1;
  static const int processingFailedId = 2;
  static const int uploadProgressId = 3;
  static const int achievementUnlockedId = 4;
  static const int safetyWarningId = 5;
  static const int safetyCriticalId = 6;
  static const int deviceDisconnectedId = 7;

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_initialized) return;

    // Android initialization settings
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS initialization settings
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create notification channel for Android
    await _createNotificationChannel();

    _initialized = true;
    debugPrint('NotificationService initialized');
  }

  /// Create Android notification channel
  Future<void> _createNotificationChannel() async {
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('Notification tapped: ${response.payload}');
    // Navigation can be handled here if needed
  }

  /// Request notification permissions
  Future<bool> requestPermissions() async {
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }

    final ios = _notifications.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();

    if (ios != null) {
      final granted = await ios.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    return true;
  }

  /// Check if notifications are enabled
  Future<bool> areNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('notifications_enabled') ?? true;
  }

  /// Set notifications enabled/disabled
  Future<void> setNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', enabled);
  }

  /// Show notification when 3D processing is complete
  Future<void> showProcessingComplete({
    required String projectName,
    int? pointCount,
  }) async {
    if (!await areNotificationsEnabled()) return;

    final body = pointCount != null
        ? 'Your 3D model "$projectName" is ready with $pointCount points!'
        : 'Your 3D model "$projectName" is ready to view!';

    await _showNotification(
      id: processingCompleteId,
      title: '3D Model Ready!',
      body: body,
      payload: 'processing_complete:$projectName',
    );

    // Save to notification history
    await _saveNotification(
      title: '3D Model Ready!',
      body: body,
      type: 'success',
    );
  }

  /// Show notification when processing fails
  Future<void> showProcessingFailed({
    required String projectName,
    String? errorMessage,
  }) async {
    if (!await areNotificationsEnabled()) return;

    final body = errorMessage ?? 'Processing failed for "$projectName". Please try again.';

    await _showNotification(
      id: processingFailedId,
      title: 'Processing Failed',
      body: body,
      payload: 'processing_failed:$projectName',
    );

    await _saveNotification(
      title: 'Processing Failed',
      body: body,
      type: 'error',
    );
  }

  /// Show upload progress notification
  Future<void> showUploadProgress({
    required int current,
    required int total,
    required String projectName,
  }) async {
    if (!await areNotificationsEnabled()) return;

    await _showProgressNotification(
      id: uploadProgressId,
      title: 'Uploading Photos',
      body: 'Uploading $current of $total photos for "$projectName"',
      progress: current,
      maxProgress: total,
    );
  }

  /// Cancel upload progress notification
  Future<void> cancelUploadProgress() async {
    await _notifications.cancel(uploadProgressId);
  }

  /// Show notification when achievement is unlocked
  Future<void> showAchievementUnlocked({
    required String achievementTitle,
    required String achievementDescription,
  }) async {
    if (!await areNotificationsEnabled()) return;

    await _showNotification(
      id: achievementUnlockedId,
      title: '🏆 Achievement Unlocked!',
      body: '$achievementTitle - $achievementDescription',
      payload: 'achievement:$achievementTitle',
    );

    await _saveNotification(
      title: 'Achievement Unlocked!',
      body: '$achievementTitle - $achievementDescription',
      type: 'achievement',
    );
  }

  /// Show safety warning notification
  Future<void> showSafetyWarning({
    required String message,
    String? sensorType,
  }) async {
    if (!await areNotificationsEnabled()) return;

    final body = sensorType != null
        ? '⚠️ $sensorType: $message'
        : '⚠️ $message';

    await _showUrgentNotification(
      id: safetyWarningId,
      title: 'Safety Warning',
      body: body,
      payload: 'safety_warning:$message',
      isWarning: true,
    );

    await _saveNotification(
      title: 'Safety Warning',
      body: body,
      type: 'warning',
    );
  }

  /// Show critical safety alert notification (highest priority)
  Future<void> showSafetyCritical({
    required String message,
    String? sensorType,
  }) async {
    if (!await areNotificationsEnabled()) return;

    final body = sensorType != null
        ? '🚨 CRITICAL - $sensorType: $message'
        : '🚨 CRITICAL: $message';

    await _showUrgentNotification(
      id: safetyCriticalId,
      title: 'CRITICAL SAFETY ALERT',
      body: body,
      payload: 'safety_critical:$message',
      isWarning: false,
    );

    await _saveNotification(
      title: 'CRITICAL SAFETY ALERT',
      body: body,
      type: 'critical',
    );
  }

  /// Show device disconnection notification
  Future<void> showDeviceDisconnected({
    required String deviceName,
  }) async {
    if (!await areNotificationsEnabled()) return;

    await _showNotification(
      id: deviceDisconnectedId,
      title: 'Sensor Disconnected',
      body: '$deviceName has been disconnected. Attempting to reconnect...',
      payload: 'device_disconnected:$deviceName',
    );

    await _saveNotification(
      title: 'Sensor Disconnected',
      body: '$deviceName has been disconnected',
      type: 'warning',
    );
  }

  /// Show urgent notification with vibration and sound
  Future<void> _showUrgentNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    required bool isWarning,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.max,
      priority: Priority.max,
      icon: '@mipmap/ic_launcher',
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      enableVibration: true,
      vibrationPattern: isWarning
          ? Int64List.fromList([0, 500, 200, 500])
          : Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
      playSound: true,
      enableLights: true,
      ledColor: isWarning ? const Color(0xFFFFB300) : const Color(0xFFE53935),
      ledOnMs: 1000,
      ledOffMs: 500,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
      interruptionLevel: InterruptionLevel.critical,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(id, title, body, details, payload: payload);
  }

  /// Show a standard notification
  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(id, title, body, details, payload: payload);
  }

  /// Show a progress notification (for uploads)
  Future<void> _showProgressNotification({
    required int id,
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: maxProgress,
      progress: progress,
      ongoing: true,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails();

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(id, title, body, details);
  }

  /// Save notification to history
  Future<void> _saveNotification({
    required String title,
    required String body,
    required String type,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('notification_history') ?? [];

    final notification = jsonEncode({
      'type': type,
      'timestamp': DateTime.now().toIso8601String(),
      'title': title,
      'body': body,
    });

    // Add to end instead of beginning to avoid O(N) insert(0)
    history.add(notification);

    // Keep only last 50 notifications (remove from beginning if needed)
    if (history.length > 50) {
      history.removeRange(0, history.length - 50);
    }

    await prefs.setStringList('notification_history', history);
  }

  /// Get notification history
  Future<List<NotificationItem>> getNotificationHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('notification_history') ?? [];

    // Reverse to get newest first (since we now store oldest-first)
    return history.reversed.map((item) {
      try {
        // Try JSON format first (new format)
        final map = jsonDecode(item) as Map<String, dynamic>;
        return NotificationItem(
          type: map['type'] as String? ?? 'unknown',
          timestamp: DateTime.tryParse(map['timestamp'] as String? ?? '') ?? DateTime.now(),
          title: map['title'] as String? ?? 'Unknown',
          body: map['body'] as String? ?? '',
        );
      } catch (_) {
        // Fall back to legacy pipe-delimited format
        final parts = item.split('|');
        if (parts.length >= 4) {
          return NotificationItem(
            type: parts[0],
            timestamp: DateTime.tryParse(parts[1]) ?? DateTime.now(),
            title: parts[2],
            body: parts.sublist(3).join('|'),
          );
        }
        return NotificationItem(
          type: 'unknown',
          timestamp: DateTime.now(),
          title: 'Unknown',
          body: item,
        );
      }
    }).toList();
  }

  /// Clear notification history
  Future<void> clearNotificationHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('notification_history');
  }

  /// Get unread notification count
  Future<int> getUnreadCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('unread_notifications') ?? 0;
  }

  /// Increment unread count
  Future<void> incrementUnreadCount() async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt('unread_notifications') ?? 0;
    await prefs.setInt('unread_notifications', current + 1);
  }

  /// Clear unread count
  Future<void> clearUnreadCount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('unread_notifications', 0);
  }
}

/// Represents a notification item in history
class NotificationItem {
  final String type;
  final DateTime timestamp;
  final String title;
  final String body;

  NotificationItem({
    required this.type,
    required this.timestamp,
    required this.title,
    required this.body,
  });

  bool get isSuccess => type == 'success';
  bool get isError => type == 'error';

  String get timeAgo {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
  }
}
