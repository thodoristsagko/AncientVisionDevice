import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Singleton service for showing OS-level local notifications.
///
/// Used for safety-critical alerts (anomaly detection, critical PPV thresholds).
/// Wraps flutter_local_notifications with try/catch guards — never crashes if
/// the notification subsystem is unavailable.
class LocalNotificationService {
  static final LocalNotificationService instance = LocalNotificationService._();
  LocalNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  // Android notification channel
  static const String _channelId = 'av_safety_channel';
  static const String _channelName = 'AncientVision Safety Alerts';
  static const String _channelDescription =
      'Critical safety notifications for vibration hazard detection';

  // Notification IDs
  static const int _anomalyAlertId = 1001;
  static const int _criticalAlertId = 1002;

  /// Initialise the notification plugin.  Safe to call multiple times.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinInit = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const initSettings = InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
      );

      await _plugin.initialize(initSettings);

      // Create high-importance Android channel for safety alerts
      const androidChannel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.max,
        enableVibration: true,
        playSound: true,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);

      _initialized = true;
      debugPrint('[LocalNotificationService] Initialized successfully.');
    } catch (e) {
      debugPrint('[LocalNotificationService] Initialization failed: $e');
      // Continue in stub mode — notifications will fall back to debugPrint.
    }
  }

  /// Show a general anomaly or safety alert notification.
  Future<void> showAnomalyAlert({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) {
      debugPrint('[LocalNotificationService] ALERT — $title: $body');
      return;
    }
    try {
      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        ticker: 'AncientVision Safety Alert',
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
        macOS: iosDetails,
      );
      await _plugin.show(
        _anomalyAlertId,
        title,
        body,
        details,
        payload: payload,
      );
    } catch (e) {
      debugPrint(
          '[LocalNotificationService] showAnomalyAlert failed: $e — $title: $body');
    }
  }

  /// Convenience method for imminent-hazard critical alerts.
  ///
  /// Fires a max-importance OS notification with evacuation instructions.
  Future<void> showCriticalAlert({required double ppv}) async {
    await showAnomalyAlert(
      title: 'CRITICAL: Imminent Hazard',
      body: 'PPV ${ppv.toStringAsFixed(3)} mm/s — EVACUATE AREA',
    );

    // Also show a second distinct notification so it is not overwritten
    // by a subsequent anomaly alert on the same ID.
    if (!_initialized) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true,
        ticker: 'CRITICAL HAZARD',
        color: Color(0xFFD32F2F),
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
        macOS: iosDetails,
      );
      await _plugin.show(
        _criticalAlertId,
        'CRITICAL: Imminent Hazard',
        'PPV ${ppv.toStringAsFixed(3)} mm/s — EVACUATE AREA',
        details,
      );
    } catch (e) {
      debugPrint('[LocalNotificationService] showCriticalAlert failed: $e');
    }
  }

  /// Cancel all pending / displayed notifications.
  Future<void> cancelAll() async {
    if (!_initialized) return;
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('[LocalNotificationService] cancelAll failed: $e');
    }
  }
}
