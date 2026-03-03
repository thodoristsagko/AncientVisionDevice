import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/inference_timing_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../services/device_memory_service.dart';
import '../utils/ble_packet_tracker.dart';

/// DiagnosticsScreen — read-only system diagnostic information panel.
///
/// Displays BLE status, ML model stats, session metrics and system info.
/// Pull down to refresh all values.
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

    if (mounted) {
      setState(() {
        _lastDeviceName = lastDevice;
        _modelFileSizeBytes = fileSize;
        _isLoading = false;
        final anomalyService = VibrationAnomalyService();
        _modelFingerprint = anomalyService.isInitialized
            ? anomalyService.modelFingerprint
            : null;
      });
    }
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
                  _buildMlSection(),
                  const SizedBox(height: 16),
                  _buildSessionSection(),
                  const SizedBox(height: 16),
                  _buildSystemSection(),
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

  Widget _buildMlSection() {
    final timing = InferenceTimingService.instance;
    final anomalyService = VibrationAnomalyService();

    final lastMs = timing.count > 0
        ? '${timing.maxMs.toStringAsFixed(1)} ms'
        : 'N/A';
    final avgMs = timing.count > 0
        ? '${timing.avgMs.toStringAsFixed(1)} ms'
        : 'N/A';
    final fingerprint = _modelFingerprint ?? 'Not loaded';

    return _DiagCard(
      title: 'ML Model',
      icon: Icons.memory,
      iconColor: const Color(0xFF9C27B0),
      rows: [
        _DiagRow('Model file size', _formatBytes(_modelFileSizeBytes)),
        _DiagRow('Model fingerprint', fingerprint),
        _DiagRow('Model version',
            anomalyService.isInitialized ? anomalyService.modelVersion : 'N/A'),
        _DiagRow('Model type',
            anomalyService.isInitialized ? anomalyService.modelType : 'N/A'),
        _DiagRow('Last inference time', lastMs),
        _DiagRow('Avg inference time', avgMs),
        _DiagRow('Total inferences', '${timing.count}'),
      ],
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
    return _DiagCard(
      title: 'System',
      icon: Icons.settings_applications,
      iconColor: const Color(0xFFFFC107),
      rows: [
        _DiagRow('Operating system', Platform.operatingSystem),
        _DiagRow('OS version', Platform.operatingSystemVersion),
        _DiagRow(
          'Available memory',
          'See device settings (not available via Dart VM)',
        ),
      ],
    );
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

class _DiagRow {
  final String key;
  final String value;

  const _DiagRow(this.key, this.value);
}
