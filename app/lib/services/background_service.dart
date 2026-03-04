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

  // ---------------------------------------------------------------------------
  // Error counter
  // ---------------------------------------------------------------------------

  /// Number of unhandled exceptions recorded in the background loop since the
  /// last call to [startService].
  int _backgroundErrors = 0;

  /// Returns the number of background errors recorded since the last start.
  int get backgroundErrors => _backgroundErrors;

  /// Increment the background error counter.  Called from the isolate-level
  /// heartbeat catch block via the singleton reference.
  void recordBackgroundError() => _backgroundErrors++;

  // ---------------------------------------------------------------------------
  // Status history
  // ---------------------------------------------------------------------------

  /// Stores up to 10 most recent service lifecycle events with ISO timestamps.
  final List<String> _statusHistory = [];

  /// Unmodifiable view of the last 10 service status change messages.
  /// Each entry has the form: "ISO-timestamp: <message>".
  List<String> get statusHistory => List.unmodifiable(_statusHistory);

  /// Append a timestamped status message, keeping at most 10 entries.
  void _recordStatus(String message) {
    final entry = '${DateTime.now().toIso8601String()}: $message';
    _statusHistory.add(entry);
    if (_statusHistory.length > 10) {
      _statusHistory.removeAt(0);
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

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

    final running = await _service.isRunning();
    if (!running) {
      _backgroundErrors = 0;
      _recordStatus('started');
      await _service.startService();
    }
  }

  /// Stop the background service
  Future<void> stopService() async {
    final running = await _service.isRunning();
    if (running) {
      _recordStatus('stopped');
      _service.invoke('stop');
    }
  }

  /// Returns true when the background service is currently running.
  Future<bool> get isRunning async {
    return _service.isRunning();
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

  // Heartbeat timer reference -- declared early so stop listener can cancel it
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

  // Keep-alive timer -- sends heartbeat every 5 seconds.
  // Safety-critical: a 30 s interval is too long to detect a stale service in
  // a life-safety context.  5 s keeps the foreground notification fresh and
  // lets the UI detect a dead service within one heartbeat cycle.
  heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
    try {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          // Calculate session duration
          final startTime =
              prefs.getInt('background_session_start') ?? sessionStartTime;
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
    } catch (e) {
      debugPrint('[BackgroundService] heartbeat error: $e');
      // Propagate error count to the manager singleton so the UI can observe
      // it via BackgroundServiceManager().backgroundErrors.
      BackgroundServiceManager()
        .._recordStatus('error: $e')
        ..recordBackgroundError();
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
