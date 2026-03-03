import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background service to keep the app running when minimized
class BackgroundServiceManager {
  static final BackgroundServiceManager _instance = BackgroundServiceManager._internal();
  factory BackgroundServiceManager() => _instance;
  BackgroundServiceManager._internal();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isInitialized = false;

  /// Initialize the background service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Create notification channel for Android
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'ancient_vision_background',
      'AncientVision Background Service',
      description: 'Keeps AncientVision running for data sync and GPS tracking',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: 'ancient_vision_background',
        initialNotificationTitle: 'AncientVision',
        initialNotificationContent: 'Field session active',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [
          AndroidForegroundType.dataSync,
          AndroidForegroundType.location,
        ],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    _isInitialized = true;
  }

  /// Start the background service
  Future<void> startService() async {
    if (!_isInitialized) await initialize();

    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
    }
  }

  /// Stop the background service
  Future<void> stopService() async {
    final isRunning = await _service.isRunning();
    if (isRunning) {
      _service.invoke('stop');
    }
  }

  /// Check if service is running
  Future<bool> isRunning() async {
    return await _service.isRunning();
  }

  /// Update the notification content
  void updateNotification(String title, String content) {
    _service.invoke('updateNotification', {
      'title': title,
      'content': content,
    });
  }

  /// Send data to the background service
  void sendData(Map<String, dynamic> data) {
    _service.invoke('receiveData', data);
  }

  /// Listen for data from the background service
  Stream<Map<String, dynamic>?> get onDataReceived {
    return _service.on('sendData');
  }
}

/// Entry point for the background service (runs in isolate)
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Track session start time
  final prefs = await SharedPreferences.getInstance();
  final sessionStartTime = DateTime.now().millisecondsSinceEpoch;
  await prefs.setInt('background_session_start', sessionStartTime);

  // Heartbeat timer reference — declared early so stop listener can cancel it
  Timer? heartbeatTimer;

  // Update notification with field session status
  if (service is AndroidServiceInstance) {
    service.on('updateNotification').listen((event) {
      if (event != null) {
        service.setForegroundNotificationInfo(
          title: event['title'] ?? 'AncientVision',
          content: event['content'] ?? 'Field session active',
        );
      }
    });

    service.on('stop').listen((event) {
      heartbeatTimer?.cancel();
      service.stopSelf();
    });

    // Set as foreground service
    service.setAsForegroundService();
  }

  // Keep-alive timer - sends heartbeat every 30 seconds
  heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        // Calculate session duration
        final startTime = prefs.getInt('background_session_start') ?? sessionStartTime;
        final duration = DateTime.now().millisecondsSinceEpoch - startTime;
        final minutes = (duration / 60000).floor();
        final hours = (minutes / 60).floor();
        final mins = minutes % 60;

        String durationText;
        if (hours > 0) {
          durationText = '${hours}h ${mins}m active';
        } else {
          durationText = '${mins}m active';
        }

        service.setForegroundNotificationInfo(
          title: 'AncientVision',
          content: 'Field session: $durationText',
        );

        // Send heartbeat to app
        service.invoke('sendData', {
          'type': 'heartbeat',
          'timestamp': DateTime.now().toIso8601String(),
          'sessionDuration': duration,
        });
      }
    }
  });

  // Listen for data from the app
  service.on('receiveData').listen((event) {
    if (event != null) {
      // Handle incoming data from app
      debugPrint('Background service received: $event');
    }
  });
}

/// iOS background handler
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}
