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

/// Smart relative timestamp — replaces the simpler timeAgo from NotificationItem.
String _formatTimestamp(DateTime timestamp) {
  final now = DateTime.now();
  final diff = now.difference(timestamp);

  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return '$m minute${m == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return '$h hour${h == 1 ? '' : 's'} ago';
  }

  // Older than 24h — show "MMM d, HH:mm" using manual month abbreviation
  // (no intl/date_format dependency needed)
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final month = months[timestamp.month - 1];
  final hour = timestamp.hour.toString().padLeft(2, '0');
  final minute = timestamp.minute.toString().padLeft(2, '0');
  return '$month ${timestamp.day}, $hour:$minute';
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

// ---------------------------------------------------------------------------
// Date-group helpers
// ---------------------------------------------------------------------------

/// Returns the date-group label for a notification timestamp.
String _dateGroup(DateTime timestamp) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final itemDay = DateTime(timestamp.year, timestamp.month, timestamp.day);

  if (itemDay == today) return 'Today';
  if (itemDay == yesterday) return 'Yesterday';
  return 'Earlier';
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<NotificationItem> _notifications = [];
  bool _isLoading = true;
  bool _notificationsEnabled = true;

  /// Filter selection: 'all' | 'critical' | 'warning' | 'info' | 'success'
  String _selectedFilter = 'all';

  /// Timestamps (ISO-8601 strings) of items marked as read this session.
  final Set<String> _readKeys = {};

  /// Unread count captured before clearing the badge (shown in AppBar).
  int _unreadCountOnOpen = 0;

  // Colour constants (matching the teal/Material theme)
  static const _bgColor = Color(0xFF1C2523);
  static const _appBarColor = Color(0xFF0D3A39);
  static const _accent = Color(0xFFFFC107);

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _loadSettings();
    _captureAndClearUnreadCount();
  }

  /// Reads the current unread badge count, stores it for display, then
  /// resets it — so the AppBar can show "(N unread)" on this visit.
  Future<void> _captureAndClearUnreadCount() async {
    final count = await NotificationService().getUnreadCount();
    await NotificationService().clearUnreadCount();
    if (mounted) {
      setState(() => _unreadCountOnOpen = count);
    }
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
      if (mounted) {
        setState(() {
          _notifications = [];
          _readKeys.clear();
        });
      }
    }
  }

  /// Mark every visible (filtered) notification as read in local UI state.
  void _markAllRead() {
    final filtered = _filteredNotifications;
    if (filtered.isEmpty) return;

    setState(() {
      for (final n in filtered) {
        _readKeys.add(n.timestamp.toIso8601String());
      }
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All marked as read'),
        duration: Duration(seconds: 2),
        backgroundColor: Color(0xFF388E3C),
      ),
    );
  }

  /// Remove a single notification from the in-memory list.
  ///
  /// The backing SharedPreferences store is left intact; the item will
  /// reappear on next cold-start.  Full persistence of individual removal
  /// would require a removeNotification API on NotificationService which
  /// is not currently exposed — this session-scoped approach is sufficient
  /// for the swipe-to-dismiss UX requirement.
  void _deleteNotification(NotificationItem item) {
    setState(() {
      _notifications.remove(item);
      _readKeys.remove(item.timestamp.toIso8601String());
    });
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  /// Returns true when a notification's type matches the active filter.
  bool _matchesFilter(NotificationItem n) {
    switch (_selectedFilter) {
      case 'critical':
        return n.type == 'critical';
      case 'warning':
        return n.type == 'warning' || n.type == 'error';
      case 'info':
        return n.type != 'critical' &&
            n.type != 'warning' &&
            n.type != 'error' &&
            n.type != 'success' &&
            n.type != 'achievement';
      case 'success':
        return n.type == 'success' || n.type == 'achievement';
      default: // 'all'
        return true;
    }
  }

  List<NotificationItem> get _filteredNotifications =>
      _notifications.where(_matchesFilter).toList();

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredNotifications;
    final hasAnyUnread = filtered.any(
      (n) => !_readKeys.contains(n.timestamp.toIso8601String()),
    );

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _appBarColor,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Notifications', style: TextStyle(color: Colors.white)),
            if (_unreadCountOnOpen > 0)
              Text(
                '$_unreadCountOnOpen unread',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                ),
              ),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          // Mark all read
          if (filtered.isNotEmpty && hasAnyUnread)
            IconButton(
              tooltip: 'Mark all as read',
              icon: const Icon(Icons.done_all),
              onPressed: _markAllRead,
            ),
          // Clear all
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
          _buildFilterChips(),
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

  // ---------------------------------------------------------------------------
  // Filter chips row
  // ---------------------------------------------------------------------------

  static const _filters = [
    ('all', 'All', Icons.list_rounded),
    ('critical', 'Critical', Icons.crisis_alert),
    ('warning', 'Warning', Icons.warning_amber_rounded),
    ('info', 'Info', Icons.info_outline),
    ('success', 'Success', Icons.check_circle_outline),
  ];

  Widget _buildFilterChips() {
    return Container(
      height: 44,
      margin: const EdgeInsets.only(top: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: _filters.map((f) {
          final key = f.$1;
          final label = f.$2;
          final icon = f.$3;
          final selected = _selectedFilter == key;

          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              selected: selected,
              avatar: Icon(
                icon,
                size: 16,
                color: selected ? Colors.black87 : Colors.white54,
              ),
              label: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.black87 : Colors.white70,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
              ),
              selectedColor: _accent,
              backgroundColor: Colors.white.withAlpha(18),
              checkmarkColor: Colors.black87,
              side: BorderSide(
                color: selected ? _accent : Colors.white.withAlpha(40),
              ),
              onSelected: (_) => setState(() => _selectedFilter = key),
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
            ),
          );
        }).toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Notification list
  // ---------------------------------------------------------------------------

  Widget _buildNotificationList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }

    final filtered = _filteredNotifications;

    if (filtered.isEmpty) {
      return RefreshIndicator(
        color: _accent,
        backgroundColor: _appBarColor,
        onRefresh: _loadNotifications,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: 400,
            child: _buildEmptyState(),
          ),
        ),
      );
    }

    // Build a flat list of items with date-group headers inserted between
    // sections.  Each entry is either a header String or a NotificationItem.
    final List<Object> rows = [];
    String? currentGroup;
    for (final n in filtered) {
      final group = _dateGroup(n.timestamp);
      if (group != currentGroup) {
        rows.add(group); // header sentinel
        currentGroup = group;
      }
      rows.add(n);
    }

    return RefreshIndicator(
      color: _accent,
      backgroundColor: _appBarColor,
      onRefresh: _loadNotifications,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          if (row is String) {
            return _buildDateHeader(row);
          }
          return _buildDismissibleTile(row as NotificationItem);
        },
      ),
    );
  }

  Widget _buildDateHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              color: Colors.white.withAlpha(26),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState() {
    final IconData icon;
    final String headline;
    final String sub;

    if (_notifications.isEmpty) {
      // Truly empty list
      icon = Icons.check_circle_outline;
      headline = "You're all caught up!";
      sub = 'Safety alerts, BLE events and processing results\nwill appear here.';
    } else {
      // List is non-empty but filter matches nothing
      switch (_selectedFilter) {
        case 'critical':
          icon = Icons.crisis_alert;
          headline = 'No critical notifications';
          sub = 'Critical safety alerts will appear here.';
        case 'warning':
          icon = Icons.warning_amber_rounded;
          headline = 'No warning notifications';
          sub = 'Warnings and errors will appear here.';
        case 'success':
          icon = Icons.check_circle_outline;
          headline = 'No success notifications';
          sub = 'Completed operations will appear here.';
        case 'info':
          icon = Icons.info_outline;
          headline = 'No info notifications';
          sub = 'Informational events will appear here.';
        default:
          icon = Icons.notifications_off_outlined;
          headline = 'No notifications';
          sub = 'Nothing to show.';
      }
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.white.withAlpha(60)),
          const SizedBox(height: 16),
          Text(
            headline,
            style: const TextStyle(color: Colors.white54, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            sub,
            style: const TextStyle(color: Colors.white30, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dismissible tile
  // ---------------------------------------------------------------------------

  Widget _buildDismissibleTile(NotificationItem notification) {
    final key = notification.timestamp.toIso8601String();

    return Dismissible(
      key: ValueKey(key),
      // Swipe right → mark as read (green background)
      background: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF388E3C),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.check, color: Colors.white, size: 28),
      ),
      // Swipe left → delete (red background)
      secondaryBackground: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFD32F2F),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Mark as read — do not remove tile from list
          setState(() => _readKeys.add(key));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Marked as read'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return false; // cancel the dismissal — tile stays in place
        }
        // Left swipe → delete: allow dismissal
        return true;
      },
      onDismissed: (direction) {
        // Only reaches here for left swipe (delete), since right swipe
        // returns false from confirmDismiss above.
        _deleteNotification(notification);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Notification deleted'),
              duration: const Duration(seconds: 3),
              action: SnackBarAction(
                label: 'Undo',
                textColor: _accent,
                onPressed: _loadNotifications,
              ),
            ),
          );
        }
      },
      child: _buildNotificationTile(notification, key),
    );
  }

  Widget _buildNotificationTile(NotificationItem notification, String key) {
    final color = _typeColor(notification.type);
    final icon = _typeIcon(notification.type);
    final label = _typeLabel(notification.type);
    final isCritical = notification.type == 'critical';
    final isRead = _readKeys.contains(key);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isRead
            ? Colors.white.withAlpha(8)
            : color.withAlpha(isCritical ? 20 : 13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isRead
              ? Colors.white.withAlpha(20)
              : color.withAlpha(isCritical ? 120 : 60),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isRead ? Colors.white.withAlpha(15) : color.withAlpha(40),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: isRead ? Colors.white38 : color, size: 20),
        ),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                notification.title,
                style: TextStyle(
                  color: isRead ? Colors.white38 : Colors.white,
                  fontWeight: isCritical && !isRead ? FontWeight.bold : FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Severity chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isRead ? Colors.white.withAlpha(15) : color.withAlpha(40),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: isRead ? Colors.white30 : color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // Unread dot
            if (!isRead) ...[
              const SizedBox(width: 6),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              notification.body,
              style: TextStyle(
                color: isRead ? Colors.white30 : Colors.white60,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTimestamp(notification.timestamp),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
