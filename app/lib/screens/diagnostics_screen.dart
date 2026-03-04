import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/background_service.dart';
import '../services/connectivity_monitor_service.dart';
import '../services/critical_event_log_service.dart';
import '../services/inference_timing_service.dart';
import '../services/ml_anomaly_service.dart';
import '../services/network_status_service.dart';
import '../services/precursor_classifier_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../services/device_memory_service.dart';
import '../utils/ble_packet_tracker.dart';
import '../widgets/model_info_card.dart';

/// DiagnosticsScreen — read-only system diagnostic information panel.
///
/// Displays BLE status, firmware info, ML model stats, session metrics and
/// system info. Pull down to refresh all values.
class DiagnosticsScreen extends StatefulWidget {
  /// Optional live BLE state values provided by the caller (e.g. SafetyView).
  /// When null the screen shows "N/A" for fields it cannot retrieve itself.
  final DiagnosticsData? data;

  const DiagnosticsScreen({super.key, this.data});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

/// Snapshot of live values the caller can pass in to populate the screen.
class DiagnosticsData {
  final String? deviceName;
  final String? connectionState;
  final DateTime? lastPacketTime;
  final BlePacketTracker? packetTracker;
  final int? lastRssi;
  final DateTime? sessionStart;
  final int totalSamples;
  final double peakPpv;
  final double peakAnomalyScore;

  const DiagnosticsData({
    this.deviceName,
    this.connectionState,
    this.lastPacketTime,
    this.packetTracker,
    this.lastRssi,
    this.sessionStart,
    this.totalSamples = 0,
    this.peakPpv = 0.0,
    this.peakAnomalyScore = 0.0,
  });
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  String? _lastDeviceName;
  String? _modelFingerprint;
  int? _modelFileSizeBytes;
  bool _isLoading = true;

  // ── Precursor classifier state ────────────────────────────────────────────
  bool _precursorLoaded = false;
  String? _precursorLastError;

  // ── Firmware fields read from SharedPreferences ──────────────────────────
  String? _fwVersion;
  int? _fwSeq;
  int? _fwBoots;
  bool? _fwGain;    // true = ±16g high-gain active
  bool? _fwCal;     // true = calibration active
  double? _fwTmp;   // °C
  int? _fwUptime;   // seconds

  // ── Memory pressure: ML score-history buffer fill levels ──────────────────
  int _scoreHistoryLen = 0;
  int _scoreHistoryCapacity = 0;
  int _mlCalibrationSamples = 0;

  // ── Last 5 entries from BackgroundServiceManager status history ───────────
  List<String> _recentStatusHistory = [];

  // ── System / app fields ──────────────────────────────────────────────────
  DateTime? _appStartTime;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    // Load last device name from persistent memory
    String? lastDevice;
    try {
      lastDevice = await DeviceMemoryService.instance.getLastDeviceName();
    } catch (_) {
      lastDevice = null;
    }

    // Load model file size from asset bundle
    int? fileSize;
    try {
      final bytes = await rootBundle.load('assets/ml/vibration_anomaly.tflite');
      fileSize = bytes.lengthInBytes;
    } catch (_) {
      fileSize = null;
    }

    // Load firmware fields and app start time from SharedPreferences
    String? fwVersion;
    int? fwSeq;
    int? fwBoots;
    bool? fwGain;
    bool? fwCal;
    double? fwTmp;
    int? fwUptime;
    DateTime? appStartTime;

    try {
      final prefs = await SharedPreferences.getInstance();
      fwVersion = prefs.getString('fw_version');
      fwSeq = prefs.getInt('seq');
      fwBoots = prefs.getInt('boots');
      fwGain = prefs.getBool('gain');
      fwCal = prefs.getBool('cal');
      final tmpRaw = prefs.get('tmp');
      if (tmpRaw is double) {
        fwTmp = tmpRaw;
      } else if (tmpRaw is int) {
        fwTmp = tmpRaw.toDouble();
      }
      fwUptime = prefs.getInt('uptime');

      final appStartMs = prefs.getInt('app_start_time');
      if (appStartMs != null) {
        appStartTime = DateTime.fromMillisecondsSinceEpoch(appStartMs);
      }
    } catch (_) {
      // SharedPreferences unavailable — leave everything null.
    }

    if (!mounted) return;
    setState(() {
      _lastDeviceName = lastDevice;
      _modelFileSizeBytes = fileSize;
      _fwVersion = fwVersion;
      _fwSeq = fwSeq;
      _fwBoots = fwBoots;
      _fwGain = fwGain;
      _fwCal = fwCal;
      _fwTmp = fwTmp;
      _fwUptime = fwUptime;
      _appStartTime = appStartTime;
      _isLoading = false;

      final anomalyService = VibrationAnomalyService();
      _modelFingerprint = anomalyService.isInitialized
          ? anomalyService.modelFingerprint
          : null;

      // Precursor classifier — read isLoaded / lastError from singleton.
      final precursor = PrecursorClassifierService();
      _precursorLoaded = precursor.isLoaded;
      _precursorLastError = precursor.lastError;

      // Memory pressure: ML autoencoder score-history buffer fill level.
      final mlService = anomalyService.mlService;
      _scoreHistoryLen = mlService.scoreHistory.length;
      _scoreHistoryCapacity = MlAnomalyService.scoreHistoryCapacity;
      _mlCalibrationSamples = mlService.calibrationSampleCount;

      // Last 5 entries from BackgroundServiceManager status history.
      final allHistory = BackgroundServiceManager().statusHistory;
      _recentStatusHistory = allHistory.length <= 5
          ? List<String>.from(allHistory)
          : allHistory.sublist(allHistory.length - 5);
    });
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  String _formatBytes(int? bytes) {
    if (bytes == null) return 'N/A';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatDuration(Duration? d) {
    if (d == null) return 'N/A';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String _formatTimestamp(DateTime? dt) {
    if (dt == null) return 'N/A';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return dt.toLocal().toString().substring(0, 19);
  }

  /// Format raw uptime seconds as "Xh Ym Zs".
  String _formatUptimeSeconds(int? totalSeconds) {
    if (totalSeconds == null) return 'N/A';
    final d = Duration(seconds: totalSeconds);
    return _formatDuration(d);
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B1A),
      appBar: AppBar(
        title: const Text(
          'Diagnostics',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF0D3A39),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFFC107)),
            )
          : RefreshIndicator(
              color: const Color(0xFFFFC107),
              backgroundColor: const Color(0xFF1C2523),
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildBleSection(),
                  const SizedBox(height: 16),
                  _buildBlePacketStatsSection(),
                  const SizedBox(height: 16),
                  _buildFirmwareSection(),
                  const SizedBox(height: 16),
                  _buildMlSection(),
                  const SizedBox(height: 16),
                  _buildMemoryPressureSection(),
                  const SizedBox(height: 16),
                  _buildSessionSection(),
                  const SizedBox(height: 16),
                  _buildSystemSection(),
                  const SizedBox(height: 16),
                  _buildRecentErrorsSection(),
                  const SizedBox(height: 24),
                  _buildExportButton(),
                  const SizedBox(height: 12),
                  _buildResetButton(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  // ─── Section builders ────────────────────────────────────────────────────────

  Widget _buildBleSection() {
    final d = widget.data;
    final tracker = d?.packetTracker;
    final effectiveName = d?.deviceName ?? _lastDeviceName;

    return _DiagCard(
      title: 'BLE Status',
      icon: Icons.bluetooth,
      iconColor: const Color(0xFF2196F3),
      rows: [
        _DiagRow('Device name', effectiveName ?? 'Not connected'),
        _DiagRow('Connection state', d?.connectionState ?? 'Unknown'),
        _DiagRow('Last packet', _formatTimestamp(d?.lastPacketTime)),
        _DiagRow(
          'Missed packets',
          tracker != null
              ? '${tracker.missedPackets} / ${tracker.totalPackets} '
                  '(${(tracker.missRate * 100).toStringAsFixed(1)}%)'
              : 'N/A',
        ),
        _DiagRow(
          'RSSI',
          d?.lastRssi != null ? '${d!.lastRssi} dBm' : 'N/A',
        ),
      ],
    );
  }

  /// BLE Packet Stats — dedicated card with total/dropped/drop-rate summary.
  ///
  /// The drop-rate badge is colour-coded: green < 1%, amber 1–5%, red >= 5%.
  /// When no tracker is available (device not connected) shows placeholders.
  Widget _buildBlePacketStatsSection() {
    final tracker = widget.data?.packetTracker;

    final totalLabel =
        tracker != null ? '${tracker.totalPackets}' : 'N/A — not connected';
    final droppedLabel =
        tracker != null ? '${tracker.missedPackets}' : 'N/A';
    final dropRateText = tracker != null
        ? '${(tracker.missRate * 100).toStringAsFixed(2)} %'
        : 'N/A';

    // Colour for the drop-rate badge based on severity.
    Color dropRateColor = const Color(0xFF4CAF50); // green — healthy
    if (tracker != null) {
      final rate = tracker.missRate;
      if (rate >= 0.05) {
        dropRateColor = const Color(0xFFF44336); // red — >5% loss
      } else if (rate >= 0.01) {
        dropRateColor = const Color(0xFFFFC107); // amber — 1–5% loss
      }
    }

    return _DiagCardWithExtra(
      title: 'BLE Packet Stats',
      icon: Icons.analytics_outlined,
      iconColor: const Color(0xFF29B6F6),
      rows: [
        _DiagRow('Total received', totalLabel),
        _DiagRow('Dropped packets', droppedLabel),
      ],
      extra: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 160,
              child: Text(
                'Drop rate',
                style: TextStyle(
                  color: Colors.white.withAlpha(160),
                  fontSize: 13,
                ),
              ),
            ),
            tracker != null
                ? Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: dropRateColor.withAlpha(40),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: dropRateColor, width: 1),
                    ),
                    child: Text(
                      dropRateText,
                      style: TextStyle(
                        color: dropRateColor,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                : Text(
                    dropRateText,
                    style: TextStyle(
                      color: Colors.white.withAlpha(160),
                      fontSize: 13,
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildFirmwareSection() {
    String gainLabel;
    if (_fwGain == null) {
      gainLabel = 'N/A';
    } else {
      gainLabel = _fwGain! ? 'Active (±16g)' : 'Normal (±4g)';
    }

    String calLabel;
    if (_fwCal == null) {
      calLabel = 'N/A';
    } else {
      calLabel = _fwCal! ? 'Yes' : 'No';
    }

    String tmpLabel;
    if (_fwTmp == null) {
      tmpLabel = 'N/A';
    } else {
      tmpLabel = '${_fwTmp!.toStringAsFixed(1)} °C';
    }

    return _DiagCard(
      title: 'Firmware',
      icon: Icons.developer_board,
      iconColor: const Color(0xFF00BCD4),
      rows: [
        _DiagRow('Version', _fwVersion ?? 'Not connected'),
        _DiagRow('Sequence number', _fwSeq != null ? '$_fwSeq' : 'N/A'),
        _DiagRow('Boot count', _fwBoots != null ? '$_fwBoots' : 'N/A'),
        _DiagRow('High-gain mode', gainLabel),
        _DiagRow('Calibration active', calLabel),
        _DiagRow('Temperature', tmpLabel),
        _DiagRow('Uptime', _formatUptimeSeconds(_fwUptime)),
      ],
    );
  }

  Widget _buildMlSection() {
    final timing = InferenceTimingService.instance;
    final anomalyService = VibrationAnomalyService();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section heading
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF9C27B0).withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.memory,
                    color: Color(0xFF9C27B0), size: 18),
              ),
              const SizedBox(width: 10),
              const Text(
                'ML Models',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
        // ── Autoencoder / anomaly model card ────────────────────────────────
        ModelInfoCard(
          modelName: 'Vibration Anomaly (Autoencoder)',
          version: anomalyService.isInitialized
              ? anomalyService.modelVersion
              : '',
          inputDim: 17,
          fingerprint: _modelFingerprint ?? '',
          isLoaded: anomalyService.isInitialized,
          avgInferenceMs: timing.count > 0 ? timing.avgMs : null,
          lastError: anomalyService.isInitialized ? null : 'Model not loaded',
        ),
        const SizedBox(height: 10),
        // ── Precursor classifier card ────────────────────────────────────────
        ModelInfoCard(
          modelName: 'Precursor Classifier',
          version: '',
          inputDim: 17,
          fingerprint: '',
          isLoaded: _precursorLoaded,
          avgInferenceMs: null,
          lastError: _precursorLastError,
        ),
        const SizedBox(height: 10),
        // ── Raw timing stats card (existing detail rows) ─────────────────────
        _DiagCard(
          title: 'Inference Timing',
          icon: Icons.timer_outlined,
          iconColor: const Color(0xFF9C27B0),
          rows: [
            _DiagRow('Model file size', _formatBytes(_modelFileSizeBytes)),
            _DiagRow(
              'Avg inference',
              timing.count > 0
                  ? '${timing.avgMs.toStringAsFixed(1)} ms'
                  : 'N/A',
            ),
            _DiagRow(
              'Last inference',
              timing.count > 0
                  ? '${timing.maxMs.toStringAsFixed(1)} ms'
                  : 'N/A',
            ),
            _DiagRow(
              'Min / Max',
              timing.count > 0
                  ? '${timing.minMs.toStringAsFixed(1)} ms / '
                      '${timing.maxMs.toStringAsFixed(1)} ms'
                  : 'N/A',
            ),
            _DiagRow('Total inferences', '${timing.count}'),
          ],
        ),
      ],
    );
  }

  /// Memory Pressure — shows how full the key in-memory buffers are.
  ///
  /// A full score-history buffer (100/100) is expected during normal
  /// operation. Calibration samples only accumulate during the initial
  /// 600-sample window and reset to 0 once calibration completes.
  Widget _buildMemoryPressureSection() {
    final fillLabel = _scoreHistoryCapacity > 0
        ? '$_scoreHistoryLen / $_scoreHistoryCapacity'
        : 'N/A';
    final fillPct = _scoreHistoryCapacity > 0
        ? _scoreHistoryLen / _scoreHistoryCapacity
        : 0.0;

    return Card(
      color: const Color(0xFF1C2523),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF66BB6A).withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.storage_outlined,
                  color: Color(0xFF66BB6A), size: 20),
            ),
            title: const Text(
              'Memory Pressure',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
          Divider(color: Colors.white.withAlpha(30), height: 1),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Score history fill bar
                Row(
                  children: [
                    SizedBox(
                      width: 160,
                      child: Text(
                        'Score history',
                        style: TextStyle(
                          color: Colors.white.withAlpha(160),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      fillLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fillPct,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      fillPct > 0.9
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFF66BB6A),
                    ),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 12),
                // Calibration sample count
                Row(
                  children: [
                    SizedBox(
                      width: 160,
                      child: Text(
                        'Calibration samples',
                        style: TextStyle(
                          color: Colors.white.withAlpha(160),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _mlCalibrationSamples > 0
                            ? '$_mlCalibrationSamples'
                            : 'Done or not started',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionSection() {
    final d = widget.data;
    Duration? sessionDuration;
    if (d?.sessionStart != null) {
      sessionDuration = DateTime.now().difference(d!.sessionStart!);
    }

    return _DiagCard(
      title: 'Session',
      icon: Icons.timeline,
      iconColor: const Color(0xFF4CAF50),
      rows: [
        _DiagRow('Session duration', _formatDuration(sessionDuration)),
        _DiagRow(
          'Total samples received',
          d != null ? '${d.totalSamples}' : 'N/A',
        ),
        _DiagRow(
          'Peak PPV',
          d != null ? '${d.peakPpv.toStringAsFixed(3)} mm/s' : 'N/A',
        ),
        _DiagRow(
          'Peak anomaly score',
          d != null ? d.peakAnomalyScore.toStringAsFixed(3) : 'N/A',
        ),
      ],
    );
  }

  Widget _buildSystemSection() {
    // App uptime
    String appUptimeLabel;
    if (_appStartTime != null) {
      appUptimeLabel = _formatDuration(DateTime.now().difference(_appStartTime!));
    } else {
      appUptimeLabel = 'N/A';
    }

    // Connectivity monitor status
    final connectivity = ConnectivityMonitorService.instance;
    final healthStatus = connectivity.healthStatus;
    String connectivityLabel;
    switch (healthStatus) {
      case CombinedHealthStatus.fullyConnected:
        connectivityLabel = 'BLE + Network';
        break;
      case CombinedHealthStatus.bleOnlyConnected:
        connectivityLabel = 'BLE only (no network)';
        break;
      case CombinedHealthStatus.networkOnlyConnected:
        connectivityLabel = 'Network only (no BLE)';
        break;
      case CombinedHealthStatus.fullyDisconnected:
        connectivityLabel = 'Disconnected';
        break;
      case CombinedHealthStatus.unknown:
        connectivityLabel = 'Unknown';
        break;
    }

    // BLE offline duration
    final bleOffline = connectivity.bleOfflineDuration;
    final bleOfflineLabel = connectivity.isBleConnected
        ? 'Connected'
        : (bleOffline == Duration.zero
            ? 'Never connected'
            : _formatDuration(bleOffline));

    // Network status
    final networkStatus = NetworkStatusService.instance.status;
    String networkLabel;
    switch (networkStatus) {
      case NetworkStatus.connected:
        networkLabel = 'Connected';
        break;
      case NetworkStatus.disconnected:
        networkLabel = 'Disconnected';
        break;
      case NetworkStatus.unknown:
        networkLabel = 'Unknown';
        break;
    }

    return _DiagCard(
      title: 'System',
      icon: Icons.settings_applications,
      iconColor: const Color(0xFFFFC107),
      rows: [
        _DiagRow('Operating system', Platform.operatingSystem),
        _DiagRow('OS version', Platform.operatingSystemVersion),
        const _DiagRow('Memory usage', 'N/A (mobile)'),
        _DiagRow('App uptime', appUptimeLabel),
        _DiagRow('Connectivity status', connectivityLabel),
        _DiagRow('Network status', networkLabel),
        _DiagRow('BLE offline duration', bleOfflineLabel),
      ],
    );
  }

  /// Last 5 Service Events — pulled from BackgroundServiceManager.statusHistory.
  ///
  /// Shows the most recent service lifecycle events (start/stop/errors) in
  /// reverse-chronological order. Each entry has an ISO timestamp prefix.
  Widget _buildRecentErrorsSection() {
    return Card(
      color: const Color(0xFF1C2523),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFEF5350).withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.error_outline,
                  color: Color(0xFFEF5350), size: 20),
            ),
            title: const Text(
              'Last 5 Service Events',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
          Divider(color: Colors.white.withAlpha(30), height: 1),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _recentStatusHistory.isEmpty
                ? Text(
                    'No service events recorded yet.',
                    style: TextStyle(
                      color: Colors.white.withAlpha(120),
                      fontSize: 13,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _recentStatusHistory.reversed
                        .map(
                          (entry) => Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              entry,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildExportButton() {
    return Center(
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1C2523),
          foregroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFFEF5350)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: const Icon(Icons.download_rounded, color: Color(0xFFEF5350)),
        label: const Text(
          'Export Critical Events',
          style: TextStyle(
            color: Color(0xFFEF5350),
            fontWeight: FontWeight.bold,
          ),
        ),
        onPressed: _exportCriticalEvents,
      ),
    );
  }

  Widget _buildResetButton() {
    return Center(
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white54,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
        onPressed: _resetDiagnosticCounters,
        child: const Text('Reset diagnostic counters'),
      ),
    );
  }

  Future<void> _exportCriticalEvents() async {
    try {
      final service = CriticalEventLogService.instance;
      service.exportAsCsv();

      // Show a snackbar only if there were no events (exportAsCsv returns
      // silently when empty).
      if (mounted && service.events.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No critical events logged yet.'),
            backgroundColor: Color(0xFF1C2523),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red[900],
          ),
        );
      }
    }
  }

  Future<void> _resetDiagnosticCounters() async {
    try {
      // Reset ML inference timing counters
      InferenceTimingService.instance.reset();

      // Reset anomaly service baseline/adaptive counters
      VibrationAnomalyService.instance.resetBaseline();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Diagnostic counters reset'),
            backgroundColor: Color(0xFF1C2523),
          ),
        );
        // Refresh the displayed values after reset
        _refresh();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reset failed: $e'),
            backgroundColor: Colors.red[900],
          ),
        );
      }
    }
  }
}

// ─── Reusable sub-widgets ─────────────────────────────────────────────────────

class _DiagCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<_DiagRow> rows;

  const _DiagCard({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1C2523),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
          // Divider
          Divider(color: Colors.white.withAlpha(30), height: 1),
          // Key-value rows
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: rows.map((row) => _buildRow(row)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(_DiagRow row) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              row.key,
              style: TextStyle(
                color: Colors.white.withAlpha(160),
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              row.value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Variant of [_DiagCard] that accepts an optional [extra] widget rendered
/// after the key-value rows (used for coloured drop-rate badge etc.).
class _DiagCardWithExtra extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<_DiagRow> rows;
  final Widget extra;

  const _DiagCardWithExtra({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.rows,
    required this.extra,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1C2523),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
          Divider(color: Colors.white.withAlpha(30), height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...rows.map(
                  (row) => Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 160,
                          child: Text(
                            row.key,
                            style: TextStyle(
                              color: Colors.white.withAlpha(160),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            row.value,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                extra,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagRow {
  final String key;
  final String value;

  const _DiagRow(this.key, this.value);
}
