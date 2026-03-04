import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:archive/archive.dart';

/// Represents a backup file
class BackupInfo {
  final String filename;
  final String path;
  final DateTime createdAt;
  final int sizeBytes;
  final Map<String, int> contentCounts;

  BackupInfo({
    required this.filename,
    required this.path,
    required this.createdAt,
    required this.sizeBytes,
    this.contentCounts = const {},
  });

  String get sizeString {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get dateString => DateFormat('MMM d, yyyy HH:mm').format(createdAt);
}

/// Service for backup and restore functionality
class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  static const String _autoBackupKey = 'auto_backup_enabled';
  static const String _lastBackupKey = 'last_backup_date';
  static const String _backupIntervalKey = 'backup_interval_days';

  final _dateTimeFormat = DateFormat('yyyy-MM-dd_HH-mm-ss');

  /// Get backup directory
  Future<Directory> get _backupDir async {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory('${dir.path}/backups');
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    return backupDir;
  }

  /// Check if auto backup is enabled
  Future<bool> isAutoBackupEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoBackupKey) ?? false;
  }

  /// Set auto backup enabled
  Future<void> setAutoBackupEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoBackupKey, enabled);
  }

  /// Get backup interval in days
  Future<int> getBackupInterval() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_backupIntervalKey) ?? 7;
  }

  /// Set backup interval in days
  Future<void> setBackupInterval(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_backupIntervalKey, days);
  }

  /// Get last backup date
  Future<DateTime?> getLastBackupDate() async {
    final prefs = await SharedPreferences.getInstance();
    final dateStr = prefs.getString(_lastBackupKey);
    if (dateStr == null) return null;
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      return null;
    }
  }

  /// Check if backup is needed
  Future<bool> isBackupNeeded() async {
    if (!await isAutoBackupEnabled()) return false;

    final lastBackup = await getLastBackupDate();
    if (lastBackup == null) return true;

    final interval = await getBackupInterval();
    final nextBackup = lastBackup.add(Duration(days: interval));
    return DateTime.now().isAfter(nextBackup);
  }

  /// Create a backup
  Future<BackupInfo?> createBackup({
    required Map<String, dynamic> data,
    String? customName,
  }) async {
    try {
      final timestamp = _dateTimeFormat.format(DateTime.now());
      final filename = customName ?? 'backup_$timestamp.zip';
      final dir = await _backupDir;
      final file = File('${dir.path}/$filename');

      // Create archive
      final archive = Archive();

      // Add manifest (rich version via buildManifest)
      final manifest = {
        ...buildManifest(data),
        'contents': data.map((key, value) => MapEntry(
              key,
              value is List ? value.length : 1,
            )),
      };

      final manifestJson = const JsonEncoder.withIndent('  ').convert(manifest);
      archive.addFile(ArchiveFile(
        'manifest.json',
        utf8.encode(manifestJson).length,
        utf8.encode(manifestJson),
      ));

      // Add each data section
      for (final entry in data.entries) {
        final json = const JsonEncoder.withIndent('  ').convert(entry.value);
        archive.addFile(ArchiveFile(
          '${entry.key}.json',
          utf8.encode(json).length,
          utf8.encode(json),
        ));
      }

      // Save ZIP
      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) return null;
      await file.writeAsBytes(zipData);

      // Update last backup date
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastBackupKey, DateTime.now().toIso8601String());

      if (kDebugMode) {
        debugPrint('Backup created: ${file.path}');
      }

      return BackupInfo(
        filename: filename,
        path: file.path,
        createdAt: DateTime.now(),
        sizeBytes: zipData.length,
        contentCounts: data.map((key, value) => MapEntry(
              key,
              value is List ? value.length : 1,
            )),
      );
    } catch (e) {
      debugPrint('Error creating backup: $e');
      return null;
    }
  }

  /// Restore from backup
  Future<Map<String, dynamic>?> restoreBackup(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        if (kDebugMode) {
          debugPrint('Backup file not found: $path');
        }
        return null;
      }

      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final restoredData = <String, dynamic>{};

      for (final archiveFile in archive) {
        if (archiveFile.isFile && archiveFile.name.endsWith('.json')) {
          final content = utf8.decode(archiveFile.content as List<int>);
          final name = archiveFile.name.replaceAll('.json', '');
          restoredData[name] = jsonDecode(content);
        }
      }

      if (kDebugMode) {
        debugPrint('Backup restored: ${restoredData.keys.join(', ')}');
      }
      return restoredData;
    } catch (e) {
      debugPrint('Error restoring backup: $e');
      return null;
    }
  }

  /// List all available backups
  Future<List<BackupInfo>> listBackups() async {
    try {
      final dir = await _backupDir;
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.zip')).toList();

      final backups = <BackupInfo>[];

      for (final file in files) {
        try {
          final stat = await file.stat();
          final bytes = await file.readAsBytes();
          final archive = ZipDecoder().decodeBytes(bytes);

          Map<String, int> counts = {};

          // Try to read manifest
          final manifestFile = archive.files.firstWhere(
            (f) => f.name == 'manifest.json',
            orElse: () => ArchiveFile('', 0, []),
          );

          if (manifestFile.content.isNotEmpty) {
            final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));
            counts = Map<String, int>.from(manifest['contents'] ?? {});
          }

          backups.add(BackupInfo(
            filename: file.path.split('/').last.split('\\').last,
            path: file.path,
            createdAt: stat.modified,
            sizeBytes: stat.size,
            contentCounts: counts,
          ));
        } catch (e) {
          debugPrint('Error reading backup file: $e');
        }
      }

      // Sort by date, newest first
      backups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return backups;
    } catch (e) {
      debugPrint('Error listing backups: $e');
      return [];
    }
  }

  /// Delete a backup
  Future<bool> deleteBackup(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        if (kDebugMode) {
          debugPrint('Backup deleted: $path');
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error deleting backup: $e');
      return false;
    }
  }

  /// Delete old backups (keep last N)
  Future<int> cleanupOldBackups({int keepCount = 5}) async {
    try {
      final backups = await listBackups();
      if (backups.length <= keepCount) return 0;

      int deleted = 0;
      for (int i = keepCount; i < backups.length; i++) {
        if (await deleteBackup(backups[i].path)) {
          deleted++;
        }
      }

      if (kDebugMode) {
        debugPrint('Cleaned up $deleted old backups');
      }
      return deleted;
    } catch (e) {
      debugPrint('Error cleaning up backups: $e');
      return 0;
    }
  }

  /// Get backup storage size
  Future<int> getTotalBackupSize() async {
    try {
      final backups = await listBackups();
      int total = 0;
      for (final backup in backups) {
        total += backup.sizeBytes;
      }
      return total;
    } catch (e) {
      return 0;
    }
  }

  /// Create quick backup of app preferences
  Future<File?> backupPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final data = <String, dynamic>{};

      for (final key in keys) {
        data[key] = prefs.get(key);
      }

      final dir = await _backupDir;
      final timestamp = _dateTimeFormat.format(DateTime.now());
      final file = File('${dir.path}/preferences_$timestamp.json');

      await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'createdAt': DateTime.now().toIso8601String(),
        'type': 'preferences',
        'data': data,
      }));

      return file;
    } catch (e) {
      debugPrint('Error backing up preferences: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Last backup info (synchronous getters backed by cached prefs value)
  // ---------------------------------------------------------------------------

  /// Last backup time read directly from SharedPreferences.
  /// Returns null if no backup has ever been created.
  Future<DateTime?> get lastBackupTime async => getLastBackupDate();

  /// Days elapsed since the last backup.  Returns -1 if no backup exists.
  Future<int> get daysSinceBackup async {
    final last = await lastBackupTime;
    if (last == null) return -1;
    return DateTime.now().difference(last).inDays;
  }

  // ---------------------------------------------------------------------------
  // Auto-backup on app launch
  // ---------------------------------------------------------------------------

  /// Call this on app launch.  If auto-backup is enabled and the configured
  /// interval has elapsed, [createBackup] is triggered with [launchData].
  ///
  /// The backup interval threshold is read from SharedPreferences
  /// (key: [_backupIntervalKey], default: 7 days).
  Future<BackupInfo?> maybeAutoBackup({
    required Map<String, dynamic> launchData,
  }) async {
    final needed = await isBackupNeeded();
    if (!needed) return null;

    if (kDebugMode) {
      debugPrint('BackupService: auto-backup triggered on app launch');
    }
    return createBackup(data: launchData);
  }

  // ---------------------------------------------------------------------------
  // Backup content manifest helpers
  // ---------------------------------------------------------------------------

  /// Builds a manifest map that is embedded in every backup archive.
  ///
  /// Callers supply [data] (the same map passed to [createBackup]).
  /// The manifest adds:
  ///   - sessions_count
  ///   - alert_count
  ///   - critical_events_count
  ///   - total_size_bytes  (approximate JSON sizes before compression)
  ///   - created_at        (ISO-8601)
  Map<String, dynamic> buildManifest(Map<String, dynamic> data) {
    int sessionsCount = 0;
    int alertCount = 0;
    int criticalCount = 0;
    int totalSizeBytes = 0;

    for (final entry in data.entries) {
      final key = entry.key.toLowerCase();
      final value = entry.value;

      // Approximate serialised size
      final encoded = jsonEncode(value);
      totalSizeBytes += utf8.encode(encoded).length;

      if (value is List) {
        if (key.contains('session')) {
          sessionsCount += value.length;
        }
        if (key.contains('alert')) {
          alertCount += value.length;
          // Count entries where level == 'CRITICAL'
          for (final item in value) {
            if (item is Map && item['level'] == 'CRITICAL') {
              criticalCount++;
            }
          }
        }
      }
    }

    return {
      'sessions_count': sessionsCount,
      'alert_count': alertCount,
      'critical_events_count': criticalCount,
      'total_size_bytes': totalSizeBytes,
      'created_at': DateTime.now().toIso8601String(),
      'app': 'AncientVision',
      'version': '1.0.0',
    };
  }

  // ---------------------------------------------------------------------------
  // Cloud backup stub
  // ---------------------------------------------------------------------------

  /// Attempts to upload the most recent local backup to Firebase Storage.
  ///
  /// If Firebase Storage is not configured (package not present or no bucket
  /// URL set in SharedPreferences under key `firebase_storage_bucket`), shows
  /// an informational dialog instead of throwing.
  ///
  /// To enable cloud backups:
  ///   1. Add `firebase_storage` to pubspec.yaml.
  ///   2. Store your bucket URL in SharedPreferences under
  ///      `firebase_storage_bucket`.
  ///   3. Replace the stub body below with the real upload logic.
  Future<void> backupToCloud({BuildContext? context}) async {
    final prefs = await SharedPreferences.getInstance();
    final bucket = prefs.getString('firebase_storage_bucket');

    final bool firebaseConfigured = bucket != null && bucket.isNotEmpty;

    if (!firebaseConfigured) {
      if (kDebugMode) {
        debugPrint(
          'BackupService.backupToCloud: Firebase Storage not configured. '
          'Set firebase_storage_bucket in SharedPreferences to enable.',
        );
      }

      if (context != null && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cloud Backup Unavailable'),
            content: const Text(
              'Firebase Storage is not configured.\n\n'
              'To enable cloud backups, configure Firebase Storage in app settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    // --- Real upload logic goes here once firebase_storage is added ---
    // Example (requires `firebase_storage` package):
    //
    // final backups = await listBackups();
    // if (backups.isEmpty) return;
    // final latest = backups.first;           // already sorted newest-first
    // final ref = FirebaseStorage.instance
    //     .ref()
    //     .child('backups/${latest.filename}');
    // await ref.putFile(File(latest.path));
    // if (kDebugMode) debugPrint('Uploaded ${latest.filename} to $bucket');

    if (kDebugMode) {
      debugPrint(
        'BackupService.backupToCloud: bucket=$bucket — stub, no upload performed.',
      );
    }
  }

  /// Restore preferences from backup
  Future<bool> restorePreferences(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;

      final content = await file.readAsString();
      final json = jsonDecode(content);
      final data = json['data'] as Map<String, dynamic>;

      final prefs = await SharedPreferences.getInstance();

      for (final entry in data.entries) {
        final value = entry.value;
        if (value is bool) {
          await prefs.setBool(entry.key, value);
        } else if (value is int) {
          await prefs.setInt(entry.key, value);
        } else if (value is double) {
          await prefs.setDouble(entry.key, value);
        } else if (value is String) {
          await prefs.setString(entry.key, value);
        } else if (value is List<String>) {
          await prefs.setStringList(entry.key, value);
        }
      }

      if (kDebugMode) {
        debugPrint('Preferences restored from: $path');
      }
      return true;
    } catch (e) {
      debugPrint('Error restoring preferences: $e');
      return false;
    }
  }
}
