# Alert Screen Redesign + GIS/GeoJSON Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Redesign the full-screen alert overlay with sensor metrics, PPV sparkline, and type-specific guidance; add GIS/GeoJSON layer support with Esri satellite tiles to the findings map.

**Architecture:** The alert overlay gains new props (metrics data + PPV history) passed from SafetyView → main.dart → FullScreenAlertOverlay. A new PpvSparkline widget renders the history. For GIS, a new GeoJsonService parses `.geojson` files into flutter_map layers; the FindingsMap switches to Esri satellite tiles with a street/satellite toggle and layer controls.

**Tech Stack:** Flutter, flutter_map (existing), file_picker (new), dart:convert for GeoJSON parsing, SharedPreferences for layer persistence.

---

### Task 1: Create PpvSparkline Widget

**Files:**
- Create: `lib/widgets/ppv_sparkline.dart`
- Create: `test/widgets/ppv_sparkline_test.dart`

**Step 1: Write the failing test**

```dart
// test/widgets/ppv_sparkline_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/widgets/ppv_sparkline.dart';

void main() {
  group('PpvSparkline', () {
    testWidgets('renders CustomPaint with data', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 60,
              child: PpvSparkline(
                data: [0.1, 0.5, 1.0, 2.0, 4.5, 3.0, 1.5],
                threshold: 3.0,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(PpvSparkline), findsOneWidget);
      expect(find.byType(CustomPaint), findsOneWidget);
    });

    testWidgets('renders empty state with no data', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 60,
              child: PpvSparkline(
                data: [],
                threshold: 3.0,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(PpvSparkline), findsOneWidget);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/ppv_sparkline_test.dart`
Expected: FAIL — `PpvSparkline` not found

**Step 3: Write minimal implementation**

```dart
// lib/widgets/ppv_sparkline.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Mini sparkline chart showing PPV history with a threshold line.
/// Used in the full-screen alert overlay to visualize the spike.
class PpvSparkline extends StatelessWidget {
  final List<double> data;
  final double threshold;
  final Color lineColor;
  final Color thresholdColor;
  final Color fillColor;

  const PpvSparkline({
    super.key,
    required this.data,
    required this.threshold,
    this.lineColor = Colors.white,
    this.thresholdColor = const Color(0xFFFFD54F),
    this.fillColor = const Color(0x33FFFFFF),
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const Center(
        child: Text(
          'No data',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );
    }

    return CustomPaint(
      painter: _SparklinePainter(
        data: data,
        threshold: threshold,
        lineColor: lineColor,
        thresholdColor: thresholdColor,
        fillColor: fillColor,
      ),
      size: Size.infinite,
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final double threshold;
  final Color lineColor;
  final Color thresholdColor;
  final Color fillColor;

  _SparklinePainter({
    required this.data,
    required this.threshold,
    required this.lineColor,
    required this.thresholdColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final maxVal = math.max(data.reduce(math.max), threshold * 1.2);
    final minVal = 0.0;
    final range = maxVal - minVal;
    if (range == 0) return;

    double yOf(double v) => size.height - ((v - minVal) / range * size.height);
    double xOf(int i) => i / (data.length - 1).clamp(1, double.infinity) * size.width;

    // Threshold dashed line
    final thresholdY = yOf(threshold);
    final threshPaint = Paint()
      ..color = thresholdColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dashWidth = 6.0;
    const dashGap = 4.0;
    var startX = 0.0;
    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, thresholdY),
        Offset(math.min(startX + dashWidth, size.width), thresholdY),
        threshPaint,
      );
      startX += dashWidth + dashGap;
    }

    // Threshold label
    final tp = TextPainter(
      text: TextSpan(
        text: '${threshold.toStringAsFixed(1)} mm/s',
        style: TextStyle(color: thresholdColor, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - tp.width - 2, thresholdY - tp.height - 2));

    // Data path
    final path = Path();
    path.moveTo(xOf(0), yOf(data[0]));
    for (var i = 1; i < data.length; i++) {
      path.lineTo(xOf(i), yOf(data[i]));
    }

    // Fill under curve
    final fillPath = Path.from(path)
      ..lineTo(xOf(data.length - 1), size.height)
      ..lineTo(xOf(0), size.height)
      ..close();
    canvas.drawPath(fillPath, Paint()..color = fillColor);

    // Stroke line
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // Current value dot
    final lastX = xOf(data.length - 1);
    final lastY = yOf(data.last);
    canvas.drawCircle(
      Offset(lastX, lastY),
      4,
      Paint()..color = data.last > threshold ? const Color(0xFFE53935) : lineColor,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.data != data || old.threshold != threshold;
}
```

**Step 4: Run test to verify it passes**

Run: `flutter test test/widgets/ppv_sparkline_test.dart`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/widgets/ppv_sparkline.dart test/widgets/ppv_sparkline_test.dart
git commit -m "feat: add PpvSparkline widget for alert overlay"
```

---

### Task 2: Expand Alert Callback to Include Metrics

**Files:**
- Modify: `lib/main.dart:131-261`
- Modify: `lib/screens/safety/safety_view.dart:33,39,1196-1199`

**Step 1: Add AlertMetrics class and expand state in main.dart**

Add this class at the top of `lib/main.dart` (after imports, before `main()`):

```dart
/// Sensor metrics passed to the alert overlay for context.
class AlertMetrics {
  final double ppv;
  final double freq;
  final double staLta;
  final double crestFactor;
  final double kurtosis;
  final String hazardType;
  final List<double> ppvHistory;

  const AlertMetrics({
    this.ppv = 0,
    this.freq = 0,
    this.staLta = 0,
    this.crestFactor = 0,
    this.kurtosis = 0,
    this.hazardType = 'none',
    this.ppvHistory = const [],
  });
}
```

**Step 2: Update _DashboardScreenState to store AlertMetrics**

In `_DashboardScreenState`, change:

```dart
// OLD (line 138-140):
bool _showFullScreenAlert = false;
String _fullScreenAlertMessage = '';
String _fullScreenAlertLevel = 'warning';

// NEW:
bool _showFullScreenAlert = false;
String _fullScreenAlertMessage = '';
String _fullScreenAlertLevel = 'warning';
AlertMetrics _fullScreenAlertMetrics = const AlertMetrics();
```

**Step 3: Update _triggerFullScreenAlert signature**

Change the method signature and the callback type in SafetyView:

In `lib/main.dart`, change `_triggerFullScreenAlert` (line 174):

```dart
// OLD:
void _triggerFullScreenAlert(String message, String level) async {

// NEW:
void _triggerFullScreenAlert(String message, String level, [AlertMetrics? metrics]) async {
```

Add inside the setState (after line 181):

```dart
_fullScreenAlertMetrics = metrics ?? const AlertMetrics();
```

**Step 4: Update SafetyView onAlert callback type**

In `lib/screens/safety/safety_view.dart`, change line 33:

```dart
// OLD:
final void Function(String message, String level) onAlert;

// NEW:
final void Function(String message, String level, [AlertMetrics? metrics]) onAlert;
```

**Step 5: Update SafetyView's _triggerFullScreenAlert to pass metrics**

In `lib/screens/safety/safety_view.dart`, change lines 1196-1199:

```dart
// OLD:
void _triggerFullScreenAlert(String message, String level) {
  try {
    widget.onAlert(message, level);
  } catch (e) {
    debugPrint('Alert callback failed: $e');
  }
}

// NEW:
void _triggerFullScreenAlert(String message, String level) {
  try {
    widget.onAlert(message, level, AlertMetrics(
      ppv: _ppv,
      freq: _dominantFreq,
      staLta: _staLtaRatio,
      crestFactor: _crestFactor,
      kurtosis: _kurtosis,
      hazardType: _hazardType,
      ppvHistory: _ppvKalmanHistory.toList(),
    ));
  } catch (e) {
    debugPrint('Alert callback failed: $e');
  }
}
```

Add import at top of safety_view.dart:

```dart
import '../../main.dart' show AlertMetrics;
```

**Step 6: Pass metrics to FullScreenAlertOverlay in main.dart**

In `lib/main.dart`, update the overlay instantiation (lines 257-261):

```dart
// OLD:
FullScreenAlertOverlay(
  message: _fullScreenAlertMessage,
  level: _fullScreenAlertLevel,
  onDismiss: _dismissFullScreenAlert,
),

// NEW:
FullScreenAlertOverlay(
  message: _fullScreenAlertMessage,
  level: _fullScreenAlertLevel,
  metrics: _fullScreenAlertMetrics,
  onDismiss: _dismissFullScreenAlert,
),
```

**Step 7: Verify build compiles**

Run: `flutter build apk --debug 2>&1 | tail -5`
Expected: Build succeeds (FullScreenAlertOverlay will complain about `metrics` param — that's expected, fixed in Task 3)

**Step 8: Commit**

```bash
git add lib/main.dart lib/screens/safety/safety_view.dart
git commit -m "feat: expand alert callback to pass sensor metrics"
```

---

### Task 3: Redesign FullScreenAlertOverlay

**Files:**
- Modify: `lib/widgets/full_screen_alert_overlay.dart` (full rewrite of the widget)

**Step 1: Rewrite the widget with metrics box, sparkline, and type-specific guidance**

Replace the entire `FullScreenAlertOverlay` class (lines 1-205) with:

```dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show AlertMetrics;
import 'ppv_sparkline.dart';

/// Full-screen alert overlay with sensor metrics and actionable guidance.
class FullScreenAlertOverlay extends StatefulWidget {
  final String message;
  final String level;
  final AlertMetrics metrics;
  final VoidCallback onDismiss;

  const FullScreenAlertOverlay({
    super.key,
    required this.message,
    required this.level,
    required this.metrics,
    required this.onDismiss,
  });

  @override
  State<FullScreenAlertOverlay> createState() => _FullScreenAlertOverlayState();
}

class _FullScreenAlertOverlayState extends State<FullScreenAlertOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _getActionGuidance() {
    switch (widget.metrics.hazardType) {
      case 'seismic':
        return 'EVACUATE THE TRENCH\nMove to safe distance (>15m). Do not re-enter until cleared.';
      case 'machinery':
        return 'STOP ALL EQUIPMENT\nInspect vibration source before resuming work.';
      case 'impact':
        return 'CHECK FOR STRUCTURAL DAMAGE\nDo not resume until inspected by engineer.';
      case 'moisture_high':
        return 'COLLAPSE RISK — EXIT TRENCH\nAssess drainage before re-entry.';
      case 'cav_damage':
        return 'CUMULATIVE DAMAGE THRESHOLD\nStructural assessment required before continuing.';
      case 'structural':
        return 'EVACUATE IMMEDIATELY\nStructural damage risk. Do not re-enter.';
      case 'dwt_transient':
        return 'HIGH-FREQUENCY TRANSIENT DETECTED\nIdentify source before resuming.';
      case 'continuous':
        return 'CONTINUOUS VIBRATION EXCEEDS LIMIT\nReduce vibration source or evacuate.';
      case 'source_change':
        return 'VIBRATION SOURCE CHANGED\nIdentify new source and assess risk.';
      default:
        return widget.level == 'critical'
            ? 'EVACUATE THE TRENCH IMMEDIATELY\nFollow emergency protocol.'
            : 'Check conditions and take appropriate action.';
    }
  }

  double _getThresholdForFreq(double freq) {
    if (freq <= 10) return 3.0;
    if (freq <= 50) return 5.0;
    return 8.0;
  }

  @override
  Widget build(BuildContext context) {
    final isCritical = widget.level == 'critical';
    final alertColor = isCritical ? const Color(0xFFE53935) : const Color(0xFFFFB300);
    final m = widget.metrics;
    final threshold = _getThresholdForFreq(m.freq);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.5,
            colors: [
              alertColor.withAlpha(200),
              Colors.black.withAlpha(230),
              Colors.black.withAlpha(250),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Pulsing icon
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseAnimation.value,
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: alertColor.withAlpha(60),
                          boxShadow: [
                            BoxShadow(
                              color: alertColor.withAlpha(100),
                              blurRadius: 30,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: Icon(
                          isCritical ? Icons.warning_rounded : Icons.error_outline,
                          size: 56,
                          color: Colors.white,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),

                // Title
                Text(
                  isCritical ? 'CRITICAL ALERT' : 'WARNING',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 12),

                // Alert message
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    widget.message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),

                // ── WHY THIS TRIGGERED ──
                if (m.ppv > 0 || m.staLta > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(25),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withAlpha(50)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'WHY THIS TRIGGERED',
                                style: TextStyle(
                                  color: alertColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 10),
                              if (m.ppv > 0) _metricRow(
                                'PPV',
                                '${m.ppv.toStringAsFixed(1)} mm/s',
                                'limit: ${threshold.toStringAsFixed(1)}',
                                m.ppv > threshold,
                              ),
                              if (m.freq > 0) _metricRow(
                                'Frequency',
                                '${m.freq.toStringAsFixed(1)} Hz',
                                m.freq <= 10 ? 'seismic band' : m.freq <= 50 ? 'machinery band' : 'high-freq',
                                false,
                              ),
                              if (m.staLta > 2.0) _metricRow(
                                'STA/LTA',
                                m.staLta.toStringAsFixed(1),
                                'trigger: 4.0',
                                m.staLta > 4.0,
                              ),
                              if (m.kurtosis > 3.0) _metricRow(
                                'Kurtosis',
                                m.kurtosis.toStringAsFixed(1),
                                m.kurtosis > 6 ? 'severe impact' : 'impact',
                                true,
                              ),
                              if (m.crestFactor > 5.0) _metricRow(
                                'Crest Factor',
                                m.crestFactor.toStringAsFixed(1),
                                'impulsive',
                                true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),

                // ── PPV SPARKLINE ──
                if (m.ppvHistory.length >= 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(25),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withAlpha(50)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PPV — LAST ${m.ppvHistory.length} READINGS',
                                style: TextStyle(
                                  color: alertColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 80,
                                child: PpvSparkline(
                                  data: m.ppvHistory,
                                  threshold: threshold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),

                // ── ACTION GUIDANCE ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: alertColor.withAlpha(40),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: alertColor.withAlpha(120)),
                    ),
                    child: Text(
                      _getActionGuidance(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Timestamp
                Text(
                  'Detected at ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}',
                  style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 14),
                ),
                const SizedBox(height: 24),

                // ACKNOWLEDGE button
                GestureDetector(
                  onTap: widget.onDismiss,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(230),
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(60),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle, color: alertColor, size: 26),
                            const SizedBox(width: 10),
                            Text(
                              'ACKNOWLEDGE',
                              style: TextStyle(
                                color: alertColor,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metricRow(String label, String value, String context, bool exceeded) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            exceeded ? Icons.arrow_upward : Icons.remove,
            color: exceeded ? const Color(0xFFFF5252) : Colors.white70,
            size: 14,
          ),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          Text(
            value,
            style: TextStyle(
              color: exceeded ? const Color(0xFFFF5252) : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($context)',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// Keep CurrentAlertBanner unchanged
class CurrentAlertBanner extends StatelessWidget {
  final String level;
  final String message;

  const CurrentAlertBanner({super.key, required this.level, required this.message});

  @override
  Widget build(BuildContext context) {
    final isCritical = level == 'critical';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isCritical ? Colors.red.withAlpha(77) : Colors.orange.withAlpha(77),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isCritical ? Colors.red : Colors.orange, width: 2),
      ),
      child: Row(
        children: [
          Icon(
            isCritical ? Icons.warning_rounded : Icons.info_outline,
            color: isCritical ? Colors.red : Colors.orange,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCritical ? 'CRITICAL ALERT' : 'WARNING',
                  style: TextStyle(
                    color: isCritical ? Colors.red : Colors.orange,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(message, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

**Step 2: Verify build compiles**

Run: `flutter test test/widgets/ppv_sparkline_test.dart`
Expected: PASS (verifies widget chain works)

**Step 3: Commit**

```bash
git add lib/widgets/full_screen_alert_overlay.dart
git commit -m "feat: redesign alert overlay with metrics, sparkline, and action guidance"
```

---

### Task 4: Add file_picker Package

**Files:**
- Modify: `pubspec.yaml`

**Step 1: Add file_picker dependency**

In `pubspec.yaml`, add under `dependencies:`:

```yaml
  file_picker: ^8.0.0
```

**Step 2: Run pub get**

Run: `flutter pub get`
Expected: Resolving dependencies... success

**Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add file_picker package for GeoJSON import"
```

---

### Task 5: Create GeoJsonService

**Files:**
- Create: `lib/services/geojson_service.dart`
- Create: `test/services/geojson_service_test.dart`

**Step 1: Write the failing tests**

```dart
// test/services/geojson_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ancient_vision/services/geojson_service.dart';

void main() {
  group('GeoJsonService', () {
    late GeoJsonService service;

    setUp(() {
      service = GeoJsonService();
    });

    test('parses polygon feature', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'name': 'Trench A'},
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [23.7, 37.9],
                  [23.701, 37.9],
                  [23.701, 37.901],
                  [23.7, 37.901],
                  [23.7, 37.9],
                ]
              ]
            }
          }
        ]
      };

      final result = service.parse(geojson);
      expect(result.polygons, hasLength(1));
      expect(result.polygons.first.points, hasLength(5));
      expect(result.polygons.first.label, 'Trench A');
    });

    test('parses linestring feature', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'name': 'Wall 1'},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [23.7, 37.9],
                [23.701, 37.901],
              ]
            }
          }
        ]
      };

      final result = service.parse(geojson);
      expect(result.polylines, hasLength(1));
      expect(result.polylines.first.points, hasLength(2));
    });

    test('parses point feature', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'name': 'Find Spot 1'},
            'geometry': {
              'type': 'Point',
              'coordinates': [23.7, 37.9]
            }
          }
        ]
      };

      final result = service.parse(geojson);
      expect(result.points, hasLength(1));
      expect(result.points.first.label, 'Find Spot 1');
    });

    test('handles empty feature collection', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': []
      };

      final result = service.parse(geojson);
      expect(result.polygons, isEmpty);
      expect(result.polylines, isEmpty);
      expect(result.points, isEmpty);
    });

    test('computes bounding box', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {},
            'geometry': {
              'type': 'Point',
              'coordinates': [23.7, 37.9]
            }
          },
          {
            'type': 'Feature',
            'properties': {},
            'geometry': {
              'type': 'Point',
              'coordinates': [23.8, 38.0]
            }
          }
        ]
      };

      final result = service.parse(geojson);
      expect(result.bounds, isNotNull);
      expect(result.bounds!.south, closeTo(37.9, 0.001));
      expect(result.bounds!.north, closeTo(38.0, 0.001));
    });
  });
}
```

**Step 2: Run tests to verify they fail**

Run: `flutter test test/services/geojson_service_test.dart`
Expected: FAIL — `GeoJsonService` not found

**Step 3: Write implementation**

```dart
// lib/services/geojson_service.dart
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:shared_preferences/shared_preferences.dart';

class GeoJsonPoint {
  final LatLng position;
  final String? label;
  GeoJsonPoint({required this.position, this.label});
}

class GeoJsonPolygon {
  final List<LatLng> points;
  final String? label;
  GeoJsonPolygon({required this.points, this.label});
}

class GeoJsonPolyline {
  final List<LatLng> points;
  final String? label;
  GeoJsonPolyline({required this.points, this.label});
}

class GeoJsonLayer {
  final String name;
  final List<GeoJsonPolygon> polygons;
  final List<GeoJsonPolyline> polylines;
  final List<GeoJsonPoint> points;
  final LatLngBounds? bounds;

  GeoJsonLayer({
    required this.name,
    required this.polygons,
    required this.polylines,
    required this.points,
    this.bounds,
  });
}

class GeoJsonService {
  static const _storageKey = 'geojson_layers';

  GeoJsonLayer parse(Map<String, dynamic> geojson, {String name = 'Layer'}) {
    final features = geojson['features'] as List? ?? [];
    final polygons = <GeoJsonPolygon>[];
    final polylines = <GeoJsonPolyline>[];
    final points = <GeoJsonPoint>[];
    final allCoords = <LatLng>[];

    for (final feature in features) {
      final props = feature['properties'] as Map<String, dynamic>? ?? {};
      final geom = feature['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;

      final label = props['name'] as String? ?? props['label'] as String?;
      final type = geom['type'] as String;
      final coords = geom['coordinates'];

      switch (type) {
        case 'Polygon':
          final ring = (coords[0] as List)
              .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList();
          polygons.add(GeoJsonPolygon(points: ring, label: label));
          allCoords.addAll(ring);
          break;
        case 'MultiPolygon':
          for (final poly in coords) {
            final ring = (poly[0] as List)
                .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            polygons.add(GeoJsonPolygon(points: ring, label: label));
            allCoords.addAll(ring);
          }
          break;
        case 'LineString':
          final pts = (coords as List)
              .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList();
          polylines.add(GeoJsonPolyline(points: pts, label: label));
          allCoords.addAll(pts);
          break;
        case 'MultiLineString':
          for (final line in coords) {
            final pts = (line as List)
                .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            polylines.add(GeoJsonPolyline(points: pts, label: label));
            allCoords.addAll(pts);
          }
          break;
        case 'Point':
          final pt = LatLng((coords[1] as num).toDouble(), (coords[0] as num).toDouble());
          points.add(GeoJsonPoint(position: pt, label: label));
          allCoords.add(pt);
          break;
      }
    }

    LatLngBounds? bounds;
    if (allCoords.isNotEmpty) {
      var south = allCoords[0].latitude, north = south;
      var west = allCoords[0].longitude, east = west;
      for (final c in allCoords) {
        if (c.latitude < south) south = c.latitude;
        if (c.latitude > north) north = c.latitude;
        if (c.longitude < west) west = c.longitude;
        if (c.longitude > east) east = c.longitude;
      }
      bounds = LatLngBounds(LatLng(south, west), LatLng(north, east));
    }

    return GeoJsonLayer(
      name: name,
      polygons: polygons,
      polylines: polylines,
      points: points,
      bounds: bounds,
    );
  }

  /// Load bundled sample GeoJSON from assets.
  Future<GeoJsonLayer> loadBundled(String assetPath, {String name = 'Sample'}) async {
    final raw = await rootBundle.loadString(assetPath);
    return parse(json.decode(raw), name: name);
  }

  /// Save layer JSON to SharedPreferences for persistence.
  Future<void> saveLayer(String name, String geojsonString) async {
    final prefs = await SharedPreferences.getInstance();
    final layers = prefs.getStringList(_storageKey) ?? [];
    // Store as "name|||json"
    layers.removeWhere((l) => l.startsWith('$name|||'));
    layers.add('$name|||$geojsonString');
    await prefs.setStringList(_storageKey, layers);
  }

  /// Load all persisted layers.
  Future<List<GeoJsonLayer>> loadSavedLayers() async {
    final prefs = await SharedPreferences.getInstance();
    final layers = prefs.getStringList(_storageKey) ?? [];
    return layers.map((entry) {
      final sep = entry.indexOf('|||');
      final name = entry.substring(0, sep);
      final jsonStr = entry.substring(sep + 3);
      return parse(json.decode(jsonStr), name: name);
    }).toList();
  }

  /// Remove a persisted layer by name.
  Future<void> removeLayer(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final layers = prefs.getStringList(_storageKey) ?? [];
    layers.removeWhere((l) => l.startsWith('$name|||'));
    await prefs.setStringList(_storageKey, layers);
  }
}
```

**Step 4: Run tests to verify they pass**

Run: `flutter test test/services/geojson_service_test.dart`
Expected: PASS (all 5 tests)

**Step 5: Commit**

```bash
git add lib/services/geojson_service.dart test/services/geojson_service_test.dart
git commit -m "feat: add GeoJsonService for parsing and persisting GeoJSON layers"
```

---

### Task 6: Create Sample GeoJSON Demo Data

**Files:**
- Create: `assets/geo/sample_trenches.geojson`
- Modify: `pubspec.yaml` (add asset path)

**Step 1: Create sample GeoJSON**

This uses coordinates near the Kalapodi temple site in Phocis, Greece (actual field test location mentioned in meeting):

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {"name": "Trench A1", "type": "excavation"},
      "geometry": {
        "type": "Polygon",
        "coordinates": [[
          [22.9820, 38.6230],
          [22.9825, 38.6230],
          [22.9825, 38.6233],
          [22.9820, 38.6233],
          [22.9820, 38.6230]
        ]]
      }
    },
    {
      "type": "Feature",
      "properties": {"name": "Trench B2", "type": "excavation"},
      "geometry": {
        "type": "Polygon",
        "coordinates": [[
          [22.9828, 38.6231],
          [22.9832, 38.6231],
          [22.9832, 38.6235],
          [22.9828, 38.6235],
          [22.9828, 38.6231]
        ]]
      }
    },
    {
      "type": "Feature",
      "properties": {"name": "Temple Wall (North)", "type": "wall"},
      "geometry": {
        "type": "LineString",
        "coordinates": [
          [22.9821, 38.6232],
          [22.9824, 38.6232],
          [22.9824, 38.6234]
        ]
      }
    },
    {
      "type": "Feature",
      "properties": {"name": "Column Base", "type": "feature"},
      "geometry": {
        "type": "Point",
        "coordinates": [22.9823, 38.6233]
      }
    },
    {
      "type": "Feature",
      "properties": {"name": "Altar Foundation", "type": "feature"},
      "geometry": {
        "type": "Point",
        "coordinates": [22.9830, 38.6233]
      }
    }
  ]
}
```

**Step 2: Add asset path to pubspec.yaml**

Under `flutter: > assets:`, add:

```yaml
    - assets/geo/
```

**Step 3: Commit**

```bash
git add assets/geo/sample_trenches.geojson pubspec.yaml
git commit -m "feat: add sample GeoJSON data for competition demo"
```

---

### Task 7: Upgrade FindingsMap with Satellite Tiles, GeoJSON Layers, and Controls

**Files:**
- Modify: `lib/screens/findings_map_screen.dart` (full upgrade)

**Step 1: Rewrite FindingsMap**

Replace the entire file content with the upgraded version. Key changes:
- Esri World Imagery satellite tiles as default
- Street/satellite toggle
- GeoJSON polygon/polyline/point rendering
- Import button with file_picker
- Layer visibility toggles
- Load bundled sample + persisted layers on init

```dart
// lib/screens/findings_map_screen.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../models/finding_model.dart';
import '../services/geojson_service.dart';

class FindingsMap extends StatefulWidget {
  final List<Finding> findings;
  final int selectedIndex;

  const FindingsMap({
    super.key,
    required this.findings,
    required this.selectedIndex,
  });

  @override
  State<FindingsMap> createState() => _FindingsMapState();
}

class _FindingsMapState extends State<FindingsMap> {
  MapController? _mapController;
  String _locationName = 'Archaeological Site';
  bool _isLoadingLocation = false;
  bool _useSatellite = true;
  bool _showFindings = true;
  bool _showGeoJsonLayers = true;
  bool _showLayerPanel = false;

  final GeoJsonService _geoJsonService = GeoJsonService();
  final List<GeoJsonLayer> _geoJsonLayers = [];

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    if (widget.findings.isNotEmpty) {
      _reverseGeocode(widget.findings.first.latitude, widget.findings.first.longitude);
    }
    _loadGeoJsonLayers();
  }

  Future<void> _loadGeoJsonLayers() async {
    try {
      // Load bundled sample
      final sample = await _geoJsonService.loadBundled(
        'assets/geo/sample_trenches.geojson',
        name: 'Kalapodi Trenches',
      );
      // Load persisted layers
      final saved = await _geoJsonService.loadSavedLayers();
      if (mounted) {
        setState(() {
          _geoJsonLayers.add(sample);
          _geoJsonLayers.addAll(saved);
        });
      }
    } catch (e) {
      debugPrint('GeoJSON load error: $e');
    }
  }

  Future<void> _importGeoJson() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String? content;
      if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      }
      if (content == null) return;

      final geojson = json.decode(content) as Map<String, dynamic>;
      final name = file.name.replaceAll('.geojson', '').replaceAll('.json', '');
      final layer = _geoJsonService.parse(geojson, name: name);

      await _geoJsonService.saveLayer(name, content);

      if (mounted) {
        setState(() => _geoJsonLayers.add(layer));

        // Zoom to imported layer bounds
        if (layer.bounds != null && _mapController != null) {
          _mapController!.fitCamera(
            CameraFit.bounds(
              bounds: layer.bounds!,
              padding: const EdgeInsets.all(50),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import: $e')),
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant FindingsMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex && widget.findings.isNotEmpty) {
      final selected = widget.findings[widget.selectedIndex];
      _mapController?.move(LatLng(selected.latitude, selected.longitude), 17.5);
      _reverseGeocode(selected.latitude, selected.longitude);
    }
  }

  Future<void> _reverseGeocode(double lat, double lon) async {
    if (_isLoadingLocation) return;
    setState(() => _isLoadingLocation = true);
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=18&addressdetails=1',
      );
      final response = await http.get(url, headers: {'User-Agent': 'AncientVision-FLL-App/1.0'});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final address = data['address'] as Map<String, dynamic>?;
        String name = data['name'] as String? ?? '';
        if (name.isEmpty) {
          name = address?['historic'] as String? ??
              address?['tourism'] as String? ??
              address?['archaeological_site'] as String? ??
              address?['amenity'] as String? ??
              address?['suburb'] as String? ??
              address?['neighbourhood'] as String? ??
              address?['village'] as String? ??
              address?['town'] as String? ??
              address?['city'] as String? ??
              'Archaeological Site';
        }
        if (mounted) setState(() => _locationName = name);
      }
    } catch (_) {}
    finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _openInGoogleMaps() async {
    final center = widget.findings[widget.selectedIndex];
    final url = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${center.latitude},${center.longitude}',
    );
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  List<Marker> _buildFindingMarkers() {
    if (!_showFindings) return [];
    return widget.findings.asMap().entries.map((entry) {
      final index = entry.key;
      final finding = entry.value;
      final isSelected = index == widget.selectedIndex;
      final typeColor = Finding.getTypeColor(finding.type);
      return Marker(
        point: LatLng(finding.latitude, finding.longitude),
        width: isSelected ? 48 : 36,
        height: isSelected ? 48 : 36,
        child: GestureDetector(
          onTap: _openInGoogleMaps,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isSelected)
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: typeColor.withAlpha(77)),
                ),
              Icon(Icons.location_pin, size: isSelected ? 40 : 32,
                color: isSelected ? typeColor : typeColor.withAlpha(217),
                shadows: [Shadow(color: Colors.black.withAlpha(128), blurRadius: 4)],
              ),
              Positioned(
                top: isSelected ? 8 : 4,
                child: Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle,
                    border: Border.all(color: typeColor, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  List<Polygon> _buildGeoJsonPolygons() {
    if (!_showGeoJsonLayers) return [];
    return _geoJsonLayers.expand((layer) => layer.polygons.map((p) => Polygon(
      points: p.points,
      color: const Color(0x33FFC107),
      borderColor: const Color(0xFFFFC107),
      borderStrokeWidth: 2,
      isFilled: true,
      label: p.label,
      labelStyle: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
    ))).toList();
  }

  List<Polyline> _buildGeoJsonPolylines() {
    if (!_showGeoJsonLayers) return [];
    return _geoJsonLayers.expand((layer) => layer.polylines.map((p) => Polyline(
      points: p.points,
      color: const Color(0xFFFF9800),
      strokeWidth: 3,
    ))).toList();
  }

  List<Marker> _buildGeoJsonPointMarkers() {
    if (!_showGeoJsonLayers) return [];
    return _geoJsonLayers.expand((layer) => layer.points.map((p) => Marker(
      point: p.position,
      width: 30,
      height: 30,
      child: Tooltip(
        message: p.label ?? '',
        child: const Icon(Icons.place, color: Color(0xFFFF9800), size: 28),
      ),
    ))).toList();
  }

  @override
  Widget build(BuildContext context) {
    final firstFinding = widget.findings.first;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: LatLng(firstFinding.latitude, firstFinding.longitude),
            initialZoom: 17.5,
            minZoom: 4,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
          ),
          children: [
            // Tile layer — satellite or street
            TileLayer(
              urlTemplate: _useSatellite
                  ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.ancient_vision',
              maxZoom: 19,
            ),
            // GeoJSON polygons
            PolygonLayer(polygons: _buildGeoJsonPolygons()),
            // GeoJSON polylines
            PolylineLayer(polylines: _buildGeoJsonPolylines()),
            // GeoJSON point markers
            MarkerLayer(markers: _buildGeoJsonPointMarkers()),
            // Finding markers
            MarkerLayer(markers: _buildFindingMarkers()),
          ],
        ),

        // Location label
        Positioned(
          top: 12, left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(179),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLoadingLocation)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox(width: 10, height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFC107)),
                      ),
                    ),
                  ),
                Text(_locationName, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),

        // Top-right controls: satellite toggle + layers
        Positioned(
          top: 12, right: 12,
          child: Column(
            children: [
              _mapButton(
                icon: _useSatellite ? Icons.satellite_alt : Icons.map,
                tooltip: _useSatellite ? 'Street view' : 'Satellite view',
                onTap: () => setState(() => _useSatellite = !_useSatellite),
              ),
              const SizedBox(height: 8),
              _mapButton(
                icon: Icons.layers,
                tooltip: 'Layers',
                onTap: () => setState(() => _showLayerPanel = !_showLayerPanel),
              ),
              const SizedBox(height: 8),
              _mapButton(
                icon: Icons.file_open,
                tooltip: 'Import GeoJSON',
                onTap: _importGeoJson,
              ),
            ],
          ),
        ),

        // Layer panel
        if (_showLayerPanel)
          Positioned(
            top: 120, right: 12,
            child: Container(
              width: 200,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(210),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Layers', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 8),
                  _layerToggle('Findings', _showFindings, (v) => setState(() => _showFindings = v)),
                  _layerToggle('GIS Layers', _showGeoJsonLayers, (v) => setState(() => _showGeoJsonLayers = v)),
                  if (_geoJsonLayers.isNotEmpty) ...[
                    const Divider(color: Colors.white24, height: 16),
                    ...(_geoJsonLayers.map((l) => Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '${l.name} (${l.polygons.length + l.polylines.length + l.points.length})',
                        style: const TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                    ))),
                  ],
                ],
              ),
            ),
          ),

        // Bottom-right: Google Maps button
        Positioned(
          bottom: 12, right: 12,
          child: GestureDetector(
            onTap: _openInGoogleMaps,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFC107),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(77), blurRadius: 8, spreadRadius: 1)],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new, color: Color(0xFF3E2723), size: 16),
                  SizedBox(width: 6),
                  Text('Google Maps', style: TextStyle(color: Color(0xFF3E2723), fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _mapButton({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(179),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Widget _layerToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24, height: 24,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            activeColor: const Color(0xFFFFC107),
            checkColor: Colors.black,
            side: const BorderSide(color: Colors.white54),
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ],
    );
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }
}
```

**Step 2: Verify build compiles**

Run: `flutter analyze lib/screens/findings_map_screen.dart`
Expected: No errors

**Step 3: Commit**

```bash
git add lib/screens/findings_map_screen.dart
git commit -m "feat: satellite tiles, GeoJSON layers, and layer controls on map"
```

---

### Task 8: Integration Test — Full Build Verification

**Step 1: Run all tests**

Run: `flutter test`
Expected: All existing tests + new tests pass

**Step 2: Build APK**

Run: `flutter build apk --release`
Expected: Build succeeds

**Step 3: Final commit with all changes**

If any fixups were needed, commit them:

```bash
git add -A
git commit -m "fix: address build issues from alert + GIS integration"
```
