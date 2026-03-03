import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_database_service.dart';
import 'notification_service.dart';

/// Achievement badge types
enum AchievementType {
  firstFinding('First Discovery', 'Record your first finding', Icons.star, 1),
  tenFindings('Explorer', 'Record 10 findings', Icons.explore, 10),
  fiftyFindings('Archaeologist', 'Record 50 findings', Icons.school, 50),
  hundredFindings('Expert', 'Record 100 findings', Icons.workspace_premium, 100),
  first3D('3D Pioneer', 'Create your first 3D model', Icons.view_in_ar, 1),
  ten3D('3D Master', 'Create 10 3D models', Icons.threed_rotation, 10),
  firstContext('Stratigraphist', 'Record your first context sheet', Icons.layers, 1),
  firstReport('Reporter', 'Generate your first PDF report', Icons.description, 1),
  weekStreak('Week Warrior', 'Record findings 7 days in a row', Icons.local_fire_department, 7),
  monthStreak('Monthly Master', 'Record findings 30 days in a row', Icons.whatshot, 30),
  firstVoiceNote('Voice Logger', 'Create your first voice note', Icons.mic, 1),
  allTypes('Collector', 'Record all artifact types', Icons.category, 13),
  firstSite('Site Creator', 'Create your first site', Icons.place, 1),
  firstExport('Data Exporter', 'Export your first dataset', Icons.download, 1),
  firstBackup('Backup Pro', 'Create your first backup', Icons.backup, 1);

  final String title;
  final String description;
  final IconData icon;
  final int requirement;

  const AchievementType(this.title, this.description, this.icon, this.requirement);
}

/// Represents an earned achievement
class Achievement {
  final AchievementType type;
  final DateTime earnedAt;

  Achievement({
    required this.type,
    DateTime? earnedAt,
  }) : earnedAt = earnedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'earnedAt': earnedAt.toIso8601String(),
      };

  factory Achievement.fromJson(Map<String, dynamic> json) => Achievement(
        type: AchievementType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => AchievementType.firstFinding,
        ),
        earnedAt: DateTime.parse(json['earnedAt']),
      );
}

/// Daily goal
class DailyGoal {
  final String id;
  final String title;
  final String description;
  final int target;
  final int current;
  final IconData icon;

  DailyGoal({
    required this.id,
    required this.title,
    required this.description,
    required this.target,
    this.current = 0,
    required this.icon,
  });

  double get progress => target > 0 ? (current / target).clamp(0.0, 1.0) : 0.0;
  bool get isComplete => current >= target;

  DailyGoal copyWith({int? current}) => DailyGoal(
        id: id,
        title: title,
        description: description,
        target: target,
        current: current ?? this.current,
        icon: icon,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'target': target,
        'current': current,
      };
}

/// Daily statistics
class DailyStats {
  final DateTime date;
  final int findingsRecorded;
  final int photosCapture;
  final int modelsCreated;
  final int contextsRecorded;
  final int notesCreated;
  final int reportsGenerated;

  DailyStats({
    required this.date,
    this.findingsRecorded = 0,
    this.photosCapture = 0,
    this.modelsCreated = 0,
    this.contextsRecorded = 0,
    this.notesCreated = 0,
    this.reportsGenerated = 0,
  });

  int get totalActions =>
      findingsRecorded +
      photosCapture +
      modelsCreated +
      contextsRecorded +
      notesCreated +
      reportsGenerated;

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'findingsRecorded': findingsRecorded,
        'photosCapture': photosCapture,
        'modelsCreated': modelsCreated,
        'contextsRecorded': contextsRecorded,
        'notesCreated': notesCreated,
        'reportsGenerated': reportsGenerated,
      };

  factory DailyStats.fromJson(Map<String, dynamic> json) => DailyStats(
        date: DateTime.parse(json['date']),
        findingsRecorded: json['findingsRecorded'] ?? 0,
        photosCapture: json['photosCapture'] ?? 0,
        modelsCreated: json['modelsCreated'] ?? 0,
        contextsRecorded: json['contextsRecorded'] ?? 0,
        notesCreated: json['notesCreated'] ?? 0,
        reportsGenerated: json['reportsGenerated'] ?? 0,
      );

  DailyStats copyWith({
    int? findingsRecorded,
    int? photosCapture,
    int? modelsCreated,
    int? contextsRecorded,
    int? notesCreated,
    int? reportsGenerated,
  }) =>
      DailyStats(
        date: date,
        findingsRecorded: findingsRecorded ?? this.findingsRecorded,
        photosCapture: photosCapture ?? this.photosCapture,
        modelsCreated: modelsCreated ?? this.modelsCreated,
        contextsRecorded: contextsRecorded ?? this.contextsRecorded,
        notesCreated: notesCreated ?? this.notesCreated,
        reportsGenerated: reportsGenerated ?? this.reportsGenerated,
      );
}

/// User progress and statistics summary
class UserProgress {
  final int totalFindings;
  final int totalPhotos;
  final int total3DModels;
  final int totalContexts;
  final int totalNotes;
  final int totalReports;
  final int currentStreak;
  final int longestStreak;
  final List<Achievement> achievements;
  final DateTime? lastActivityDate;

  UserProgress({
    this.totalFindings = 0,
    this.totalPhotos = 0,
    this.total3DModels = 0,
    this.totalContexts = 0,
    this.totalNotes = 0,
    this.totalReports = 0,
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.achievements = const [],
    this.lastActivityDate,
  });

  int get level {
    final total = totalFindings + total3DModels + totalContexts;
    if (total >= 500) return 10;
    if (total >= 300) return 9;
    if (total >= 200) return 8;
    if (total >= 150) return 7;
    if (total >= 100) return 6;
    if (total >= 70) return 5;
    if (total >= 50) return 4;
    if (total >= 30) return 3;
    if (total >= 15) return 2;
    return 1;
  }

  String get levelTitle {
    switch (level) {
      case 1:
        return 'Novice';
      case 2:
        return 'Apprentice';
      case 3:
        return 'Student';
      case 4:
        return 'Researcher';
      case 5:
        return 'Field Worker';
      case 6:
        return 'Archaeologist';
      case 7:
        return 'Senior Archaeologist';
      case 8:
        return 'Expert';
      case 9:
        return 'Master';
      case 10:
        return 'Legend';
      default:
        return 'Novice';
    }
  }

  Map<String, dynamic> toJson() => {
        'totalFindings': totalFindings,
        'totalPhotos': totalPhotos,
        'total3DModels': total3DModels,
        'totalContexts': totalContexts,
        'totalNotes': totalNotes,
        'totalReports': totalReports,
        'currentStreak': currentStreak,
        'longestStreak': longestStreak,
        'achievements': achievements.map((a) => a.toJson()).toList(),
        'lastActivityDate': lastActivityDate?.toIso8601String(),
      };

  factory UserProgress.fromJson(Map<String, dynamic> json) => UserProgress(
        totalFindings: json['totalFindings'] ?? 0,
        totalPhotos: json['totalPhotos'] ?? 0,
        total3DModels: json['total3DModels'] ?? 0,
        totalContexts: json['totalContexts'] ?? 0,
        totalNotes: json['totalNotes'] ?? 0,
        totalReports: json['totalReports'] ?? 0,
        currentStreak: json['currentStreak'] ?? 0,
        longestStreak: json['longestStreak'] ?? 0,
        achievements: json['achievements'] != null
            ? (json['achievements'] as List)
                .map((a) => Achievement.fromJson(a))
                .toList()
            : [],
        lastActivityDate: json['lastActivityDate'] != null
            ? DateTime.parse(json['lastActivityDate'])
            : null,
      );
}

/// Service for tracking user progress and achievements
/// Hybrid: Cloud (Firestore) when logged in, local (SharedPreferences) always as cache
class ProgressService {
  static final ProgressService _instance = ProgressService._internal();
  factory ProgressService() => _instance;
  ProgressService._internal();

  final _cloudDb = CloudDatabaseService();

  // SharedPreferences keys for local storage
  static const _progressKey = 'user_progress';
  static const _dailyStatsKey = 'daily_stats';
  static const _weeklyStatsKey = 'weekly_stats';

  UserProgress _progress = UserProgress();
  DailyStats _todayStats = DailyStats(date: DateTime.now());

  UserProgress get progress => _progress;
  DailyStats get todayStats => _todayStats;

  /// Initialize the service
  Future<void> initialize() async {
    await _loadProgress();
    await _loadTodayStats();
    await _checkStreak();
  }

  /// Load progress - from cloud if logged in, local otherwise
  Future<void> _loadProgress() async {
    try {
      // Always load local first as cache
      await _loadProgressLocal();

      // If logged in, also try to get from cloud and merge
      if (_cloudDb.useCloud) {
        final data = await _cloudDb.getProgressStats();
        if (data != null) {
          _progress = UserProgress.fromJson(data);
          // Update local cache
          await _saveProgressLocal();
        }
      }
    } catch (e) {
      debugPrint('Error loading progress: $e');
    }
  }

  /// Load progress from local SharedPreferences
  Future<void> _loadProgressLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_progressKey);
      if (json != null) {
        _progress = UserProgress.fromJson(jsonDecode(json));
      }
    } catch (e) {
      debugPrint('Error loading local progress: $e');
      _progress = UserProgress();
    }
  }

  /// Save progress to local SharedPreferences
  Future<void> _saveProgressLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_progressKey, jsonEncode(_progress.toJson()));
    } catch (e) {
      debugPrint('Error saving local progress: $e');
    }
  }

  /// Load today's stats
  Future<void> _loadTodayStats() async {
    try {
      // Load local first
      await _loadTodayStatsLocal();

      // If logged in, also try cloud
      if (_cloudDb.useCloud) {
        final today = DateTime.now();
        final dateKey = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
        final data = await _cloudDb.getDailyStats(dateKey);

        if (data != null) {
          final stats = DailyStats.fromJson(data);
          if (stats.date.year == today.year &&
              stats.date.month == today.month &&
              stats.date.day == today.day) {
            _todayStats = stats;
            await _saveTodayStatsLocal();
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading today stats: $e');
    }
  }

  /// Load today's stats from local
  Future<void> _loadTodayStatsLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_dailyStatsKey);
      if (json != null) {
        final stats = DailyStats.fromJson(jsonDecode(json));
        final today = DateTime.now();
        if (stats.date.year == today.year &&
            stats.date.month == today.month &&
            stats.date.day == today.day) {
          _todayStats = stats;
        } else {
          _todayStats = DailyStats(date: today);
        }
      } else {
        _todayStats = DailyStats(date: DateTime.now());
      }
    } catch (e) {
      debugPrint('Error loading local today stats: $e');
      _todayStats = DailyStats(date: DateTime.now());
    }
  }

  /// Save today's stats to local
  Future<void> _saveTodayStatsLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dailyStatsKey, jsonEncode(_todayStats.toJson()));
    } catch (e) {
      debugPrint('Error saving local today stats: $e');
    }
  }

  /// Check and update streak
  Future<void> _checkStreak() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (_progress.lastActivityDate == null) return;

    final lastActivity = DateTime(
      _progress.lastActivityDate!.year,
      _progress.lastActivityDate!.month,
      _progress.lastActivityDate!.day,
    );

    final difference = today.difference(lastActivity).inDays;

    if (difference > 1) {
      // Streak broken
      _progress = UserProgress(
        totalFindings: _progress.totalFindings,
        totalPhotos: _progress.totalPhotos,
        total3DModels: _progress.total3DModels,
        totalContexts: _progress.totalContexts,
        totalNotes: _progress.totalNotes,
        totalReports: _progress.totalReports,
        currentStreak: 0,
        longestStreak: _progress.longestStreak,
        achievements: _progress.achievements,
        lastActivityDate: _progress.lastActivityDate,
      );
      await _saveProgress();
    }
  }

  /// Record a finding
  Future<List<Achievement>> recordFinding() async {
    _todayStats = _todayStats.copyWith(
      findingsRecorded: _todayStats.findingsRecorded + 1,
    );
    await _saveTodayStats();

    _progress = UserProgress(
      totalFindings: _progress.totalFindings + 1,
      totalPhotos: _progress.totalPhotos,
      total3DModels: _progress.total3DModels,
      totalContexts: _progress.totalContexts,
      totalNotes: _progress.totalNotes,
      totalReports: _progress.totalReports,
      currentStreak: _progress.currentStreak,
      longestStreak: _progress.longestStreak,
      achievements: _progress.achievements,
      lastActivityDate: DateTime.now(),
    );

    await _updateStreak();
    return await _checkAchievements();
  }

  /// Record a 3D model
  Future<List<Achievement>> record3DModel() async {
    _todayStats = _todayStats.copyWith(
      modelsCreated: _todayStats.modelsCreated + 1,
    );
    await _saveTodayStats();

    _progress = UserProgress(
      totalFindings: _progress.totalFindings,
      totalPhotos: _progress.totalPhotos,
      total3DModels: _progress.total3DModels + 1,
      totalContexts: _progress.totalContexts,
      totalNotes: _progress.totalNotes,
      totalReports: _progress.totalReports,
      currentStreak: _progress.currentStreak,
      longestStreak: _progress.longestStreak,
      achievements: _progress.achievements,
      lastActivityDate: DateTime.now(),
    );

    await _updateStreak();
    return await _checkAchievements();
  }

  /// Record a context sheet
  Future<List<Achievement>> recordContext() async {
    _todayStats = _todayStats.copyWith(
      contextsRecorded: _todayStats.contextsRecorded + 1,
    );
    await _saveTodayStats();

    _progress = UserProgress(
      totalFindings: _progress.totalFindings,
      totalPhotos: _progress.totalPhotos,
      total3DModels: _progress.total3DModels,
      totalContexts: _progress.totalContexts + 1,
      totalNotes: _progress.totalNotes,
      totalReports: _progress.totalReports,
      currentStreak: _progress.currentStreak,
      longestStreak: _progress.longestStreak,
      achievements: _progress.achievements,
      lastActivityDate: DateTime.now(),
    );

    await _updateStreak();
    return await _checkAchievements();
  }

  /// Record a note
  Future<List<Achievement>> recordNote() async {
    _todayStats = _todayStats.copyWith(
      notesCreated: _todayStats.notesCreated + 1,
    );
    await _saveTodayStats();

    _progress = UserProgress(
      totalFindings: _progress.totalFindings,
      totalPhotos: _progress.totalPhotos,
      total3DModels: _progress.total3DModels,
      totalContexts: _progress.totalContexts,
      totalNotes: _progress.totalNotes + 1,
      totalReports: _progress.totalReports,
      currentStreak: _progress.currentStreak,
      longestStreak: _progress.longestStreak,
      achievements: _progress.achievements,
      lastActivityDate: DateTime.now(),
    );

    await _updateStreak();
    return await _checkAchievements();
  }

  /// Record a report
  Future<List<Achievement>> recordReport() async {
    _todayStats = _todayStats.copyWith(
      reportsGenerated: _todayStats.reportsGenerated + 1,
    );
    await _saveTodayStats();

    _progress = UserProgress(
      totalFindings: _progress.totalFindings,
      totalPhotos: _progress.totalPhotos,
      total3DModels: _progress.total3DModels,
      totalContexts: _progress.totalContexts,
      totalNotes: _progress.totalNotes,
      totalReports: _progress.totalReports + 1,
      currentStreak: _progress.currentStreak,
      longestStreak: _progress.longestStreak,
      achievements: _progress.achievements,
      lastActivityDate: DateTime.now(),
    );

    return await _checkAchievements();
  }

  /// Record photos captured (can record multiple at once)
  Future<void> recordPhotos(int count) async {
    if (count <= 0) return;

    _todayStats = _todayStats.copyWith(
      photosCapture: _todayStats.photosCapture + count,
    );
    await _saveTodayStats();

    _progress = UserProgress(
      totalFindings: _progress.totalFindings,
      totalPhotos: _progress.totalPhotos + count,
      total3DModels: _progress.total3DModels,
      totalContexts: _progress.totalContexts,
      totalNotes: _progress.totalNotes,
      totalReports: _progress.totalReports,
      currentStreak: _progress.currentStreak,
      longestStreak: _progress.longestStreak,
      achievements: _progress.achievements,
      lastActivityDate: _progress.lastActivityDate,
    );

    await _saveProgress();
  }

  /// Update streak
  Future<void> _updateStreak() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    int newStreak = _progress.currentStreak;
    int newLongest = _progress.longestStreak;

    if (_progress.lastActivityDate == null) {
      newStreak = 1;
    } else {
      final lastActivity = DateTime(
        _progress.lastActivityDate!.year,
        _progress.lastActivityDate!.month,
        _progress.lastActivityDate!.day,
      );

      final difference = today.difference(lastActivity).inDays;

      if (difference == 0) {
        // Same day, no change
      } else if (difference == 1) {
        // Consecutive day
        newStreak = _progress.currentStreak + 1;
      } else {
        // Streak broken
        newStreak = 1;
      }
    }

    if (newStreak > newLongest) {
      newLongest = newStreak;
    }

    _progress = UserProgress(
      totalFindings: _progress.totalFindings,
      totalPhotos: _progress.totalPhotos,
      total3DModels: _progress.total3DModels,
      totalContexts: _progress.totalContexts,
      totalNotes: _progress.totalNotes,
      totalReports: _progress.totalReports,
      currentStreak: newStreak,
      longestStreak: newLongest,
      achievements: _progress.achievements,
      lastActivityDate: DateTime.now(),
    );

    await _saveProgress();
  }

  /// Check for new achievements
  Future<List<Achievement>> _checkAchievements() async {
    final newAchievements = <Achievement>[];
    final existingTypes = _progress.achievements.map((a) => a.type).toSet();

    // Check each achievement type
    for (final type in AchievementType.values) {
      if (existingTypes.contains(type)) continue;

      bool earned = false;

      switch (type) {
        case AchievementType.firstFinding:
          earned = _progress.totalFindings >= 1;
          break;
        case AchievementType.tenFindings:
          earned = _progress.totalFindings >= 10;
          break;
        case AchievementType.fiftyFindings:
          earned = _progress.totalFindings >= 50;
          break;
        case AchievementType.hundredFindings:
          earned = _progress.totalFindings >= 100;
          break;
        case AchievementType.first3D:
          earned = _progress.total3DModels >= 1;
          break;
        case AchievementType.ten3D:
          earned = _progress.total3DModels >= 10;
          break;
        case AchievementType.firstContext:
          earned = _progress.totalContexts >= 1;
          break;
        case AchievementType.firstReport:
          earned = _progress.totalReports >= 1;
          break;
        case AchievementType.weekStreak:
          earned = _progress.currentStreak >= 7;
          break;
        case AchievementType.monthStreak:
          earned = _progress.currentStreak >= 30;
          break;
        case AchievementType.firstVoiceNote:
          earned = _progress.totalNotes >= 1;
          break;
        default:
          break;
      }

      if (earned) {
        final achievement = Achievement(type: type);
        newAchievements.add(achievement);
      }
    }

    if (newAchievements.isNotEmpty) {
      final allAchievements = [..._progress.achievements, ...newAchievements];
      _progress = UserProgress(
        totalFindings: _progress.totalFindings,
        totalPhotos: _progress.totalPhotos,
        total3DModels: _progress.total3DModels,
        totalContexts: _progress.totalContexts,
        totalNotes: _progress.totalNotes,
        totalReports: _progress.totalReports,
        currentStreak: _progress.currentStreak,
        longestStreak: _progress.longestStreak,
        achievements: allAchievements,
        lastActivityDate: _progress.lastActivityDate,
      );
      await _saveProgress();

      // Send notification for each new achievement
      final notificationService = NotificationService();
      for (final achievement in newAchievements) {
        await notificationService.showAchievementUnlocked(
          achievementTitle: achievement.type.title,
          achievementDescription: achievement.type.description,
        );
      }
    }

    return newAchievements;
  }

  /// Get daily goals
  List<DailyGoal> getDailyGoals() {
    return [
      DailyGoal(
        id: 'findings',
        title: 'Record Findings',
        description: 'Record at least 3 findings today',
        target: 3,
        current: _todayStats.findingsRecorded,
        icon: Icons.add_a_photo,
      ),
      DailyGoal(
        id: 'photos',
        title: 'Capture Photos',
        description: 'Take at least 10 photos',
        target: 10,
        current: _todayStats.photosCapture,
        icon: Icons.camera_alt,
      ),
      DailyGoal(
        id: 'notes',
        title: 'Write Notes',
        description: 'Create at least 2 notes',
        target: 2,
        current: _todayStats.notesCreated,
        icon: Icons.note_add,
      ),
    ];
  }

  /// Save progress - to cloud if logged in, always to local
  Future<void> _saveProgress() async {
    // Always save locally
    await _saveProgressLocal();

    // Also save to cloud if logged in
    if (_cloudDb.useCloud) {
      await _cloudDb.saveProgressStats(_progress.toJson());
    }
  }

  /// Save today's stats - to cloud if logged in, always to local
  Future<void> _saveTodayStats() async {
    // Always save locally
    await _saveTodayStatsLocal();

    // Also save to cloud if logged in
    if (_cloudDb.useCloud) {
      final today = DateTime.now();
      final dateKey = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      await _cloudDb.saveDailyStats(dateKey, _todayStats.toJson());
    }

    // Also update weekly stats locally
    await _saveWeeklyStatsLocal();
  }

  /// Save weekly stats for charting (local)
  Future<void> _saveWeeklyStatsLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingJson = prefs.getString(_weeklyStatsKey);
      List<DailyStats> weeklyStats = [];

      if (existingJson != null) {
        final list = jsonDecode(existingJson) as List;
        weeklyStats = list.map((e) => DailyStats.fromJson(e)).toList();
      }

      // Update or add today's stats
      final todayIndex = weeklyStats.indexWhere((s) =>
          s.date.year == _todayStats.date.year &&
          s.date.month == _todayStats.date.month &&
          s.date.day == _todayStats.date.day);

      if (todayIndex >= 0) {
        weeklyStats[todayIndex] = _todayStats;
      } else {
        weeklyStats.add(_todayStats);
      }

      // Keep only last 7 days
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      weeklyStats = weeklyStats.where((s) => s.date.isAfter(cutoff)).toList();

      await prefs.setString(
        _weeklyStatsKey,
        jsonEncode(weeklyStats.map((s) => s.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('Error saving weekly stats: $e');
    }
  }

  /// Reset all progress
  Future<void> resetProgress() async {
    _progress = UserProgress();
    _todayStats = DailyStats(date: DateTime.now());
    await _saveProgress();
    await _saveTodayStats();
  }

  /// Get weekly stats for charting (last 7 days)
  Future<List<DailyStats>> getWeeklyStats() async {
    final stats = <DailyStats>[];

    try {
      // Try cloud first if logged in
      if (_cloudDb.useCloud) {
        final data = await _cloudDb.getWeeklyStats();
        for (final item in data) {
          stats.add(DailyStats.fromJson(item));
        }
      }

      // If no cloud data, load from local
      if (stats.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final json = prefs.getString(_weeklyStatsKey);
        if (json != null) {
          final list = jsonDecode(json) as List;
          for (final item in list) {
            stats.add(DailyStats.fromJson(item));
          }
        }
      }
    } catch (e) {
      debugPrint('Error getting weekly stats: $e');
    }

    // Ensure we have 7 days of data (fill gaps with zeros)
    final now = DateTime.now();
    final result = <DailyStats>[];

    for (int i = 6; i >= 0; i--) {
      final date = DateTime(now.year, now.month, now.day - i);
      final existing = stats.where((s) =>
          s.date.year == date.year &&
          s.date.month == date.month &&
          s.date.day == date.day).toList();

      if (existing.isNotEmpty) {
        result.add(existing.first);
      } else if (i == 0) {
        // Today - use current todayStats
        result.add(_todayStats);
      } else {
        result.add(DailyStats(date: date));
      }
    }

    return result;
  }

  /// Get XP progress to next level
  int get currentXP {
    return _progress.totalFindings + _progress.total3DModels + _progress.totalContexts;
  }

  int get xpForCurrentLevel {
    switch (_progress.level) {
      case 1: return 0;
      case 2: return 15;
      case 3: return 30;
      case 4: return 50;
      case 5: return 70;
      case 6: return 100;
      case 7: return 150;
      case 8: return 200;
      case 9: return 300;
      case 10: return 500;
      default: return 0;
    }
  }

  int get xpForNextLevel {
    switch (_progress.level) {
      case 1: return 15;
      case 2: return 30;
      case 3: return 50;
      case 4: return 70;
      case 5: return 100;
      case 6: return 150;
      case 7: return 200;
      case 8: return 300;
      case 9: return 500;
      case 10: return 500; // Max level
      default: return 15;
    }
  }

  double get levelProgress {
    if (_progress.level >= 10) return 1.0;
    final current = currentXP - xpForCurrentLevel;
    final needed = xpForNextLevel - xpForCurrentLevel;
    return (current / needed).clamp(0.0, 1.0);
  }
}
