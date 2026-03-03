import 'package:flutter/material.dart';

/// Immutable data class holding information about a discovered BLE device.
class BleDeviceInfo {
  final String id;
  final String name;
  final DateTime lastSeen;
  final int rssi; // dBm — typically -40 (strong) to -100 (weak)

  const BleDeviceInfo({
    required this.id,
    required this.name,
    required this.lastSeen,
    required this.rssi,
  });
}

/// Displays a scrollable list of recently seen BLE devices.
///
/// Each tile shows the device name, ID, last-seen time and signal strength.
/// Tapping a tile calls [onSelect] with the chosen [BleDeviceInfo].
class DeviceListWidget extends StatefulWidget {
  /// The list of discovered BLE devices to display.
  final List<BleDeviceInfo> devices;

  /// Callback invoked when the user taps a device tile.
  final Function(BleDeviceInfo) onSelect;

  const DeviceListWidget({
    super.key,
    required this.devices,
    required this.onSelect,
  });

  @override
  State<DeviceListWidget> createState() => _DeviceListWidgetState();
}

class _DeviceListWidgetState extends State<DeviceListWidget> {
  @override
  Widget build(BuildContext context) {
    if (widget.devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth_searching, size: 48, color: Colors.grey),
              SizedBox(height: 12),
              Text(
                'No devices found.\nMake sure your sensor is powered on.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: widget.devices.length,
      itemBuilder: (context, index) {
        final device = widget.devices[index];
        return _DeviceTile(
          device: device,
          onTap: () => widget.onSelect(device),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Internal tile widget
// ---------------------------------------------------------------------------

class _DeviceTile extends StatelessWidget {
  final BleDeviceInfo device;
  final VoidCallback onTap;

  const _DeviceTile({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: onTap,
        leading: _SignalStrengthBar(rssi: device.rssi),
        title: Text(
          device.name.isEmpty ? '(Unknown)' : device.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              device.id,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _relativeTime(device.lastSeen),
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        isThreeLine: true,
      ),
    );
  }

  /// Returns a human-readable relative time string for [time].
  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 10) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds} sec ago';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return '$m ${m == 1 ? 'min' : 'min'} ago';
    }
    final h = diff.inHours;
    return '$h ${h == 1 ? 'hour' : 'hours'} ago';
  }
}

// ---------------------------------------------------------------------------
// Signal strength indicator (1–4 bars)
// ---------------------------------------------------------------------------

class _SignalStrengthBar extends StatelessWidget {
  final int rssi; // dBm

  const _SignalStrengthBar({required this.rssi});

  /// Maps RSSI to a bar count 1–4.
  ///
  /// -40 dBm or better  → 4 bars (excellent)
  /// -60 to -41         → 3 bars (good)
  /// -75 to -61         → 2 bars (fair)
  /// below -75          → 1 bar  (poor)
  int get _bars {
    if (rssi >= -40) return 4;
    if (rssi >= -60) return 3;
    if (rssi >= -75) return 2;
    return 1;
  }

  Color get _color {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -75) return Colors.orange;
    return Colors.red;
  }

  IconData get _icon {
    switch (_bars) {
      case 4:
        return Icons.signal_cellular_4_bar;
      case 3:
        return Icons.signal_cellular_alt;
      case 2:
        return Icons.signal_cellular_alt_2_bar;
      case 1:
      default:
        return Icons.signal_cellular_alt_1_bar;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_icon, color: _color, size: 28),
        Text(
          '$rssi dBm',
          style: TextStyle(fontSize: 9, color: _color),
        ),
      ],
    );
  }
}
