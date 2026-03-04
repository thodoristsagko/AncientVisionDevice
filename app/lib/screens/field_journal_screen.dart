// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/field_journal.dart';
import '../services/voice_service.dart';
import '../services/progress_service.dart';
import '../services/cloud_database_service.dart';
import '../services/weather_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../services/location_service.dart';
import '../utils/app_styles.dart';

/// Field Journal Screen for daily documentation
/// Hybrid: Cloud (Firestore) when logged in, local (SharedPreferences) always as cache
class FieldJournalScreen extends StatefulWidget {
  const FieldJournalScreen({super.key});

  @override
  State<FieldJournalScreen> createState() => _FieldJournalScreenState();
}

class _FieldJournalScreenState extends State<FieldJournalScreen> {
  List<JournalEntry> _entries = [];
  bool _isLoading = true;
  JournalEntryType _selectedFilter = JournalEntryType.daily;
  bool _showAllTypes = true;
  final _voiceService = VoiceService();
  final _progressService = ProgressService();
  final _cloudDb = CloudDatabaseService();
  final _weatherService = WeatherService();
  String _searchQuery = '';
  final _searchController = TextEditingController();
  bool _showSearchBar = false;
  WeatherLog? _currentWeather;
  DateTimeRange? _dateRange;

  // SharedPreferences key for local storage
  static const _entriesKey = 'journal_entries';

  @override
  void initState() {
    super.initState();
    _loadEntries();
    _initServices();
  }

  Future<void> _initServices() async {
    await _voiceService.initialize();
    await _progressService.initialize();
    await _loadCurrentWeather();
  }

  Future<void> _loadCurrentWeather() async {
    try {
      final weather = await _weatherService.getLatestLog();
      if (weather != null && mounted) {
        setState(() => _currentWeather = weather);
      }
    } catch (e) {
      debugPrint('Error loading weather: $e');
    }
  }

  void _showWeatherDialog() {
    final weather = _currentWeather;
    if (weather == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.wb_sunny, color: Color(0xFF87CEEB)),
            SizedBox(width: 8),
            Text('Current Weather', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildWeatherRow(Icons.thermostat, 'Temperature', weather.temperatureString),
            _buildWeatherRow(Icons.water_drop, 'Humidity', weather.humidityString),
            _buildWeatherRow(Icons.speed, 'Pressure', weather.pressureString),
            if (weather.condition != null)
              _buildWeatherRow(Icons.cloud, 'Condition', weather.condition!.label),
            if (weather.windDirection != null)
              _buildWeatherRow(Icons.air, 'Wind', '${weather.windDirection!.label}${weather.windSpeed != null ? ' ${weather.windSpeed!.toStringAsFixed(0)} km/h' : ''}'),
            const Divider(color: Colors.white24, height: 24),
            Text(
              'Last updated: ${_formatWeatherTime(weather.timestamp)}',
              style: TextStyle(color: Colors.white.withAlpha(128), fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _logNewWeather();
            },
            child: const Text('Log Weather', style: TextStyle(color: Color(0xFFFFC107))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _buildWeatherRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 18),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 14)),
          const Spacer(),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  String _formatWeatherTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    return '${diff.inDays} days ago';
  }

  Future<void> _logNewWeather() async {
    // Quick weather log dialog
    WeatherCondition? selectedCondition;
    final tempController = TextEditingController();
    final humidityController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF1C2523),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Log Weather', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Condition selector
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: WeatherCondition.values.take(8).map((condition) {
                    final isSelected = selectedCondition == condition;
                    return GestureDetector(
                      onTap: () => setModalState(() => selectedCondition = condition),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFF87CEEB).withAlpha(60) : Colors.white.withAlpha(20),
                          borderRadius: BorderRadius.circular(16),
                          border: isSelected ? Border.all(color: const Color(0xFF87CEEB)) : null,
                        ),
                        child: Text(
                          condition.label,
                          style: TextStyle(
                            color: isSelected ? const Color(0xFF87CEEB) : Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: tempController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Temperature (°C)',
                    labelStyle: TextStyle(color: Colors.white.withAlpha(179)),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withAlpha(77)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: Color(0xFF87CEEB)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: humidityController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Humidity (%)',
                    labelStyle: TextStyle(color: Colors.white.withAlpha(179)),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withAlpha(77)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: Color(0xFF87CEEB)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              onPressed: () async {
                final log = await _weatherService.logWeather(
                  temperature: double.tryParse(tempController.text),
                  humidity: double.tryParse(humidityController.text),
                  condition: selectedCondition,
                );
                if (log != null && mounted) {
                  setState(() => _currentWeather = log);
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(
                        content: Text('Weather logged successfully'),
                        backgroundColor: Color(0xFF4CAF50),
                      ),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  Future<void> _loadEntries() async {
    try {
      // Always load local first
      await _loadEntriesLocal();

      // If logged in, also try cloud
      if (_cloudDb.useCloud) {
        final data = await _cloudDb.getJournalEntries();
        if (data.isNotEmpty) {
          _entries = data.map((json) => JournalEntry.fromJson(json)).toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          // Update local cache
          await _saveEntriesLocal();
        }
      }
    } catch (e) {
      debugPrint('Error loading entries: $e');
    }
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadEntriesLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = prefs.getStringList(_entriesKey) ?? [];
      _entries = jsonList
          .map((json) => JournalEntry.fromJson(jsonDecode(json)))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      debugPrint('Error loading local entries: $e');
      _entries = [];
    }
  }

  Future<void> _saveEntriesLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _entries.map((e) => jsonEncode(e.toJson())).toList();
      await prefs.setStringList(_entriesKey, jsonList);
    } catch (e) {
      debugPrint('Error saving local entries: $e');
    }
  }

  Future<void> _saveEntry(JournalEntry entry) async {
    // Always save locally
    await _saveEntriesLocal();

    // Also save to cloud if logged in
    if (_cloudDb.useCloud) {
      await _cloudDb.addJournalEntry(entry.toJson());
    }
  }

  Future<void> _updateEntry(JournalEntry entry) async {
    // Always save locally
    await _saveEntriesLocal();

    // Also update in cloud if logged in
    if (_cloudDb.useCloud) {
      await _cloudDb.updateJournalEntry(entry.id, entry.toJson());
    }
  }

  Future<void> _deleteEntry(JournalEntry entry) async {
    // Always save locally (entry already removed from _entries list)
    await _saveEntriesLocal();

    // Also delete from cloud if logged in
    if (_cloudDb.useCloud) {
      await _cloudDb.deleteJournalEntry(entry.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: _showSearchBar
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search by title, content or tags...',
                  hintStyle: TextStyle(color: Colors.white.withAlpha(128)),
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : Text('Field Journal (${_entries.length})', style: AppTextStyles.h3),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        actions: [
          // Weather indicator
          if (_currentWeather != null && !_showSearchBar)
            GestureDetector(
              onTap: _showWeatherDialog,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(40),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wb_sunny, color: AppColors.info, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      _currentWeather!.temperatureString,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.info,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          IconButton(
            icon: Icon(_showSearchBar ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _showSearchBar = !_showSearchBar;
                if (!_showSearchBar) {
                  _searchController.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
          if (!_showSearchBar) ...[
            IconButton(
              icon: const Icon(Icons.filter_list),
              onPressed: _showFilterDialog,
            ),
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export entries',
              onPressed: _exportEntries,
            ),
          ],
        ],
      ),
      body: Container(
        decoration: AppDecorations.screenBackground,
        child: SafeArea(
          child: _isLoading
              ? AppWidgets.loading()
              : _entries.isEmpty
                  ? _buildEmptyState()
                  : _buildJournalList(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showQuickEntrySheet(),
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.primary,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.book_outlined, size: 80, color: AppColors.textHint),
          const SizedBox(height: AppSpacing.lg),
          Text('No journal entries yet', style: AppTextStyles.h3.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'No journal entries yet. Start monitoring to record events.',
            style: TextStyle(
              color: AppColors.textHint,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJournalList() {
    var filteredEntries = _showAllTypes
        ? _entries
        : _entries.where((e) => e.type == _selectedFilter).toList();

    // Apply date range filter
    if (_dateRange != null) {
      final rangeStart = DateTime(
          _dateRange!.start.year, _dateRange!.start.month, _dateRange!.start.day);
      final rangeEnd = DateTime(
          _dateRange!.end.year, _dateRange!.end.month, _dateRange!.end.day, 23, 59, 59);
      filteredEntries = filteredEntries
          .where((e) =>
              !e.createdAt.isBefore(rangeStart) &&
              !e.createdAt.isAfter(rangeEnd))
          .toList();
    }

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      filteredEntries = filteredEntries.where((e) {
        final query = _searchQuery.toLowerCase();
        return e.title.toLowerCase().contains(query) ||
            e.content.toLowerCase().contains(query) ||
            (e.tags?.any((t) => t.toLowerCase().contains(query)) ?? false) ||
            (e.transcription?.toLowerCase().contains(query) ?? false);
      }).toList();
    }

    // Group entries by date
    final groupedEntries = <String, List<JournalEntry>>{};
    for (final entry in filteredEntries) {
      final dateKey = _formatDateKey(entry.createdAt);
      groupedEntries.putIfAbsent(dateKey, () => []).add(entry);
    }

    if (groupedEntries.isEmpty) {
      return Column(
        children: [
          _buildStatsHeader(filteredEntries),
          _buildDateRangeFilterRow(),
          Expanded(
            child: Center(
              child: Text(
                'No entries found',
                style: TextStyle(color: Colors.white.withAlpha(150)),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        _buildStatsHeader(filteredEntries),
        _buildDateRangeFilterRow(),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: groupedEntries.length,
            itemBuilder: (context, index) {
              final dateKey = groupedEntries.keys.elementAt(index);
              final entries = groupedEntries[dateKey]!;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      dateKey,
                      style: TextStyle(
                        color: Colors.white.withAlpha(179),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...entries.map((entry) => _buildEntryCard(entry)),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// Compact stats card shown above the entry list.
  Widget _buildStatsHeader(List<JournalEntry> visibleEntries) {
    final total = _entries.length;
    final lastEntry = _entries.isEmpty ? null : _entries.first;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final lastDate = lastEntry == null
        ? '—'
        : '${months[lastEntry.createdAt.month - 1]} ${lastEntry.createdAt.day}';

    return Container(
      height: 60,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Row(
        children: [
          _buildStatCell(Icons.book, total.toString(), 'entries'),
          _buildStatDivider(),
          _buildStatCell(Icons.event, lastDate, 'last entry'),
          _buildStatDivider(),
          _buildStatCell(
            Icons.search,
            visibleEntries.length.toString(),
            'visible',
          ),
        ],
      ),
    );
  }

  Widget _buildStatCell(IconData icon, String value, String label) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 12, color: AppColors.accent),
              const SizedBox(width: 4),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Text(
            label,
            style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildStatDivider() {
    return Container(width: 1, height: 32, color: Colors.white.withAlpha(38));
  }

  /// Date range filter chip row shown below the stats header.
  Widget _buildDateRangeFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          if (_dateRange == null)
            GestureDetector(
              onTap: _pickDateRange,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(25),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withAlpha(50)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.date_range, size: 14, color: Colors.white70),
                    SizedBox(width: 6),
                    Text(
                      'All dates',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.accent.withAlpha(50),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.accent.withAlpha(150)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.date_range, size: 14, color: AppColors.accent),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: _pickDateRange,
                    child: Text(
                      _formatDateRangeLabel(_dateRange!),
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => setState(() => _dateRange = null),
                    child: const Icon(Icons.close, size: 14, color: AppColors.accent),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _dateRange,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppColors.accent,
            onPrimary: AppColors.primaryDark,
            surface: Color(0xFF1C2523),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _dateRange = picked);
    }
  }

  String _formatDateRangeLabel(DateTimeRange range) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final start = range.start;
    final end = range.end;
    if (start.month == end.month && start.year == end.year) {
      return '${months[start.month - 1]} ${start.day}–${end.day}';
    }
    return '${months[start.month - 1]} ${start.day} – ${months[end.month - 1]} ${end.day}';
  }

  /// Export currently visible entries as a JSON array via the system share sheet.
  void _exportEntries() {
    // Collect the currently filtered entries (same logic as _buildJournalList)
    var toExport = _showAllTypes
        ? _entries
        : _entries.where((e) => e.type == _selectedFilter).toList();

    if (_dateRange != null) {
      final rangeStart = DateTime(
          _dateRange!.start.year, _dateRange!.start.month, _dateRange!.start.day);
      final rangeEnd = DateTime(
          _dateRange!.end.year, _dateRange!.end.month, _dateRange!.end.day, 23, 59, 59);
      toExport = toExport
          .where((e) =>
              !e.createdAt.isBefore(rangeStart) &&
              !e.createdAt.isAfter(rangeEnd))
          .toList();
    }

    if (_searchQuery.isNotEmpty) {
      toExport = toExport.where((e) {
        final query = _searchQuery.toLowerCase();
        return e.title.toLowerCase().contains(query) ||
            e.content.toLowerCase().contains(query) ||
            (e.tags?.any((t) => t.toLowerCase().contains(query)) ?? false) ||
            (e.transcription?.toLowerCase().contains(query) ?? false);
      }).toList();
    }

    final jsonList = toExport
        .map((e) => {
              'id': e.id,
              'date': e.createdAt.toIso8601String(),
              'title': e.title,
              'content': e.content,
              'type': e.type.name,
            })
        .toList();

    final jsonString = const JsonEncoder.withIndent('  ').convert(jsonList);

    // Use Clipboard as fallback (share_plus is not imported here)
    Clipboard.setData(ClipboardData(text: jsonString));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Exported ${toExport.length} entr${toExport.length == 1 ? 'y' : 'ies'} — copied to clipboard',
        ),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _buildEntryCard(JournalEntry entry) {
    return GestureDetector(
      onTap: () => _showEntryDetails(entry),
      onLongPress: () => _showEntryOptions(entry),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(26),
          borderRadius: BorderRadius.circular(12),
          border: entry.isPinned
              ? Border.all(color: Colors.amber, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: entry.type.color.withAlpha(51),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    entry.type.icon,
                    color: entry.type.color,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        entry.type.label,
                        style: TextStyle(
                          color: entry.type.color,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (entry.isPinned)
                  const Icon(Icons.push_pin, color: Colors.amber, size: 16),
                if (entry.transcription != null && entry.transcription!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(Icons.mic, color: Colors.red.withAlpha(179), size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              entry.content,
              style: TextStyle(
                color: Colors.white.withAlpha(204),
                fontSize: 14,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            // Show transcription preview if exists
            if (entry.transcription != null && entry.transcription!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.record_voice_over, color: Colors.red, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.transcription!,
                        style: TextStyle(
                          color: Colors.white.withAlpha(180),
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Weather info if available
            if (entry.weather != null || entry.temperature != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF87CEEB).withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wb_sunny, color: Color(0xFF87CEEB), size: 14),
                    const SizedBox(width: 6),
                    if (entry.temperature != null)
                      Text(
                        '${entry.temperature!.toStringAsFixed(1)}°C',
                        style: const TextStyle(
                          color: Color(0xFF87CEEB),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (entry.weather != null && entry.temperature != null)
                      const Text(' • ', style: TextStyle(color: Color(0xFF87CEEB), fontSize: 11)),
                    if (entry.weather != null)
                      Flexible(
                        child: Text(
                          entry.weather!,
                          style: TextStyle(
                            color: Colors.white.withAlpha(180),
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (entry.tags != null && entry.tags!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: entry.tags!.map((tag) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '#$tag',
                    style: TextStyle(
                      color: Colors.white.withAlpha(179),
                      fontSize: 12,
                    ),
                  ),
                )).toList(),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatTime(entry.createdAt),
                  style: TextStyle(
                    color: Colors.white.withAlpha(128),
                    fontSize: 12,
                  ),
                ),
                if (entry.workCondition != null)
                  Row(
                    children: [
                      Icon(
                        entry.workCondition!.icon,
                        color: entry.workCondition!.color,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        entry.workCondition!.label,
                        style: TextStyle(
                          color: Colors.white.withAlpha(128),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Quick-entry bottom sheet: minimal fields + live PPV/anomaly context + GPS.
  void _showQuickEntrySheet() {
    final noteController = TextEditingController();
    JournalEntryType selectedType = JournalEntryType.daily;

    // Snapshot current vibration state (for future display when stream is wired up)
    // ignore: unused_local_variable
    final anomalyService = VibrationAnomalyService.instance;
    // Use last known location from LocationService
    final locService = LocationService.instance;
    final lastLoc = locService.lastLocation;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Handle bar
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Quick Entry',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Vibration context banner (always shown; 'No data' if not connected)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withAlpha(38)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.sensors, color: Color(0xFFFFC107), size: 16),
                        const SizedBox(width: 8),
                        Text(
                          'Vibration: N/A (not yet processed)',
                          style: TextStyle(
                            color: Colors.white.withAlpha(179),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // GPS context
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withAlpha(38)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          lastLoc != null ? Icons.location_on : Icons.location_off,
                          color: lastLoc != null ? const Color(0xFF4CAF50) : Colors.white38,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          lastLoc != null
                              ? '${lastLoc.latitude.toStringAsFixed(5)}, ${lastLoc.longitude.toStringAsFixed(5)}'
                              : 'No GPS',
                          style: TextStyle(
                            color: Colors.white.withAlpha(179),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Note text field
                  TextField(
                    controller: noteController,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 4,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Note',
                      labelStyle: const TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Colors.white.withAlpha(26),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      hintText: 'Describe your observation...',
                      hintStyle: TextStyle(color: Colors.white.withAlpha(77)),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Entry type dropdown
                  const Text('Type', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      JournalEntryType.observation,
                      JournalEntryType.problem,
                      JournalEntryType.method,
                      JournalEntryType.other,
                    ].map((type) {
                      final isSelected = selectedType == type;
                      return GestureDetector(
                        onTap: () => setSheet(() => selectedType = type),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? type.color : Colors.white.withAlpha(26),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(type.icon, size: 14, color: isSelected ? Colors.white : type.color),
                              const SizedBox(width: 4),
                              Text(
                                type.label,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  // Link to full entry form
                  Center(
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showNewEntryDialog();
                      },
                      child: const Text(
                        'Full entry with tags & voice...',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Save button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final noteText = noteController.text.trim();
                        if (noteText.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Please enter a note')),
                          );
                          return;
                        }

                        // Try to get fresh GPS fix (non-blocking, use cached if unavailable)
                        GpsLocation? gps = locService.lastLocation;
                        try {
                          gps = await locService.getCurrentLocation()
                              .timeout(const Duration(seconds: 3));
                        } catch (_) {
                          // Use cached location
                        }

                        final locationSubtitle = gps != null
                            ? '📍 ${gps.latitude.toStringAsFixed(5)}, ${gps.longitude.toStringAsFixed(5)}'
                            : null;

                        final entry = JournalEntry(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          type: selectedType,
                          title: locationSubtitle ?? selectedType.label,
                          content: noteText,
                        );

                        setState(() => _entries.insert(0, entry));
                        await _saveEntry(entry);

                        if (mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                locationSubtitle != null
                                    ? 'Entry saved • $locationSubtitle'
                                    : 'Entry saved (no GPS)',
                              ),
                              backgroundColor: const Color(0xFF4CAF50),
                            ),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFC107),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Save',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showFilterDialog() {
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
              'Filter by Type',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.all_inclusive, color: Colors.white),
              title: const Text('All Types', style: TextStyle(color: Colors.white)),
              trailing: _showAllTypes ? const Icon(Icons.check, color: Colors.green) : null,
              onTap: () {
                setState(() => _showAllTypes = true);
                Navigator.pop(context);
              },
            ),
            ...JournalEntryType.values.take(6).map((type) => ListTile(
              leading: Icon(type.icon, color: type.color),
              title: Text(type.label, style: const TextStyle(color: Colors.white)),
              trailing: !_showAllTypes && _selectedFilter == type
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                setState(() {
                  _showAllTypes = false;
                  _selectedFilter = type;
                });
                Navigator.pop(context);
              },
            )),
          ],
        ),
      ),
    );
  }

  void _showNewEntryDialog() {
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    JournalEntryType selectedType = JournalEntryType.daily;
    WorkCondition? selectedCondition;
    List<String> tags = [];
    final tagController = TextEditingController();
    String? voiceTranscription;
    bool isRecording = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'New Journal Entry',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // Voice recording button
                    Container(
                      decoration: BoxDecoration(
                        color: isRecording ? Colors.red : Colors.red.withAlpha(50),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: IconButton(
                        icon: Icon(
                          isRecording ? Icons.stop : Icons.mic,
                          color: isRecording ? Colors.white : Colors.red,
                        ),
                        onPressed: () async {
                          if (isRecording) {
                            final text = await _voiceService.stopListening();
                            setModalState(() {
                              isRecording = false;
                              if (text.isNotEmpty) {
                                voiceTranscription = text;
                                // Append to content
                                if (contentController.text.isNotEmpty) {
                                  contentController.text += '\n\n[Voice Note]: $text';
                                } else {
                                  contentController.text = text;
                                }
                              }
                            });
                          } else {
                            final started = await _voiceService.startListening(
                              onResult: (text, isFinal) {
                                setModalState(() {
                                  voiceTranscription = text;
                                });
                              },
                            );
                            if (started) {
                              setModalState(() => isRecording = true);
                            } else {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Voice recognition not available')),
                                );
                              }
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ),

                // Voice recording indicator
                if (isRecording) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withAlpha(30),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withAlpha(100)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.graphic_eq, color: Colors.red),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Recording...',
                                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                              ),
                              if (voiceTranscription != null && voiceTranscription!.isNotEmpty)
                                Text(
                                  voiceTranscription!,
                                  style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Show voice transcription result
                if (!isRecording && voiceTranscription != null && voiceTranscription!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withAlpha(30),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Voice note captured',
                          style: TextStyle(color: Colors.green),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Type selection
                const Text('Entry Type', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: JournalEntryType.values.take(6).map((type) {
                    final isSelected = selectedType == type;
                    return GestureDetector(
                      onTap: () => setModalState(() => selectedType = type),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected ? type.color : Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(type.icon, size: 16, color: isSelected ? Colors.white : type.color),
                            const SizedBox(width: 4),
                            Text(
                              type.label,
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Title
                TextField(
                  controller: titleController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Title',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Colors.white.withAlpha(26),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Content with voice input button
                Stack(
                  children: [
                    TextField(
                      controller: contentController,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: 'Content',
                        labelStyle: const TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: Colors.white.withAlpha(26),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Work condition
                const Text('Work Condition', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: WorkCondition.values.map((condition) {
                    final isSelected = selectedCondition == condition;
                    return GestureDetector(
                      onTap: () => setModalState(() => selectedCondition = condition),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isSelected ? condition.color.withAlpha(51) : Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(8),
                          border: isSelected ? Border.all(color: condition.color) : null,
                        ),
                        child: Icon(condition.icon, color: condition.color, size: 24),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Tags
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: tagController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Add tag...',
                          hintStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: Colors.white.withAlpha(26),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.add, color: Colors.white),
                      onPressed: () {
                        if (tagController.text.isNotEmpty) {
                          setModalState(() {
                            tags.add(tagController.text);
                            tagController.clear();
                          });
                        }
                      },
                    ),
                  ],
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: tags.map((tag) => Chip(
                      label: Text('#$tag'),
                      onDeleted: () => setModalState(() => tags.remove(tag)),
                      backgroundColor: Colors.white.withAlpha(26),
                      labelStyle: const TextStyle(color: Colors.white),
                      deleteIconColor: Colors.white54,
                    )).toList(),
                  ),
                ],
                const SizedBox(height: 24),

                // Save button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (titleController.text.isEmpty || contentController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please fill in title and content')),
                        );
                        return;
                      }

                      final entry = JournalEntry(
                        id: DateTime.now().millisecondsSinceEpoch.toString(),
                        type: selectedType,
                        title: titleController.text,
                        content: contentController.text,
                        workCondition: selectedCondition,
                        tags: tags.isEmpty ? null : tags,
                        transcription: voiceTranscription,
                        weather: _currentWeather?.summary,
                        temperature: _currentWeather?.temperature,
                      );

                      setState(() {
                        _entries.insert(0, entry);
                      });
                      await _saveEntry(entry);

                      // Record progress and check for achievements
                      final achievements = await _progressService.recordNote();
                      if (achievements.isNotEmpty && mounted) {
                        _showAchievementDialog(achievements.first);
                      }

                      if (mounted) Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFC107),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Save Entry', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAchievementDialog(Achievement achievement) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFFC107).withAlpha(50),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Icon(
                achievement.type.icon,
                color: const Color(0xFFFFC107),
                size: 48,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Achievement Unlocked!',
              style: TextStyle(
                color: Color(0xFFFFC107),
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              achievement.type.title,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 4),
            Text(
              achievement.type.description,
              style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Awesome!'),
          ),
        ],
      ),
    );
  }

  void _showEntryDetails(JournalEntry entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: entry.type.color.withAlpha(51),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(entry.type.icon, color: entry.type.color, size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${entry.type.label} - ${entry.dayOfWeek}',
                          style: TextStyle(color: entry.type.color),
                        ),
                      ],
                    ),
                  ),
                  // Read aloud button
                  IconButton(
                    icon: Icon(
                      _voiceService.isSpeaking ? Icons.stop : Icons.volume_up,
                      color: const Color(0xFFFFC107),
                    ),
                    onPressed: () async {
                      if (_voiceService.isSpeaking) {
                        await _voiceService.stopSpeaking();
                      } else {
                        final textToRead = '${entry.title}. ${entry.content}';
                        await _voiceService.speak(textToRead);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                entry.content,
                style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5),
              ),

              // Show voice transcription if exists
              if (entry.transcription != null && entry.transcription!.isNotEmpty) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(30),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withAlpha(100)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.record_voice_over, color: Colors.red, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Voice Note Transcription',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.volume_up, color: Colors.red, size: 20),
                            onPressed: () => _voiceService.speak(entry.transcription!),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        entry.transcription!,
                        style: TextStyle(
                          color: Colors.white.withAlpha(200),
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (entry.workCondition != null) ...[
                const SizedBox(height: 24),
                Row(
                  children: [
                    Icon(entry.workCondition!.icon, color: entry.workCondition!.color),
                    const SizedBox(width: 8),
                    Text(
                      'Work Condition: ${entry.workCondition!.label}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ],
              if (entry.tags != null && entry.tags!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: entry.tags!.map((tag) => Chip(
                    label: Text('#$tag'),
                    backgroundColor: Colors.white.withAlpha(26),
                    labelStyle: const TextStyle(color: Colors.white),
                  )).toList(),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Created: ${_formatDateTime(entry.createdAt)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEntryOptions(JournalEntry entry) {
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
          children: [
            ListTile(
              leading: const Icon(Icons.volume_up, color: Color(0xFFFFC107)),
              title: const Text('Read Aloud', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _voiceService.speak('${entry.title}. ${entry.content}');
              },
            ),
            ListTile(
              leading: Icon(
                entry.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                color: Colors.amber,
              ),
              title: Text(
                entry.isPinned ? 'Unpin Entry' : 'Pin Entry',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () async {
                final updatedEntry = entry.copyWith(isPinned: !entry.isPinned);
                setState(() {
                  final index = _entries.indexOf(entry);
                  _entries[index] = updatedEntry;
                });
                await _updateEntry(updatedEntry);
                if (mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete Entry', style: TextStyle(color: Colors.white)),
              onTap: () async {
                setState(() => _entries.remove(entry));
                await _deleteEntry(entry);
                if (mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateKey(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final entryDate = DateTime(date.year, date.month, date.day);

    if (entryDate == today) return 'Today';
    if (entryDate == today.subtract(const Duration(days: 1))) return 'Yesterday';

    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _formatTime(DateTime date) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime date) {
    return '${_formatDateKey(date)} at ${_formatTime(date)}';
  }
}
