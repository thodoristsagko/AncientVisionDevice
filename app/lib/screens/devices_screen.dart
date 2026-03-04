import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/device_memory_service.dart';
import '../utils/app_styles.dart';

/// DevicesScreen — manage saved BLE devices.
///
/// Shows all known devices from [DeviceMemoryService] with per-device metadata:
/// last-seen timestamp, last known PPV, uptime, and firmware version.
/// Supports swipe-to-forget with a confirmation dialog and color-coded
/// freshness indicators (green = <60s, amber = 1–5min, red = >5min or unknown).
class DevicesScreen extends StatefulWidget {
  /// Called when the user taps "Connect" on a saved device tile.
  final void Function(String deviceId, String deviceName)? onConnect;

  /// Called when the user taps the "Scan for new devices" FAB.
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

  // Primary device (last connected)
  _SavedDevice? _primaryDevice;
  DateTime? _lastSeenAt;
  double? _lastPpv;
  Duration? _uptime;
  String? _firmwareVersion;

  // All known device IDs for multi-device display
  List<String> _allKnownIds = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final svc = DeviceMemoryService.instance;
      final id = await svc.getLastDeviceId();
      final name = await svc.getLastDeviceName();
      final seenAt = await svc.getLastSeenAt();
      final allIds = await svc.allKnownDevices;

      // Fetch per-device metadata for the primary device
      double? ppv;
      Duration? uptime;
      if (id != null) {
        ppv = await svc.getLastKnownPpv(id);
        uptime = await svc.getDeviceUptime(id);
      }

      // Read firmware version from SharedPreferences (written by safety_view)
      String? fwVersion;
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('fw_version');
        if (raw != null && raw.isNotEmpty) fwVersion = raw;
      } catch (_) {}

      if (mounted) {
        setState(() {
          _primaryDevice = (id != null && name != null)
              ? _SavedDevice(id: id, name: name)
              : null;
          _lastSeenAt = seenAt;
          _lastPpv = ppv;
          _uptime = uptime;
          _firmwareVersion = fwVersion;
          _allKnownIds = allIds;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _primaryDevice = null;
          _lastSeenAt = null;
          _lastPpv = null;
          _uptime = null;
          _firmwareVersion = null;
          _allKnownIds = [];
          _loading = false;
        });
      }
    }
  }

  // ── Forget ──────────────────────────────────────────────────────────────────

  /// Shows a confirmation dialog and forgets the given device.
  Future<void> _forgetDevice(String deviceId, String deviceName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.primaryDark,
        title: const Text('Forget Device?', style: AppTextStyles.h3),
        content: Text(
          'Remove "$deviceName" from saved devices?\n\n'
          'You will need to scan and reconnect manually.',
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

    if (confirmed == true && mounted) {
      await DeviceMemoryService.instance.forgetDevice(deviceId);
      // If it was also the primary device, clear global keys too.
      if (_primaryDevice?.id == deviceId) {
        await DeviceMemoryService.instance.clearDevice();
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$deviceName" forgotten')),
        );
      }
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Human-readable "last seen X ago" string.
  String _lastSeenLabel(DateTime? seenAt) {
    if (seenAt == null) return 'Never seen';
    final diff = DateTime.now().difference(seenAt);
    if (diff.inSeconds < 60) return 'Last seen just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours}h ago';
    return 'Last seen ${diff.inDays}d ago';
  }

  /// Human-readable uptime string, e.g. "3h 14m" or "2d 1h".
  String _uptimeLabel(Duration? uptime) {
    if (uptime == null) return 'Unknown';
    if (uptime.inDays > 0) {
      final h = uptime.inHours.remainder(24);
      return '${uptime.inDays}d ${h}h';
    }
    if (uptime.inHours > 0) {
      final m = uptime.inMinutes.remainder(60);
      return '${uptime.inHours}h ${m}m';
    }
    return '${uptime.inMinutes}m';
  }

  /// Color based on how recently the device was seen.
  Color _freshnessColor(DateTime? seenAt) {
    if (seenAt == null) return AppColors.error;
    final diff = DateTime.now().difference(seenAt);
    if (diff.inSeconds < 60) return AppColors.success;
    if (diff.inMinutes < 5) return AppColors.warning;
    return AppColors.error;
  }

  /// RSSI-style signal icon (we do not persist live RSSI, so we derive
  /// a visual hint from last-seen freshness instead).
  Widget _freshnessIcon(DateTime? seenAt) {
    final color = _freshnessColor(seenAt);
    final IconData icon;
    if (seenAt == null) {
      icon = Icons.signal_cellular_nodata;
    } else {
      final diff = DateTime.now().difference(seenAt);
      if (diff.inSeconds < 60) {
        icon = Icons.network_wifi;
      } else if (diff.inMinutes < 5) {
        icon = Icons.network_wifi_3_bar;
      } else {
        icon = Icons.network_wifi_1_bar;
      }
    }
    return Icon(icon, color: color, size: 20);
  }

  // ── Build ────────────────────────────────────────────────────────────────────

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
              : (_primaryDevice == null && _allKnownIds.isEmpty)
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
        label: const Text('Scan for new devices', style: AppTextStyles.buttonSmall),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth_disabled, size: 72, color: AppColors.textHint),
          SizedBox(height: AppSpacing.lg),
          Text(
            'No saved devices',
            style: AppTextStyles.h3,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: AppSpacing.sm),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Tap "Scan for new devices" below to find your AncientVision sensor.',
              style: AppTextStyles.subtitle,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        // ── Last connected device ──────────────────────────────────────────
        if (_primaryDevice != null) ...[
          AppWidgets.sectionHeader('Last Connected Sensor', Icons.bluetooth_connected),
          const SizedBox(height: AppSpacing.md),
          _buildSwipeable(
            deviceId: _primaryDevice!.id,
            deviceName: _primaryDevice!.name,
            child: _DeviceTile(
              device: _primaryDevice!,
              freshnessIcon: _freshnessIcon(_lastSeenAt),
              freshnessColor: _freshnessColor(_lastSeenAt),
              lastSeenLabel: _lastSeenLabel(_lastSeenAt),
              lastPpv: _lastPpv,
              uptimeLabel: _uptimeLabel(_uptime),
              firmwareVersion: _firmwareVersion,
              onConnect: () =>
                  widget.onConnect?.call(_primaryDevice!.id, _primaryDevice!.name),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
        ],

        // ── Other known devices (IDs only — metadata stored under device ID) ──
        if (_allKnownIds
            .where((id) => id != (_primaryDevice?.id ?? ''))
            .isNotEmpty) ...[
          AppWidgets.sectionHeader('Other Known Devices', Icons.devices),
          const SizedBox(height: AppSpacing.md),
          ..._allKnownIds
              .where((id) => id != (_primaryDevice?.id ?? ''))
              .map((id) => _buildOrphanTile(id)),
          const SizedBox(height: AppSpacing.xl),
        ],

        // ── Hint ────────────────────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Text(
            'Swipe left on a device to forget it.',
            style: AppTextStyles.caption,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  /// Wraps [child] in a [Dismissible] that triggers the forget-device flow.
  Widget _buildSwipeable({
    required String deviceId,
    required String deviceName,
    required Widget child,
  }) {
    return Dismissible(
      key: Key('device_$deviceId'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        await _forgetDevice(deviceId, deviceName);
        // Return false — _forgetDevice calls _load() which rebuilds the list.
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.error.withAlpha(50),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, color: AppColors.error),
            SizedBox(width: AppSpacing.sm),
            Text('Forget', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      child: Container(
        decoration: AppDecorations.card,
        child: child,
      ),
    );
  }

  /// Tile for devices in the metadata store but not the primary device.
  /// These have an ID but no cached name, so we show just the ID + a forget button.
  Widget _buildOrphanTile(String deviceId) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: _buildSwipeable(
        deviceId: deviceId,
        deviceName: deviceId,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          leading: Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: AppDecorations.iconContainer(AppColors.textHint),
            child: const Icon(Icons.sensors, color: AppColors.textHint, size: 24),
          ),
          title: Text(
            deviceId,
            style: AppTextStyles.body,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const Text('Inactive device', style: AppTextStyles.caption),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, color: AppColors.error, size: 20),
            tooltip: 'Forget device',
            onPressed: () => _forgetDevice(deviceId, deviceId),
          ),
        ),
      ),
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
  final Widget freshnessIcon;
  final Color freshnessColor;
  final String lastSeenLabel;
  final double? lastPpv;
  final String uptimeLabel;
  final String? firmwareVersion;
  final VoidCallback onConnect;

  const _DeviceTile({
    required this.device,
    required this.freshnessIcon,
    required this.freshnessColor,
    required this.lastSeenLabel,
    this.lastPpv,
    required this.uptimeLabel,
    this.firmwareVersion,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      leading: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: AppDecorations.iconContainer(freshnessColor),
        child: Icon(Icons.sensors, color: freshnessColor, size: 24),
      ),
      title: Text(device.name, style: AppTextStyles.body),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 2),
          Text(
            device.id,
            style: AppTextStyles.caption,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          // Last-seen row with colored dot
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: freshnessColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                lastSeenLabel,
                style: AppTextStyles.caption.copyWith(color: freshnessColor),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // PPV + uptime row
          Row(
            children: [
              if (lastPpv != null) ...[
                const Icon(Icons.vibration, size: 12, color: AppColors.textHint),
                const SizedBox(width: 3),
                Text(
                  'PPV ${lastPpv!.toStringAsFixed(3)} mm/s',
                  style: AppTextStyles.caption.copyWith(fontSize: 10),
                ),
                const SizedBox(width: 8),
              ],
              const Icon(Icons.timer_outlined, size: 12, color: AppColors.textHint),
              const SizedBox(width: 3),
              Text(
                'Up: $uptimeLabel',
                style: AppTextStyles.caption.copyWith(fontSize: 10),
              ),
            ],
          ),
          if (firmwareVersion != null) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.memory, size: 12, color: AppColors.textHint),
                const SizedBox(width: 3),
                Text(
                  'FW $firmwareVersion',
                  style: AppTextStyles.caption.copyWith(fontSize: 10),
                ),
              ],
            ),
          ],
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          freshnessIcon,
          const SizedBox(width: AppSpacing.sm),
          ElevatedButton(
            onPressed: onConnect,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Connect', style: AppTextStyles.buttonSmall),
          ),
        ],
      ),
    );
  }
}
