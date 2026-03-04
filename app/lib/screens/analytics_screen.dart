import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/progress_service.dart';
import '../services/local_storage_service.dart';
import '../services/export_service.dart';
import '../services/session_export_service.dart';
import '../services/session_history_service.dart';
import '../services/alert_history_service.dart';
import '../services/inference_timing_service.dart';

/// Analytics and Statistics Dashboard Screen
/// Professional documentation statistics with beautiful visualizations
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen>
    with SingleTickerProviderStateMixin {
  final _progressService = ProgressService();
  final _localStorage = LocalStorageService();
  bool _isLoading = true;
  List<DailyStats> _weeklyStats = [];
  List<DailyStats> _monthlyStats = [];
  List<Map<String, dynamic>> _allFindings = [];
  int _selectedPeriod = 0; // 0: Week, 1: Month, 2: All Time
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Computed from real data
  Map<String, int> _materialCounts = {};

  // P156: Data quality + model performance extras
  String? _modelAccuracy;    // loaded from precursor_training_metrics.json
  bool _metricsLoaded = false;

  // Session timeline (last 10 sessions, newest first)
  List<SessionRecord> _recentSessions = [];

  // Alert level distribution from alert history
  Map<String, int> _alertLevelCounts = {};

  // ML inference stats snapshot
  int _inferenceCount = 0;
  double _inferenceAvgMs = 0.0;

  // PPV statistics (P157: Enhanced vibration analytics)
  double _meanPpv = 0.0;
  double _stdDevPpv = 0.0;
  double _peakPpv = 0.0;
  int _totalReadings = 0;
  double _alertRate = 0.0;
  Duration? _lastSessionDuration;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _loadData();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    await _progressService.initialize();
    await _localStorage.initialize();

    _weeklyStats = await _progressService.getWeeklyStats();
    _monthlyStats = await _getMonthlyStats();
    _allFindings = _localStorage.getAllCachedFindings();

    // Analyze real finding data
    _analyzeFindingData();

    // P156: Attempt to load model performance metrics
    await _loadModelMetrics();

    // Load session timeline (last 10 sessions)
    final allSessions = await SessionHistoryService.instance.getSessions();
    _recentSessions = allSessions.take(10).toList();

    // Load alert level distribution
    final alertHistory = await AlertHistoryService().load();
    _alertLevelCounts = {};
    for (final entry in alertHistory) {
      final level = entry.level.isNotEmpty ? entry.level : 'unknown';
      _alertLevelCounts[level] = (_alertLevelCounts[level] ?? 0) + 1;
    }

    // Snapshot ML inference stats
    final timing = InferenceTimingService.instance;
    _inferenceCount = timing.count;
    _inferenceAvgMs = timing.avgMs;

    // P157: Calculate PPV statistics from findings
    _calculatePpvStatistics();

    // P157: Calculate alert rate (ANOMALY or CRITICAL as % of total readings)
    _calculateAlertRate(alertHistory);

    // P157: Get last session duration
    if (_recentSessions.isNotEmpty) {
      _lastSessionDuration = _recentSessions.first.duration;
    }

    if (mounted) {
      setState(() => _isLoading = false);
      _animationController.forward();
    }
  }

  /// Get monthly stats (last 30 days)
  Future<List<DailyStats>> _getMonthlyStats() async {
    // For now, return weekly stats extended - can be enhanced later
    return _weeklyStats;
  }

  /// Analyze real finding data for materials
  void _analyzeFindingData() {
    _materialCounts = {};

    for (final finding in _allFindings) {
      // Count materials
      final material = finding['material'] as String? ?? 'Unknown';
      _materialCounts[material] = (_materialCounts[material] ?? 0) + 1;
    }
  }

  /// P157: Calculate PPV statistics from findings
  /// Computes mean, std dev, peak PPV, and total reading count.
  void _calculatePpvStatistics() {
    if (_allFindings.isEmpty) {
      _meanPpv = 0.0;
      _stdDevPpv = 0.0;
      _peakPpv = 0.0;
      _totalReadings = 0;
      return;
    }

    // Extract PPV values from findings
    final ppvValues = <double>[];
    for (final finding in _allFindings) {
      if (finding['ppv'] != null) {
        final ppv = (finding['ppv'] as num?)?.toDouble() ?? 0.0;
        if (ppv > 0) {
          ppvValues.add(ppv);
        }
      }
    }

    if (ppvValues.isEmpty) {
      _meanPpv = 0.0;
      _stdDevPpv = 0.0;
      _peakPpv = 0.0;
      _totalReadings = 0;
      return;
    }

    _totalReadings = ppvValues.length;

    // Calculate mean
    _meanPpv = ppvValues.fold(0.0, (a, b) => a + b) / ppvValues.length;

    // Calculate peak
    _peakPpv = ppvValues.fold(0.0, (a, b) => a > b ? a : b);

    // Calculate standard deviation
    final variance = ppvValues.fold(0.0, (sum, val) => sum + ((val - _meanPpv) * (val - _meanPpv))) / ppvValues.length;
    _stdDevPpv = math.sqrt(variance);
  }

  /// P157: Calculate alert rate as percentage of readings that triggered ANOMALY/CRITICAL.
  void _calculateAlertRate(List<AlertData> alertHistory) {
    if (_totalReadings == 0) {
      _alertRate = 0.0;
      return;
    }

    final anomalyCount = alertHistory
        .where((e) => e.level == 'ANOMALY' || e.level == 'CRITICAL')
        .length;

    _alertRate = _totalReadings > 0 ? (anomalyCount / _totalReadings) * 100 : 0.0;
  }

  /// Get filtered stats based on selected period
  List<DailyStats> get _filteredStats {
    switch (_selectedPeriod) {
      case 0: // Week
        return _weeklyStats;
      case 1: // Month
        return _monthlyStats;
      case 2: // All Time
        return _weeklyStats; // Show weekly as sample of all time
      default:
        return _weeklyStats;
    }
  }

  /// Get period label for display
  String get _periodLabel {
    switch (_selectedPeriod) {
      case 0:
        return 'This Week';
      case 1:
        return 'This Month';
      case 2:
        return 'All Time';
      default:
        return 'This Week';
    }
  }

  /// P156: Load model performance metrics from bundled JSON asset.
  Future<void> _loadModelMetrics() async {
    try {
      final raw = await rootBundle.loadString(
          'assets/ml/precursor_training_metrics.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final acc = json['accuracy'] ?? json['val_accuracy'] ?? json['test_accuracy'];
      if (acc != null) {
        setState(() {
          _modelAccuracy = '${(acc * 100).toStringAsFixed(1)}%';
          _metricsLoaded = true;
        });
        return;
      }
    } catch (_) {
      // Asset may not exist — fall through to show "Model not loaded"
    }
    setState(() {
      _modelAccuracy = null;
      _metricsLoaded = true;
    });
  }

  /// P156: Export all available session data via SessionExportService.
  Future<void> _exportAllSessions(BuildContext context) async {
    // Build records from cached findings (best effort — full session data
    // is only available when the safety view is active and passes records in).
    final records = _allFindings.map((f) {
      return {
        'timestamp': f['timestamp'] ?? '',
        'ppv': f['ppv'] ?? '',
        'rms': f['rms'] ?? '',
        'freq': f['dominantFreq'] ?? '',
        'kurtosis': f['kurtosis'] ?? '',
        'stalta': f['stalta'] ?? '',
        'anomaly_score': f['anomalyScore'] ?? '',
        'anomaly_level': f['anomalyLevel'] ?? '',
        'precursor_pattern': f['precursorPattern'] ?? '',
        'confidence': f['confidence'] ?? '',
      };
    }).toList();

    if (records.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No data to export'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    try {
      await SessionExportService.instance.exportSession(records);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Show export dialog for analytics data
  void _showExportDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Export Analytics',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Export your documentation statistics',
              style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 14),
            ),
            const SizedBox(height: 20),
            _buildExportOption(
              context,
              icon: Icons.description,
              title: 'Export as CSV',
              subtitle: 'Spreadsheet format for analysis',
              onTap: () => _exportAnalytics(context, 'csv'),
            ),
            const SizedBox(height: 12),
            _buildExportOption(
              context,
              icon: Icons.code,
              title: 'Export as JSON',
              subtitle: 'Full data with metadata',
              onTap: () => _exportAnalytics(context, 'json'),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildExportOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(30)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFC107).withAlpha(30),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: const Color(0xFFFFC107), size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withAlpha(150),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.white.withAlpha(100)),
          ],
        ),
      ),
    );
  }

  Future<void> _exportAnalytics(BuildContext context, String format) async {
    Navigator.pop(context); // Close bottom sheet

    final progress = _progressService.progress;
    final today = _progressService.todayStats;

    // Build analytics data as a list of findings-like maps for export
    final analyticsData = [
      {
        'category': 'Summary',
        'metric': 'Total Findings',
        'value': progress.totalFindings,
      },
      {
        'category': 'Summary',
        'metric': 'Total Photos',
        'value': progress.totalPhotos,
      },
      {
        'category': 'Summary',
        'metric': 'Total 3D Models',
        'value': progress.total3DModels,
      },
      {
        'category': 'Summary',
        'metric': 'Total Contexts',
        'value': progress.totalContexts,
      },
      {
        'category': 'Summary',
        'metric': 'Total Notes',
        'value': progress.totalNotes,
      },
      {
        'category': 'Summary',
        'metric': 'Total Reports',
        'value': progress.totalReports,
      },
      {
        'category': 'Summary',
        'metric': 'Current Streak',
        'value': progress.currentStreak,
      },
      {
        'category': 'Summary',
        'metric': 'Level',
        'value': '${progress.level} - ${progress.levelTitle}',
      },
      {
        'category': 'Today',
        'metric': 'Findings Recorded',
        'value': today.findingsRecorded,
      },
      {
        'category': 'Today',
        'metric': 'Photos Captured',
        'value': today.photosCapture,
      },
      {
        'category': 'Today',
        'metric': 'Models Created',
        'value': today.modelsCreated,
      },
      {
        'category': 'Today',
        'metric': 'Total Actions',
        'value': today.totalActions,
      },
      // Add material breakdown
      ..._materialCounts.entries.map((e) => {
        'category': 'Materials',
        'metric': e.key,
        'value': e.value,
      }),
    ];

    try {
      final exportService = ExportService();
      File? file;

      if (format == 'csv') {
        file = await exportService.exportFindingsToCsv(analyticsData);
      } else {
        file = await exportService.exportFindingsToJson(analyticsData);
      }

      if (context.mounted && file != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Analytics exported successfully'),
            backgroundColor: const Color(0xFF4CAF50),
            action: SnackBarAction(
              label: 'Share',
              textColor: Colors.white,
              onPressed: () => exportService.shareFile(file!),
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0D3A39),
              Color(0xFF1C2523),
            ],
          ),
        ),
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFFFFC107)))
            : CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                // Custom App Bar with Stats Overview
                _buildSliverAppBar(),

                // Content
                SliverToBoxAdapter(
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Time Period Filter
                          _buildPeriodFilter(),
                          const SizedBox(height: 20),

                          // P156: Data Quality summary card
                          _buildDataQualityCard(),
                          const SizedBox(height: 16),

                          // P156: Model Performance card
                          _buildModelPerformanceCard(),
                          const SizedBox(height: 20),

                          // Quick Stats Cards
                          _buildQuickStatsRow(),
                          const SizedBox(height: 24),

                          // P157: Vibration Statistics Card (PPV, Alert Rate, Session Duration)
                          _buildVibrationStatsCard(),
                          const SizedBox(height: 24),

                          // Weekly Activity Chart
                          _buildSectionHeader('Activity Overview', Icons.show_chart),
                          const SizedBox(height: 12),
                          _buildWeeklyChart(),
                          const SizedBox(height: 24),

                          // Category Breakdown
                          _buildSectionHeader('Documentation Breakdown', Icons.pie_chart),
                          const SizedBox(height: 12),
                          _buildCategoryBreakdown(),
                          const SizedBox(height: 24),

                          // Material Analysis
                          _buildSectionHeader('Material Analysis', Icons.category),
                          const SizedBox(height: 12),
                          _buildMaterialAnalysis(),
                          const SizedBox(height: 24),

                          // Session PPV Timeline
                          _buildSectionHeader('Session PPV Timeline', Icons.timeline),
                          const SizedBox(height: 12),
                          _buildSessionTimeline(),
                          const SizedBox(height: 24),

                          // ML Performance
                          _buildSectionHeader('ML Inference Performance', Icons.speed),
                          const SizedBox(height: 12),
                          _buildMlPerformanceSection(),
                          const SizedBox(height: 24),

                          // Anomaly Level Distribution
                          _buildSectionHeader('Anomaly Distribution', Icons.donut_large),
                          const SizedBox(height: 12),
                          _buildAnomalyPieChart(),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  // ─── P156 new cards ──────────────────────────────────────────────────────────

  /// Data Quality card: session count, sample count, date range.
  Widget _buildDataQualityCard() {
    final sessionCount = _weeklyStats.length;
    final totalSamples = _allFindings.length;

    // Date range from weekly stats
    String dateRange = 'N/A';
    if (_weeklyStats.isNotEmpty) {
      final first = _weeklyStats.first.date;
      final last = _weeklyStats.last.date;
      dateRange = '${_fmtDate(first)} – ${_fmtDate(last)}';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.verified_outlined, color: Color(0xFF4CAF50), size: 18),
              SizedBox(width: 8),
              Text(
                'Data Quality',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildKV('Sessions (this week)', '$sessionCount'),
          const SizedBox(height: 6),
          _buildKV('Total cached items', '$totalSamples'),
          const SizedBox(height: 6),
          _buildKV('Date range', dateRange),
        ],
      ),
    );
  }

  /// Model Performance card: reads precursor_training_metrics.json.
  Widget _buildModelPerformanceCard() {
    final label = !_metricsLoaded
        ? 'Loading…'
        : (_modelAccuracy != null ? _modelAccuracy! : 'Model not loaded');

    final color = _modelAccuracy != null
        ? const Color(0xFF4CAF50)
        : Colors.white54;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.model_training, color: Color(0xFF9C27B0), size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Model Performance',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildKV('Precursor classifier accuracy', label),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withAlpha(80)),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// P157: Vibration Statistics Card
  /// Displays PPV mean, std dev, peak, total readings, alert rate, and last session duration.
  Widget _buildVibrationStatsCard() {
    final meanLabel = _totalReadings > 0
        ? '${_meanPpv.toStringAsFixed(3)} mm/s'
        : 'N/A';
    final stdDevLabel = _totalReadings > 0
        ? '${_stdDevPpv.toStringAsFixed(3)} mm/s'
        : 'N/A';
    final peakLabel = _peakPpv > 0
        ? '${_peakPpv.toStringAsFixed(3)} mm/s'
        : 'N/A';
    final readingLabel = '$_totalReadings';
    final alertRateLabel = '${_alertRate.toStringAsFixed(1)}%';
    final durationLabel = _lastSessionDuration != null
        ? _formatDuration(_lastSessionDuration!)
        : 'N/A';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.show_chart, color: Color(0xFF00BCD4), size: 18),
              SizedBox(width: 8),
              Text(
                'Vibration Statistics',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 2x3 grid of stats
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatItem('Mean PPV', meanLabel),
                    const SizedBox(height: 8),
                    _buildStatItem('Peak PPV', peakLabel),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatItem('Std Dev', stdDevLabel),
                    const SizedBox(height: 8),
                    _buildStatItem('Total readings', readingLabel),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Alert rate and session duration (full width)
          Row(
            children: [
              Expanded(
                child: _buildStatItem('Alert rate (ANOMALY/CRITICAL)', alertRateLabel),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildStatItem('Last session duration', durationLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Helper widget for a single statistic item (label + value).
  Widget _buildStatItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withAlpha(140),
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// Format duration as "Xm Ys" or "Xh Ym".
  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  Widget _buildKV(String key, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          key,
          style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 13),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  String _fmtDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.year}';

  // ─── Original section builders ────────────────────────────────────────────

  Widget _buildSliverAppBar() {
    final progress = _progressService.progress;
    final totalItems = progress.totalFindings +
        progress.total3DModels +
        progress.totalContexts +
        progress.totalNotes;

    return SliverAppBar(
      expandedHeight: 200,
      floating: false,
      pinned: true,
      backgroundColor: const Color(0xFF0D3A39),
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          icon: const Icon(Icons.upload_rounded),
          tooltip: 'Export All Sessions',
          onPressed: () => _exportAllSessions(context),
        ),
        IconButton(
          icon: const Icon(Icons.file_download_rounded),
          tooltip: 'Export Analytics',
          onPressed: () => _showExportDialog(context),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF0D3A39),
                const Color(0xFF1A5653),
                const Color(0xFF0D3A39).withAlpha(200),
              ],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFC107).withAlpha(30),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.analytics,
                          color: Color(0xFFFFC107),
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Documentation Analytics',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$totalItems total items documented',
                              style: TextStyle(
                                color: Colors.white.withAlpha(180),
                                fontSize: 14,
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
          ),
        ),
      ),
    );
  }

  Widget _buildPeriodFilter() {
    final periods = ['This Week', 'This Month', 'All Time'];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: List.generate(periods.length, (index) {
          final isSelected = _selectedPeriod == index;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _selectedPeriod = index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFFFFC107)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  periods[index],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isSelected ? Colors.black : Colors.white70,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildQuickStatsRow() {
    final today = _progressService.todayStats;
    final weekTotal = _weeklyStats.fold<int>(0, (sum, s) => sum + s.totalActions);
    final avgPerDay = _weeklyStats.isNotEmpty
        ? (weekTotal / _weeklyStats.length).round()
        : 0;

    return Row(
      children: [
        Expanded(
          child: _buildQuickStatCard(
            title: 'Today',
            value: today.totalActions,
            subtitle: 'actions',
            icon: Icons.today,
            color: const Color(0xFF4CAF50),
            trend: _calculateTodayTrend(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuickStatCard(
            title: 'This Week',
            value: weekTotal,
            subtitle: 'total',
            icon: Icons.date_range,
            color: const Color(0xFF2196F3),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuickStatCard(
            title: 'Daily Avg',
            value: avgPerDay,
            subtitle: 'actions/day',
            icon: Icons.trending_up,
            color: const Color(0xFFFFC107),
          ),
        ),
      ],
    );
  }

  int _calculateTodayTrend() {
    if (_weeklyStats.length < 2) return 0;
    final today = _progressService.todayStats.totalActions;
    final yesterday = _weeklyStats.length >= 2
        ? _weeklyStats[_weeklyStats.length - 2].totalActions
        : 0;
    return today - yesterday;
  }

  Widget _buildQuickStatCard({
    required String title,
    required int value,
    required String subtitle,
    required IconData icon,
    required Color color,
    int? trend,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withAlpha(40),
            color.withAlpha(20),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 18),
              if (trend != null && trend != 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: trend > 0
                        ? Colors.green.withAlpha(40)
                        : Colors.red.withAlpha(40),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        trend > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 10,
                        color: trend > 0 ? Colors.green : Colors.red,
                      ),
                      Text(
                        '${trend.abs()}',
                        style: TextStyle(
                          color: trend > 0 ? Colors.green : Colors.red,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: value),
            duration: const Duration(milliseconds: 800),
            builder: (context, val, child) {
              return Text(
                '$val',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              );
            },
          ),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withAlpha(150),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFFFC107), size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildWeeklyChart() {
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final stats = _filteredStats;
    final maxValue = stats.fold<int>(
      1,
      (max, stat) => stat.totalActions > max ? stat.totalActions : max,
    );

    return Container(
      height: 240,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$_periodLabel Activity',
                style: TextStyle(
                  color: Colors.white.withAlpha(200),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107).withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${stats.fold<int>(0, (sum, s) => sum + s.totalActions)} total',
                  style: const TextStyle(
                    color: Color(0xFFFFC107),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxValue.toDouble() + 2,
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    tooltipBgColor: const Color(0xFF1A5653),
                    tooltipRoundedRadius: 8,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      if (groupIndex >= stats.length) return null;
                      final stat = stats[groupIndex];
                      return BarTooltipItem(
                        '${stat.totalActions} actions\n'
                        '${stat.findingsRecorded} findings\n'
                        '${stat.photosCapture} photos',
                        const TextStyle(color: Colors.white, fontSize: 11),
                      );
                    },
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final index = value.toInt();
                        if (index >= 0 && index < stats.length) {
                          final dayIndex = stats[index].date.weekday - 1;
                          final isToday = index == stats.length - 1;
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              days[dayIndex],
                              style: TextStyle(
                                color: isToday
                                    ? const Color(0xFFFFC107)
                                    : Colors.white.withAlpha(150),
                                fontSize: 11,
                                fontWeight:
                                    isToday ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          );
                        }
                        return const Text('');
                      },
                      reservedSize: 28,
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        if (value == 0) return const SizedBox();
                        return Text(
                          value.toInt().toString(),
                          style: TextStyle(
                            color: Colors.white.withAlpha(100),
                            fontSize: 10,
                          ),
                        );
                      },
                      reservedSize: 28,
                    ),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: maxValue > 5 ? (maxValue / 3) : 1,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: Colors.white.withAlpha(20),
                    strokeWidth: 1,
                    dashArray: [5, 5],
                  ),
                ),
                barGroups: List.generate(stats.length, (index) {
                  final stat = stats[index];
                  final isToday = index == stats.length - 1;
                  return BarChartGroupData(
                    x: index,
                    barRods: [
                      BarChartRodData(
                        toY: stat.totalActions.toDouble(),
                        gradient: LinearGradient(
                          colors: isToday
                              ? [const Color(0xFFFFC107), const Color(0xFFFF9800)]
                              : [const Color(0xFF4CAF50), const Color(0xFF2E7D32)],
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                        ),
                        width: 28,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(8),
                        ),
                        backDrawRodData: BackgroundBarChartRodData(
                          show: true,
                          toY: maxValue.toDouble() + 2,
                          color: Colors.white.withAlpha(10),
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBreakdown() {
    final progress = _progressService.progress;
    final categories = [
      _CategoryData('Findings', progress.totalFindings, const Color(0xFF2196F3)),
      _CategoryData('Photos', progress.totalPhotos, const Color(0xFF00BCD4)),
      _CategoryData('3D Models', progress.total3DModels, const Color(0xFF9C27B0)),
      _CategoryData('Contexts', progress.totalContexts, const Color(0xFFFF9800)),
      _CategoryData('Notes', progress.totalNotes, const Color(0xFF4CAF50)),
      _CategoryData('Reports', progress.totalReports, const Color(0xFFF44336)),
    ];

    final total = categories.fold<int>(0, (sum, c) => sum + c.value);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Row(
        children: [
          // Pie Chart
          SizedBox(
            height: 140,
            width: 140,
            child: total > 0
                ? PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 35,
                      sections: categories
                          .where((c) => c.value > 0)
                          .map((c) => PieChartSectionData(
                                value: c.value.toDouble(),
                                color: c.color,
                                radius: 30,
                                showTitle: false,
                              ))
                          .toList(),
                    ),
                  )
                : Center(
                    child: Text(
                      'No data yet',
                      style: TextStyle(color: Colors.white.withAlpha(150)),
                    ),
                  ),
          ),
          const SizedBox(width: 20),
          // Legend
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: categories.map((c) {
                final percentage =
                    total > 0 ? ((c.value / total) * 100).round() : 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: c.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.name,
                          style: TextStyle(
                            color: Colors.white.withAlpha(200),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        '${c.value}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '($percentage%)',
                        style: TextStyle(
                          color: Colors.white.withAlpha(120),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMaterialAnalysis() {
    // Material colors mapping
    const materialColors = {
      'Ceramic': Color(0xFFE57373),
      'Stone': Color(0xFF64B5F6),
      'Metal': Color(0xFFFFD54F),
      'Bone': Color(0xFFAED581),
      'Glass': Color(0xFFBA68C8),
      'Wood': Color(0xFF8D6E63),
      'Textile': Color(0xFFCE93D8),
      'Organic': Color(0xFFA5D6A7),
      'Unknown': Color(0xFF90A4AE),
    };

    // Build materials list from real data
    final materials = _materialCounts.entries.map((e) {
      final color = materialColors[e.key] ?? const Color(0xFF90A4AE);
      return _MaterialData(e.key, e.value, color);
    }).toList()
      ..sort((a, b) => b.count.compareTo(a.count)); // Sort by count descending

    // Take top 5 and group rest as "Other"
    final displayMaterials = <_MaterialData>[];
    if (materials.length <= 5) {
      displayMaterials.addAll(materials);
    } else {
      displayMaterials.addAll(materials.take(4));
      final otherCount = materials.skip(4).fold<int>(0, (sum, m) => sum + m.count);
      if (otherCount > 0) {
        displayMaterials.add(_MaterialData('Other', otherCount, const Color(0xFF90A4AE)));
      }
    }

    final total = displayMaterials.fold(0, (sum, m) => sum + m.count);

    if (displayMaterials.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(20),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha(30)),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.category, color: Colors.white.withAlpha(100), size: 40),
                const SizedBox(height: 12),
                Text(
                  'No material data yet',
                  style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  'Add findings with material types to see analysis',
                  style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        children: displayMaterials.map((m) {
          final percentage = total > 0 ? (m.count / total) : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: m.color,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          m.name,
                          style: TextStyle(
                            color: Colors.white.withAlpha(200),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${m.count} (${(percentage * 100).round()}%)',
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
                    value: percentage,
                    backgroundColor: Colors.white.withAlpha(30),
                    valueColor: AlwaysStoppedAnimation<Color>(m.color),
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ─── New: Session PPV Timeline ───────────────────────────────────────────────

  /// Bar chart using CustomPainter — no chart packages.
  Widget _buildSessionTimeline() {
    if (_recentSessions.isEmpty) {
      return _buildEmptyCard('No session data yet.\nStart a monitoring session to record PPV history.');
    }

    // Sessions come newest-first; reverse so oldest is on the left.
    final sessions = _recentSessions.reversed.toList();
    final maxPpv = sessions.fold<double>(0.01, (m, s) => s.peakPpv > m ? s.peakPpv : m);

    return Container(
      height: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Peak PPV per session (last ${sessions.length})',
            style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _SessionTimelinePainter(sessions: sessions, maxPpv: maxPpv),
            ),
          ),
        ],
      ),
    );
  }

  // ─── New: ML Performance Section ─────────────────────────────────────────────

  Widget _buildMlPerformanceSection() {
    final countLabel = _inferenceCount > 0 ? '$_inferenceCount' : 'N/A';
    final avgLabel = _inferenceCount > 0
        ? '${_inferenceAvgMs.toStringAsFixed(1)} ms'
        : 'N/A';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildKV('Total inferences (this session)', countLabel),
          const SizedBox(height: 8),
          _buildKV('Avg inference time', avgLabel),
          const SizedBox(height: 8),
          _buildKV('Model accuracy (from training)', _modelAccuracy ?? 'N/A'),
          const SizedBox(height: 8),
          _buildKV('Inference engine', 'TFLite on-device'),
        ],
      ),
    );
  }

  // ─── New: Anomaly Distribution Pie Chart ─────────────────────────────────────

  Widget _buildAnomalyPieChart() {
    if (_alertLevelCounts.isEmpty) {
      return _buildEmptyCard('No alert history yet.\nAlert levels will be recorded here during monitoring sessions.');
    }

    const levelColors = {
      'critical': Color(0xFFE53935),
      'warning': Color(0xFFFFB300),
      'elevated': Color(0xFFFF7043),
      'normal': Color(0xFF4CAF50),
      'unknown': Color(0xFF90A4AE),
    };

    final entries = _alertLevelCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (s, e) => s + e.value);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Pie chart using CustomPainter
          SizedBox(
            width: 130,
            height: 130,
            child: CustomPaint(
              painter: _PieChartPainter(
                entries: entries.map((e) => _PieSlice(
                  label: e.key,
                  count: e.value,
                  color: levelColors[e.key] ?? const Color(0xFF90A4AE),
                )).toList(),
                total: total,
              ),
            ),
          ),
          const SizedBox(width: 20),
          // Legend
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: entries.map((e) {
                final color = levelColors[e.key] ?? const Color(0xFF90A4AE);
                final pct = total > 0 ? ((e.value / total) * 100).round() : 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 10, height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          e.key.toUpperCase(),
                          style: TextStyle(
                            color: Colors.white.withAlpha(200),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        '${e.value}',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '($pct%)',
                        style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCard(String text) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Center(
        child: Text(
          text,
          style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 13, height: 1.5),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ─── CustomPainter: Session PPV bar chart ─────────────────────────────────────

class _SessionTimelinePainter extends CustomPainter {
  final List<SessionRecord> sessions;
  final double maxPpv;

  _SessionTimelinePainter({required this.sessions, required this.maxPpv});

  static const _safeThreshold = 3.0;   // DIN 4150-3 low-end

  @override
  void paint(Canvas canvas, Size size) {
    if (sessions.isEmpty) return;

    final n = sessions.length;
    final barWidth = (size.width / n) * 0.6;
    final slotWidth = size.width / n;
    const labelH = 20.0;
    final chartH = size.height - labelH;

    final safePaint = Paint()..color = const Color(0xFF4CAF50);
    final warnPaint = Paint()..color = const Color(0xFFFFB300);
    final critPaint = Paint()..color = const Color(0xFFE53935);
    final gridPaint = Paint()
      ..color = Colors.white.withAlpha(20)
      ..strokeWidth = 1;
    final textStyle = TextStyle(
      color: Colors.white.withAlpha(140),
      fontSize: 9,
    );

    // Horizontal grid line at threshold
    final thresholdY = chartH * (1 - (_safeThreshold / maxPpv).clamp(0, 1));
    canvas.drawLine(Offset(0, thresholdY), Offset(size.width, thresholdY), gridPaint);

    for (int i = 0; i < n; i++) {
      final s = sessions[i];
      final ppv = s.peakPpv;
      final frac = (ppv / maxPpv).clamp(0.0, 1.0);
      final barH = (chartH * frac).clamp(2.0, chartH);

      final left = slotWidth * i + (slotWidth - barWidth) / 2;
      final top = chartH - barH;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barH),
        const Radius.circular(3),
      );

      final paint = ppv >= _safeThreshold * 1.5
          ? critPaint
          : ppv >= _safeThreshold
              ? warnPaint
              : safePaint;
      canvas.drawRRect(rect, paint);

      // X-axis label: month/day
      final label = '${s.start.month}/${s.start.day}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: slotWidth);
      tp.paint(canvas, Offset(left + (barWidth - tp.width) / 2, chartH + 3));
    }

    // Y-axis label at top: max value
    final maxLabel = TextPainter(
      text: TextSpan(
        text: '${maxPpv.toStringAsFixed(1)} mm/s',
        style: textStyle,
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 60);
    maxLabel.paint(canvas, const Offset(0, 0));
  }

  @override
  bool shouldRepaint(_SessionTimelinePainter old) =>
      old.sessions != sessions || old.maxPpv != maxPpv;
}

// ─── CustomPainter: Pie chart ─────────────────────────────────────────────────

class _PieSlice {
  final String label;
  final int count;
  final Color color;
  _PieSlice({required this.label, required this.count, required this.color});
}

class _PieChartPainter extends CustomPainter {
  final List<_PieSlice> entries;
  final int total;

  _PieChartPainter({required this.entries, required this.total});

  @override
  void paint(Canvas canvas, Size size) {
    if (total == 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    const gapAngle = 0.04; // radians between slices

    double startAngle = -math.pi / 2;
    for (final slice in entries) {
      final sweep = (slice.count / total) * 2 * math.pi - gapAngle;
      if (sweep <= 0) continue;
      final paint = Paint()
        ..color = slice.color
        ..style = PaintingStyle.fill;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle + gapAngle / 2,
        sweep,
        true,
        paint,
      );
      startAngle += sweep + gapAngle;
    }

    // Centre hole
    canvas.drawCircle(center, radius * 0.48,
        Paint()..color = const Color(0xFF1C2523));
  }

  @override
  bool shouldRepaint(_PieChartPainter old) =>
      old.entries != entries || old.total != total;
}

class _CategoryData {
  final String name;
  final int value;
  final Color color;

  _CategoryData(this.name, this.value, this.color);
}

class _MaterialData {
  final String name;
  final int count;
  final Color color;

  _MaterialData(this.name, this.count, this.color);
}
