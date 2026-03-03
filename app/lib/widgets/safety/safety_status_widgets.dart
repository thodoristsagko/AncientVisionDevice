import 'package:flutter/material.dart';

class LiveChip extends StatefulWidget {
  final bool isConnected;
  final String status;

  const LiveChip({super.key, required this.isConnected, required this.status});

  @override
  State<LiveChip> createState() => _LiveChipState();
}

class _LiveChipState extends State<LiveChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Widget _livePulseDot() {
    if (!widget.isConnected) {
      return Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Colors.white38,
          shape: BoxShape.circle,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: Color.fromRGBO(
              76, 175, 80, 0.3 + _pulseController.value * 0.7),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _livePulseDot(),
        const SizedBox(width: 5),
        Text(
          widget.isConnected ? 'LIVE' : 'OFFLINE',
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class SafetyStatCard extends StatelessWidget {
  final String title;
  final String value;
  final String status;
  final Color? statusColor;

  const SafetyStatCard({
    super.key,
    required this.title,
    required this.value,
    required this.status,
    this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 130,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 12, fontWeight: FontWeight.w500)),
          const Spacer(),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(status, style: TextStyle(color: statusColor ?? Colors.white.withAlpha(180), fontSize: 12)),
        ],
      ),
    );
  }
}

class LiveSensorsCard extends StatelessWidget {
  final double accX, accY, accZ;
  final int moisturePercent;
  final String lastUpdate;
  final bool isConnected;
  final double vibration;
  final double ppv;
  final double dominantFreq;
  final double crestFactor;
  final double rms;
  final String hazardType;

  const LiveSensorsCard({
    super.key,
    required this.accX, required this.accY, required this.accZ,
    required this.moisturePercent, required this.lastUpdate, required this.isConnected,
    this.vibration = 0.0, this.ppv = 0.0, this.dominantFreq = 0.0,
    this.crestFactor = 0.0, this.rms = 0.0, this.hazardType = 'none',
  });

  @override
  Widget build(BuildContext context) {
    String vibStatus = 'Safe';
    Color vibColor = Colors.green;
    if (ppv > 10.0) { vibStatus = 'CRITICAL'; vibColor = const Color(0xFFE53935); }
    else if (ppv > 3.0) { vibStatus = 'DIN EXCEEDED'; vibColor = const Color(0xFFFF5722); }
    else if (ppv > 2.5) { vibStatus = 'Heritage limit'; vibColor = Colors.orange; }
    else if (ppv > 0.3) { vibStatus = 'Perceptible'; vibColor = const Color(0xFFFFC107); }
    else if (ppv == 0.0 && vibration > 0.5) { vibStatus = 'HIGH!'; vibColor = Colors.red; }
    else if (ppv == 0.0 && vibration > 0.2) { vibStatus = 'Moderate'; vibColor = Colors.orange; }

    final bool hasV2Data = ppv > 0 || rms > 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Live sensors', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (hasV2Data)
                Text('v2.0 DSP', style: TextStyle(color: const Color(0xFF00BCD4).withAlpha(200), fontSize: 9, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: isConnected ? Colors.green : Colors.grey, size: 16),
            ],
          ),
          const SizedBox(height: 10),
          _SensorRow(
            label: hasV2Data ? 'PPV (DIN 4150-3)' : 'Vibration',
            value: hasV2Data ? '${ppv.toStringAsFixed(1)} mm/s  $vibStatus' : '${vibration.toStringAsFixed(2)}g  $vibStatus',
            icon: Icons.vibration, valueColor: vibColor,
          ),
          if (hasV2Data) ...[
            const SizedBox(height: 6),
            _SensorRow(
              label: 'Frequency',
              value: '${dominantFreq.toStringAsFixed(0)} Hz  Crest: ${crestFactor.toStringAsFixed(1)}  RMS: ${rms.toStringAsFixed(4)}g',
              icon: Icons.graphic_eq,
            ),
          ],
          const SizedBox(height: 6),
          _SensorRow(label: 'Soil moisture', value: '$moisturePercent % (safe: 30-60%)', icon: Icons.water_drop_outlined),
          const SizedBox(height: 8),
          Text('Last update: $lastUpdate', style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 11)),
        ],
      ),
    );
  }
}

class _SensorRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  const _SensorRow({required this.label, required this.value, required this.icon, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white70),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(color: valueColor ?? Colors.white.withAlpha(190), fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}
