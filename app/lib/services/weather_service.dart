import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Weather conditions enum
enum WeatherCondition {
  sunny('Sunny', 'Clear sky with sunshine'),
  partlyCloudy('Partly Cloudy', 'Mix of sun and clouds'),
  cloudy('Cloudy', 'Overcast sky'),
  rainy('Rainy', 'Light to moderate rain'),
  heavyRain('Heavy Rain', 'Heavy rainfall'),
  stormy('Stormy', 'Thunderstorms'),
  snowy('Snowy', 'Snowfall'),
  foggy('Foggy', 'Reduced visibility due to fog'),
  windy('Windy', 'Strong winds'),
  hot('Hot', 'High temperatures'),
  cold('Cold', 'Low temperatures'),
  humid('Humid', 'High humidity'),
  dry('Dry', 'Low humidity');

  final String label;
  final String description;

  const WeatherCondition(this.label, this.description);
}

/// Wind direction
enum WindDirection {
  n('N', 'North'),
  ne('NE', 'Northeast'),
  e('E', 'East'),
  se('SE', 'Southeast'),
  s('S', 'South'),
  sw('SW', 'Southwest'),
  w('W', 'West'),
  nw('NW', 'Northwest'),
  calm('Calm', 'No wind');

  final String symbol;
  final String label;

  const WindDirection(this.symbol, this.label);
}

/// A single weather log entry
class WeatherLog {
  final String id;
  final DateTime timestamp;
  final String? siteId;
  final double? temperature; // Celsius
  final double? humidity; // Percentage
  final double? pressure; // hPa
  final WeatherCondition? condition;
  final WindDirection? windDirection;
  final double? windSpeed; // km/h
  final double? rainfall; // mm
  final String? notes;
  final bool isAutomatic; // True if from sensors, false if manual

  WeatherLog({
    required this.id,
    DateTime? timestamp,
    this.siteId,
    this.temperature,
    this.humidity,
    this.pressure,
    this.condition,
    this.windDirection,
    this.windSpeed,
    this.rainfall,
    this.notes,
    this.isAutomatic = false,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Get formatted temperature string
  String get temperatureString {
    if (temperature == null) return 'N/A';
    return '${temperature!.toStringAsFixed(1)}°C';
  }

  /// Get formatted humidity string
  String get humidityString {
    if (humidity == null) return 'N/A';
    return '${humidity!.toStringAsFixed(0)}%';
  }

  /// Get formatted pressure string
  String get pressureString {
    if (pressure == null) return 'N/A';
    return '${pressure!.toStringAsFixed(1)} hPa';
  }

  /// Get weather summary
  String get summary {
    final parts = <String>[];
    if (condition != null) parts.add(condition!.label);
    if (temperature != null) parts.add(temperatureString);
    if (humidity != null) parts.add('Humidity: $humidityString');
    if (windDirection != null && windDirection != WindDirection.calm) {
      parts.add('Wind: ${windDirection!.symbol}${windSpeed != null ? ' ${windSpeed!.toStringAsFixed(0)} km/h' : ''}');
    }
    return parts.isEmpty ? 'No data' : parts.join(', ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'siteId': siteId,
        'temperature': temperature,
        'humidity': humidity,
        'pressure': pressure,
        'condition': condition?.name,
        'windDirection': windDirection?.name,
        'windSpeed': windSpeed,
        'rainfall': rainfall,
        'notes': notes,
        'isAutomatic': isAutomatic,
      };

  factory WeatherLog.fromJson(Map<String, dynamic> json) => WeatherLog(
        id: json['id'],
        timestamp: DateTime.parse(json['timestamp']),
        siteId: json['siteId'],
        temperature: json['temperature']?.toDouble(),
        humidity: json['humidity']?.toDouble(),
        pressure: json['pressure']?.toDouble(),
        condition: json['condition'] != null
            ? WeatherCondition.values.firstWhere(
                (c) => c.name == json['condition'],
                orElse: () => WeatherCondition.sunny,
              )
            : null,
        windDirection: json['windDirection'] != null
            ? WindDirection.values.firstWhere(
                (d) => d.name == json['windDirection'],
                orElse: () => WindDirection.calm,
              )
            : null,
        windSpeed: json['windSpeed']?.toDouble(),
        rainfall: json['rainfall']?.toDouble(),
        notes: json['notes'],
        isAutomatic: json['isAutomatic'] ?? false,
      );
}

/// Daily weather summary
class DailyWeatherSummary {
  final DateTime date;
  final double? avgTemperature;
  final double? minTemperature;
  final double? maxTemperature;
  final double? avgHumidity;
  final double? totalRainfall;
  final WeatherCondition? predominantCondition;
  final int logCount;

  DailyWeatherSummary({
    required this.date,
    this.avgTemperature,
    this.minTemperature,
    this.maxTemperature,
    this.avgHumidity,
    this.totalRainfall,
    this.predominantCondition,
    this.logCount = 0,
  });

  String get temperatureRange {
    if (minTemperature == null || maxTemperature == null) return 'N/A';
    return '${minTemperature!.toStringAsFixed(0)}° - ${maxTemperature!.toStringAsFixed(0)}°C';
  }

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'avgTemperature': avgTemperature,
        'minTemperature': minTemperature,
        'maxTemperature': maxTemperature,
        'avgHumidity': avgHumidity,
        'totalRainfall': totalRainfall,
        'predominantCondition': predominantCondition?.name,
        'logCount': logCount,
      };
}

/// Service for logging and tracking weather conditions
class WeatherService {
  static final WeatherService _instance = WeatherService._internal();
  factory WeatherService() => _instance;
  WeatherService._internal();

  static const String _logsKey = 'weather_logs';
  static const String _autoLogKey = 'auto_weather_logging';
  static const String _logIntervalKey = 'weather_log_interval_minutes';

  Timer? _autoLogTimer;
  final _logController = StreamController<WeatherLog>.broadcast();

  Stream<WeatherLog> get logStream => _logController.stream;

  /// Check if auto-logging is enabled
  Future<bool> isAutoLoggingEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoLogKey) ?? false;
  }

  /// Set auto-logging enabled
  Future<void> setAutoLoggingEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoLogKey, enabled);

    if (enabled) {
      await startAutoLogging();
    } else {
      stopAutoLogging();
    }
  }

  /// Get auto-log interval in minutes
  Future<int> getLogInterval() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_logIntervalKey) ?? 60;
  }

  /// Set auto-log interval
  Future<void> setLogInterval(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logIntervalKey, minutes);

    // Restart auto-logging with new interval
    if (await isAutoLoggingEnabled()) {
      stopAutoLogging();
      await startAutoLogging();
    }
  }

  /// Start automatic weather logging
  Future<void> startAutoLogging({
    double? temperature,
    double? humidity,
    double? pressure,
  }) async {
    final interval = await getLogInterval();
    _autoLogTimer?.cancel();

    _autoLogTimer = Timer.periodic(Duration(minutes: interval), (_) async {
      // In a real app, this would read from sensors
      // For now, we'll just log whatever values are available
      await logWeather(
        temperature: temperature,
        humidity: humidity,
        pressure: pressure,
        isAutomatic: true,
      );
    });

    debugPrint('Auto weather logging started (interval: $interval minutes)');
  }

  /// Stop automatic logging
  void stopAutoLogging() {
    _autoLogTimer?.cancel();
    _autoLogTimer = null;
    debugPrint('Auto weather logging stopped');
  }

  /// Log current weather conditions
  Future<WeatherLog?> logWeather({
    String? siteId,
    double? temperature,
    double? humidity,
    double? pressure,
    WeatherCondition? condition,
    WindDirection? windDirection,
    double? windSpeed,
    double? rainfall,
    String? notes,
    bool isAutomatic = false,
  }) async {
    try {
      final log = WeatherLog(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        siteId: siteId,
        temperature: temperature,
        humidity: humidity,
        pressure: pressure,
        condition: condition,
        windDirection: windDirection,
        windSpeed: windSpeed,
        rainfall: rainfall,
        notes: notes,
        isAutomatic: isAutomatic,
      );

      await _saveLog(log);
      _logController.add(log);

      debugPrint('Weather logged: ${log.summary}');
      return log;
    } catch (e) {
      debugPrint('Error logging weather: $e');
      return null;
    }
  }

  /// Get all weather logs
  Future<List<WeatherLog>> getAllLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logsJson = prefs.getStringList(_logsKey) ?? [];
      // Reverse to get newest first (since we now store oldest-first)
      // Then sort by timestamp as a safety measure
      return logsJson.reversed
          .map((json) => WeatherLog.fromJson(jsonDecode(json)))
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (e) {
      debugPrint('Error getting weather logs: $e');
      return [];
    }
  }

  /// Get logs for a specific date
  Future<List<WeatherLog>> getLogsForDate(DateTime date) async {
    final allLogs = await getAllLogs();
    return allLogs.where((log) =>
        log.timestamp.year == date.year &&
        log.timestamp.month == date.month &&
        log.timestamp.day == date.day).toList();
  }

  /// Get logs for a specific site
  Future<List<WeatherLog>> getLogsForSite(String siteId) async {
    final allLogs = await getAllLogs();
    return allLogs.where((log) => log.siteId == siteId).toList();
  }

  /// Get logs for date range
  Future<List<WeatherLog>> getLogsForDateRange(DateTime start, DateTime end) async {
    final allLogs = await getAllLogs();
    return allLogs.where((log) =>
        log.timestamp.isAfter(start) && log.timestamp.isBefore(end.add(const Duration(days: 1)))).toList();
  }

  /// Get daily summary
  Future<DailyWeatherSummary> getDailySummary(DateTime date) async {
    final logs = await getLogsForDate(date);

    if (logs.isEmpty) {
      return DailyWeatherSummary(date: date);
    }

    final temperatures = logs.where((l) => l.temperature != null).map((l) => l.temperature!).toList();
    final humidities = logs.where((l) => l.humidity != null).map((l) => l.humidity!).toList();
    final rainfalls = logs.where((l) => l.rainfall != null).map((l) => l.rainfall!).toList();
    final conditions = logs.where((l) => l.condition != null).map((l) => l.condition!).toList();

    // Find predominant condition
    WeatherCondition? predominant;
    if (conditions.isNotEmpty) {
      final conditionCounts = <WeatherCondition, int>{};
      for (final c in conditions) {
        conditionCounts[c] = (conditionCounts[c] ?? 0) + 1;
      }
      predominant = conditionCounts.entries
          .reduce((a, b) => a.value > b.value ? a : b)
          .key;
    }

    return DailyWeatherSummary(
      date: date,
      avgTemperature: temperatures.isEmpty ? null : temperatures.reduce((a, b) => a + b) / temperatures.length,
      minTemperature: temperatures.isEmpty ? null : temperatures.reduce((a, b) => a < b ? a : b),
      maxTemperature: temperatures.isEmpty ? null : temperatures.reduce((a, b) => a > b ? a : b),
      avgHumidity: humidities.isEmpty ? null : humidities.reduce((a, b) => a + b) / humidities.length,
      totalRainfall: rainfalls.isEmpty ? null : rainfalls.reduce((a, b) => a + b),
      predominantCondition: predominant,
      logCount: logs.length,
    );
  }

  /// Get the latest weather log
  Future<WeatherLog?> getLatestLog() async {
    final logs = await getAllLogs();
    return logs.isEmpty ? null : logs.first;
  }

  /// Delete a weather log
  Future<bool> deleteLog(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logsJson = prefs.getStringList(_logsKey) ?? [];

      final filtered = logsJson.where((json) {
        final log = jsonDecode(json);
        return log['id'] != id;
      }).toList();

      await prefs.setStringList(_logsKey, filtered);
      return true;
    } catch (e) {
      debugPrint('Error deleting weather log: $e');
      return false;
    }
  }

  /// Clear all weather logs
  Future<bool> clearAllLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_logsKey);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Export weather logs to JSON
  Future<String> exportLogsToJson() async {
    final logs = await getAllLogs();
    return const JsonEncoder.withIndent('  ').convert({
      'exportDate': DateTime.now().toIso8601String(),
      'count': logs.length,
      'logs': logs.map((l) => l.toJson()).toList(),
    });
  }

  /// Save a log to storage
  Future<void> _saveLog(WeatherLog log) async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getStringList(_logsKey) ?? [];

    // Add to end instead of beginning to avoid O(N) insert(0)
    logsJson.add(jsonEncode(log.toJson()));

    // Keep only last 500 logs (remove from beginning if needed)
    if (logsJson.length > 500) {
      logsJson.removeRange(0, logsJson.length - 500);
    }

    await prefs.setStringList(_logsKey, logsJson);
  }

  /// Dispose resources
  void dispose() {
    _autoLogTimer?.cancel();
    _logController.close();
  }
}
