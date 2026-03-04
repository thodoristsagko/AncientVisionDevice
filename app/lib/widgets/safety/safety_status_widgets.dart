import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// LiveChip
// ---------------------------------------------------------------------------

/// Pulsing LIVE / OFFLINE chip shown in the header row.
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

// ---------------------------------------------------------------------------
// SafetyStatCard
// ---------------------------------------------------------------------------

/// A metric card with optional micro-trend arrow, colour-coded status,
/// delta-rate label, and long-press tooltip.
///
/// New optional parameters are backward-compatible (all have defaults).
class SafetyStatCard extends StatefulWidget {
  final String title;
  final String value;
  final String status;
  final Color? statusColor;

  // --- New params for enhanced behaviour ---

  /// Previous value used to compute trend arrow direction.
  final double? previousNumericValue;

  /// Current numeric value (e.g. PPV in mm/s). Used for trend + zone colour.
  final double? currentNumericValue;

  /// Rate of change per second (e.g. Δ PPV/s). When non-null, shown as a
  /// small label below the value: "+0.05 mm/s/s" or "stable".
  final double? deltaPerSecond;

  /// Unit string appended to the delta label (e.g. "mm/s/s").
  final String deltaUnit;

  /// Description shown in the long-press tooltip.
  final String? tooltipDescription;

  /// Normal range shown in the long-press tooltip.
  final String? tooltipRange;

  /// Thresholds [safe, elevated] for background zone colouring.
  /// E.g. PPV: [0.3, 1.0]. Values below safe → green tint, between → amber
  /// tint, above elevated → red tint. Pass null to disable zone colouring.
  final List<double>? zoneThresholds;

  const SafetyStatCard({
    super.key,
    required this.title,
    required this.value,
    required this.status,
    this.statusColor,
    this.previousNumericValue,
    this.currentNumericValue,
    this.deltaPerSecond,
    this.deltaUnit = 'mm/s/s',
    this.tooltipDescription,
    this.tooltipRange,
    this.zoneThresholds,
  });

  @override
  State<SafetyStatCard> createState() => _SafetyStatCardState();
}

class _SafetyStatCardState extends State<SafetyStatCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _trendController;
  late Animation<double> _trendAnim;
  bool _showTooltip = false;

  @override
  void initState() {
    super.initState();
    _trendController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _trendAnim = CurvedAnimation(parent: _trendController, curve: Curves.easeOut);
    _trendController.forward();
  }

  @override
  void didUpdateWidget(SafetyStatCard old) {
    super.didUpdateWidget(old);
    if (old.currentNumericValue != widget.currentNumericValue) {
      _trendController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _trendController.dispose();
    super.dispose();
  }

  // Compute the zone background colour based on currentNumericValue.
  Color _zoneTint() {
    final thresholds = widget.zoneThresholds;
    final v = widget.currentNumericValue;
    if (thresholds == null || thresholds.length < 2 || v == null) {
      return Colors.white.withAlpha(18);
    }
    if (v >= thresholds[1]) return const Color(0xFFE53935).withAlpha(30); // red zone
    if (v >= thresholds[0]) return const Color(0xFFFFC107).withAlpha(28); // amber zone
    return const Color(0xFF4CAF50).withAlpha(20);                          // green zone
  }

  // Trend arrow widget: up / down / flat compared to previousNumericValue.
  Widget _trendArrow() {
    final cur = widget.currentNumericValue;
    final prev = widget.previousNumericValue;
    if (cur == null || prev == null) return const SizedBox.shrink();

    final diff = cur - prev;
    const threshold = 0.01;

    IconData icon;
    Color color;
    if (diff > threshold) {
      icon = Icons.arrow_upward;
      color = const Color(0xFFE53935);
    } else if (diff < -threshold) {
      icon = Icons.arrow_downward;
      color = const Color(0xFF4CAF50);
    } else {
      icon = Icons.remove;
      color = Colors.white54;
    }

    return AnimatedBuilder(
      animation: _trendAnim,
      builder: (_, child) => Opacity(
        opacity: _trendAnim.value,
        child: child,
      ),
      child: Icon(icon, size: 14, color: color),
    );
  }

  // Delta-rate label: "+0.05 mm/s/s" or "stable"
  Widget _deltaLabel() {
    final delta = widget.deltaPerSecond;
    if (delta == null) return const SizedBox.shrink();

    final String text;
    final Color color;
    const stableThreshold = 0.001;

    if (delta.abs() < stableThreshold) {
      text = 'stable';
      color = Colors.white38;
    } else {
      final sign = delta > 0 ? '+' : '';
      text = '$sign${delta.toStringAsFixed(3)} ${widget.deltaUnit}';
      color = delta > 0
          ? const Color(0xFFFF8F00)
          : const Color(0xFF81C784);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w500),
      ),
    );
  }

  void _onLongPress() {
    if (widget.tooltipDescription == null && widget.tooltipRange == null) return;
    HapticFeedback.mediumImpact();
    setState(() => _showTooltip = true);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: _onLongPress,
      onLongPressEnd: (_) => setState(() => _showTooltip = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        height: 130,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _zoneTint(),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _showTooltip ? Colors.white30 : Colors.transparent,
            width: 1,
          ),
        ),
        child: Stack(
          children: [
            // Main content
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    color: Colors.white.withAlpha(200),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        widget.value,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _trendArrow(),
                  ],
                ),
                _deltaLabel(),
                const SizedBox(height: 4),
                Text(
                  widget.status,
                  style: TextStyle(
                    color: widget.statusColor ?? Colors.white.withAlpha(180),
                    fontSize: 12,
                  ),
                ),
              ],
            ),

            // Long-press tooltip overlay
            if (_showTooltip &&
                (widget.tooltipDescription != null ||
                    widget.tooltipRange != null))
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(210),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.tooltipDescription != null)
                        Text(
                          widget.tooltipDescription!,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11),
                        ),
                      if (widget.tooltipRange != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Normal: ${widget.tooltipRange!}',
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 10),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ConnectionStatusCard
// ---------------------------------------------------------------------------

/// Standalone connection-quality card with RSSI bars, last-packet age, and
/// missed-packet count.  Can be embedded anywhere that has the necessary data.
class ConnectionStatusCard extends StatelessWidget {
  final bool isConnected;
  final int? rssi;

  /// Time of the most recent BLE packet (used for "Last packet: Xs ago").
  final DateTime? lastPacketTime;

  /// Cumulative missed packet count from BlePacketTracker.
  final int missedPackets;

  const ConnectionStatusCard({
    super.key,
    required this.isConnected,
    this.rssi,
    this.lastPacketTime,
    this.missedPackets = 0,
  });

  // ------------------------------------------------------------------
  // RSSI helpers
  // ------------------------------------------------------------------

  /// Maps RSSI dBm to bar count 0–4.
  static int _rssiBars(int? rssi) {
    if (rssi == null) return 0;
    if (rssi >= -50) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -90) return 2;
    return 1;
  }

  static Color _rssiColor(int bars) {
    switch (bars) {
      case 4:
      case 3:
        return const Color(0xFF4CAF50);
      case 2:
        return const Color(0xFFFFC107);
      default:
        return const Color(0xFFE53935);
    }
  }

  // ------------------------------------------------------------------
  // Last-packet age helpers
  // ------------------------------------------------------------------

  static int _secondsAgo(DateTime? t) {
    if (t == null) return 9999;
    return DateTime.now().difference(t).inSeconds;
  }

  static Color _packetAgeColor(int secs) {
    if (secs < 2) return const Color(0xFF4CAF50);
    if (secs < 5) return const Color(0xFFFFC107);
    return const Color(0xFFE53935);
  }

  // ------------------------------------------------------------------
  // Widgets
  // ------------------------------------------------------------------

  Widget _rssiBarsWidget(int bars, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        final filled = i < bars;
        final barHeight = 4.0 + i * 3.0;
        return Padding(
          padding: const EdgeInsets.only(right: 2),
          child: Container(
            width: 4,
            height: barHeight,
            decoration: BoxDecoration(
              color: filled ? color : Colors.white24,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isConnected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 13, color: Colors.white38),
            const SizedBox(width: 5),
            Text('Disconnected',
                style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 11)),
          ],
        ),
      );
    }

    final bars = _rssiBars(rssi);
    final barColor = _rssiColor(bars);
    final secs = _secondsAgo(lastPacketTime);
    final ageColor = _packetAgeColor(secs);
    final ageLabel = secs >= 9999
        ? 'No packet'
        : secs == 0
            ? 'Just now'
            : '${secs}s ago';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // RSSI bars
          _rssiBarsWidget(bars, barColor),
          const SizedBox(width: 6),
          // RSSI dBm
          if (rssi != null)
            Text(
              '$rssi dBm',
              style: TextStyle(color: barColor, fontSize: 10, fontWeight: FontWeight.w600),
            ),
          const SizedBox(width: 8),
          // Last packet age
          Icon(Icons.access_time, size: 11, color: ageColor),
          const SizedBox(width: 2),
          Text(
            ageLabel,
            style: TextStyle(color: ageColor, fontSize: 10),
          ),
          // Missed packets
          if (missedPackets > 0) ...[
            const SizedBox(width: 8),
            const Icon(Icons.warning_amber_rounded, size: 11, color: Colors.orangeAccent),
            const SizedBox(width: 2),
            Text(
              'Miss: $missedPackets',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SafeSinceTimer
// ---------------------------------------------------------------------------

/// Counts up from [safeStart] while the system is in SAFE state.
/// Resets / hides when [isInSafeState] is false.
class SafeSinceTimer extends StatefulWidget {
  final bool isInSafeState;

  /// Timestamp when SAFE state was entered (last transition to safe).
  final DateTime? safeStart;

  const SafeSinceTimer({
    super.key,
    required this.isInSafeState,
    this.safeStart,
  });

  @override
  State<SafeSinceTimer> createState() => _SafeSinceTimerState();
}

class _SafeSinceTimerState extends State<SafeSinceTimer>
    with SingleTickerProviderStateMixin {
  late AnimationController _ticker;

  @override
  void initState() {
    super.initState();
    // Tick every second to refresh the elapsed label.
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  String _elapsed() {
    final start = widget.safeStart;
    if (start == null) return '';
    final diff = DateTime.now().difference(start);
    final m = diff.inMinutes;
    final s = diff.inSeconds % 60;
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isInSafeState || widget.safeStart == null) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _ticker,
      builder: (_, __) {
        final elapsed = _elapsed();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF4CAF50).withAlpha(30),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF4CAF50).withAlpha(80), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline,
                  size: 13, color: Color(0xFF81C784)),
              const SizedBox(width: 4),
              Text(
                'Safe for: $elapsed',
                style: const TextStyle(
                  color: Color(0xFF81C784),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// LiveSensorsCard
// ---------------------------------------------------------------------------

/// Card showing raw sensor readings (accelerometer axes, vibration, moisture)
/// with enhanced connection status and safe-since timer.
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

  // --- New optional params ---

  /// RSSI in dBm from BLE.
  final int? rssi;

  /// Time of last BLE packet for "last packet Xs ago".
  final DateTime? lastPacketTime;

  /// Cumulative missed packet count from BlePacketTracker.
  final int missedPackets;

  /// If the system is in SAFE state, the time SAFE was entered.
  final DateTime? safeStart;

  /// Whether the current alert level is 'safe'.
  final bool isInSafeState;

  const LiveSensorsCard({
    super.key,
    required this.accX, required this.accY, required this.accZ,
    required this.moisturePercent, required this.lastUpdate, required this.isConnected,
    this.vibration = 0.0, this.ppv = 0.0, this.dominantFreq = 0.0,
    this.crestFactor = 0.0, this.rms = 0.0, this.hazardType = 'none',
    this.rssi,
    this.lastPacketTime,
    this.missedPackets = 0,
    this.safeStart,
    this.isInSafeState = true,
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
          // Header row
          Row(
            children: [
              const Text('Live sensors',
                  style: TextStyle(
                      color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (hasV2Data)
                Text('v2.0 DSP',
                    style: TextStyle(
                        color: const Color(0xFF00BCD4).withAlpha(200),
                        fontSize: 9,
                        fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Icon(
                isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: isConnected ? Colors.green : Colors.grey,
                size: 16,
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Connection status row (RSSI bars + packet age + missed packets)
          ConnectionStatusCard(
            isConnected: isConnected,
            rssi: rssi,
            lastPacketTime: lastPacketTime,
            missedPackets: missedPackets,
          ),
          const SizedBox(height: 8),

          // Safe-since timer
          SafeSinceTimer(
            isInSafeState: isInSafeState,
            safeStart: safeStart,
          ),
          if (isInSafeState && safeStart != null) const SizedBox(height: 8),

          // Sensor rows
          _SensorRow(
            label: hasV2Data ? 'PPV (DIN 4150-3)' : 'Vibration',
            value: hasV2Data
                ? '${ppv.toStringAsFixed(1)} mm/s  $vibStatus'
                : '${vibration.toStringAsFixed(2)}g  $vibStatus',
            icon: Icons.vibration,
            valueColor: vibColor,
          ),
          if (hasV2Data) ...[
            const SizedBox(height: 6),
            _SensorRow(
              label: 'Frequency',
              value:
                  '${dominantFreq.toStringAsFixed(0)} Hz  Crest: ${crestFactor.toStringAsFixed(1)}  RMS: ${rms.toStringAsFixed(4)}g',
              icon: Icons.graphic_eq,
            ),
          ],
          const SizedBox(height: 6),
          _SensorRow(
            label: 'Soil moisture',
            value: '$moisturePercent % (safe: 30-60%)',
            icon: Icons.water_drop_outlined,
          ),
          const SizedBox(height: 8),
          Text(
            'Last update: $lastUpdate',
            style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SensorRow (private)
// ---------------------------------------------------------------------------

class _SensorRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  const _SensorRow(
      {required this.label,
      required this.value,
      required this.icon,
      this.valueColor});

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
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      color: valueColor ?? Colors.white.withAlpha(190),
                      fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// PpvGauge
// ---------------------------------------------------------------------------

/// Animated arc-style PPV gauge with coloured zones and an animated needle.
///
/// Zones (based on DIN 4150-3 / project thresholds):
///   - Green  0 – 0.3 mm/s  (safe)
///   - Amber  0.3 – 1.0 mm/s (perceptible)
///   - Red    1.0+ mm/s (hazardous)
class PpvGauge extends StatefulWidget {
  /// Current PPV in mm/s.
  final double ppv;

  /// Maximum value on the gauge scale (default 5.0 mm/s).
  final double maxValue;

  /// Rate of change in mm/s per second (optional).
  final double? deltaPerSecond;

  const PpvGauge({
    super.key,
    required this.ppv,
    this.maxValue = 5.0,
    this.deltaPerSecond,
  });

  @override
  State<PpvGauge> createState() => _PpvGaugeState();
}

class _PpvGaugeState extends State<PpvGauge>
    with SingleTickerProviderStateMixin {
  late AnimationController _needleController;
  late Animation<double> _needleAnim;
  double _prevNeedleFraction = 0.0;

  @override
  void initState() {
    super.initState();
    _needleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _needleAnim = Tween<double>(begin: 0.0, end: _fraction())
        .animate(CurvedAnimation(parent: _needleController, curve: Curves.easeOut));
    _prevNeedleFraction = _fraction();
    _needleController.forward();
  }

  @override
  void didUpdateWidget(PpvGauge old) {
    super.didUpdateWidget(old);
    if (old.ppv != widget.ppv) {
      final target = _fraction();
      _needleAnim = Tween<double>(begin: _prevNeedleFraction, end: target)
          .animate(CurvedAnimation(parent: _needleController, curve: Curves.easeOut));
      _prevNeedleFraction = target;
      _needleController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _needleController.dispose();
    super.dispose();
  }

  double _fraction() =>
      (widget.ppv / widget.maxValue).clamp(0.0, 1.0);

  Color _gaugeColor() {
    if (widget.ppv >= 1.0) return const Color(0xFFE53935);
    if (widget.ppv >= 0.3) return const Color(0xFFFFC107);
    return const Color(0xFF4CAF50);
  }

  String _deltaLabel() {
    final d = widget.deltaPerSecond;
    if (d == null) return '';
    if (d.abs() < 0.001) return 'stable';
    final sign = d > 0 ? '+' : '';
    return '$sign${d.toStringAsFixed(3)} mm/s/s';
  }

  Color _deltaColor() {
    final d = widget.deltaPerSecond;
    if (d == null || d.abs() < 0.001) return Colors.white38;
    return d > 0 ? const Color(0xFFFF8F00) : const Color(0xFF81C784);
  }

  @override
  Widget build(BuildContext context) {
    final color = _gaugeColor();
    final deltaText = _deltaLabel();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          height: 70,
          child: AnimatedBuilder(
            animation: _needleAnim,
            builder: (_, __) => CustomPaint(
              painter: _GaugePainter(
                fraction: _needleAnim.value,
                needleColor: color,
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${widget.ppv.toStringAsFixed(2)} mm/s',
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (deltaText.isNotEmpty)
          Text(
            deltaText,
            style: TextStyle(color: _deltaColor(), fontSize: 9),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _GaugePainter (private)
// ---------------------------------------------------------------------------

class _GaugePainter extends CustomPainter {
  final double fraction; // 0.0 – 1.0
  final Color needleColor;

  // Zone fractions (based on 5 mm/s max)
  static const double _greenEnd = 0.3 / 5.0;   // 0.3 mm/s
  static const double _amberEnd = 1.0 / 5.0;   // 1.0 mm/s

  static const double _startAngle = math.pi * 0.75;  // 135° from 3-o'clock
  static const double _sweepAngle = math.pi * 1.5;   // 270° total sweep

  _GaugePainter({required this.fraction, required this.needleColor});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height - 6;
    final radius = math.min(cx, cy) - 4;

    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: radius);

    void drawArc(double start, double end, Color color) {
      canvas.drawArc(
        rect,
        _startAngle + start * _sweepAngle,
        (end - start) * _sweepAngle,
        false,
        Paint()
          ..color = color
          ..strokeWidth = 10
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.butt,
      );
    }

    // Background track
    canvas.drawArc(
      rect,
      _startAngle,
      _sweepAngle,
      false,
      Paint()
        ..color = Colors.white12
        ..strokeWidth = 10
        ..style = PaintingStyle.stroke,
    );

    // Zone segments
    drawArc(0.0, _greenEnd, const Color(0xFF4CAF50).withAlpha(180));
    drawArc(_greenEnd, _amberEnd, const Color(0xFFFFC107).withAlpha(180));
    drawArc(_amberEnd, 1.0, const Color(0xFFE53935).withAlpha(180));

    // Filled arc up to current value
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        _startAngle,
        fraction * _sweepAngle,
        false,
        Paint()
          ..color = needleColor.withAlpha(140)
          ..strokeWidth = 10
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    // Needle (line from centre to arc edge)
    final needleAngle = _startAngle + fraction * _sweepAngle;
    final needleEnd = Offset(
      cx + radius * math.cos(needleAngle),
      cy + radius * math.sin(needleAngle),
    );
    canvas.drawLine(
      Offset(cx, cy),
      needleEnd,
      Paint()
        ..color = needleColor
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    // Centre pivot dot
    canvas.drawCircle(
      Offset(cx, cy),
      4,
      Paint()..color = needleColor,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      4,
      Paint()
        ..color = Colors.white.withAlpha(180)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Zone tick marks at 0.3 and 1.0
    _drawTick(canvas, cx, cy, radius, _greenEnd, const Color(0xFFFFC107));
    _drawTick(canvas, cx, cy, radius, _amberEnd, const Color(0xFFE53935));
  }

  void _drawTick(Canvas canvas, double cx, double cy, double radius,
      double frac, Color color) {
    final angle = _startAngle + frac * _sweepAngle;
    final inner = radius - 7;
    final outer = radius + 2;
    canvas.drawLine(
      Offset(cx + inner * math.cos(angle), cy + inner * math.sin(angle)),
      Offset(cx + outer * math.cos(angle), cy + outer * math.sin(angle)),
      Paint()
        ..color = color.withAlpha(220)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.fraction != fraction || old.needleColor != needleColor;
}
