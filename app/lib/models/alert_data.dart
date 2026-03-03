enum AlertLevel { critical, warning, ok }

class AlertData {
  final String time;
  final AlertLevel level;
  final String title;
  final String message;

  AlertData({required this.time, required this.level, required this.title, required this.message});
}
