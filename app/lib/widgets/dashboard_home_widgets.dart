import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class LogoCard extends StatelessWidget {
  const LogoCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/logo.png', width: 40, height: 40, fit: BoxFit.contain);
  }
}

/// Simple stat row: Total | Today
class CombinedStatCard extends StatelessWidget {
  final String totalFindings;
  final String todayFindings;

  const CombinedStatCard({
    super.key,
    required this.totalFindings,
    required this.todayFindings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _stat('Total', totalFindings),
          Container(width: 1, height: 32, color: Colors.white.withAlpha(40)),
          _stat('Today', todayFindings),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 12)),
        ],
      ),
    );
  }
}

/// Compact BLE connection status
class ActiveDevicesCard extends StatefulWidget {
  const ActiveDevicesCard({super.key});

  @override
  State<ActiveDevicesCard> createState() => ActiveDevicesCardState();
}

class ActiveDevicesCardState extends State<ActiveDevicesCard> {
  int _connectedCount = 0;
  String _deviceName = '';
  late StreamSubscription<List<BluetoothDevice>> _subscription;

  @override
  void initState() {
    super.initState();
    _checkConnectedDevices();
    _subscription = Stream.periodic(const Duration(seconds: 3))
        .asyncMap((_) => FlutterBluePlus.connectedDevices)
        .listen((devices) {
      if (mounted) {
        setState(() {
          _connectedCount = devices.length;
          _deviceName = devices.isNotEmpty
              ? (devices.first.platformName.isNotEmpty ? devices.first.platformName : 'M5StickC')
              : '';
        });
      }
    });
  }

  Future<void> _checkConnectedDevices() async {
    try {
      final devices = FlutterBluePlus.connectedDevices;
      if (mounted) {
        setState(() {
          _connectedCount = devices.length;
          _deviceName = devices.isNotEmpty
              ? (devices.first.platformName.isNotEmpty ? devices.first.platformName : 'M5StickC')
              : '';
        });
      }
    } catch (e) {
      debugPrint('Error checking connected devices: $e');
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connectedCount > 0;
    final color = connected ? const Color(0xFF4CAF50) : Colors.white.withAlpha(100);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: connected ? const Color(0xFF4CAF50).withAlpha(25) : Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
        border: connected ? Border.all(color: const Color(0xFF4CAF50).withAlpha(80)) : null,
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              connected ? _deviceName : 'No sensor connected',
              style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
          if (connected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50).withAlpha(50),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('LIVE',
                  style: TextStyle(color: Color(0xFF4CAF50), fontSize: 10, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

/// Simple last findings list
class LastFindingsCard extends StatelessWidget {
  final List<Map<String, dynamic>> findings;

  const LastFindingsCard({super.key, required this.findings});

  String _formatTime(dynamic createdAt) {
    if (createdAt == null) return '--:--';
    if (createdAt is Timestamp) {
      final dt = createdAt.toDate();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '--:--';
  }

  @override
  Widget build(BuildContext context) {
    if (findings.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent', style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 13)),
        const SizedBox(height: 8),
        ...findings.take(3).map((f) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Text(_formatTime(f['createdAt']),
                      style: TextStyle(color: Colors.white.withAlpha(140), fontSize: 12)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(f['type'] ?? 'Unknown',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                  ),
                  Text(f['site'] ?? '',
                      style: TextStyle(color: Colors.white.withAlpha(140), fontSize: 12)),
                ],
              ),
            )),
      ],
    );
  }
}
