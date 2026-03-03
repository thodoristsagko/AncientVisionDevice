# Competition Sprint Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement 7 competition-ready features across Safety, Archaeology, AI, and Reliability sectors before March 21, 2026.

**Architecture:** Features 1–4 are isolated (one screen each, run in parallel). Features 5–7 share files and run sequentially. All packages already in pubspec.yaml — no new dependencies.

**Tech Stack:** Flutter, Firestore, `fl_chart`, `speech_to_text`, `shared_preferences`, `permission_handler`.

---

### Task 1: Alert History Service + UI

**Files:**
- Create: `lib/services/alert_history_service.dart`
- Create: `test/services/alert_history_service_test.dart`
- Modify: `lib/screens/safety/safety_view.dart`

**Step 1: Write the failing tests**

Create `test/services/alert_history_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ancient_vision/services/alert_history_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AlertHistoryService', () {
    test('starts empty', () async {
      final svc = AlertHistoryService();
      final entries = await svc.load();
      expect(entries, isEmpty);
    });

    test('add stores an entry', () async {
      final svc = AlertHistoryService();
      await svc.add(level: 'warning', type: 'seismic', ppv: 3.5, message: 'Stop work');
      final entries = await svc.load();
      expect(entries.length, 1);
      expect(entries.first['level'], 'warning');
      expect(entries.first['ppv'], 3.5);
    });

    test('clear removes all entries', () async {
      final svc = AlertHistoryService();
      await svc.add(level: 'critical', type: 'impact', ppv: 12.0, message: 'Evacuate');
      await svc.clear();
      final entries = await svc.load();
      expect(entries, isEmpty);
    });

    test('max 100 entries (FIFO eviction)', () async {
      final svc = AlertHistoryService();
      for (int i = 0; i < 105; i++) {
        await svc.add(level: 'warning', type: 'seismic', ppv: i.toDouble(), message: 'msg $i');
      }
      final entries = await svc.load();
      expect(entries.length, 100);
      expect(entries.last['ppv'], 104.0); // newest last
    });
  });
}
```

**Step 2: Run tests to verify they fail**

```
flutter test test/services/alert_history_service_test.dart --reporter=compact
```
Expected: FAIL with "Target file not found"

**Step 3: Create `lib/services/alert_history_service.dart`**

```dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AlertHistoryService {
  static const _key = 'alert_history';
  static const _maxEntries = 100;

  Future<List<Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> add({
    required String level,
    required String type,
    required double ppv,
    required String message,
  }) async {
    final entries = await load();
    entries.add({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': type,
      'ppv': ppv,
      'message': message,
    });
    final trimmed = entries.length > _maxEntries
        ? entries.sublist(entries.length - _maxEntries)
        : entries;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
```

**Step 4: Run tests to verify they pass**

```
flutter test test/services/alert_history_service_test.dart --reporter=compact
```
Expected: `+4: All tests passed!`

**Step 5: Add history logging to `safety_view.dart`**

In `lib/screens/safety/safety_view.dart`, add the import at the top (after existing imports):
```dart
import '../../services/alert_history_service.dart';
```

In `_SafetyViewState`, add the service field after existing fields (e.g. after `_lastRssi`):
```dart
  final _alertHistory = AlertHistoryService();
```

In `_triggerFullScreenAlert`, after the `widget.onAlert(...)` call, add:
```dart
    _alertHistory.add(
      level: level,
      type: _hazardType,
      ppv: _ppv,
      message: message,
    ).catchError((_) {});
```

**Step 6: Add History button to Safety tab header**

Find the Safety tab's `build()` method. Locate the header Row that contains the title "Monitor" or "Safety". Add an `IconButton` for history next to the title:

Find the section in `build()` that shows the tab title (look for `Text('Monitor'` or similar). Add after it, in the same Row:

```dart
                IconButton(
                  icon: const Icon(Icons.history_rounded, color: Colors.white70, size: 22),
                  tooltip: 'Alert History',
                  onPressed: () => _showAlertHistory(context),
                ),
```

**Step 7: Add `_showAlertHistory` method**

Add this method to `_SafetyViewState` (alongside `_triggerFullScreenAlert`):

```dart
  void _showAlertHistory(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1C2523),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: Row(
                  children: [
                    const Text('Alert History',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        await _alertHistory.clear();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Clear', style: TextStyle(color: Colors.white54)),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _alertHistory.load(),
                  builder: (_, snap) {
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107)));
                    final entries = snap.data!.reversed.toList();
                    if (entries.isEmpty) {
                      return const Center(child: Text('No alerts recorded', style: TextStyle(color: Colors.white54)));
                    }
                    return ListView.builder(
                      controller: controller,
                      itemCount: entries.length,
                      itemBuilder: (_, i) {
                        final e = entries[i];
                        final ts = DateTime.tryParse(e['timestamp'] ?? '');
                        final diff = ts != null ? DateTime.now().difference(ts) : null;
                        final ago = diff == null ? '' :
                            diff.inMinutes < 1 ? 'just now' :
                            diff.inHours < 1 ? '${diff.inMinutes}m ago' :
                            diff.inDays < 1 ? '${diff.inHours}h ago' :
                            '${diff.inDays}d ago';
                        final isCritical = e['level'] == 'critical';
                        return ListTile(
                          leading: Icon(Icons.warning_rounded,
                              color: isCritical ? Colors.red : const Color(0xFFFFC107)),
                          title: Text(e['message'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
                          subtitle: Text('${e['type']} · ${(e['ppv'] as num).toStringAsFixed(2)} mm/s',
                              style: const TextStyle(color: Colors.white54, fontSize: 11)),
                          trailing: Text(ago, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
```

**Step 8: flutter analyze**

```
flutter analyze lib/services/alert_history_service.dart lib/screens/safety/safety_view.dart
```
Expected: `No issues found!`

**Step 9: Full test suite**

```
flutter test --reporter=compact 2>&1 | python -c "import sys; lines=sys.stdin.readlines(); print(lines[-1].strip())"
```
Expected: `All tests passed!`

**Step 10: Commit**

```bash
git add lib/services/alert_history_service.dart \
        test/services/alert_history_service_test.dart \
        lib/screens/safety/safety_view.dart
git commit -m "$(cat <<'EOF'
feat: alert history log on Safety tab

Stores triggered alerts locally (max 100, FIFO). History button opens
timeline sheet with level, type, PPV, and relative time. Clear-all option.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Findings Dashboard Stats

**Files:**
- Modify: `lib/screens/dashboard_home_view.dart`

**Step 1: Read `lib/screens/dashboard_home_view.dart`**

Read the full file to find the `build()` method and where new content can be appended. The file already has `_totalFindings`, `_todayFindings`, `_lastFindings` fields.

**Step 2: Add stats fields to `DashboardHomeViewState`**

After existing fields (`_unreadNotifications`, etc.), add:

```dart
  int _significantFindings = 0;
  Map<String, int> _findingsByType = {};
  List<int> _last7DaysCounts = List.filled(7, 0);
  bool _statsLoading = true;
```

**Step 3: Add `_loadStats()` method**

Add this method to `DashboardHomeViewState`:

```dart
  Future<void> _loadStats() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('findings')
          .get()
          .timeout(const Duration(seconds: 10));
      final now = DateTime.now();
      int significant = 0;
      final byType = <String, int>{};
      final days = List.filled(7, 0);
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['isSignificant'] == true) significant++;
        final type = (data['type'] as String? ?? 'Other').trim();
        final key = ['Coin', 'Fragment', 'Structure'].contains(type) ? type : 'Other';
        byType[key] = (byType[key] ?? 0) + 1;
        final raw = data['createdAt'];
        DateTime? created;
        if (raw is String) created = DateTime.tryParse(raw);
        if (raw is Timestamp) created = raw.toDate();
        if (created != null) {
          final daysAgo = now.difference(created).inDays;
          if (daysAgo >= 0 && daysAgo < 7) days[6 - daysAgo]++;
        }
      }
      if (mounted) {
        setState(() {
          _significantFindings = significant;
          _findingsByType = byType;
          _last7DaysCounts = days;
          _statsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _statsLoading = false);
    }
  }
```

**Step 4: Call `_loadStats()` in `initState`**

In `initState()`, add:
```dart
    _loadStats();
```

**Step 5: Add the stats card to `build()`**

Add the `fl_chart` import at the top of the file:
```dart
import 'package:fl_chart/fl_chart.dart';
```

In `build()`, find the return of the main Column. Add a new stats card widget **after** the existing content (before the final closing of the column). Add this method to the class:

```dart
  Widget _buildStatsCard() {
    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha(26)),
        ),
        child: _statsLoading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107)))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Findings Overview',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  // Counters row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statChip('Total', _totalFindings.toString(), Colors.white70),
                      _statChip('Significant', _significantFindings.toString(), const Color(0xFFFFC107)),
                      _statChip('Today', _todayFindings.toString(), const Color(0xFF2196F3)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Bar chart: last 7 days
                  SizedBox(
                    height: 80,
                    child: BarChart(
                      BarChartData(
                        alignment: BarChartAlignment.spaceAround,
                        maxY: (_last7DaysCounts.fold(0, (a, b) => a > b ? a : b) + 1).toDouble(),
                        barTouchData: BarTouchData(enabled: false),
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              getTitlesWidget: (value, _) {
                                final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                                final today = DateTime.now().weekday - 1;
                                final idx = ((today - (6 - value.toInt())) % 7 + 7) % 7;
                                return Text(days[idx],
                                    style: const TextStyle(color: Colors.white38, fontSize: 9));
                              },
                              reservedSize: 16,
                            ),
                          ),
                        ),
                        gridData: const FlGridData(show: false),
                        borderData: FlBorderData(show: false),
                        barGroups: _last7DaysCounts.asMap().entries.map((e) =>
                            BarChartGroupData(x: e.key, barRods: [
                              BarChartRodData(
                                toY: e.value.toDouble(),
                                color: const Color(0xFFFFC107),
                                width: 14,
                                borderRadius: BorderRadius.circular(4),
                              )
                            ])).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Type breakdown row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: _findingsByType.entries.map((e) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('${e.key}: ${e.value}',
                          style: const TextStyle(color: Colors.white54, fontSize: 11)),
                    )).toList(),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _statChip(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }
```

Also add the import for AnalyticsScreen at the top:
```dart
import 'analytics_screen.dart';
```

**Step 6: Call `_buildStatsCard()` in `build()`**

In the `build()` method, find the main scrollable column's children list. Add `_buildStatsCard()` after the existing quick-action cards but before the bottom padding.

**Step 7: flutter analyze**

```
flutter analyze lib/screens/dashboard_home_view.dart
```
Expected: `No issues found!`

**Step 8: Commit**

```bash
git add lib/screens/dashboard_home_view.dart
git commit -m "$(cat <<'EOF'
feat: findings stats card on Dashboard with 7-day bar chart

Shows total/significant/today counters and a bar chart of finds per day
for the last week. Type breakdown row (Coin/Fragment/Structure/Other).
Tapping navigates to full Analytics screen.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Voice Description Input

**Files:**
- Modify: `lib/screens/manual_entry_form_screen.dart`

**Step 1: Add state variables**

In `_ManualEntryFormScreenState`, find existing state fields. Add:

```dart
  bool _isListening = false;
  late AnimationController _micPulseController;
```

**Step 2: Initialize and dispose animation controller**

In `initState()`, add:
```dart
    _micPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
```

In `dispose()`, add before `super.dispose()`:
```dart
    _micPulseController.dispose();
```

The class must use `TickerProviderStateMixin`. Find the class declaration:
```dart
class _ManualEntryFormScreenState extends State<ManualEntryFormScreen>
```
Change to:
```dart
class _ManualEntryFormScreenState extends State<ManualEntryFormScreen>
    with TickerProviderStateMixin
```

**Step 3: Add `_toggleVoice()` method**

Add this method to `_ManualEntryFormScreenState`:

```dart
  Future<void> _toggleVoice() async {
    final stt = SpeechToText();
    if (_isListening) {
      await stt.stop();
      setState(() => _isListening = false);
      return;
    }
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required for voice input')),
        );
      }
      return;
    }
    final available = await stt.initialize(onError: (_) => setState(() => _isListening = false));
    if (!available) return;
    setState(() => _isListening = true);
    await stt.listen(
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          final current = _descriptionController.text;
          _descriptionController.text = current.isEmpty
              ? result.recognizedWords
              : '$current ${result.recognizedWords}';
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      onSoundLevelChange: null,
    );
    if (mounted) setState(() => _isListening = false);
  }
```

**Step 4: Add imports**

At the top of `manual_entry_form_screen.dart`, add:
```dart
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
```

**Step 5: Add mic button to Description field**

Find the Description `TextField` in the build method (look for `_descriptionController`). It likely looks like:
```dart
TextField(
  controller: _descriptionController,
  ...
)
```

Add a `suffixIcon` to its `InputDecoration`:
```dart
suffixIcon: AnimatedBuilder(
  animation: _micPulseController,
  builder: (_, __) => IconButton(
    icon: Icon(
      _isListening ? Icons.mic : Icons.mic_none,
      color: _isListening
          ? Color.lerp(const Color(0xFFE53935), const Color(0xFFFFC107),
              _micPulseController.value)!
          : Colors.white54,
    ),
    onPressed: _toggleVoice,
    tooltip: _isListening ? 'Stop listening' : 'Voice input',
  ),
),
```

**Step 6: flutter analyze**

```
flutter analyze lib/screens/manual_entry_form_screen.dart
```
Expected: `No issues found!`

**Step 7: Commit**

```bash
git add lib/screens/manual_entry_form_screen.dart
git commit -m "$(cat <<'EOF'
feat: voice-to-text description input in Manual Entry

Mic button on Description field. Tap to start speech_to_text listening
(button pulses red-amber). Transcript appended to existing text.
30s timeout, 5s pause detection. Requires microphone permission.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Coin AI Confidence Ring

**Files:**
- Modify: `lib/screens/ai_recognition_screen.dart`

**Step 1: Add AnimationController**

In `_AIRecognitionScreenState`, the class already has state. Make it use `TickerProviderStateMixin` if it doesn't already:

Find:
```dart
class _AIRecognitionScreenState extends State<AIRecognitionScreen> {
```
Change to:
```dart
class _AIRecognitionScreenState extends State<AIRecognitionScreen>
    with SingleTickerProviderStateMixin {
```

Add field after `_isSignificant`:
```dart
  late AnimationController _ringController;
  late Animation<double> _ringAnimation;
```

**Step 2: Initialize and dispose**

In `initState()`, add:
```dart
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _ringAnimation = CurvedAnimation(parent: _ringController, curve: Curves.easeOut);
```

In `dispose()` (add it if it doesn't exist, or append):
```dart
    _ringController.dispose();
```

**Step 3: Trigger animation when result arrives**

Find where `_coinResult` is set in `setState`. It will be in `_classifyCoin()` or similar. After `_coinResult = result;` (inside setState), add:
```dart
              _ringController.forward(from: 0);
```

Also in `_reset()` where `_coinResult = null`, add:
```dart
              _ringController.reset();
```

**Step 4: Replace confidence text with ring widget**

Find the widget that displays `_coinResult!.confidence` (look for `'${_coinResult!.confidence}%'` or similar). Replace it with a `_buildConfidenceRing()` call.

Add this method to `_AIRecognitionScreenState`:

```dart
  Widget _buildConfidenceRing() {
    final confidence = _coinResult!.confidence / 100.0;
    final color = confidence >= 0.70
        ? Colors.green
        : confidence >= 0.50
            ? const Color(0xFFFFC107)
            : Colors.red;
    return AnimatedBuilder(
      animation: _ringAnimation,
      builder: (_, __) {
        final animated = _ringAnimation.value * confidence;
        return SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: animated,
                backgroundColor: Colors.white12,
                valueColor: AlwaysStoppedAnimation<Color>(color),
                strokeWidth: 8,
              ),
              Text(
                '${(_ringAnimation.value * _coinResult!.confidence).round()}%',
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
```

**Step 5: flutter analyze**

```
flutter analyze lib/screens/ai_recognition_screen.dart
```
Expected: `No issues found!`

**Step 6: Commit**

```bash
git add lib/screens/ai_recognition_screen.dart
git commit -m "$(cat <<'EOF'
feat: animated confidence ring on Coin AI result

Circular progress indicator animates from 0 to confidence value over 1s.
Green ≥70%, amber 50-69%, red <50%. Percentage shown in centre.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Vibration Calibration Baseline

**Files:**
- Modify: `lib/services/settings_service.dart`
- Modify: `lib/screens/safety/safety_view.dart`

**Step 1: Add `calibrationBaselinePpv` to `SettingsService`**

In `lib/services/settings_service.dart`:

Find the `AppSettings` class. After `final String lockedSensorMac;`, add:
```dart
  final double calibrationBaselinePpv;
```

In the constructor, after `this.lockedSensorMac = '',`, add:
```dart
    this.calibrationBaselinePpv = 0.0,
```

In `copyWith`, after `String? lockedSensorMac,`, add:
```dart
    double? calibrationBaselinePpv,
```

In the `copyWith` return, after `lockedSensorMac: lockedSensorMac ?? this.lockedSensorMac,`, add:
```dart
        calibrationBaselinePpv: calibrationBaselinePpv ?? this.calibrationBaselinePpv,
```

In `toJson()`, after `'lockedSensorMac': lockedSensorMac,`, add:
```dart
        'calibrationBaselinePpv': calibrationBaselinePpv,
```

In `fromJson()`, after `lockedSensorMac: json['lockedSensorMac'] ?? '',`, add:
```dart
        calibrationBaselinePpv: (json['calibrationBaselinePpv'] ?? 0.0).toDouble(),
```

In the `updateSetting` switch, after the `lockedSensorMac` case, add:
```dart
      case 'calibrationBaselinePpv':
        _settings = _settings.copyWith(calibrationBaselinePpv: value as double);
        break;
```

**Step 2: Add calibration state and logic to `safety_view.dart`**

In `_SafetyViewState`, add fields after `_alertHistory`:
```dart
  bool _isCalibrating = false;
  final List<double> _calibrationSamples = [];
  final _settingsServiceCal = SettingsService();
```

Add this method:
```dart
  Future<void> _startCalibration() async {
    if (_isCalibrating) return;
    setState(() {
      _isCalibrating = true;
      _calibrationSamples.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Calibrating… keep sensor still for 5 seconds'),
        duration: Duration(seconds: 5),
      ),
    );
    await Future.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    final mean = _calibrationSamples.isEmpty
        ? 0.0
        : _calibrationSamples.fold(0.0, (a, b) => a + b) / _calibrationSamples.length;
    await _settingsServiceCal.updateSetting('calibrationBaselinePpv', mean);
    setState(() => _isCalibrating = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Baseline set: ${mean.toStringAsFixed(3)} mm/s')),
      );
    }
  }
```

**Step 3: Collect PPV samples during calibration**

In the BLE data handler where `_ppv` is updated (search for `_ppv =` assignment inside `setState`), add after the assignment:
```dart
              if (_isCalibrating) _calibrationSamples.add(_ppv);
```

**Step 4: Subtract baseline from threshold comparisons**

Find the PPV threshold check (around `if (_ppv > 3.0)`). Replace `_ppv` in the comparison with `_effectivePpv`. Add a getter to `_SafetyViewState`:
```dart
  double get _effectivePpv {
    final baseline = SettingsService().settings.calibrationBaselinePpv;
    return (_ppv - baseline).clamp(0.0, double.infinity);
  }
```

Replace the threshold check:
```dart
if (_ppv > 3.0) {
```
with:
```dart
if (_effectivePpv > 3.0) {
```

**Step 5: Add Calibrate button to Safety header**

In the Safety tab header (where the History button was added in Task 1), add after the history `IconButton`:
```dart
                TextButton.icon(
                  onPressed: _isCalibrating ? null : _startCalibration,
                  icon: Icon(
                    _isCalibrating ? Icons.hourglass_top : Icons.tune_rounded,
                    size: 16,
                    color: _isCalibrating ? Colors.white38 : Colors.white70,
                  ),
                  label: Text(
                    _isCalibrating ? 'Calibrating…' : 'Calibrate',
                    style: TextStyle(
                      color: _isCalibrating ? Colors.white38 : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),
```

**Step 6: flutter analyze**

```
flutter analyze lib/services/settings_service.dart lib/screens/safety/safety_view.dart
```
Expected: `No issues found!`

**Step 7: Full tests**

```
flutter test --reporter=compact 2>&1 | python -c "import sys; lines=sys.stdin.readlines(); print(lines[-1].strip())"
```
Expected: `All tests passed!`

**Step 8: Commit**

```bash
git add lib/services/settings_service.dart lib/screens/safety/safety_view.dart
git commit -m "$(cat <<'EOF'
feat: vibration calibration baseline on Safety tab

5-second ambient sampling computes mean PPV baseline, stored in settings.
Effective PPV = raw - baseline, preventing ambient vibration false triggers.
Calibrate button in Safety header with hourglass state during sampling.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Offline Demo Mode

**Files:**
- Create: `assets/data/demo_findings.json`
- Modify: `pubspec.yaml` (add assets/data/ path)
- Modify: `lib/screens/findings_view.dart`

**Step 1: Create demo findings asset**

Create `assets/data/demo_findings.json`:

```json
[
  {
    "id": "demo_001",
    "name": "Bronze Coin — Macedonian",
    "type": "Coin",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-01",
    "description": "Well-preserved bronze coin, obverse shows head of Apollo, reverse depicts tripod. Diameter 18mm.",
    "latitude": 38.7201,
    "longitude": 22.8734,
    "source": "photo",
    "isSignificant": true,
    "createdAt": "2026-03-01T09:15:00Z"
  },
  {
    "id": "demo_002",
    "name": "Ceramic Fragment — Black-Figure",
    "type": "Fragment",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-01",
    "description": "Body fragment of black-figure ware. Depicts running figure, possibly athlete. Corinthian fabric.",
    "latitude": 38.7198,
    "longitude": 22.8741,
    "source": "manual",
    "isSignificant": true,
    "createdAt": "2026-03-01T10:30:00Z"
  },
  {
    "id": "demo_003",
    "name": "Iron Nail",
    "type": "Metal",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-01",
    "description": "Heavily corroded iron nail, L=8cm. Found in burnt destruction layer. Roman period context.",
    "latitude": 38.7195,
    "longitude": 22.8728,
    "source": "manual",
    "isSignificant": false,
    "createdAt": "2026-03-01T11:00:00Z"
  },
  {
    "id": "demo_004",
    "name": "Stone Foundation Block",
    "type": "Structure",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-01",
    "description": "Limestone ashlar block, in situ. Part of temple foundation. 60x40x30cm. Classical period.",
    "latitude": 38.7205,
    "longitude": 22.8750,
    "source": "manual",
    "isSignificant": false,
    "createdAt": "2026-03-01T13:45:00Z"
  },
  {
    "id": "demo_005",
    "name": "Silver Tetradrachm — Athens",
    "type": "Coin",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-02",
    "description": "Athenian tetradrachm, Athena obverse / owl reverse. 5th century BC. Exceptional condition.",
    "latitude": 38.7202,
    "longitude": 22.8736,
    "source": "photo",
    "isSignificant": true,
    "createdAt": "2026-03-02T09:00:00Z"
  },
  {
    "id": "demo_006",
    "name": "Animal Bone — Bovine",
    "type": "Bone",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-02",
    "description": "Bovine femur fragment. Possible ritual deposit near altar area. Cut marks visible.",
    "latitude": 38.7196,
    "longitude": 22.8743,
    "source": "quick",
    "isSignificant": false,
    "createdAt": "2026-03-02T10:15:00Z"
  },
  {
    "id": "demo_007",
    "name": "Ceramic Lamp Fragment",
    "type": "Fragment",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-02",
    "description": "Wheel-thrown oil lamp nozzle, blackened from use. Hellenistic period. Standard Attic type.",
    "latitude": 38.7199,
    "longitude": 22.8730,
    "source": "manual",
    "isSignificant": false,
    "createdAt": "2026-03-02T11:30:00Z"
  },
  {
    "id": "demo_008",
    "name": "Bronze Fibula",
    "type": "Metal",
    "site": "Kalapodi Temple Site",
    "date": "2026-03-02",
    "description": "Complete bronze bow fibula, spring intact. Early Iron Age type. Possible votive offering.",
    "latitude": 38.7203,
    "longitude": 22.8747,
    "source": "manual",
    "isSignificant": true,
    "createdAt": "2026-03-02T14:00:00Z"
  }
]
```

**Step 2: Register asset in `pubspec.yaml`**

In `pubspec.yaml`, in the `assets:` block, add:
```yaml
    - assets/data/
```

**Step 3: Add demo mode state to `FindingsViewState`**

In `lib/screens/findings_view.dart`, add fields after `_isLoading`:
```dart
  bool _isDemoMode = false;
```

**Step 4: Update Firestore load to fall back to demo data**

Find `_loadFindings()`. The Firestore call currently throws on error and shows a SnackBar. Update the catch block:

After the existing catch that sets `_isLoading = false`, replace or augment it to also call `_loadDemoFindings()`:

```dart
    } catch (e) {
      debugPrint('Error loading findings: $e');
      if (mounted) {
        await _loadDemoFindings();
      }
    }
```

Add this method:
```dart
  Future<void> _loadDemoFindings() async {
    try {
      final raw = await rootBundle.loadString('assets/data/demo_findings.json');
      final list = jsonDecode(raw) as List;
      final findings = list.map((data) => Finding(
        id: data['id'],
        name: data['name'],
        type: data['type'],
        site: data['site'],
        date: data['date'],
        description: data['description'],
        latitude: (data['latitude'] ?? 0.0).toDouble(),
        longitude: (data['longitude'] ?? 0.0).toDouble(),
        source: FindingSource.fromString(data['source']),
        photoGallery: [],
        isSignificant: data['isSignificant'] ?? false,
      )).toList();
      setState(() {
        _findings = findings;
        _filteredFindings = findings;
        _isLoading = false;
        _isDemoMode = true;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }
```

Add the import at top of `findings_view.dart`:
```dart
import 'package:flutter/services.dart';
import 'dart:convert';
```

**Step 5: Show Demo Mode banner**

In `build()`, find where the findings list starts (after the filter chips). Add above the list:
```dart
              if (_isDemoMode)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFC107).withAlpha(40),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFC107).withAlpha(100)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off_rounded, color: Color(0xFFFFC107), size: 14),
                      SizedBox(width: 6),
                      Text('Demo Mode — offline sample data',
                          style: TextStyle(color: Color(0xFFFFC107), fontSize: 12)),
                    ],
                  ),
                ),
```

**Step 6: Block write operations in demo mode**

In `_saveFinding()` (or wherever findings are saved to Firestore), add a guard at the start:
```dart
    if (_isDemoMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Demo mode — connect to save findings')),
      );
      return;
    }
```

**Step 7: flutter analyze**

```
flutter analyze lib/screens/findings_view.dart
```
Expected: `No issues found!`

**Step 8: Commit**

```bash
git add assets/data/demo_findings.json pubspec.yaml lib/screens/findings_view.dart
git commit -m "$(cat <<'EOF'
feat: offline demo mode with Kalapodi sample findings

If Firestore fetch fails, loads 8 pre-built Kalapodi findings from asset.
Amber 'Demo Mode' banner shown. Write operations blocked in demo mode.
Ensures demo works regardless of venue WiFi.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Site Management

**Files:**
- Create: `lib/services/site_service.dart`
- Create: `test/services/site_service_test.dart`
- Modify: `lib/screens/findings_view.dart`
- Modify: `lib/screens/manual_entry_form_screen.dart`
- Modify: `lib/screens/quick_capture_screen.dart`
- Modify: `lib/screens/ai_recognition_screen.dart`
- Modify: `lib/screens/dashboard_home_view.dart`

**Step 1: Write failing tests**

Create `test/services/site_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ancient_vision/services/site_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SiteService', () {
    test('getSites returns empty list initially', () async {
      final svc = SiteService();
      expect(await svc.getSites(), isEmpty);
    });

    test('addSite stores a site', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      expect(await svc.getSites(), contains('Kalapodi'));
    });

    test('setActiveSite persists active site', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      await svc.setActiveSite('Kalapodi');
      expect(await svc.getActiveSite(), 'Kalapodi');
    });

    test('removeSite removes from list', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      await svc.removeSite('Kalapodi');
      expect(await svc.getSites(), isEmpty);
    });

    test('removeSite clears activeSite if it was the active one', () async {
      final svc = SiteService();
      await svc.addSite('Kalapodi');
      await svc.setActiveSite('Kalapodi');
      await svc.removeSite('Kalapodi');
      expect(await svc.getActiveSite(), '');
    });
  });
}
```

**Step 2: Run tests to verify they fail**

```
flutter test test/services/site_service_test.dart --reporter=compact
```
Expected: FAIL

**Step 3: Create `lib/services/site_service.dart`**

```dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SiteService {
  static const _sitesKey = 'site_list';
  static const _activeKey = 'active_site';

  Future<List<String>> getSites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sitesKey);
    if (raw == null) return [];
    return List<String>.from(jsonDecode(raw));
  }

  Future<String> getActiveSite() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey) ?? '';
  }

  Future<void> addSite(String name) async {
    final sites = await getSites();
    if (sites.contains(name)) return;
    sites.add(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sitesKey, jsonEncode(sites));
  }

  Future<void> setActiveSite(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, name);
  }

  Future<void> removeSite(String name) async {
    final sites = await getSites();
    sites.remove(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sitesKey, jsonEncode(sites));
    final active = await getActiveSite();
    if (active == name) await prefs.setString(_activeKey, '');
  }
}
```

**Step 4: Run tests to verify they pass**

```
flutter test test/services/site_service_test.dart --reporter=compact
```
Expected: `+5: All tests passed!`

**Step 5: Add site selector to `FindingsView` header**

In `lib/screens/findings_view.dart`:

Add import:
```dart
import '../services/site_service.dart';
```

Add fields to `FindingsViewState`:
```dart
  final _siteService = SiteService();
  String _activeSite = '';
```

In `initState()`, add:
```dart
    _siteService.getActiveSite().then((s) {
      if (mounted) setState(() => _activeSite = s);
    });
```

Add `_showSiteSelector` method:
```dart
  void _showSiteSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C2523),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: FutureBuilder<List<String>>(
          future: _siteService.getSites(),
          builder: (ctx, snap) {
            final sites = snap.data ?? [];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Select Site',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ...sites.map((s) => ListTile(
                  title: Text(s, style: const TextStyle(color: Colors.white)),
                  trailing: _activeSite == s
                      ? const Icon(Icons.check, color: Color(0xFFFFC107))
                      : null,
                  onTap: () async {
                    await _siteService.setActiveSite(s);
                    if (mounted) setState(() => _activeSite = s);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                )),
                const Divider(color: Colors.white12),
                ListTile(
                  leading: const Icon(Icons.add, color: Color(0xFFFFC107)),
                  title: const Text('New site…', style: TextStyle(color: Color(0xFFFFC107))),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final name = await _showNewSiteDialog(context);
                    if (name != null && name.isNotEmpty) {
                      await _siteService.addSite(name);
                      await _siteService.setActiveSite(name);
                      if (mounted) setState(() => _activeSite = name);
                    }
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<String?> _showNewSiteDialog(BuildContext context) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: const Text('New Site', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Site name (e.g. Kalapodi Trench A)',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add', style: TextStyle(color: Color(0xFFFFC107))),
          ),
        ],
      ),
    );
  }
```

In the `build()` method, find the search bar row (with the search TextField). Add a site chip before or after it:

```dart
              // Active site chip
              if (_activeSite.isNotEmpty)
                GestureDetector(
                  onTap: () => _showSiteSelector(context),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withAlpha(50)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.location_on_rounded, color: Color(0xFFFFC107), size: 14),
                        const SizedBox(width: 4),
                        Text(_activeSite,
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more, color: Colors.white38, size: 14),
                      ],
                    ),
                  ),
                )
              else
                GestureDetector(
                  onTap: () => _showSiteSelector(context),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_location_alt_rounded, color: Colors.white54, size: 14),
                        SizedBox(width: 4),
                        Text('Set site', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
```

**Step 6: Pre-fill site in all 3 entry screens**

In each of `manual_entry_form_screen.dart`, `quick_capture_screen.dart`, `ai_recognition_screen.dart`:

Add import:
```dart
import '../services/site_service.dart';
```

In `initState()`, add:
```dart
    SiteService().getActiveSite().then((site) {
      if (mounted && site.isNotEmpty) {
        _siteController.text = site; // manual_entry uses _siteController
        // quick_capture uses _selectedSite or similar — check the field name
      }
    });
```

(For `quick_capture_screen.dart` and `ai_recognition_screen.dart`, check the actual field name for site and pre-fill accordingly.)

**Step 7: Show active site on Dashboard**

In `lib/screens/dashboard_home_view.dart`, add field:
```dart
  String _activeSite = '';
```

In `initState()`, add:
```dart
    SiteService().getActiveSite().then((s) {
      if (mounted) setState(() => _activeSite = s);
    });
```

Add import:
```dart
import '../services/site_service.dart';
```

In `build()`, find the greeting/header text. Add below it:
```dart
                if (_activeSite.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.location_on_rounded, color: Color(0xFFFFC107), size: 14),
                        const SizedBox(width: 4),
                        Text(_activeSite,
                            style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
```

**Step 8: flutter analyze**

```
flutter analyze lib/services/site_service.dart lib/screens/findings_view.dart lib/screens/manual_entry_form_screen.dart lib/screens/quick_capture_screen.dart lib/screens/ai_recognition_screen.dart lib/screens/dashboard_home_view.dart
```
Expected: `No issues found!`

**Step 9: Full tests**

```
flutter test --reporter=compact 2>&1 | python -c "import sys; lines=sys.stdin.readlines(); print(lines[-1].strip())"
```
Expected: `All tests passed!`

**Step 10: Commit**

```bash
git add lib/services/site_service.dart \
        test/services/site_service_test.dart \
        lib/screens/findings_view.dart \
        lib/screens/manual_entry_form_screen.dart \
        lib/screens/quick_capture_screen.dart \
        lib/screens/ai_recognition_screen.dart \
        lib/screens/dashboard_home_view.dart
git commit -m "$(cat <<'EOF'
feat: site management — create, switch, and pre-fill active site

SiteService persists site list and active site via SharedPreferences.
Site selector chip in Findings header. Active site pre-filled in all
3 entry screens. Active site shown on Dashboard below greeting.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Final Verify

**Step 1: Full flutter analyze**

```
flutter analyze
```
Expected: `No issues found!`

**Step 2: Full test suite**

```
flutter test --reporter=compact 2>&1 | python -c "import sys; lines=sys.stdin.readlines(); print(lines[-1].strip())"
```
Expected: `All tests passed!`

**Step 3: Push**

```bash
git push
```
