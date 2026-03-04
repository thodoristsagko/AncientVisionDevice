// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/dashboard_home_widgets.dart';
import '../services/auth_service.dart';
import '../services/alert_history_service.dart';
import '../services/local_storage_service.dart';
import '../services/notification_service.dart';
import '../services/site_service.dart';
import '../services/session_history_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../services/connectivity_monitor_service.dart';
import '../services/critical_event_log_service.dart';
import 'notifications_screen.dart';
import 'qr_scanner_screen.dart';
import 'analytics_screen.dart';
import 'calibration_wizard_screen.dart';
import 'session_history_screen.dart';
import 'vibration_event_log_screen.dart';

class DashboardHomeView extends StatefulWidget {
  /// Called when the view wants to switch the main navigation tab.
  /// Tab indices: 0=Home, 1=Findings, 2=Tools, 3=Monitor, 4=History
  final ValueChanged<int>? onNavigate;

  const DashboardHomeView({super.key, this.onNavigate});

  @override
  State<DashboardHomeView> createState() => DashboardHomeViewState();
}

class DashboardHomeViewState extends State<DashboardHomeView> {
  int _totalFindings = 0;
  int _todayFindings = 0;
  String _userName = '';
  List<Map<String, dynamic>> _lastFindings = [];
  int _offlineDataCount = 0;
  bool _isSyncing = false;
  int _unreadNotifications = 0;

  int _significantFindings = 0;
  Map<String, int> _findingsByType = {};
  List<int> _last7DaysCounts = List.filled(7, 0);
  bool _statsLoading = true;
  String _activeSite = '';

  // --- Quick stats (vibration / sessions) ---
  int _sessionsToday = 0;
  double _peakPpvToday = 0.0;
  List<SessionRecord> _recentSessions = [];
  String _mlStatus = 'Not loaded';
  String _lastSync = 'Never';
  bool _sessionStatsLoading = true;

  // --- Quick Status Banner ---
  int _appStartTimeMs = 0;

  // --- Recent Alerts Summary ---
  int _alerts24h = 0;
  AlertData? _mostRecentAlert;
  bool _alertsLoading = true;

  // --- Critical Events & Health ---
  int _totalCriticalEvents = 0;
  double _lastEventPpv = 0.0;
  DateTime? _lastEventTime;
  double _healthScore = 0.0;

  @override
  void initState() {
    super.initState();
    _loadUserName();
    _loadLastFindings();
    _checkOfflineData();
    _loadUnreadNotifications();
    _loadStats();
    SiteService().getActiveSite().then((s) {
      if (mounted) setState(() => _activeSite = s);
    });
    _loadSessionStats();
    _loadSystemStatus();
    _loadAppStartTime();
    _loadRecentAlerts();
    _loadCriticalEventsAndHealth();
  }

  // ---------------------------------------------------------------------------
  // Session / vibration quick stats
  // ---------------------------------------------------------------------------

  Future<void> _loadSessionStats() async {
    try {
      final sessions = await SessionHistoryService.instance.getSessions();
      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);

      final todaySessions = sessions
          .where((s) => !s.start.isBefore(startOfDay))
          .toList();

      double peakPpv = 0.0;
      for (final s in todaySessions) {
        if (s.peakPpv > peakPpv) peakPpv = s.peakPpv;
      }

      if (mounted) {
        setState(() {
          _sessionsToday = todaySessions.length;
          _peakPpvToday = peakPpv;
          _recentSessions = sessions.take(3).toList();
          _sessionStatsLoading = false;
        });
      }
    } catch (e) {
      debugPrint('_loadSessionStats error: $e');
      if (mounted) setState(() => _sessionStatsLoading = false);
    }
  }

  Future<void> _loadSystemStatus() async {
    try {
      // ML model status
      final anomalyService = VibrationAnomalyService.instance;
      final mlStatus = anomalyService.isInitialized
          ? 'Loaded (${anomalyService.modeLabel})'
          : 'Not loaded';

      // Last sync time
      final prefs = await SharedPreferences.getInstance();
      final lastSyncMs = prefs.getInt('last_sync_time');
      String lastSync = 'Never';
      if (lastSyncMs != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(lastSyncMs);
        final diff = DateTime.now().difference(dt);
        if (diff.inMinutes < 1) {
          lastSync = 'Just now';
        } else if (diff.inHours < 1) {
          lastSync = '${diff.inMinutes}m ago';
        } else if (diff.inDays < 1) {
          lastSync = '${diff.inHours}h ago';
        } else {
          lastSync = '${diff.inDays}d ago';
        }
      }

      if (mounted) {
        setState(() {
          _mlStatus = mlStatus;
          _lastSync = lastSync;
        });
      }
    } catch (e) {
      debugPrint('_loadSystemStatus error: $e');
    }
  }

  Future<void> _loadAppStartTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt('app_start_time') ?? 0;
    if (ms == 0) {
      // Store on first run
      final now = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt('app_start_time', now);
      if (mounted) setState(() => _appStartTimeMs = now);
    } else {
      if (mounted) setState(() => _appStartTimeMs = ms);
    }
  }

  Future<void> _loadRecentAlerts() async {
    try {
      final alertService = AlertHistoryService();
      final recent = await alertService.getRecent(const Duration(hours: 24));
      AlertData? mostRecent;
      if (recent.isNotEmpty) {
        recent.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        mostRecent = recent.first;
      }
      if (mounted) {
        setState(() {
          _alerts24h = recent.length;
          _mostRecentAlert = mostRecent;
          _alertsLoading = false;
        });
      }
    } catch (e) {
      debugPrint('_loadRecentAlerts error: $e');
      if (mounted) setState(() => _alertsLoading = false);
    }
  }

  Future<void> _loadCriticalEventsAndHealth() async {
    try {
      // Load critical events from CriticalEventLogService
      await CriticalEventLogService.instance.initialize();
      final events = CriticalEventLogService.instance.events;
      final mostRecent = CriticalEventLogService.instance.mostRecentEvent;

      // Get health score from ConnectivityMonitorService
      final healthScore = ConnectivityMonitorService.instance.healthScore;

      if (mounted) {
        setState(() {
          _totalCriticalEvents = events.length;
          _lastEventPpv = mostRecent?.ppv ?? 0.0;
          _lastEventTime = mostRecent?.timestamp;
          _healthScore = healthScore;
        });
      }
    } catch (e) {
      debugPrint('_loadCriticalEventsAndHealth error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Existing loaders (unchanged)
  // ---------------------------------------------------------------------------

  Future<void> _loadStats() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('findings')
          .get()
          .timeout(const Duration(seconds: 10));
      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);
      int significant = 0;
      int todayCount = 0;
      final byType = <String, int>{};
      final days = List.filled(7, 0);
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['isSignificant'] == true) significant++;
        final type = (data['type'] as String? ?? 'Other').trim();
        final key = ['Coin', 'Fragment', 'Structure'].contains(type) ? type : 'Other';
        byType[key] = (byType[key] ?? 0) + 1;
        final raw = data['createdAt'];
        DateTime? created;
        if (raw is String) created = DateTime.tryParse(raw);
        if (raw is Timestamp) created = raw.toDate();
        if (created != null) {
          final daysAgo = now.difference(created).inDays;
          if (daysAgo >= 0 && daysAgo < 7) days[6 - daysAgo]++;
          if (!created.isBefore(startOfDay)) todayCount++;
        }
      }
      if (mounted) {
        setState(() {
          _totalFindings = snap.docs.length;
          _todayFindings = todayCount;
          _significantFindings = significant;
          _findingsByType = byType;
          _last7DaysCounts = days;
          _statsLoading = false;
        });
      }
    } catch (e, stack) {
      debugPrint('_loadStats error: $e\n$stack');
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  Future<void> _loadUnreadNotifications() async {
    final count = await NotificationService().getUnreadCount();
    if (mounted) setState(() => _unreadNotifications = count);
  }

  Future<void> _checkOfflineData() async {
    final storage = LocalStorageService();
    await storage.initialize();
    if (mounted) setState(() => _offlineDataCount = storage.offlineDataCount);
  }

  Future<void> _syncNow() async {
    setState(() => _isSyncing = true);
    final storage = LocalStorageService();
    final synced = await storage.syncPendingUploads();
    if (mounted) {
      setState(() {
        _isSyncing = false;
        _offlineDataCount = storage.offlineDataCount;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(synced > 0 ? 'Synced $synced finding${synced > 1 ? 's' : ''}' : 'Up to date'),
          backgroundColor: const Color(0xFF4CAF50),
        ),
      );
      _loadStats();
      _loadLastFindings();
    }
  }

  Future<void> _loadLastFindings() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('findings')
          .orderBy('createdAt', descending: true)
          .limit(3)
          .get();
      if (mounted) {
        setState(() {
          _lastFindings = snapshot.docs.map((doc) {
            final data = doc.data();
            return {
              'type': data['type'] ?? 'Unknown',
              'site': data['site'] ?? 'Unknown',
              'createdAt': data['createdAt'],
            };
          }).toList();
        });
      }
    } catch (e) {
      debugPrint('Error loading last findings: $e');
    }
  }

  Future<void> _loadUserName() async {
    final user = AuthService.currentUser;
    if (user == null) {
      setState(() => _userName = 'Guest');
      return;
    }
    if (user.displayName != null && user.displayName!.isNotEmpty) {
      setState(() => _userName = user.displayName!.split(' ').first);
      return;
    }
    try {
      final profile = await AuthService.getUserProfile(user.uid);
      if (profile != null && profile['fullName'] != null && (profile['fullName'] as String).isNotEmpty) {
        if (mounted) setState(() => _userName = (profile['fullName'] as String).split(' ').first);
        return;
      }
    } catch (e) {
      debugPrint('_loadUserName error: $e');
    }
    if (user.email != null && user.email!.isNotEmpty) {
      final name = user.email!.split('@').first;
      if (mounted) setState(() => _userName = name[0].toUpperCase() + name.substring(1).toLowerCase());
    } else {
      if (mounted) setState(() => _userName = 'User');
    }
  }

  // ---------------------------------------------------------------------------
  // Widgets
  // ---------------------------------------------------------------------------

  // --- Quick Status Banner ---------------------------------------------------

  String _formatElapsed(int startMs) {
    if (startMs == 0) return 'Active';
    final elapsed = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(startMs));
    if (elapsed.inHours >= 1) {
      return '${elapsed.inHours}h ${elapsed.inMinutes.remainder(60)}m';
    }
    return '${elapsed.inMinutes}m';
  }

  Widget _buildStatusBanner() {
    final anomalyService = VibrationAnomalyService.instance;
    final bool isConnected = anomalyService.isInitialized;
    final String modeLabel = isConnected ? anomalyService.modeLabel : 'Disconnected';
    final Color bleColor =
        isConnected ? const Color(0xFF4CAF50) : Colors.white38;
    final String elapsedStr = _formatElapsed(_appStartTimeMs);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Row(
        children: [
          // BLE dot
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: bleColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            isConnected ? 'Connected' : 'No Device',
            style: TextStyle(color: bleColor, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          // Mode badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFFFC107).withAlpha(30),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFFC107).withAlpha(80)),
            ),
            child: Text(
              modeLabel,
              style: const TextStyle(
                  color: Color(0xFFFFC107), fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ),
          const Spacer(),
          // Session timer
          const Icon(Icons.timer_outlined, color: Colors.white38, size: 14),
          const SizedBox(width: 4),
          Text(
            elapsedStr,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // --- Recent Alerts Summary Card --------------------------------------------

  Widget _buildRecentAlertsSummaryCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Color(0xFFFFC107), size: 16),
                const SizedBox(width: 8),
                const Text(
                  'Alerts (24h)',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const VibrationEventLogScreen()),
                  ),
                  child: const Text(
                    'View all',
                    style: TextStyle(color: Color(0xFFFFC107), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (_alertsLoading)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                height: 24,
                child: LinearProgressIndicator(
                    color: Color(0xFFFFC107),
                    backgroundColor: Colors.white10),
              ),
            )
          else if (_alerts24h == 0)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline,
                      color: Color(0xFF4CAF50), size: 16),
                  SizedBox(width: 8),
                  Text(
                    'No alerts in last 24h',
                    style: TextStyle(color: Color(0xFF4CAF50), fontSize: 13),
                  ),
                ],
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF44336).withAlpha(40),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color(0xFFF44336).withAlpha(80)),
                    ),
                    child: Text(
                      '$_alerts24h alert${_alerts24h > 1 ? 's' : ''}',
                      style: const TextStyle(
                          color: Color(0xFFF44336),
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_mostRecentAlert != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Last: ${_formatTime(_mostRecentAlert!.timestamp)} · ${_mostRecentAlert!.level}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  // --- Session Stats Row (today) ---------------------------------------------

  Widget _buildSessionStatsRow() {
    final String monitoringTime = _formatElapsed(_appStartTimeMs);
    final String peakPpv = _sessionStatsLoading
        ? '...'
        : '${_peakPpvToday.toStringAsFixed(2)} mm/s';
    final String totalEvents = _alertsLoading ? '...' : '$_alerts24h';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          _sessionStatChip(
            icon: Icons.access_time_rounded,
            label: 'Monitoring',
            value: monitoringTime,
            color: const Color(0xFF2196F3),
          ),
          const SizedBox(width: 8),
          _sessionStatChip(
            icon: Icons.speed_rounded,
            label: 'Peak PPV',
            value: peakPpv,
            color: const Color(0xFFFFC107),
          ),
          const SizedBox(width: 8),
          _sessionStatChip(
            icon: Icons.notifications_active_rounded,
            label: 'Events',
            value: totalEvents,
            color: _alerts24h > 0
                ? const Color(0xFFF44336)
                : const Color(0xFF4CAF50),
          ),
        ],
      ),
    );
  }

  Widget _sessionStatChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    label,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 9),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statChip(String label, int value, Color color) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOut,
      builder: (_, animated, __) => Column(
        children: [
          Text(
            animated.round().toString(),
            style: TextStyle(
                color: color, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }

  // --- Quick stats row (sessions / PPV / ML status) -------------------------

  Widget _buildQuickStatsRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Sessions today
            SizedBox(
              width: 100,
              child: _quickStatCard(
                icon: Icons.sensors_rounded,
                label: 'Sessions',
                value: _sessionStatsLoading ? '...' : _sessionsToday.toString(),
                color: const Color(0xFF2196F3),
              ),
            ),
            const SizedBox(width: 10),
            // Peak PPV today
            SizedBox(
              width: 100,
              child: _quickStatCard(
                icon: Icons.speed_rounded,
                label: 'Peak PPV',
                value: _sessionStatsLoading
                    ? '...'
                    : _peakPpvToday.toStringAsFixed(2),
                color: const Color(0xFFFFC107),
              ),
            ),
            const SizedBox(width: 10),
            // Health score indicator
            SizedBox(
              width: 100,
              child: _buildHealthScoreIndicator(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // --- Recent sessions card --------------------------------------------------

  Widget _buildRecentSessionsCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Text(
                  'Recent Sessions',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    if (widget.onNavigate != null) {
                      widget.onNavigate!(4); // History tab
                    } else {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SessionHistoryScreen()),
                      );
                    }
                  },
                  child: const Text(
                    'See all',
                    style: TextStyle(color: Color(0xFFFFC107), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (_sessionStatsLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: CircularProgressIndicator(
                  color: Color(0xFFFFC107),
                  strokeWidth: 2,
                ),
              ),
            )
          else if (_recentSessions.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                'No sessions recorded yet. Start monitoring to begin.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            )
          else
            ..._recentSessions.map((s) => _sessionListTile(s)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _sessionListTile(SessionRecord s) {
    final timeStr = _formatTime(s.start);
    final ppvColor = s.peakPpv > 0.3
        ? const Color(0xFFF44336)
        : s.peakPpv > 0.1
            ? const Color(0xFFFFC107)
            : const Color(0xFF4CAF50);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      leading: Icon(Icons.sensors_rounded, color: ppvColor, size: 20),
      title: Text(
        s.deviceName.isNotEmpty ? s.deviceName : 'AncientVision',
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
      subtitle: Text(
        timeStr,
        style: const TextStyle(color: Colors.white38, fontSize: 11),
      ),
      trailing: Text(
        '${s.peakPpv.toStringAsFixed(3)} mm/s',
        style: TextStyle(
          color: ppvColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // --- Quick action buttons --------------------------------------------------

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quick Actions',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _quickActionButton(
                icon: Icons.sensors_rounded,
                label: 'Monitor',
                color: const Color(0xFF4CAF50),
                onTap: () {
                  if (widget.onNavigate != null) {
                    widget.onNavigate!(3); // Safety/Monitor tab
                  }
                },
              ),
              _quickActionButton(
                icon: Icons.history_rounded,
                label: 'History',
                color: const Color(0xFF2196F3),
                onTap: () {
                  if (widget.onNavigate != null) {
                    widget.onNavigate!(4);
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SessionHistoryScreen()),
                    );
                  }
                },
              ),
              _quickActionButton(
                icon: Icons.tune_rounded,
                label: 'Calibrate',
                color: const Color(0xFFFFC107),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CalibrationWizardScreen(),
                    ),
                  );
                },
              ),
              _quickActionButton(
                icon: Icons.ios_share_rounded,
                label: 'Export',
                color: const Color(0xFF9C27B0),
                onTap: () {
                  if (widget.onNavigate != null) {
                    widget.onNavigate!(2); // Tools tab
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(color: color, fontSize: 12)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: color.withAlpha(120)),
        backgroundColor: color.withAlpha(20),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  // --- Health Score Indicator --------------------------------------------------

  Widget _buildHealthScoreIndicator() {
    Color healthColor = const Color(0xFF4CAF50); // Green
    String healthLabel = 'Excellent';

    if (_healthScore > 0.7) {
      healthColor = const Color(0xFF4CAF50);
      healthLabel = 'Excellent';
    } else if (_healthScore > 0.4) {
      healthColor = const Color(0xFFFFC107);
      healthLabel = 'Good';
    } else {
      healthColor = const Color(0xFFF44336);
      healthLabel = 'Poor';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: healthColor.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: healthColor.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.favorite, color: healthColor, size: 14),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                healthLabel,
                style: TextStyle(
                  color: healthColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'Health',
                style: TextStyle(
                  color: healthColor.withAlpha(150),
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Last Event Summary Card --------------------------------------------------

  Widget _buildLastEventSummaryCard() {
    if (_totalCriticalEvents == 0) {
      return const SizedBox.shrink();
    }

    String timeSinceLastEvent = 'Unknown';
    if (_lastEventTime != null) {
      final diff = DateTime.now().difference(_lastEventTime!);
      if (diff.inMinutes < 1) {
        timeSinceLastEvent = 'Just now';
      } else if (diff.inHours < 1) {
        timeSinceLastEvent = '${diff.inMinutes}m ago';
      } else if (diff.inDays < 1) {
        timeSinceLastEvent = '${diff.inHours}h ago';
      } else {
        timeSinceLastEvent = '${diff.inDays}d ago';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(26)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_rounded, color: Color(0xFFF44336), size: 16),
                const SizedBox(width: 8),
                const Text(
                  'Last Critical Event',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF44336).withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFF44336).withAlpha(80)),
                  ),
                  child: Text(
                    '${_lastEventPpv.toStringAsFixed(2)} mm/s',
                    style: const TextStyle(
                      color: Color(0xFFF44336),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Total Events',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$_totalCriticalEvents',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Peak PPV',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_lastEventPpv.toStringAsFixed(3)} mm/s',
                        style: const TextStyle(
                          color: Color(0xFFF44336),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Time Since',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        timeSinceLastEvent,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- System status card ---------------------------------------------------

  Widget _buildSystemStatusCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'System Status',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _statusRow(
            icon: Icons.memory_rounded,
            label: 'ML Model',
            value: _mlStatus,
            valueColor: _mlStatus.startsWith('Loaded')
                ? const Color(0xFF4CAF50)
                : Colors.white38,
          ),
          const SizedBox(height: 8),
          _statusRow(
            icon: Icons.cloud_sync_rounded,
            label: 'Last Sync',
            value: _lastSync,
            valueColor: Colors.white70,
          ),
          const SizedBox(height: 8),
          _statusRow(
            icon: Icons.storage_rounded,
            label: 'Data Files',
            value: 'N/A (mobile)',
            valueColor: Colors.white38,
          ),
        ],
      ),
    );
  }

  Widget _statusRow({
    required IconData icon,
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.white38, size: 16),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  // --- Findings stats card (existing) ---------------------------------------

  Widget _buildStatsCard(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
      child: Container(
        margin: const EdgeInsets.fromLTRB(0, 0, 0, 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha(26)),
        ),
        child: _statsLoading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator(color: Color(0xFFFFC107))),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Findings Overview',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statChip('Total', _totalFindings, Colors.white70),
                      _statChip('Significant', _significantFindings, const Color(0xFFFFC107)),
                      _statChip('Today', _todayFindings, const Color(0xFF2196F3)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 80,
                    child: BarChart(
                      BarChartData(
                        alignment: BarChartAlignment.spaceAround,
                        maxY: (_last7DaysCounts.fold(0, (a, b) => a > b ? a : b) + 1).toDouble(),
                        barTouchData: BarTouchData(enabled: false),
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              getTitlesWidget: (value, _) {
                                final i = value.toInt();
                                final date = DateTime.now().add(Duration(days: i - 6));
                                const abbr = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
                                return Text(
                                  abbr[date.weekday - 1],
                                  style: const TextStyle(color: Colors.white38, fontSize: 9),
                                );
                              },
                              reservedSize: 16,
                            ),
                          ),
                        ),
                        gridData: const FlGridData(show: false),
                        borderData: FlBorderData(show: false),
                        barGroups: _last7DaysCounts.asMap().entries.map((e) =>
                            BarChartGroupData(x: e.key, barRods: [
                              BarChartRodData(
                                toY: e.value.toDouble(),
                                color: const Color(0xFFFFC107),
                                width: 14,
                                borderRadius: BorderRadius.circular(4),
                              )
                            ])).toList(),
                      ),
                    ),
                  ),
                  if (_findingsByType.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _findingsByType.entries.map((e) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text('${e.key}: ${e.value}',
                            style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      )).toList(),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D3A39), Color(0xFF1C2523)],
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // HEADER: greeting + actions
              Row(
                children: [
                  const LogoCard(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hello, ${_userName.isEmpty ? "..." : _userName}',
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                        ),
                        if (_activeSite.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.location_on_rounded, color: Color(0xFFFFC107), size: 14),
                                const SizedBox(width: 4),
                                Text(_activeSite,
                                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  _headerIcon(
                    Icons.notifications_outlined,
                    badge: _unreadNotifications,
                    onTap: () async {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen()));
                      _loadUnreadNotifications();
                    },
                  ),
                  _headerIcon(Icons.qr_code_scanner, onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const QRScannerScreen()));
                  }),
                ],
              ),

              const SizedBox(height: 16),

              // QUICK STATUS BANNER
              _buildStatusBanner(),

              // OFFLINE SYNC (compact)
              if (_offlineDataCount > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GestureDetector(
                    onTap: _isSyncing ? null : _syncNow,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFC107).withAlpha(30),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          if (_isSyncing)
                            const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Color(0xFFFFC107))),
                            )
                          else
                            const Icon(Icons.cloud_upload_outlined, color: Color(0xFFFFC107), size: 18),
                          const SizedBox(width: 10),
                          Text(
                            '$_offlineDataCount pending',
                            style: const TextStyle(color: Color(0xFFFFC107), fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          const Spacer(),
                          if (!_isSyncing)
                            const Text('Sync', style: TextStyle(color: Color(0xFFFFC107), fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),

              // SESSION STATS ROW (today: monitoring time, peak PPV, events)
              _buildSessionStatsRow(),

              // QUICK STATS ROW (sessions / PPV / health)
              _buildQuickStatsRow(),

              // LAST EVENT SUMMARY CARD (if events exist)
              _buildLastEventSummaryCard(),

              // RECENT ALERTS SUMMARY
              _buildRecentAlertsSummaryCard(),

              // STATS
              CombinedStatCard(totalFindings: '$_totalFindings', todayFindings: '$_todayFindings'),
              const SizedBox(height: 12),

              // SENSOR STATUS
              const ActiveDevicesCard(),
              const SizedBox(height: 16),

              // RECENT SESSIONS
              _buildRecentSessionsCard(),

              // QUICK ACTIONS
              _buildQuickActions(),

              // RECENT FINDINGS
              LastFindingsCard(findings: _lastFindings),
              const SizedBox(height: 16),

              // FINDINGS STATS CARD
              _buildStatsCard(context),

              // SYSTEM STATUS CARD
              _buildSystemStatusCard(),

              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerIcon(IconData icon, {int badge = 0, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 36, height: 36,
        child: Stack(
          children: [
            Center(child: Icon(icon, color: Colors.white.withAlpha(200), size: 22)),
            if (badge > 0)
              Positioned(
                top: 2, right: 2,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: Color(0xFFFFC107), shape: BoxShape.circle),
                  constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                  child: Text(
                    badge > 9 ? '9+' : '$badge',
                    style: const TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
