import 'package:flutter/material.dart';
import '../services/notification_service.dart';

// ---------------------------------------------------------------------------
// Helpers — resolve colour, icon and label from NotificationItem.type
// ---------------------------------------------------------------------------

Color _typeColor(String type) {
  switch (type) {
    case 'critical':
      return const Color(0xFFE53935); // red
    case 'warning':
      return const Color(0xFFFF9800); // orange
    case 'error':
      return const Color(0xFFF44336); // red-ish
    case 'success':
      return const Color(0xFF4CAF50); // green
    case 'achievement':
      return const Color(0xFFFFC107); // gold
    default:
      return const Color(0xFF2196F3); // blue / info
  }
}

IconData _typeIcon(String type) {
  switch (type) {
    case 'critical':
      return Icons.crisis_alert;
    case 'warning':
      return Icons.warning_amber_rounded;
    case 'error':
      return Icons.error_outline;
    case 'success':
      return Icons.check_circle_outline;
    case 'achievement':
      return Icons.emoji_events_outlined;
    default:
      return Icons.info_outline;
  }
}

String _typeLabel(String type) {
  switch (type) {
    case 'critical':
      return 'CRITICAL';
    case 'warning':
      return 'WARNING';
    case 'error':
      return 'ERROR';
    case 'success':
      return 'SUCCESS';
    case 'achievement':
      return 'ACHIEVEMENT';
    default:
      return 'INFO';
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<NotificationItem> _notifications = [];
  bool _isLoading = true;
  bool _notificationsEnabled = true;

  // Colour constants (matching the teal/Material theme)
  static const _bgColor = Color(0xFF1C2523);
  static const _appBarColor = Color(0xFF0D3A39);
  static const _accent = Color(0xFFFFC107);

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _loadSettings();
    // Clear badge count when the user opens this screen
    NotificationService().clearUnreadCount();
  }

  Future<void> _loadNotifications() async {
    final notifications = await NotificationService().getNotificationHistory();
    if (mounted) {
      setState(() {
        _notifications = notifications;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSettings() async {
    final enabled = await NotificationService().areNotificationsEnabled();
    if (mounted) {
      setState(() => _notificationsEnabled = enabled);
    }
  }

  Future<void> _toggleNotifications(bool value) async {
    await NotificationService().setNotificationsEnabled(value);
    setState(() => _notificationsEnabled = value);
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bgColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Clear History',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Are you sure you want to clear all notifications?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await NotificationService().clearNotificationHistory();
      if (mounted) setState(() => _notifications = []);
    }
  }

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _appBarColor,
        title: const Text('Notifications', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_notifications.isNotEmpty)
            IconButton(
              tooltip: 'Clear all notifications',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearHistory,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildToggleRow(),
          _buildSummaryBanner(),
          Expanded(child: _buildNotificationList()),
        ],
      ),
    );
  }

  // Push-notifications enable/disable toggle
  Widget _buildToggleRow() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(26)),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_active, color: _accent, size: 24),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Push Notifications',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                Text(
                  'Safety alerts, processing status and device events',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(
            value: _notificationsEnabled,
            onChanged: _toggleNotifications,
            activeColor: _accent,
          ),
        ],
      ),
    );
  }

  // Summary pill row showing counts per severity
  Widget _buildSummaryBanner() {
    if (_notifications.isEmpty) return const SizedBox(height: 8);

    int critical = 0, warnings = 0, info = 0;
    for (final n in _notifications) {
      if (n.type == 'critical') {
        critical++;
      } else if (n.type == 'warning' || n.type == 'error') {
        warnings++;
      } else {
        info++;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          if (critical > 0) _summaryPill('$critical Critical', const Color(0xFFE53935)),
          if (critical > 0 && warnings > 0) const SizedBox(width: 8),
          if (warnings > 0) _summaryPill('$warnings Warning${warnings > 1 ? 's' : ''}', const Color(0xFFFF9800)),
          if ((critical > 0 || warnings > 0) && info > 0) const SizedBox(width: 8),
          if (info > 0) _summaryPill('$info Info', const Color(0xFF2196F3)),
          const Spacer(),
          Text(
            '${_notifications.length} total',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _summaryPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(100)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  // Main notification list (or loading / empty state)
  Widget _buildNotificationList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }

    if (_notifications.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.notifications_off_outlined, size: 64, color: Colors.white.withAlpha(60)),
            const SizedBox(height: 16),
            const Text(
              'No notifications yet',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'Safety alerts, BLE events and processing results\nwill appear here.',
              style: TextStyle(color: Colors.white30, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _notifications.length,
      itemBuilder: (context, index) => _buildNotificationTile(_notifications[index]),
    );
  }

  Widget _buildNotificationTile(NotificationItem notification) {
    final color = _typeColor(notification.type);
    final icon = _typeIcon(notification.type);
    final label = _typeLabel(notification.type);
    final isCritical = notification.type == 'critical';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(isCritical ? 20 : 13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(isCritical ? 120 : 60)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withAlpha(40),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                notification.title,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: isCritical ? FontWeight.bold : FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Severity chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withAlpha(40),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              notification.body,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              notification.timeAgo,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
