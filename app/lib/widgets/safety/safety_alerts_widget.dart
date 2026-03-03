import 'package:flutter/material.dart';
import '../../models/alert_data.dart';

class SafetyAlertsCard extends StatelessWidget {
  final List<AlertData> alerts;

  const SafetyAlertsCard({super.key, required this.alerts});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Alerts', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (alerts.isEmpty)
            Text('No alerts yet', style: TextStyle(color: Colors.white.withAlpha(153), fontSize: 12))
          else
            ...alerts.take(5).map((alert) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: AlertRow(
                time: alert.time,
                level: alert.level,
                title: alert.title,
                trench: 'Trench B3',
                message: alert.message,
              ),
            )),
        ],
      ),
    );
  }
}

class AlertRow extends StatelessWidget {
  final String time;
  final AlertLevel level;
  final String title;
  final String trench;
  final String message;

  const AlertRow({
    super.key,
    required this.time, required this.level, required this.title,
    required this.trench, required this.message,
  });

  Color _dotColor() {
    switch (level) {
      case AlertLevel.critical: return const Color(0xFFE53935);
      case AlertLevel.warning: return const Color(0xFFFFB300);
      case AlertLevel.ok: return const Color(0xFF43A047);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(time, style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 11)),
        const SizedBox(width: 10),
        Container(
          width: 8, height: 8,
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(color: _dotColor(), shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$title • $trench', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(message, style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

class SafetyInsightCard extends StatelessWidget {
  const SafetyInsightCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Safety Thresholds', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          SizedBox(height: 6),
          Text(
            '• Soil Moisture: 30-60% is safe range\n'
            '• Vibration: <0.3g stable, >0.8g critical\n'
            '• Connect M5StickC Plus 2 for live monitoring',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
