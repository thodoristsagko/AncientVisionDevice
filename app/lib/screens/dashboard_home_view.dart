// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/dashboard_home_widgets.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../services/notification_service.dart';
import '../services/site_service.dart';
import 'notifications_screen.dart';
import 'qr_scanner_screen.dart';
import 'analytics_screen.dart';

class DashboardHomeView extends StatefulWidget {
  const DashboardHomeView({super.key});

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
  }

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

  Widget _buildStatsCard(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
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

              const SizedBox(height: 20),

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

              // STATS
              CombinedStatCard(totalFindings: '$_totalFindings', todayFindings: '$_todayFindings'),
              const SizedBox(height: 12),

              // SENSOR STATUS
              const ActiveDevicesCard(),
              const SizedBox(height: 20),

              // RECENT FINDINGS
              LastFindingsCard(findings: _lastFindings),
              const SizedBox(height: 16),

              // FINDINGS STATS CARD
              _buildStatsCard(context),

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
