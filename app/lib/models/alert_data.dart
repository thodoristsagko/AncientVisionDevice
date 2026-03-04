enum AlertLevel { critical, warning, ok }

class AlertData {
  final String time;
  final AlertLevel level;
  final String title;
  final String message;

  /// Precise machine timestamp for relative-time display and CSV export.
  /// Optional for backward compatibility with existing callers that only
  /// pass a pre-formatted [time] string.
  final DateTime? timestamp;

  AlertData({
    required this.time,
    required this.level,
    required this.title,
    required this.message,
    this.timestamp,
  });
}
