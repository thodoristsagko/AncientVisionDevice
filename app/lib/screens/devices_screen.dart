import 'package:flutter/material.dart';
import '../services/device_memory_service.dart';
import '../utils/app_styles.dart';

/// DevicesScreen — manage saved BLE devices.
///
/// Shows the device stored in [DeviceMemoryService] (one device is retained
/// across sessions). Long-press any tile to forget that device. The scan FAB
/// navigates back so the caller can trigger BLE scanning.
class DevicesScreen extends StatefulWidget {
  /// Called when the user taps "Connect" on a saved device tile.
  /// The device ID is passed so the caller can initiate connection.
  final void Function(String deviceId, String deviceName)? onConnect;

  /// Called when the user taps the Scan FAB.
  final VoidCallback? onScan;

  const DevicesScreen({
    super.key,
    this.onConnect,
    this.onScan,
  });

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  _SavedDevice? _savedDevice;
  DateTime? _lastSeenAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final id = await DeviceMemoryService.instance.getLastDeviceId();
      final name = await DeviceMemoryService.instance.getLastDeviceName();
      final seenAt = await DeviceMemoryService.instance.getLastSeenAt();

      if (mounted) {
        setState(() {
          _savedDevice = (id != null && name != null)
              ? _SavedDevice(id: id, name: name)
              : null;
          _lastSeenAt = seenAt;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _savedDevice = null;
          _lastSeenAt = null;
          _loading = false;
        });
      }
    }
  }

  Future<void> _forgetDevice() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        title: const Text('Forget Device?', style: AppTextStyles.h3),
        content: const Text(
          'This will remove the saved device. You will need to scan and reconnect manually.',
          style: AppTextStyles.subtitle,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: AppTextStyles.button
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Forget',
                style: AppTextStyles.button.copyWith(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DeviceMemoryService.instance.clearDevice();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device forgotten')),
        );
      }
    }
  }

  // ── Last-seen label helper ──────────────────────────────────────────────────

  /// Returns a human-readable "last seen X ago" string, or null if unknown.
  String? _lastSeenLabel(DateTime? seenAt) {
    if (seenAt == null) return null;
    final diff = DateTime.now().difference(seenAt);
    if (diff.inSeconds < 60) return 'last seen just now';
    if (diff.inMinutes < 60) return 'last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'last seen ${diff.inHours}h ago';
    return 'last seen ${diff.inDays}d ago';
  }

  // ── RSSI signal icon helper ─────────────────────────────────────────────────

  /// Returns a WiFi-style icon representing approximate signal strength.
  /// We use WiFi icons as a signal-strength analogue since Material does not
  /// have a generic RSSI icon. RSSI typically ranges from -30 (excellent) to
  /// -90 (very poor) dBm for BLE.
  Widget _rssiIcon(int? rssi) {
    final IconData icon;
    final Color color;

    if (rssi == null) {
      icon = Icons.signal_cellular_nodata;
      color = Colors.white38;
    } else if (rssi >= -60) {
      icon = Icons.network_wifi;
      color = Colors.green;
    } else if (rssi >= -75) {
      icon = Icons.network_wifi_3_bar;
      color = Colors.amber;
    } else {
      icon = Icons.network_wifi_1_bar;
      color = Colors.red;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 20),
        if (rssi != null)
          Text(
            '$rssi dBm',
            style: TextStyle(color: color, fontSize: 9),
          ),
      ],
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Saved Devices', style: AppTextStyles.h3),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: Container(
        decoration: AppDecorations.screenBackground,
        child: SafeArea(
          child: _loading
              ? AppWidgets.loading()
              : _savedDevice == null
                  ? _buildEmptyState()
                  : _buildDeviceList(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (widget.onScan != null) {
            widget.onScan!();
          } else {
            Navigator.pop(context);
          }
        },
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.primary,
        icon: const Icon(Icons.bluetooth_searching),
        label: const Text('Scan', style: AppTextStyles.buttonSmall),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth_disabled,
              size: 72, color: AppColors.textHint),
          SizedBox(height: AppSpacing.lg),
          Text(
            'No saved devices.',
            style: AppTextStyles.h3,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: AppSpacing.sm),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Scan to find your AncientVision sensor.',
              style: AppTextStyles.subtitle,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    final device = _savedDevice!;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        AppWidgets.sectionHeader('Known Sensor', Icons.bluetooth_connected),
        const SizedBox(height: AppSpacing.md),
        Container(
          decoration: AppDecorations.card,
          child: _DeviceTile(
            device: device,
            rssiIcon: _rssiIcon(null), // last RSSI not persisted
            lastSeenLabel: _lastSeenLabel(_lastSeenAt),
            onConnect: () {
              widget.onConnect?.call(device.id, device.name);
            },
            onLongPress: _forgetDevice,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Text(
            'Long-press a device to forget it.',
            style: AppTextStyles.caption,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

// ── Internal data class ───────────────────────────────────────────────────────

class _SavedDevice {
  final String id;
  final String name;

  const _SavedDevice({required this.id, required this.name});
}

// ── Device tile widget ────────────────────────────────────────────────────────

class _DeviceTile extends StatelessWidget {
  final _SavedDevice device;
  final Widget rssiIcon;

  /// Human-readable "last seen X ago" label.  Null when unknown.
  final String? lastSeenLabel;

  final VoidCallback onConnect;
  final VoidCallback onLongPress;

  const _DeviceTile({
    required this.device,
    required this.rssiIcon,
    this.lastSeenLabel,
    required this.onConnect,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      leading: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: AppDecorations.iconContainer(AppColors.info),
        child: const Icon(Icons.sensors, color: AppColors.info, size: 24),
      ),
      title: Text(device.name, style: AppTextStyles.body),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            device.id,
            style: AppTextStyles.caption,
            overflow: TextOverflow.ellipsis,
          ),
          if (lastSeenLabel != null)
            Text(
              lastSeenLabel!,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textHint,
                fontSize: 10,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          rssiIcon,
          const SizedBox(width: AppSpacing.sm),
          ElevatedButton(
            onPressed: onConnect,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Connect', style: AppTextStyles.buttonSmall),
          ),
        ],
      ),
      onLongPress: onLongPress,
    );
  }
}
