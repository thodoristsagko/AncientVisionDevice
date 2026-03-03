// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// import 'package:firebase_auth/firebase_auth.dart'; // TEST BUILD
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
// import 'services/auth_service.dart'; // TEST BUILD
import 'services/notification_service.dart';
import 'services/background_service.dart';
import 'services/settings_service.dart';

import 'widgets/offline_indicator.dart';
import 'widgets/glass_bottom_nav_bar.dart';
import 'widgets/full_screen_alert_overlay.dart';
// import 'screens/login_screen.dart'; // TEST BUILD
// import 'screens/biometric_gate_screen.dart'; // TEST BUILD
import 'screens/dashboard_home_view.dart';
import 'screens/findings_view.dart';
import 'screens/tools_view.dart';
import 'screens/safety/index.dart';


/// Sensor metrics passed to the alert overlay for context.
class AlertMetrics {
  final double ppv;
  final double freq;
  final double staLta;
  final double crestFactor;
  final double kurtosis;
  final String hazardType;
  final List<double> ppvHistory;

  const AlertMetrics({
    this.ppv = 0,
    this.freq = 0,
    this.staLta = 0,
    this.crestFactor = 0,
    this.kurtosis = 0,
    this.hazardType = 'none',
    this.ppvHistory = const [],
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true);
  // Initialize notification service
  await NotificationService().initialize();
  await NotificationService().requestPermissions();
  // Initialize background service to keep app running
  await BackgroundServiceManager().initialize();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _settingsService = SettingsService();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initSettings();
  }

  Future<void> _initSettings() async {
    await _settingsService.initialize();
    _settingsService.addListener(_onSettingsChanged);
    if (mounted) setState(() => _initialized = true);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _settingsService.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF0D3A39),
          body: Center(
            child: CircularProgressIndicator(color: Color(0xFFFFC107)),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _settingsService.getThemeData(MediaQuery.platformBrightnessOf(context)),
      builder: (context, child) {
        if (_settingsService.settings.nightMode) {
          return ColorFiltered(
            colorFilter: const ColorFilter.matrix(<double>[
              0.8, 0,   0,   0, 0,   // Red channel preserved
              0,   0.15, 0,   0, 0,   // Green greatly reduced
              0,   0,   0.15, 0, 0,   // Blue greatly reduced
              0,   0,   0,   1, 0,   // Alpha unchanged
            ]),
            child: child,
          );
        }
        return child ?? const SizedBox.shrink();
      },
      // TEST BUILD: Skip auth — go straight to dashboard
      home: const DashboardScreen(),
      // home: StreamBuilder<User?>(
      //   stream: AuthService.authStateChanges,
      //   builder: (context, snapshot) {
      //     if (snapshot.connectionState == ConnectionState.waiting) {
      //       return const Scaffold(
      //         body: Center(
      //           child: CircularProgressIndicator(color: Color(0xFFFFC107)),
      //         ),
      //       );
      //     }
      //     if (snapshot.hasData) {
      //       return const BiometricGate();
      //     }
      //     return const LoginScreen();
      //   },
      // ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 3; // TEST BUILD: default to Monitor tab
  final _findingsKey = GlobalKey<FindingsViewState>();

  // Global mute state (shared across all tabs)
  bool _isMuted = false;

  // Full-screen alert state (shown on top of all tabs)
  bool _showFullScreenAlert = false;
  String _fullScreenAlertMessage = '';
  String _fullScreenAlertLevel = 'warning';
  AlertMetrics _fullScreenAlertMetrics = const AlertMetrics();

  // Audio/voice for alerts
  late FlutterTts _tts;
  final AudioPlayer _alarmPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _tts = FlutterTts();
    _tts.setLanguage('en-US');
    _tts.setSpeechRate(0.5);
  }

  @override
  void dispose() {
    _tts.stop();
    _alarmPlayer.stop();
    _alarmPlayer.dispose();
    super.dispose();
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      if (_isMuted) {
        _alarmPlayer.stop();
        _tts.stop();
        // Also dismiss any active full-screen alert when muting
        _showFullScreenAlert = false;
      }
    });
  }

  void _triggerFullScreenAlert(String message, String level, [AlertMetrics? metrics]) async {
    if (!mounted) return;
    if (_isMuted) return;

    setState(() {
      _showFullScreenAlert = true;
      _fullScreenAlertMessage = message;
      _fullScreenAlertLevel = level;
      _fullScreenAlertMetrics = metrics ?? const AlertMetrics();
    });

    // Haptic feedback
    try {
      HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('Haptic error: $e');
    }

    // Play alarm sound
    try {
      await _alarmPlayer.play(AssetSource('audio/alarm.wav'));
    } catch (e) {
      debugPrint('Could not play alarm: $e');
    }

    // Voice alert
    try {
      String voiceMessage = level == 'critical'
          ? 'Critical alert! $message'
          : 'Warning! $message';
      await _tts.speak(voiceMessage);
    } catch (e) {
      debugPrint('TTS error: $e');
    }
  }

  void _dismissFullScreenAlert() {
    _alarmPlayer.stop();
    setState(() {
      _showFullScreenAlert = false;
    });
  }

  Widget _buildBody() {
    return IndexedStack(
      index: _currentIndex,
      children: [
        const DashboardHomeView(),
        FindingsView(key: _findingsKey),
        const ToolsView(),
        SafetyView(
          isMuted: _isMuted,
          onToggleMute: _toggleMute,
          onAlert: _triggerFullScreenAlert,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return OfflineIndicator(
      child: Stack(
        children: [
          Scaffold(
            extendBody: true,
            backgroundColor: Colors.transparent,
            body: _buildBody(),
            floatingActionButton: _currentIndex == 1
                ? FloatingActionButton(
                    onPressed: () {
                      final ctx = _findingsKey.currentContext;
                      if (ctx != null) {
                        _findingsKey.currentState?.showAddOptions(ctx);
                      }
                    },
                    backgroundColor: const Color(0xFFFFC107),
                    foregroundColor: const Color(0xFF3E2723),
                    child: const Icon(Icons.add_rounded),
                  )
                : null,
            bottomNavigationBar: SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: GlassBottomNavBar(
                currentIndex: _currentIndex,
                isMuted: _isMuted,
                onToggleMute: _toggleMute,
                onItemSelected: (index) {
                  setState(() {
                    _currentIndex = index;
                  });
                },
              ),
            ),
          ),
          // Full-screen alert overlay on top of everything
          if (_showFullScreenAlert)
            FullScreenAlertOverlay(
              message: _fullScreenAlertMessage,
              level: _fullScreenAlertLevel,
              metrics: _fullScreenAlertMetrics,
              onDismiss: _dismissFullScreenAlert,
            ),
        ],
      ),
    );
  }
}
