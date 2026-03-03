import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import '../../models/alert_data.dart';
import '../../widgets/safety/index.dart';
import '../../widgets/full_screen_alert_overlay.dart';
import '../../services/vibration_anomaly_service.dart';
import '../../services/vibration_metrics_service.dart';
import '../../services/notification_service.dart';
import '../../services/settings_service.dart';
import '../../services/wavelet_service.dart';
import '../../widgets/spectrogram_widget.dart';
import '../../services/ppv_prediction_service.dart';
import '../../utils/fft_ble_parser.dart';
import '../../utils/circular_buffer.dart';
import '../../services/vibration_dsp_service.dart';
import '../../utils/ble_parser.dart' show RawAccelReassembler;
import '../vibration_event_log_screen.dart';
import '../../main.dart' show AlertMetrics;
import '../../services/translation_service.dart';
import '../../services/alert_history_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String _bleSensorServiceUUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";

class SafetyView extends StatefulWidget {
  final bool isMuted;
  final VoidCallback onToggleMute;
  final void Function(String message, String level, [AlertMetrics? metrics]) onAlert;

  const SafetyView({
    super.key,
    required this.isMuted,
    required this.onToggleMute,
    required this.onAlert,
  });

  @override
  State<SafetyView> createState() => _SafetyViewState();
}

class _SafetyViewState extends State<SafetyView> with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  // Keep the BLE connection alive when switching tabs
  @override
  bool get wantKeepAlive => true;

  BluetoothDevice? _connectedDevice;
  bool _isScanning = false;
  bool _isConnecting = false;
  String _connectionStatus = 'Disconnected';
  int? _lastRssi;
  final _alertHistory = AlertHistoryService();
  DateTime? _lastHistoryLogTime;

  double _accX = 0.0, _accY = 0.0, _accZ = 0.0;
  double _vibration = 0.0;
  int _moisturePercent = 0;
  String _alertLevel = 'safe';
  String _alertMessage = '';
  String _lastUpdate = '--:--';

  // New v2.0 vibration analysis fields from firmware
  double _ppv = 0.0;           // Peak Particle Velocity (mm/s)
  double _vectorPPV = 0.0;     // Vector sum PPV (mm/s) from phone-side DSP
  double _rms = 0.0;           // RMS acceleration (g)
  double _dominantFreq = 0.0;  // Dominant frequency (Hz)
  double _crestFactor = 0.0;   // Crest factor (Peak/RMS)
  String _hazardType = 'none'; // Hazard classification type

  // v3.0 fields
  double _centroid = 0.0;      // Spectral centroid (Hz)
  double _kurtosis = 0.0;      // Excess kurtosis
  double _staLtaRatio = 0.0;   // STA/LTA ratio
  double _ppvSmoothed = 0.0;   // EMA smoothed PPV
  double _ppvPeakHold = 0.0;   // 5-second peak hold
  DateTime _ppvPeakTime = DateTime.now();

  // v4.0 fields
  double _arias = 0.0;         // Arias Intensity (m/s)
  double _cav = 0.0;           // Cumulative Absolute Velocity (g·s)
  double _temp = 0.0;          // IMU temperature (°C)
  double _dwt1 = 0.0;          // DWT level 1 energy (50-100Hz)
  double _dwt2 = 0.0;          // DWT level 2 energy (25-50Hz)
  double _dwt3 = 0.0;          // DWT level 3 energy (12-25Hz)

  // v4.1 fields
  double _batteryVoltage = 0.0;  // Battery voltage (V)
  int _batteryPercent = 100;      // Battery percentage (0-100%)
  bool _batteryCharging = false;  // Charging status

  // Wavelet analysis (app-side DWT on rolling buffer)
  // Using CircularBuffer for O(1) eviction (Knuth Vol.1 S2.2.2)
  final CircularBuffer<double> _waveletBuffer = CircularBuffer(256);
  Map<String, double> _waveletBandEnergy = {};
  List<TransientEvent> _waveletTransients = [];
  bool _transientFlash = false;
  DateTime _lastTransientTime = DateTime(2000);

  // Spectrogram rolling buffer (synthesized from BLE frequency data)
  final SpectrogramBuffer _spectrogramBuffer = SpectrogramBuffer(maxColumns: 120);
  String _spectrogramColorMap = 'viridis';

  // PPV history for trend graph (DIN 4150-3)
  final CircularBuffer<Map<String, dynamic>> _ppvHistory = CircularBuffer(60);

  // Vibration feature log for ML training data
  final CircularBuffer<Map<String, dynamic>> _vibrationFeatureLog = CircularBuffer(500);

  // Kalman filter + trend prediction (v4.2)
  final _kalmanFilter = KalmanPPVFilter(q: 0.01, r: 0.5);
  final _trendPredictor = PPVTrendPredictor(windowSize: 20, sampleIntervalSec: 0.5);
  double _ppvKalman = 0.0;
  PPVPrediction? _ppvPrediction;
  final CircularBuffer<double> _ppvKalmanHistory = CircularBuffer(60);

  // Phone-side DSP engine (replaces firmware FFT/DWT/kurtosis)
  final _dspService = VibrationDspService();
  final _rawAccelReassembler = RawAccelReassembler();

  // ML Anomaly Detection (Tier 2)
  final _anomalyService = VibrationAnomalyService();
  AnomalyResult _lastAnomalyResult = const AnomalyResult(score: 0, level: AnomalyLevel.unknown, rawError: 0);
  bool _mlModelLoaded = false;
  final CircularBuffer<double> _anomalyScoreHistory = CircularBuffer(30);
  Map<String, double> _lastMLFeatures = {}; // features passed to last detect() call

  // Precursor detection state
  String? _lastPrecursorPattern;
  double _lastPrecursorScore = 0.0;
  bool _isPrecursorDriven = false;

  // Site calibration
  bool _isCalibrating = false;
  String? _calibrationSiteName;

  // PPV baseline calibration
  static const int _kCalibrationSeconds = 5;
  bool _isPpvCalibrating = false;
  final List<double> _calibrationSamples = [];
  final _settingsServiceCal = SettingsService();

  // Translation
  final _t = TranslationService();

  // Fukuzono time-to-failure prediction
  double? _fukuzonoTTF;       // seconds until predicted failure
  double? _fukuzonoR2;        // fit quality
  double? _fukuzonoAlpha;     // Voight α
  double? _psdSlope;          // PSD log-log slope
  String? _psdClassification; // earthquake / landslide / noise

  // Multi-standard classification (VibrationMetricsService)
  List<StandardClassification> _standardClassifications = [];
  final VibrationMetrics _vibrationMetrics = VibrationMetrics();
  double _housnerSI = 0.0;

  final List<AlertData> _alerts = [];

  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  final List<StreamSubscription> _charSubscriptions = [];

  Timer? _firebaseLogTimer;
  final CircularBuffer<Map<String, dynamic>> _sensorHistory = CircularBuffer(30);

  // Enhanced connection management
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;
  Timer? _reconnectTimer;
  Timer? _keepAliveTimer;
  DateTime? _lastDataReceived;
  DateTime? _keepAliveStartTime;
  String? _lastNotifiedAlertLevel; // Prevent duplicate notifications
  int _truncatedPackets = 0; // Count of dropped truncated BLE packets
  Timer? _uiRefreshTimer; // Throttled UI refresh at fixed rate
  bool _uiDirty = false; // Flag: new data arrived since last refresh

  // Simple/Detailed view mode toggle (simple by default for archaeologist UX)
  bool _simpleMode = true;
  bool _hasReceivedVibData = false; // Latches true once PPV/RMS data arrives

  // FFT BLE data from firmware (real spectral bins)
  FftBleData? _lastFftData;

  // BLE characteristic references for bidirectional communication
  BluetoothCharacteristic? _alertCharacteristic;

  @override
  void initState() {
    super.initState();
    _checkBluetoothAndScan();
    _startFirebaseLogging();
    _loadSensorHistory();
    _initAnomalyModel();
    // Throttled UI refresh: max 2 repaints/sec to prevent flickering
    _uiRefreshTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      if (_uiDirty && mounted) {
        _uiDirty = false;
        setState(() {});
      }
    });
  }

  Future<void> _initAnomalyModel() async {
    final success = await _anomalyService.initialize();
    if (mounted) {
      setState(() => _mlModelLoaded = success);
    }
    debugPrint('Anomaly detection ready: ${_anomalyService.modeLabel}');
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    for (var sub in _charSubscriptions) {
      sub.cancel();
    }
    _firebaseLogTimer?.cancel();
    _reconnectTimer?.cancel();
    _keepAliveTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _dspService.dispose();
    _anomalyService.dispose();
    super.dispose();
  }

  Future<void> _ensureLocationPermission() async {
    // Android 11 and below require location permission for BLE scanning
    // Use Geolocator (already a dependency) to request it
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      debugPrint('>>> Location permission check: $perm');
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        debugPrint('>>> Location permission after request: $perm');
      }
      if (perm == LocationPermission.deniedForever) {
        debugPrint('>>> Location permanently denied — user must enable in settings');
        if (mounted) {
          _showError('Location permission required for Bluetooth. Please enable in Settings > Apps > AncientVision > Permissions');
        }
      }
    } catch (e) {
      debugPrint('>>> Location permission error (non-fatal): $e');
    }
  }

  Future<void> _checkBluetoothAndScan() async {
    debugPrint('>>> _checkBluetoothAndScan START');

    if (await FlutterBluePlus.isSupported == false) {
      _showError('Bluetooth not supported');
      return;
    }
    debugPrint('>>> BLE supported: true');

    // Request location permission (required for BLE on Android 11)
    await _ensureLocationPermission();
    if (!mounted) return;

    final state = await FlutterBluePlus.adapterState.first;
    debugPrint('>>> Bluetooth adapter state: $state');
    if (!mounted) return;
    if (state != BluetoothAdapterState.on) {
      setState(() => _connectionStatus = 'Bluetooth OFF');
      return;
    }

    // FIRST: Check if device is already connected
    try {
      final lockedMac = SettingsService().settings.lockedSensorMac;
      final connectedDevices = FlutterBluePlus.connectedDevices;
      for (final device in connectedDevices) {
        // If MAC is locked, only connect to that exact device
        if (lockedMac.isNotEmpty) {
          if (device.remoteId.str.toLowerCase() != lockedMac.toLowerCase()) continue;
        } else {
          final name = device.platformName.toLowerCase();
          // platformName may be empty for some devices — accept any already-connected BLE device
          // since we only connect to our device in the first place
          if (name.isNotEmpty && !(name.contains('ancientvision') || name.contains('ancient') ||
              name.contains('m5stick') || name.contains('m5-') || name.startsWith('m5'))) {
            continue;
          }
        }
        debugPrint('>>> ALREADY CONNECTED: ${device.platformName} - subscribing to data...');
        setState(() {
          _connectedDevice = device;
          _connectionStatus = 'Connected';
          _isConnecting = false;
          _isScanning = false;
        });
        WakelockPlus.enable();
        _startKeepAliveMonitor();
        // Request larger MTU for already-connected devices too
        try {
          final mtu = await device.requestMtu(512);
          debugPrint('>>> MTU negotiated (already connected): $mtu');
        } catch (e) {
          debugPrint('>>> MTU request failed (non-fatal): $e');
        }
        await Future.delayed(const Duration(milliseconds: 500));
        await _discoverAndSubscribe(device);
        return;
      }
    } catch (e) {
      debugPrint('Error checking connected devices: $e');
    }

    // If not already connected, start scanning
    _startScan();
  }

  Future<void> _startScan() async {
    if (_isScanning || _isConnecting || _connectedDevice != null) return;

    setState(() {
      _isScanning = true;
      _connectionStatus = 'Scanning...';
    });

    try {
      int devicesFound = 0;
      final lockedMac = SettingsService().settings.lockedSensorMac;

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        if (_isConnecting || _connectedDevice != null) return;
        for (ScanResult r in results) {
          final platformName = r.device.platformName;
          final advName = r.advertisementData.advName;
          final name = platformName.isNotEmpty ? platformName : advName;
          final nameLower = name.toLowerCase();

          if (devicesFound < 30) {
            debugPrint('BLE Found: platform="$platformName" adv="$advName" (${r.device.remoteId}) RSSI=${r.rssi}');
            devicesFound++;
          }

          bool matched = false;
          if (lockedMac.isNotEmpty) {
            matched = r.device.remoteId.str.toLowerCase() == lockedMac.toLowerCase();
          } else {
            matched = nameLower.contains('ancientvision') ||
                nameLower.contains('ancient') ||
                nameLower.contains('m5stick') ||
                nameLower.contains('m5-') ||
                nameLower.startsWith('m5');
          }

          if (matched) {
            debugPrint('>>> MATCHED DEVICE: $name (${r.device.remoteId}) - connecting...');
            FlutterBluePlus.stopScan();
            _scanSubscription?.cancel();
            _reconnectTimer?.cancel();
            setState(() => _isScanning = false);
            _connectToDevice(r.device);
            return;
          }
        }
      });

      // Start scan AFTER setting up listener
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));

      // startScan completes when timeout expires
      if (_connectedDevice == null && !_isConnecting && mounted) {
        _scanSubscription?.cancel();
        setState(() {
          _isScanning = false;
          _connectionStatus = 'Sensor not found - check device is on';
        });
        debugPrint('Scan complete - AncientVision device not found');
      }
    } catch (e) {
      debugPrint('>>> BLE Scan error: $e');
      if (mounted) {
        _scanSubscription?.cancel();
        final errStr = e.toString().toLowerCase();
        String status = 'Scan failed';
        if (errStr.contains('permission') || errStr.contains('location')) {
          status = 'Location permission required — enable in phone Settings';
        } else {
          status = 'Scan failed: $e';
        }
        setState(() {
          _isScanning = false;
          _connectionStatus = status;
        });
      }
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnecting || _connectedDevice != null) {
      debugPrint('>>> _connectToDevice SKIPPED: isConnecting=$_isConnecting connectedDevice=$_connectedDevice');
      return;
    }

    debugPrint('>>> _connectToDevice START: ${device.remoteId}');
    setState(() {
      _isConnecting = true;
      _connectionStatus = 'Connecting...';
    });
    _reconnectTimer?.cancel();

    try {
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      debugPrint('>>> device.connect() SUCCEEDED');

      setState(() {
        _connectedDevice = device;
        _isConnecting = false;
        _isScanning = false;
        _connectionStatus = 'Connected';
        _reconnectAttempts = 0;
      });
      WakelockPlus.enable();

      _dspService.reset();
      _rawAccelReassembler.reset();

      // Start keepalive monitoring
      _startKeepAliveMonitor();

      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          _handleDisconnection();
        } else if (state == BluetoothConnectionState.connected && mounted) {
          setState(() {
            _connectionStatus = 'Connected';
            _reconnectAttempts = 0;
            _truncatedPackets = 0;
          });
        }
      });

      // Request larger MTU so BLE JSON payloads are not truncated
      try {
        final mtu = await device.requestMtu(512);
        debugPrint('>>> MTU negotiated: $mtu');
      } catch (e) {
        debugPrint('>>> MTU request failed (non-fatal): $e');
      }

      // Small delay to let MTU take effect before service discovery
      await Future.delayed(const Duration(milliseconds: 500));

      await _discoverAndSubscribe(device);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _connectionStatus = 'Connection failed';
        });
        // Auto-retry with exponential backoff
        _scheduleReconnect();
      }
    }
  }

  /// Handle device disconnection with smart reconnect
  void _handleDisconnection() {
    if (!mounted) return;
    final deviceName = _connectedDevice?.platformName ?? 'Sensor';

    // Cancel all BLE subscriptions to prevent stale data / duplicates on reconnect
    for (final sub in _charSubscriptions) {
      sub.cancel();
    }
    _charSubscriptions.clear();
    _connectionSubscription?.cancel();
    _connectionSubscription = null;

    setState(() {
      _connectedDevice = null;
      _lastRssi = null;
      _truncatedPackets = 0;
      _connectionStatus = 'Reconnecting...';
    });
    WakelockPlus.disable();

    // Send notification about disconnection
    NotificationService().showDeviceDisconnected(deviceName: deviceName);

    _dspService.reset();
    _rawAccelReassembler.reset();

    // Cancel keepalive
    _keepAliveTimer?.cancel();

    // Schedule reconnect with exponential backoff
    _scheduleReconnect();
  }

  /// Schedule reconnection with exponential backoff
  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      setState(() => _connectionStatus = 'Connection lost - tap Scan');
      return;
    }

    // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
    final delaySeconds = (1 << _reconnectAttempts).clamp(1, 30);
    _reconnectAttempts++;

    setState(() {
      _connectionStatus = 'Reconnecting in ${delaySeconds}s... ($_reconnectAttempts/$_maxReconnectAttempts)';
    });

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (mounted && _connectedDevice == null) {
        _checkBluetoothAndScan();
      }
    });
  }

  /// Monitor connection health and request RSSI periodically
  void _startKeepAliveMonitor() {
    _keepAliveTimer?.cancel();
    _lastDataReceived = DateTime.now();
    _keepAliveStartTime = DateTime.now();

    _keepAliveTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted || _connectedDevice == null) {
        timer.cancel();
        return;
      }

      // Read RSSI every tick for signal strength indicator
      try {
        final rssi = await _connectedDevice!.readRssi();
        if (mounted) setState(() => _lastRssi = rssi);
      } catch (e) {
        // RSSI read failed — only disconnect if we HAD data before and lost it
        final now = DateTime.now();
        final lastData = _lastDataReceived;
        // Don't trigger disconnect if we never received data yet (still setting up)
        if (lastData != null &&
            now.difference(lastData).inSeconds > 15 &&
            now.difference(_keepAliveStartTime ?? now).inSeconds > 20) {
          debugPrint('Connection stale - no data for 15s, RSSI read failed');
          _handleDisconnection();
          return;
        }
      }

      // Also check for stale data even if RSSI read succeeded
      final now = DateTime.now();
      if (_lastDataReceived != null &&
          now.difference(_lastDataReceived!).inSeconds > 15) {
        debugPrint('Connection stale - no data for 15s');
      }
    });
  }

  Future<void> _disconnectDevice() async {
    if (_connectedDevice == null) return;

    try {
      // Cancel characteristic subscriptions
      for (final sub in _charSubscriptions) {
        await sub.cancel();
      }
      _charSubscriptions.clear();

      // Cancel connection subscription
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;

      // Disconnect the device
      await _connectedDevice!.disconnect();

      if (mounted) {
        setState(() {
          _connectedDevice = null;
          _lastRssi = null;
          _connectionStatus = 'Disconnected';
        });
      }
    } catch (e) {
      debugPrint('Disconnect error: $e');
      if (mounted) {
        setState(() {
          _connectedDevice = null;
          _lastRssi = null;
          _connectionStatus = 'Disconnected';
        });
      }
    }
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    try {
      debugPrint('>>> Starting service discovery for ${device.platformName}...');
      List<BluetoothService> services = await device.discoverServices();
      debugPrint('>>> Found ${services.length} services');

      bool foundService = false;
      for (BluetoothService service in services) {
        final serviceUuid = service.uuid.toString().toLowerCase();
        debugPrint('>>> Service: $serviceUuid');

        // Check if this is our sensor service
        if (serviceUuid.contains('4fafc201') || serviceUuid == _bleSensorServiceUUID.toLowerCase()) {
          foundService = true;
          debugPrint('>>> MATCHED our sensor service!');

          for (BluetoothCharacteristic char in service.characteristics) {
            final charUuidStr = char.uuid.toString().toLowerCase();
            debugPrint('>>>   Characteristic: $charUuidStr notify=${char.properties.notify} read=${char.properties.read}');
            // Store alert characteristic reference for bidirectional TX
            if (charUuidStr.endsWith('26aa') || charUuidStr.contains('b26aa')) {
              _alertCharacteristic = char;
              debugPrint('>>>   Alert characteristic stored for TX');
            }

            if (char.properties.notify) {
              try {
                await char.setNotifyValue(true);
                debugPrint('>>>   Notifications ENABLED for $charUuidStr');
                final sub = char.onValueReceived.listen((value) {
                  debugPrint('>>>   DATA RECEIVED on $charUuidStr: ${value.length} bytes');
                  _handleCharacteristicData(charUuidStr, value);
                });
                _charSubscriptions.add(sub);
                debugPrint('>>>   SUBSCRIBED to $charUuidStr');
              } catch (e) {
                debugPrint('>>>   FAILED to subscribe to $charUuidStr: $e');
                if (mounted) {
                  setState(() => _connectionStatus = 'Data subscribe failed');
                }
              }
            }
          }
        }
      }

      if (!foundService) {
        debugPrint('>>> WARNING: Our sensor service was NOT found!');
      }
    } catch (e) {
      debugPrint('Service discovery error: $e');
    }
  }

  void _handleCharacteristicData(String charUuid, List<int> value) {
    if (!mounted) return;

    // FFT characteristic now sends raw acceleration binary (v5.0 firmware)
    // or FFT bins (v4.x firmware). Detect by checking header.
    if (isFftCharacteristic(charUuid)) {
      _lastDataReceived = DateTime.now();

      // v5.0: raw accel packets have header [seqNum, sampleCount/2].
      // Firmware sends FFT_SAMPLES>>1 (128) since 256 overflows uint8.
      if (value.length < 2) return;
      final sampleCountRaw = value[1];
      final sampleCount = sampleCountRaw <= 128 ? sampleCountRaw * 2 : sampleCountRaw;
      if (value.length > 4 && sampleCount >= 128) {
        final rawAccel = _rawAccelReassembler.addPacket(value);
        if (rawAccel != null && rawAccel.sampleCount >= 128) {
          // Run phone-side DSP on a background isolate (off main thread)
          _dspService.processAsync(
            rawAccel.accelX, rawAccel.accelY, rawAccel.accelZ,
          ).then((result) {
            if (!mounted) return;
            final dspResult = result.dsp;
            _vectorPPV = result.ppv;

            // Update fields directly — throttled timer handles UI refresh
            _dominantFreq = dspResult.dominantFreq;
            _centroid = dspResult.spectralCentroid;
            _kurtosis = dspResult.kurtosis;
            _arias = dspResult.ariasIntensity;
            _cav = dspResult.cav;
            _dwt1 = dspResult.dwtEnergy1;
            _dwt2 = dspResult.dwtEnergy2;
            _dwt3 = dspResult.dwtEnergy3;
            _psdSlope = dspResult.psdSlope;
            _uiDirty = true;

            // Feed spectrogram with real FFT data from phone DSP
            final column = List<double>.filled(128, 0.0);
            for (int i = 0; i < dspResult.fftMagnitudes.length && i < 128; i++) {
              column[i] = dspResult.fftMagnitudes[i] * 100;
            }
            _spectrogramBuffer.addColumn(column);

            debugPrint('>>> Phone DSP: freq=${dspResult.dominantFreq.toStringAsFixed(1)}Hz '
                'kurt=${dspResult.kurtosis.toStringAsFixed(2)} '
                'dwt=[${dspResult.dwtEnergy1.toStringAsFixed(4)},${dspResult.dwtEnergy2.toStringAsFixed(4)},${dspResult.dwtEnergy3.toStringAsFixed(4)}]');
          }).catchError((e) {
            debugPrint('DSP isolate error: $e');
          });
        }
        return;
      }

      // v4.x fallback: parse as FFT bins
      final fftData = parseFftBlePayload(value);
      if (fftData != null) {
        _lastFftData = fftData;
        debugPrint('>>> FFT BLE: ${fftData.binCount} bins, dominant=${fftData.dominantFrequency.toStringAsFixed(1)}Hz');
      }
      return;
    }

    try {
      // Strip null bytes that C snprintf may include
      final cleaned = value.where((b) => b != 0).toList();
      final jsonStr = String.fromCharCodes(cleaned).trim();
      debugPrint('>>> RAW BLE DATA from $charUuid (${value.length} bytes): "$jsonStr"');
      if (jsonStr.isEmpty) return;

      // Check for truncated JSON (missing closing brace)
      if (!jsonStr.endsWith('}')) {
        debugPrint('>>> WARNING: Truncated BLE data! MTU too small. Raw length=${value.length}');
        _truncatedPackets++;
        // Show amber snackbar on first truncation (Nielsen Heuristic #9)
        if (_truncatedPackets == 1 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_t.tr('partial_data')),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        _uiDirty = true;
        return;
      }

      final data = json.decode(jsonStr);
      if (data == null) return;

      // Update last data received for keepalive monitoring
      _lastDataReceived = DateTime.now();

      // Debug: log received data with full UUID
      debugPrint('>>> PARSED BLE Data UUID=$charUuid data=$data');

      // Update fields directly — UI refreshes on throttled timer
      {
        _lastUpdate = _formatTime(DateTime.now());
        _uiDirty = true;

        // Match by last part of UUID (the unique suffix)
        // IMU: beb5483e-36e1-4688-b7f5-ea07361b26a8
        // Moisture: beb5483e-36e1-4688-b7f5-ea07361b26a9
        // Alert: beb5483e-36e1-4688-b7f5-ea07361b26aa
        if (charUuid.endsWith('26a8') || charUuid.contains('b26a8')) {
          // IMU characteristic (v2.0: includes processed vibration features)
          _accX = (data['x'] as num?)?.toDouble() ?? 0.0;
          _accY = (data['y'] as num?)?.toDouble() ?? 0.0;
          _accZ = (data['z'] as num?)?.toDouble() ?? 0.0;
          _vibration = (data['vib'] as num?)?.toDouble() ?? 0.0;

          // Parse v2.0+ fields (backward compatible - defaults to 0 if missing)
          _ppv = (data['ppv'] as num?)?.toDouble() ?? 0.0;
          if (_isPpvCalibrating) _calibrationSamples.add(_ppv);
          if (_ppv > 0 || _rms > 0) _hasReceivedVibData = true;
          _rms = (data['rms'] as num?)?.toDouble() ?? 0.0;
          _crestFactor = (data['crest'] as num?)?.toDouble() ?? 0.0;
          _staLtaRatio = (data['stalta'] as num?)?.toDouble() ?? 0.0;
          _temp = (data['temp'] as num?)?.toDouble() ?? 0.0;

          // Only overwrite phone-DSP fields if firmware actually sends them
          // (v5.0 firmware omits freq/kurt/cent/arias/cav/dwt — phone DSP computes them)
          if (data.containsKey('freq')) _dominantFreq = (data['freq'] as num).toDouble();
          if (data.containsKey('cent')) _centroid = (data['cent'] as num).toDouble();
          if (data.containsKey('kurt')) _kurtosis = (data['kurt'] as num).toDouble();
          if (data.containsKey('arias')) _arias = (data['arias'] as num).toDouble();
          if (data.containsKey('cav')) _cav = (data['cav'] as num).toDouble();
          if (data.containsKey('dwt1')) _dwt1 = (data['dwt1'] as num).toDouble();
          if (data.containsKey('dwt2')) _dwt2 = (data['dwt2'] as num).toDouble();
          if (data.containsKey('dwt3')) _dwt3 = (data['dwt3'] as num).toDouble();

          // PPV EMA smoothing (alpha = 0.3)
          _ppvSmoothed = _kalmanFilter.update(_ppv);
          _ppvKalman = _ppvSmoothed;

          // 5-second peak hold
          if (_ppv > _ppvPeakHold) {
            _ppvPeakHold = _ppv;
            _ppvPeakTime = DateTime.now();
          } else if (DateTime.now().difference(_ppvPeakTime).inSeconds >= 5) {
            _ppvPeakHold = _ppv;
            _ppvPeakTime = DateTime.now();
          }

          // PPV alarm: DIN 4150-3 heritage limit exceeded
          if (_effectivePpv > 3.0) {
            _triggerFullScreenAlert(
              _t.tr('stop_work'),
              _effectivePpv > 10.0 ? 'critical' : 'warning',
            );
            HapticFeedback.heavyImpact();
          }

          // Add to legacy graph history (O(1) via CircularBuffer)
          _sensorHistory.add({
            'vibration': _vibration,
            'moisture': _moisturePercent,
            'timestamp': DateTime.now(),
          });

          // Add to PPV trend history (for DIN 4150-3 graph)
          _ppvHistory.add({
            'ppv': _ppv,
            'freq': _dominantFreq,
            'crest': _crestFactor,
            'rms': _rms,
            'cent': _centroid,
            'kurt': _kurtosis,
            'stalta': _staLtaRatio,
            'timestamp': DateTime.now(),
          });

          // Log feature vector for ML training
          _vibrationFeatureLog.add({
            'rms': _rms,
            'ppv': _ppv,
            'freq': _dominantFreq,
            'crest': _crestFactor,
            'cent': _centroid,
            'kurt': _kurtosis,
            'stalta': _staLtaRatio,
            'timestamp': DateTime.now().toIso8601String(),
          });

          debugPrint('>>> VIBRATION v4.0: PPV=${_ppv}mm/s Freq=${_dominantFreq}Hz Crest=$_crestFactor Kurt=$_kurtosis STA/LTA=$_staLtaRatio Arias=$_arias CAV=$_cav Temp=${_temp}C DWT=[$_dwt1,$_dwt2,$_dwt3] History=${_ppvHistory.length} pts ML=${_lastAnomalyResult.levelLabel}');
        } else if (charUuid.endsWith('26a9') || charUuid.contains('b26a9')) {
          // Moisture characteristic (also includes vibration for reliability)
          _moisturePercent = (data['percent'] as num?)?.toInt() ?? 0;
          // Read vibration from moisture characteristic (more reliable than IMU char)
          if (data.containsKey('vib')) {
            _vibration = (data['vib'] as num?)?.toDouble() ?? 0.0;
            debugPrint('>>> VIBRATION FROM MOISTURE: $_vibration');
          }
          debugPrint('>>> MOISTURE UPDATED: $_moisturePercent%');
        } else if (charUuid.endsWith('26aa') || charUuid.contains('b26aa')) {
          final newLevel = data['level'] as String? ?? 'safe';
          final newMessage = data['message'] as String? ?? '';
          _hazardType = data['type'] as String? ?? 'none';

          if (newLevel != 'safe' && newMessage.isNotEmpty) {
            _alerts.insert(0, AlertData(
              time: _lastUpdate,
              level: newLevel == 'critical' ? AlertLevel.critical : AlertLevel.warning,
              title: newLevel == 'critical' ? 'Critical Alert' : 'Warning',
              message: newMessage,
            ));
            if (_alerts.length > 10) _alerts.removeLast();
            _saveAlertToFirebase(newLevel, newMessage);

            // Send push notification for alerts (only if level changed)
            _sendAlertNotification(newLevel, newMessage);

            // Show full-screen alert for ALL alerts (both warning and critical)
            _triggerFullScreenAlert(newMessage, newLevel);
          }

          _alertLevel = newLevel;
          _alertMessage = newMessage;
        } else if (charUuid.endsWith('26ab') || charUuid.contains('b26ab')) {
          // Battery characteristic (v4.1)
          _batteryVoltage = (data['voltage'] as num?)?.toDouble() ?? 0.0;
          _batteryPercent = (data['percent'] as num?)?.toInt() ?? 100;
          _batteryCharging = data['charging'] as bool? ?? false;

          debugPrint('>>> BATTERY: $_batteryPercent% ($_batteryVoltage V) ${_batteryCharging ? 'CHARGING' : ''}');

          // Low battery warning
          if (_batteryPercent < 20 && !_batteryCharging) {
            NotificationService().showSafetyWarning(
              message: 'M5StickC Plus 2 battery low: $_batteryPercent%',
              sensorType: 'Device Battery',
            );
          }
        }
      }

      // Run heavy processing outside setState to avoid blocking BLE
      if (charUuid.endsWith('26a8') || charUuid.contains('b26a8')) {
        _runDeferredProcessing();
      }
    } catch (e) {
      debugPrint('Error parsing BLE data: $e');
    }
  }

  /// Debounce flag — skip stale BLE packets if processing is still running.
  bool _deferredProcessingPending = false;

  /// Run heavy analytics in a microtask so the UI paints first, then
  /// analytics run before the next event. Debounces rapid BLE packets.
  void _runDeferredProcessing() {
    if (!mounted || _deferredProcessingPending) return;
    _deferredProcessingPending = true;
    Future.microtask(() {
      _deferredProcessingPending = false;
      if (!mounted) return;
      _doDeferredProcessing();
    });
  }

  /// Actual deferred processing logic (runs in microtask after UI paint).
  /// All state mutations are batched into a single setState at the end
  /// to minimise widget rebuilds (Flutter rendering pipeline docs).
  void _doDeferredProcessing() {
    bool needsRebuild = false;

    // 1. Feed wavelet buffer with vibration magnitude (O(1) circular buffer)
    _waveletBuffer.add(_vibration > 0 ? _vibration : _rms);

    // 2. Run app-side wavelet analysis when buffer is full enough
    bool hasNewTransient = false;
    if (_waveletBuffer.length >= 32) {
      final waveletList = _waveletBuffer.toList();
      final bandEnergy = WaveletService.bandEnergy(
        waveletList,
        levels: 3,
        sampleRate: 200.0,
      );
      final transients = WaveletService.detectTransients(
        waveletList,
        sensitivity: 3.0,
        sampleRate: 200.0,
      );

      if (transients.isNotEmpty) {
        final now = DateTime.now();
        if (now.difference(_lastTransientTime).inMilliseconds > 500) {
          hasNewTransient = true;
          _lastTransientTime = now;
        }
      }

      _waveletBandEnergy = bandEnergy;
      _waveletTransients = transients;
      if (hasNewTransient) _transientFlash = true;
      needsRebuild = true;
    }

    // 3. Feed spectrogram buffer — prefer real FFT bins from firmware
    if (_lastFftData != null) {
      _spectrogramBuffer.addColumn(_lastFftData!.toSpectrogramColumn());
      _lastFftData = null;
      needsRebuild = true;
    } else if (_dominantFreq > 0 || _rms > 0) {
      const fftBins = 128;
      final column = List<double>.filled(fftBins, 0.0);
      const binResolution = 200.0 / 256;

      if (_dominantFreq > 0 && _rms > 0) {
        final dominantBin = (_dominantFreq / binResolution).round().clamp(0, fftBins - 1);
        column[dominantBin] = _rms * 100;
        for (int i = 1; i <= 3; i++) {
          final spread = _rms * 100 * math.exp(-i * i * 0.5);
          if (dominantBin + i < fftBins) column[dominantBin + i] = spread;
          if (dominantBin - i >= 0) column[dominantBin - i] = spread;
        }
      }

      if (_dwt1 > 0) {
        final startBin = (50.0 / binResolution).round().clamp(0, fftBins - 1);
        final endBin = (100.0 / binResolution).round().clamp(0, fftBins - 1);
        for (int i = startBin; i < endBin && i < fftBins; i++) {
          column[i] += _dwt1 * 50;
        }
      }
      if (_dwt2 > 0) {
        final startBin = (25.0 / binResolution).round().clamp(0, fftBins - 1);
        final endBin = (50.0 / binResolution).round().clamp(0, fftBins - 1);
        for (int i = startBin; i < endBin && i < fftBins; i++) {
          column[i] += _dwt2 * 50;
        }
      }
      if (_dwt3 > 0) {
        final startBin = (12.5 / binResolution).round().clamp(0, fftBins - 1);
        final endBin = (25.0 / binResolution).round().clamp(0, fftBins - 1);
        for (int i = startBin; i < endBin && i < fftBins; i++) {
          column[i] += _dwt3 * 50;
        }
      }

      _spectrogramBuffer.addColumn(column);
      needsRebuild = true;
    }

    // 4. Multi-standard classification
    if (_ppv > 0 || _rms > 0) {
      _standardClassifications = VibrationMetricsService.classifyAllStandards(
        _ppv,
        _dominantFreq,
      );

      _vibrationMetrics.updateWithSample(_rms, 1.0 / 2.0);
      _housnerSI = _vibrationMetrics.housnerSI;

      if (_ppv > 0 && _dominantFreq > 0) {
        _vibrationMetrics.damageIndex = VibrationMetricsService.updateDamageIndex(
          _vibrationMetrics.damageIndex,
          _ppv,
          0.5,
          _dominantFreq,
        );
      }
      needsRebuild = true;
    }

    // 5. ML anomaly detection
    if (_mlModelLoaded && (_ppv > 0 || _rms > 0)) {
      try {
        final features = {
          'rms': _rms,
          'ppv': _ppv,
          'freq': _dominantFreq,
          'crest': _crestFactor,
          'centroid': _centroid,
          'kurtosis': _kurtosis,
          'stalta': _staLtaRatio,
          'arias': _arias,
          'cav': _cav,
          'temp': _temp,
          'psdSlope': _psdSlope ?? 0.0,
        };

        final result = _anomalyService.detect(features);
        _anomalyScoreHistory.add(result.score);
        _lastAnomalyResult = result;
        _lastMLFeatures = features;
        needsRebuild = true;

        // Alarm + haptic for red-level ML anomaly
        if (result.level == AnomalyLevel.anomaly && result.score >= 0.8) {
          _triggerFullScreenAlert(
            _t.tr('unusual_vibration'),
            'warning',
          );
          HapticFeedback.heavyImpact();
        } else if (result.level == AnomalyLevel.unusual) {
          HapticFeedback.lightImpact();
        }

        // Feed calibration if active
        if (_isCalibrating) {
          _anomalyService.mlService.feedCalibrationSample(features);
        }
      } catch (e) {
        debugPrint('ML anomaly detection error: $e');
      }
    }

    // 5b. Feed PSD slope to adaptive service and compute Fukuzono
    if (_psdSlope != null) {
      _anomalyService.adaptiveService.updatePsdSlope(_psdSlope!);
    }
    if (_anomalyService.adaptiveService.isCalibrated) {
      final fukuzono = _anomalyService.adaptiveService.computeFukuzono();
      if (fukuzono != null) {
        _fukuzonoTTF = fukuzono.ttfSeconds;
        _fukuzonoR2 = fukuzono.r2;
        _fukuzonoAlpha = fukuzono.alpha;
        _psdClassification = fukuzono.psdClassification;
        needsRebuild = true;

        // Trigger full-screen alert if failure predicted within 10 minutes
        if (fukuzono.ttfSeconds < 600 && fukuzono.r2 > 0.7) {
          final mins = (fukuzono.ttfSeconds / 60).floor();
          final secs = (fukuzono.ttfSeconds % 60).floor();
          _triggerFullScreenAlert(
            'FUKUZONO PREDICTION: Soil failure in ~${mins}m ${secs}s. Evacuate immediately!',
            'critical',
          );
          HapticFeedback.heavyImpact();
        }
      } else {
        _fukuzonoTTF = null;
        _fukuzonoR2 = null;
        _fukuzonoAlpha = null;
        // Keep psdClassification from PSD slope directly
        if (_psdSlope != null) {
          final s = _psdSlope!;
          _psdClassification = s > -1.5 ? 'earthquake' : (s > -9.0 ? 'landslide' : 'noise');
        }
      }
    }

    // 5c. Check for precursor patterns
    if (_anomalyService.adaptiveService.isCalibrated) {
      final adaptiveResult = _anomalyService.adaptiveService.detect({
        'ppv': _ppv, 'rms': _rms, 'crest': _crestFactor,
        'kurtosis': _kurtosis, 'stalta': _staLtaRatio, 'cav': _cav, 'freq': _dominantFreq,
      });
      if (adaptiveResult != null) {
        _lastPrecursorPattern = adaptiveResult.precursorPattern;
        _lastPrecursorScore = adaptiveResult.precursorScore;
        _isPrecursorDriven = adaptiveResult.isPrecursorDriven;
        needsRebuild = true;

        // Surface precursor patterns to the user
        if (_lastPrecursorPattern != null && _lastPrecursorPattern != 'none') {
          final patternLabel = _formatPrecursorPattern(_lastPrecursorPattern!);
          final confidence = (_lastPrecursorScore * 100).toStringAsFixed(0);

          if (_lastPrecursorPattern == 'imminent_failure') {
            // Critical level: trigger full-screen alert + heavy haptic + alarm sound
            _triggerFullScreenAlert(
              'IMMINENT FAILURE PATTERN DETECTED: $patternLabel ($confidence% confidence). Evacuate area immediately!',
              'critical',
            );
            HapticFeedback.heavyImpact();
          } else if (_lastPrecursorPattern == 'crack_propagation') {
            // Warning level: show snackbar + medium haptic
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('WARNING: $patternLabel detected ($confidence% confidence)'),
                  backgroundColor: Colors.orange,
                  duration: const Duration(seconds: 8),
                  action: SnackBarAction(
                    label: 'DETAILS',
                    textColor: Colors.white,
                    onPressed: () {
                      // User can see details in the precursor card already shown
                    },
                  ),
                ),
              );
            }
            // Medium haptic feedback
            HapticFeedback.mediumImpact();
          } else if (_lastPrecursorPattern == 'soil_creep') {
            // Caution level: log and rely on visual indicator (already shown in UI) + light haptic
            debugPrint('PRECURSOR: Soil creep pattern detected ($confidence% confidence)');
            // Light haptic feedback
            HapticFeedback.lightImpact();
          }
        }
      }
    }

    // 6. PPV trend prediction
    if (_ppv > 0 || _rms > 0) {
      _ppvKalmanHistory.add(_ppvKalman);

      if (_ppvKalmanHistory.length >= 5) {
        final limit = _dominantFreq <= 10 ? 3.0 : (_dominantFreq <= 50 ? 5.0 : 8.0);
        _ppvPrediction = _trendPredictor.predict(
          _ppvKalmanHistory.toList(),
          limitMmPerSec: limit,
        );
        needsRebuild = true;
      }
    }

    // Mark UI dirty — throttled timer will call setState
    if (needsRebuild && mounted) {
      _uiDirty = true;
    }

    // Clear transient flash after short delay
    if (hasNewTransient) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _transientFlash = false);
      });
    }
  }

  /// Send push notification for safety alerts
  void _sendAlertNotification(String level, String message) {
    // Only notify if alert level changed (prevent spam)
    if (_lastNotifiedAlertLevel == level) return;
    _lastNotifiedAlertLevel = level;

    if (level == 'critical') {
      NotificationService().showSafetyCritical(
        message: message,
        sensorType: 'Trench Safety',
      );
    } else if (level == 'warning') {
      NotificationService().showSafetyWarning(
        message: message,
        sensorType: 'Trench Safety',
      );
    } else {
      // Alert cleared
      _lastNotifiedAlertLevel = null;
    }
  }

  /// Trigger full-screen alert via parent Dashboard (works on all tabs)
  void _showAlertHistory(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1C2523),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: Row(
                  children: [
                    const Text('Alert History',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        await _alertHistory.clear();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Clear', style: TextStyle(color: Colors.white54)),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _alertHistory.load(),
                  builder: (_, snap) {
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107)));
                    final entries = snap.data!.reversed.toList();
                    if (entries.isEmpty) {
                      return const Center(child: Text('No alerts recorded', style: TextStyle(color: Colors.white54)));
                    }
                    return ListView.builder(
                      controller: controller,
                      itemCount: entries.length,
                      itemBuilder: (_, i) {
                        final e = entries[i];
                        final ts = DateTime.tryParse(e['timestamp'] ?? '');
                        final diff = ts != null ? DateTime.now().difference(ts) : null;
                        final ago = diff == null ? '' :
                            diff.inMinutes < 1 ? 'just now' :
                            diff.inHours < 1 ? '${diff.inMinutes}m ago' :
                            diff.inDays < 1 ? '${diff.inHours}h ago' :
                            '${diff.inDays}d ago';
                        final isCritical = e['level'] == 'critical';
                        return ListTile(
                          leading: Icon(Icons.warning_rounded,
                              color: isCritical ? Colors.red : const Color(0xFFFFC107)),
                          title: Text(e['message'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
                          subtitle: Text('${e['type']} · ${((e['ppv'] as num?) ?? 0).toStringAsFixed(2)} mm/s',
                              style: const TextStyle(color: Colors.white54, fontSize: 11)),
                          trailing: Text(ago, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _triggerFullScreenAlert(String message, String level) {
    try {
      widget.onAlert(message, level, AlertMetrics(
        ppv: _ppv,
        freq: _dominantFreq,
        staLta: _staLtaRatio,
        crestFactor: _crestFactor,
        kurtosis: _kurtosis,
        hazardType: _hazardType,
        ppvHistory: _ppvKalmanHistory.toList(),
      ));
      final now = DateTime.now();
      if (_lastHistoryLogTime == null ||
          now.difference(_lastHistoryLogTime!) > const Duration(seconds: 30)) {
        _lastHistoryLogTime = now;
        _alertHistory.add(
          level: level,
          type: _hazardType,
          ppv: _ppv,
          message: message,
        ).catchError((_) {});
      }
    } catch (e) {
      debugPrint('Alert callback failed: $e');
    }
  }

  /// Write a command to the device via the alert characteristic (App → Device)
  Future<void> _writeAlertCommand(String command) async {
    if (_alertCharacteristic == null) {
      debugPrint('>>> Alert characteristic not available for TX');
      return;
    }
    try {
      final bytes = utf8.encode(command);
      await _alertCharacteristic!.write(bytes, withoutResponse: false);
      debugPrint('>>> TX to device: $command');
    } catch (e) {
      debugPrint('>>> TX error: $e');
    }
  }

  String _generateDamageAssessment() {
    final ppv = _ppvSmoothed > 0 ? _ppvSmoothed : _ppv;
    if (ppv <= 0 && _rms <= 0) return '';

    final parts = <String>[];

    // DIN 4150-3 heritage structure assessment based on PPV + frequency
    if (ppv > 0) {
      final freqLimit = _dominantFreq <= 10 ? 3.0 : (_dominantFreq <= 50 ? 5.0 : 8.0);
      final ratio = ppv / freqLimit;
      if (ratio >= 1.0) {
        parts.add('PPV exceeds DIN 4150-3 heritage limit (${freqLimit.toStringAsFixed(0)} mm/s)');
      } else if (ratio >= 0.7) {
        parts.add('PPV approaching heritage limit (${(ratio * 100).toStringAsFixed(0)}%)');
      } else if (ratio >= 0.4) {
        parts.add('Moderate vibration — monitor closely');
      } else {
        parts.add('Vibration within safe limits');
      }
    }

    // Kurtosis assessment
    if (_kurtosis > 6) {
      parts.add('Severe impulsive loading detected (kurtosis ${_kurtosis.toStringAsFixed(1)})');
    } else if (_kurtosis > 3) {
      parts.add('Impact-type vibration present');
    }

    // STA/LTA assessment
    if (_staLtaRatio > 4.0) {
      parts.add('Seismic event trigger active (STA/LTA ${_staLtaRatio.toStringAsFixed(1)})');
    } else if (_staLtaRatio > 2.0) {
      parts.add('Elevated seismic activity');
    }

    // Crest factor
    if (_crestFactor > 5) {
      parts.add('High crest factor — transient impacts');
    }

    return parts.join('. ');
  }

  Future<void> _saveAlertToFirebase(String level, String message) async {
    try {
      // Get last known GPS position (non-blocking)
      double? lat, lng;
      try {
        final pos = await Geolocator.getLastKnownPosition();
        if (pos != null) {
          lat = pos.latitude;
          lng = pos.longitude;
        }
      } catch (e) {
        debugPrint('Geolocation unavailable for alert: $e');
      }

      final assessment = _generateDamageAssessment();
      await FirebaseFirestore.instance.collection('safety_alerts').add({
        'level': level,
        'message': message,
        'vibration': _vibration,
        'moisture': _moisturePercent,
        'accX': _accX,
        'accY': _accY,
        'accZ': _accZ,
        'ppv': _ppv,
        'rms': _rms,
        'freq': _dominantFreq,
        'crest': _crestFactor,
        'kurtosis': _kurtosis,
        'staLta': _staLtaRatio,
        'hazardType': _hazardType,
        'assessment': assessment,
        'deviceName': _connectedDevice?.platformName ?? 'Unknown',
        'timestamp': FieldValue.serverTimestamp(),
        if (lat != null) 'latitude': lat,
        if (lng != null) 'longitude': lng,
      }).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Error saving alert: $e');
    }
  }

  void _startFirebaseLogging() {
    _firebaseLogTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (mounted && _connectedDevice != null) {
        _saveSensorDataToFirebase();
      }
    });
  }

  Future<void> _saveSensorDataToFirebase() async {
    try {
      await FirebaseFirestore.instance.collection('sensor_data').add({
        'vibration': _vibration,
        'moisture': _moisturePercent,
        'accX': _accX,
        'accY': _accY,
        'accZ': _accZ,
        'ppv': _ppv,
        'rms': _rms,
        'freq': _dominantFreq,
        'crest': _crestFactor,
        'hazardType': _hazardType,
        'deviceName': _connectedDevice?.platformName ?? 'Unknown',
        'timestamp': FieldValue.serverTimestamp(),
      }).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Error saving sensor data: $e');
    }
  }

  Future<void> _loadSensorHistory() async {
    // Don't load from Firebase if device is connected - use live BLE data instead
    if (_connectedDevice != null) {
      debugPrint('Device connected - using live BLE data for graph');
      return;
    }

    try {
      // Only load from Firebase when no device connected
      final snapshot = await FirebaseFirestore.instance
          .collection('sensor_data')
          .orderBy('timestamp', descending: true)
          .limit(30)
          .get()
          .timeout(const Duration(seconds: 10));

      if (mounted && _connectedDevice == null) {
        setState(() {
          _sensorHistory.clear();
          final docs = snapshot.docs.reversed.toList();
          for (final doc in docs) {
            final data = doc.data();
            _sensorHistory.add({
              'vibration': (data['vibration'] as num?)?.toDouble() ?? 0.0,
              'moisture': (data['moisture'] as num?)?.toInt() ?? 0,
              'timestamp': (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
            });
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading sensor history: $e');
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  String _getVibrationStatus() {
    // DIN 4150-3 compliant status using PPV
    if (_effectivePpv > 10.0) return _t.tr('critical_evacuate');
    if (_effectivePpv > 3.0) return _t.tr('din_exceeded');
    if (_effectivePpv > 2.5) return _t.tr('heritage_limit');
    if (_effectivePpv > 0.3) return _t.tr('perceptible');
    // Fallback to legacy threshold if no PPV data
    if (_ppv == 0.0 && _vibration > 0.8) return _t.tr('critical_evacuate');
    if (_ppv == 0.0 && _vibration > 0.3) return _t.tr('use_caution');
    return _t.tr('safe');
  }

  String _getHazardTypeLabel() {
    switch (_hazardType) {
      case 'seismic': return 'Seismic Activity';
      case 'machinery': return 'Heavy Machinery';
      case 'structural': return 'Structural Risk';
      case 'hf_stress': return 'HF Stress';
      case 'impact': return 'Impact';
      case 'continuous': return 'Continuous Vib.';
      case 'source_change': return 'Source Changed';
      case 'moisture_low': return 'Dry Soil';
      case 'moisture_high': return 'Wet Soil';
      case 'test': return 'Test Alert';
      default: return 'Normal';
    }
  }

  Color _getPPVColor() {
    if (_effectivePpv > 10.0) return const Color(0xFFE53935); // Red - structural damage
    if (_effectivePpv > 3.0) return const Color(0xFFFF5722);  // Deep orange - DIN exceeded
    if (_effectivePpv > 2.5) return const Color(0xFFFF9800);  // Orange - heritage limit
    if (_effectivePpv > 0.3) return const Color(0xFFFFC107);  // Amber - perceptible
    return const Color(0xFF4CAF50);                    // Green - safe
  }

  String _getMoistureStatus() {
    if (_moisturePercent < 30) return _t.tr('too_dry');
    if (_moisturePercent > 60) return _t.tr('too_wet');
    return _t.tr('safe_range');
  }

  // === Site Calibration ===

  void _showCalibrationDialog() {
    final controller = TextEditingController(
      text: 'Site ${DateTime.now().toString().substring(0, 10)}',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: Text(_t.tr('calibration_title'), style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _t.tr('calibration_description'),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: _t.tr('site_name'),
                labelStyle: const TextStyle(color: Colors.white54),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.tealAccent),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_t.tr('cancel'), style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startCalibration(controller.text.trim());
            },
            child: Text(_t.tr('start'), style: const TextStyle(color: Colors.tealAccent)),
          ),
        ],
      ),
    );
  }

  void _startCalibration(String siteName) {
    if (siteName.isEmpty) return;
    _anomalyService.mlService.startCalibration();
    setState(() {
      _isCalibrating = true;
      _calibrationSiteName = siteName;
    });
  }

  void _stopCalibration() {
    final profile = _anomalyService.mlService.finishCalibration(
      _calibrationSiteName ?? 'Unknown',
    );
    setState(() => _isCalibrating = false);

    if (profile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_t.tr('not_enough_data')),
        ),
      );
      return;
    }

    _anomalyService.mlService.saveSiteProfile(profile);

    final warning = profile.highVarianceWarning
        ? _t.tr('high_variance_warning')
        : '';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_t.trArgs('site_learned', [profile.name])}$warning',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // === PPV Baseline Calibration ===

  double get _effectivePpv {
    final baseline = _settingsServiceCal.settings.calibrationBaselinePpv;
    return (_ppv - baseline).clamp(0.0, double.infinity);
  }

  Future<void> _startPpvCalibration() async {
    if (_isPpvCalibrating) return;
    setState(() {
      _isPpvCalibrating = true;
      _calibrationSamples.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Calibrating… keep sensor still for $_kCalibrationSeconds seconds'),
        duration: Duration(seconds: _kCalibrationSeconds),
      ),
    );
    await Future.delayed(const Duration(seconds: _kCalibrationSeconds));
    if (!mounted) return;
    final mean = _calibrationSamples.isEmpty
        ? 0.0
        : _calibrationSamples.fold(0.0, (a, b) => a + b) / _calibrationSamples.length;
    await _settingsServiceCal.updateSetting('calibrationBaselinePpv', mean);
    if (!mounted) return;
    setState(() => _isPpvCalibrating = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Baseline set: ${mean.toStringAsFixed(3)} mm/s')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final isConnected = _connectedDevice != null;

    return Stack(
      children: [
        // Main content
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0D3A39), Color(0xFF1C2523)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // HEADER
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                  child: Column(
                    children: [
                      // Title row
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _t.tr('trench_safety'),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                            ),
                          ),
                          LiveChip(isConnected: isConnected, status: _connectionStatus),
                          if (isConnected && _lastRssi != null) ...[
                            const SizedBox(width: 4),
                            _buildRssiChip(),
                          ],
                          if (isConnected) ...[
                            const SizedBox(width: 4),
                            _buildBatteryChip(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Action row
                      Row(
                        children: [
                          _buildSimpleModeToggle(),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => setState(() => _t.toggleLanguage()),
                            child: Text(_t.isGreek ? 'EN' : 'EL', style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                          ),
                          if (isConnected && _mlModelLoaded) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: _isCalibrating ? _stopCalibration : _showCalibrationDialog,
                              child: Icon(
                                _isCalibrating ? Icons.stop_circle_rounded : Icons.tune_rounded,
                                color: _isCalibrating ? Colors.orangeAccent : Colors.white70, size: 18,
                              ),
                            ),
                          ],
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.history_rounded, color: Colors.white70, size: 22),
                            tooltip: 'Alert History',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _showAlertHistory(context),
                          ),
                          TextButton.icon(
                            onPressed: _isPpvCalibrating ? null : _startPpvCalibration,
                            icon: Icon(
                              _isPpvCalibrating ? Icons.hourglass_top : Icons.tune_rounded,
                              size: 16,
                              color: _isPpvCalibrating ? Colors.white38 : Colors.white70,
                            ),
                            label: Text(
                              _isPpvCalibrating ? 'Calibrating…' : 'Calibrate',
                              style: TextStyle(
                                color: _isPpvCalibrating ? Colors.white38 : Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // Scan/Reconnect
                          if (!isConnected)
                            GestureDetector(
                              onTap: () { _reconnectTimer?.cancel(); _reconnectAttempts = 0; _checkBluetoothAndScan(); },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(color: const Color(0xFFFFC107), borderRadius: BorderRadius.circular(10)),
                                child: Text(_t.tr('scan'), style: const TextStyle(color: Color(0xFF0D3A39), fontSize: 12, fontWeight: FontWeight.w600)),
                              ),
                            ),
                          if (isConnected)
                            GestureDetector(
                              onTap: _disconnectDevice,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(color: Colors.red.withAlpha(180), borderRadius: BorderRadius.circular(10)),
                                child: Text(_t.tr('disconnect'), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // ===== SIMPLE MODE: archaeologist-friendly status =====
                if (_simpleMode)
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                      child: Column(
                        children: [
                          _buildSimpleStatusDisplay(isConnected),

                          // Current Alert Banner (always visible in both modes)
                          if (_alertLevel != 'safe' && _alertMessage.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            CurrentAlertBanner(level: _alertLevel, message: _alertMessage),
                          ],

                          // Test Alert button (always available in both modes)
                          if (isConnected && _alertCharacteristic != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: GestureDetector(
                                onTap: () => _writeAlertCommand('test'),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withAlpha(15),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white.withAlpha(40)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.notifications_active, color: Colors.white.withAlpha(150), size: 16),
                                      const SizedBox(width: 6),
                                      Text('Test Alert', style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 12)),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                          const SizedBox(height: 100),
                        ],
                      ),
                    ),
                  ),

                // ===== DETAILED MODE: tabbed technical view =====
                if (!_simpleMode)
                  Expanded(
                    child: DefaultTabController(
                      length: 3,
                      child: Column(
                        children: [
                          // Tab Bar
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 24),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(10),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: TabBar(
                              indicatorSize: TabBarIndicatorSize.tab,
                              indicator: BoxDecoration(
                                color: const Color(0xFFFFC107),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              labelColor: const Color(0xFF0D3A39),
                              unselectedLabelColor: Colors.white.withAlpha(180),
                              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                              tabs: const [
                                Tab(text: 'STATUS'),
                                Tab(text: 'ANALYSIS'),
                                Tab(text: 'STANDARDS'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Tab Bar View
                          Expanded(
                            child: TabBarView(
                              children: [
                                _buildStatusTab(isConnected),
                                _buildAnalysisTab(isConnected),
                                _buildStandardsTab(isConnected),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Build STATUS tab - most important, shown first
  Widget _buildStatusTab(bool isConnected) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // STATS ROW - PPV (primary metric) + Moisture
          Row(
            children: [
              Expanded(
                child: SafetyStatCard(
                  title: 'PPV (DIN 4150-3)',
                  value: _ppv > 0 ? '${_ppv.toStringAsFixed(1)} mm/s' : '${_vibration.toStringAsFixed(3)} g',
                  status: _getVibrationStatus(),
                  statusColor: _getPPVColor(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SafetyStatCard(
                  title: 'Soil Moisture',
                  value: '$_moisturePercent %',
                  status: _getMoistureStatus(),
                  statusColor: (_moisturePercent < 30 || _moisturePercent > 60) ? Colors.orange : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Vibration Analysis Card (v4.0)
          VibrationAnalysisCard(
            ppv: _ppv,
            rms: _rms,
            dominantFreq: _dominantFreq,
            crestFactor: _crestFactor,
            ppvSmoothed: _ppvSmoothed,
            ppvPeakHold: _ppvPeakHold,
            kurtosis: _kurtosis,
            staLtaRatio: _staLtaRatio,
            centroid: _centroid,
            arias: _arias,
            cav: _cav,
            temp: _temp,
            dwt1: _dwt1,
            dwt2: _dwt2,
            dwt3: _dwt3,
            hazardType: _hazardType,
            hazardLabel: _getHazardTypeLabel(),
            ppvColor: _getPPVColor(),
            isConnected: isConnected,
            damageAssessment: _generateDamageAssessment(),
            onHistoryTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const VibrationEventLogScreen()),
              );
            },
          ),
          const SizedBox(height: 12),

          // Precursor pattern warning card (if active)
          if (_isPrecursorDriven && _lastPrecursorPattern != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFF6F00).withAlpha(30),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFF6F00).withAlpha(100), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF6F00), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PRECURSOR: ${_formatPrecursorPattern(_lastPrecursorPattern!)}',
                          style: const TextStyle(color: Color(0xFFFF6F00), fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Confidence: ${(_lastPrecursorScore * 100).toStringAsFixed(0)}% — Physics-informed pattern match',
                          style: TextStyle(color: const Color(0xFFFF6F00).withAlpha(180), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Fukuzono TTF & PSD classification
          if (_fukuzonoTTF != null || _psdClassification != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: (_fukuzonoTTF != null && _fukuzonoTTF! < 600)
                    ? Colors.red.withAlpha(30)
                    : Colors.blueGrey.withAlpha(20),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: (_fukuzonoTTF != null && _fukuzonoTTF! < 600)
                      ? Colors.red.withAlpha(100)
                      : Colors.blueGrey.withAlpha(60),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_fukuzonoTTF != null) ...[
                    Text(
                      'Failure: ~${(_fukuzonoTTF! / 60).floor()}m ${(_fukuzonoTTF! % 60).floor()}s (R\u00B2=${_fukuzonoR2?.toStringAsFixed(2) ?? "?"})',
                      style: TextStyle(
                        color: _fukuzonoTTF! < 600 ? Colors.red : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_fukuzonoAlpha != null)
                      Text(
                        '\u03B1=${_fukuzonoAlpha!.toStringAsFixed(2)} (soil: 1.9-2.1)',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                  ],
                  if (_psdClassification != null)
                    Text(
                      'PSD: $_psdClassification (slope=${_psdSlope?.toStringAsFixed(1) ?? "?"})',
                      style: TextStyle(
                        color: _psdClassification == 'landslide' ? Colors.orange : Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // ML / Adaptive Anomaly Detection Indicator (Tier 2)
          if (_mlModelLoaded && _hasReceivedVibData)
            MLAnomalyIndicator(
              result: _lastAnomalyResult,
              features: _lastMLFeatures,
              anomalyHistory: _anomalyScoreHistory.toList(),
              modelVersion: _anomalyService.modeLabel,
            ),
          if (_mlModelLoaded && _hasReceivedVibData)
            const SizedBox(height: 12),

          // Live Sensors Card (legacy + enhanced)
          LiveSensorsCard(
            accX: _accX, accY: _accY, accZ: _accZ,
            vibration: _vibration,
            moisturePercent: _moisturePercent,
            lastUpdate: _lastUpdate,
            isConnected: isConnected,
            ppv: _ppv,
            dominantFreq: _dominantFreq,
            crestFactor: _crestFactor,
            rms: _rms,
            hazardType: _hazardType,
          ),
          const SizedBox(height: 12),

          // Alerts Card
          SafetyAlertsCard(alerts: _alerts),
          const SizedBox(height: 12),

          // Current Alert Banner (if any)
          if (_alertLevel != 'safe' && _alertMessage.isNotEmpty)
            CurrentAlertBanner(level: _alertLevel, message: _alertMessage),

          // Test Alert button (only when connected)
          if (isConnected && _alertCharacteristic != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GestureDetector(
                onTap: () => _writeAlertCommand('test'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withAlpha(40)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_active, color: Colors.white.withAlpha(150), size: 16),
                      const SizedBox(width: 6),
                      Text('Test Alert', style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),

          const SizedBox(height: 12),
          const SafetyInsightCard(),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  /// Build ANALYSIS tab - visualizations and trends
  Widget _buildAnalysisTab(bool isConnected) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wavelet Analysis Card (app-side DWT)
          if (_waveletBandEnergy.isNotEmpty)
            WaveletAnalysisCard(
              bandEnergy: _waveletBandEnergy,
              transients: _waveletTransients,
              transientFlash: _transientFlash,
              bufferFill: _waveletBuffer.length / _waveletBuffer.capacity,
            ),
          if (_waveletBandEnergy.isNotEmpty)
            const SizedBox(height: 12),

          // PPV Trend Warning Banner
          if (_ppvPrediction != null && _ppvPrediction!.isTrendingUp && _ppvPrediction!.minutesToLimit != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFF8F00).withAlpha(30),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFF8F00).withAlpha(100), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.trending_up, color: Color(0xFFFF8F00), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'PPV trending toward DIN 4150-3 limit in ~${_ppvPrediction!.minutesToLimit!.toStringAsFixed(1)} min '
                      '(R²=${_ppvPrediction!.rSquared.toStringAsFixed(2)})',
                      style: const TextStyle(color: Color(0xFFFF8F00), fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),

          // PPV Trend Graph with DIN 4150-3 limit lines
          RepaintBoundary(
            child: PPVTrendGraphCard(
              ppvHistory: _ppvHistory.toList(),
              prediction: _ppvPrediction,
              kalmanHistory: _ppvKalmanHistory.toList(),
            ),
          ),
          const SizedBox(height: 12),

          // Time-Frequency Spectrogram (RepaintBoundary isolates repaints)
          if (_spectrogramBuffer.length > 2)
            RepaintBoundary(child: _buildSpectrogramCard()),
          if (_spectrogramBuffer.length > 2)
            const SizedBox(height: 12),

          // Sensor History Graph Card (legacy moisture + vibration)
          RepaintBoundary(
            child: SensorHistoryGraphCard(sensorHistory: _sensorHistory.toList()),
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  /// Build STANDARDS tab - multi-standard classification and detailed metrics
  Widget _buildStandardsTab(bool isConnected) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Multi-Standard Classification Card
          if (_hasReceivedVibData)
            MultiStandardCard(
              classifications: _standardClassifications,
              damageIndex: _vibrationMetrics.damageIndex,
              housnerSI: _housnerSI,
              isConnected: isConnected,
            ),
          if (_hasReceivedVibData)
            const SizedBox(height: 12),

          // Detailed metrics display
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(10),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withAlpha(40)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Detailed Metrics',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                _buildMetricRow('Kurtosis', _kurtosis.toStringAsFixed(2)),
                _buildMetricRow('Crest Factor', _crestFactor.toStringAsFixed(2)),
                _buildMetricRow('STA/LTA Ratio', _staLtaRatio.toStringAsFixed(2)),
                _buildMetricRow('CAV', '${_cav.toStringAsFixed(3)} g·s'),
                _buildMetricRow('Arias Intensity', '${_arias.toStringAsFixed(3)} m/s'),
                _buildMetricRow('Spectral Centroid', '${_centroid.toStringAsFixed(1)} Hz'),
                _buildMetricRow('DWT Level 1 (50-100Hz)', _dwt1.toStringAsFixed(3)),
                _buildMetricRow('DWT Level 2 (25-50Hz)', _dwt2.toStringAsFixed(3)),
                _buildMetricRow('DWT Level 3 (12-25Hz)', _dwt3.toStringAsFixed(3)),
              ],
            ),
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  /// Helper to build a metric row
  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 13),
          ),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// Build the Simple/Detailed mode toggle chip for the header
  Widget _buildSimpleModeToggle() {
    final color = _simpleMode ? const Color(0xFF4CAF50) : const Color(0xFF2196F3);
    return GestureDetector(
      onTap: () => setState(() => _simpleMode = !_simpleMode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withAlpha(40),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_simpleMode ? Icons.shield_rounded : Icons.analytics_rounded, color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Text(_simpleMode ? 'Simple' : 'Detail', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// Determine the simplified safety level from all available data
  String _getSimpleSafetyLevel() {
    // Danger: PPV exceeds DIN 4150-3 heritage limits or critical alert active
    if (_effectivePpv > 3.0 || _alertLevel == 'critical') return 'danger';
    // Also danger if legacy vibration is critical and no PPV data
    if (_ppv == 0.0 && _vibration > 0.8) return 'danger';

    // Caution: approaching limits, warning alert, or notable vibration
    if (_effectivePpv > 1.5 || _alertLevel == 'warning') return 'caution';
    if (_effectivePpv > 0.3) return 'caution';
    if (_ppv == 0.0 && _vibration > 0.3) return 'caution';
    // Soil moisture out of range
    if (_moisturePercent > 0 && (_moisturePercent < 30 || _moisturePercent > 60)) return 'caution';

    return 'safe';
  }

  /// Build the simplified status display for archaeologists
  Widget _buildSimpleStatusDisplay(bool isConnected) {
    final safetyLevel = _getSimpleSafetyLevel();

    // Status color, label, and description
    final Color statusColor;
    final String statusLabel;
    final String statusDescription;
    final IconData statusIcon;

    switch (safetyLevel) {
      case 'danger':
        statusColor = const Color(0xFFE53935);
        statusLabel = _t.tr('stop_work');
        statusDescription = _t.tr('stop_description');
        statusIcon = Icons.dangerous_rounded;
        break;
      case 'caution':
        statusColor = const Color(0xFFFFC107);
        statusLabel = _t.tr('use_caution');
        statusDescription = _t.tr('caution_description');
        statusIcon = Icons.warning_amber_rounded;
        break;
      default:
        statusColor = const Color(0xFF4CAF50);
        statusLabel = _t.tr('safe_to_work');
        statusDescription = _t.tr('safe_description');
        statusIcon = Icons.check_circle_rounded;
    }

    // PPV context string
    final String ppvContext;
    if (_ppv > 0) {
      final freqLimit = _dominantFreq <= 10 ? 3.0 : (_dominantFreq <= 50 ? 5.0 : 8.0);
      final percentage = (_ppv / freqLimit * 100).clamp(0, 999).toStringAsFixed(0);
      if (_ppv >= freqLimit) {
        ppvContext = _t.trArgs('exceeds_limit', [_ppv.toStringAsFixed(1)]);
      } else if (_ppv >= freqLimit * 0.5) {
        ppvContext = _t.trArgs('percent_of_limit', [_ppv.toStringAsFixed(1), percentage]);
      } else {
        ppvContext = _t.trArgs('within_limits', [_ppv.toStringAsFixed(1)]);
      }
    } else if (_vibration > 0) {
      ppvContext = '${_vibration.toStringAsFixed(3)} g';
    } else {
      ppvContext = _t.tr('no_data');
    }

    // Find DIN 4150-3 classification for badge
    String dinBadge = '';
    for (final c in _standardClassifications) {
      if (c.standard == VibrationStandard.din4150) {
        dinBadge = 'DIN 4150-3: ${c.level}';
        break;
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: statusColor.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor.withAlpha(100), width: 1.5),
      ),
      child: Column(
        children: [
          // Status icon + label
          Icon(statusIcon, color: statusColor, size: 48),
          const SizedBox(height: 12),
          Text(statusLabel, style: TextStyle(color: statusColor, fontSize: 22, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(statusDescription, style: TextStyle(color: Colors.white.withAlpha(170), fontSize: 13, height: 1.4), textAlign: TextAlign.center),
          const SizedBox(height: 16),

          // PPV reading
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.speed_rounded, color: _getPPVColor(), size: 18),
              const SizedBox(width: 8),
              Flexible(child: Text(ppvContext, style: TextStyle(color: Colors.white.withAlpha(210), fontSize: 15, fontWeight: FontWeight.w600))),
            ],
          ),

          // Vector PPV
          if (_vectorPPV > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text("Vector PPV: ${_vectorPPV.toStringAsFixed(1)} mm/s", style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 13)),
            ),

          // DIN badge
          if (dinBadge.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(dinBadge, style: TextStyle(color: _getPPVColor(), fontSize: 12, fontWeight: FontWeight.w600)),
            ),

          // Soil moisture
          if (_moisturePercent > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Soil: $_moisturePercent% - ${_getMoistureStatus()}',
                style: TextStyle(
                  color: (_moisturePercent < 30 || _moisturePercent > 60) ? Colors.orange : Colors.white.withAlpha(160),
                  fontSize: 12,
                ),
              ),
            ),

          // Warnings section
          ..._buildSimpleWarnings(isConnected),

          // Connection info
          const SizedBox(height: 14),
          Text(
            isConnected ? _t.trArgs('sensor_active', [_lastUpdate]) : _t.tr('sensor_not_connected'),
            style: TextStyle(color: Colors.white.withAlpha(90), fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// Build warning cards for simple mode (extracted to reduce nesting)
  List<Widget> _buildSimpleWarnings(bool isConnected) {
    final warnings = <Widget>[];

    // PPV trend
    if (_ppvPrediction != null && _ppvPrediction!.isTrendingUp && _ppvPrediction!.minutesToLimit != null) {
      warnings.add(_simpleWarningRow(Icons.trending_up, const Color(0xFFFF8F00),
        'Vibration increasing - may exceed limits in ~${_ppvPrediction!.minutesToLimit!.toStringAsFixed(0)} min'));
    }

    // ML anomaly
    if (_mlModelLoaded && _lastAnomalyResult.level == AnomalyLevel.anomaly) {
      warnings.add(_simpleWarningRow(Icons.psychology_alt, Colors.redAccent, _t.tr('unusual_vibration')));
    }

    // Precursor
    if (_isPrecursorDriven && _lastPrecursorPattern != null) {
      warnings.add(_simpleWarningRow(Icons.warning_amber_rounded, const Color(0xFFFF6F00),
        'Precursor: ${_formatPrecursorPattern(_lastPrecursorPattern!)} (${(_lastPrecursorScore * 100).toStringAsFixed(0)}%)'));
    }

    // Fukuzono / PSD
    if (_fukuzonoTTF != null || _psdClassification != null) {
      final parts = <String>[];
      if (_fukuzonoTTF != null) parts.add('Failure: ~${(_fukuzonoTTF! / 60).floor()}m ${(_fukuzonoTTF! % 60).floor()}s');
      if (_psdClassification != null) parts.add('PSD: $_psdClassification');
      warnings.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(parts.join(' | '), style: TextStyle(
          color: (_fukuzonoTTF != null && _fukuzonoTTF! < 600) ? Colors.red : Colors.white54, fontSize: 11,
          fontWeight: _fukuzonoTTF != null ? FontWeight.w600 : FontWeight.normal,
        )),
      ));
    }

    // Low battery
    if (isConnected && _batteryPercent <= 20 && !_batteryCharging) {
      final c = _batteryPercent <= 10 ? Colors.red : Colors.orange;
      warnings.add(_simpleWarningRow(Icons.battery_alert_rounded, c,
        _batteryPercent <= 10 ? _t.tr('battery_critical') : _t.trArgs('battery_low', ['$_batteryPercent'])));
    }

    // Calibration
    if (_isCalibrating) {
      warnings.add(Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t.trArgs('learning_label', [_calibrationSiteName ?? '']),
              style: const TextStyle(color: Colors.tealAccent, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: _anomalyService.mlService.calibrationProgress, backgroundColor: Colors.white12, color: Colors.tealAccent),
          ],
        ),
      ));
    }

    return warnings;
  }

  Widget _simpleWarningRow(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  String _formatPrecursorPattern(String pattern) {
    switch (pattern) {
      case 'soil_creep': return _t.tr('soil_creep');
      case 'crack_propagation': return _t.tr('crack_propagation');
      case 'imminent_failure': return _t.tr('imminent_failure');
      default: return pattern;
    }
  }

  /// Build the spectrogram card with colormap selector
  Widget _buildSpectrogramCard() {
    const colormaps = ['viridis', 'hot', 'inferno'];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Spectrogram', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          // Colormap selector
          Row(
            children: colormaps.map((cm) {
              final selected = cm == _spectrogramColorMap;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _spectrogramColorMap = cm),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF9C27B0).withAlpha(60) : Colors.white.withAlpha(10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(cm, style: TextStyle(
                      color: selected ? const Color(0xFFCE93D8) : Colors.white.withAlpha(140), fontSize: 11,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    )),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: (MediaQuery.of(context).size.height * 0.12).clamp(150.0, 250.0),
            child: SpectrogramWidget(
              spectrogramData: _spectrogramBuffer.data,
              sampleRate: 200, fftSize: 256, maxFrequency: 100,
              colorMap: _spectrogramColorMap,
              height: (MediaQuery.of(context).size.height * 0.12).clamp(150.0, 250.0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRssiChip() {
    final rssi = _lastRssi ?? -100;
    final IconData icon;
    final Color color;
    if (rssi > -60) {
      icon = Icons.signal_cellular_4_bar;
      color = const Color(0xFF4CAF50);
    } else if (rssi > -75) {
      icon = Icons.signal_cellular_alt;
      color = const Color(0xFFFFC107);
    } else {
      icon = Icons.signal_cellular_alt_1_bar;
      color = Colors.orangeAccent;
    }
    return Tooltip(
      message: 'RSSI: $rssi dBm',
      child: Icon(icon, color: color, size: 16),
    );
  }

  /// Build battery indicator chip (v4.1)
  Widget _buildBatteryChip() {
    final Color batteryColor = _batteryCharging
        ? const Color(0xFF4CAF50) // Green when charging
        : _batteryPercent < 20
            ? Colors.red // Red when low
            : _batteryPercent < 50
                ? Colors.orange // Orange when medium
                : Colors.white; // White when good

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _batteryCharging ? Icons.battery_charging_full
              : _batteryPercent > 50 ? Icons.battery_full
              : _batteryPercent > 20 ? Icons.battery_3_bar
              : Icons.battery_1_bar,
          color: batteryColor, size: 16,
        ),
        const SizedBox(width: 2),
        Text('$_batteryPercent%', style: TextStyle(color: batteryColor, fontSize: 11, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
