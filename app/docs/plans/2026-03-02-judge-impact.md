# Judge Impact — Visual Polish Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the app immediately impressive to competition judges with a redesigned Tools tab hero layout and animated polish across Dashboard, Findings, and Safety tabs.

**Architecture:** 4 independent tasks, each touching a different file. Tasks 1–4 can run in parallel. All changes are pure UI — no new services, no new packages, no new tests (existing 264 pass).

**Tech Stack:** Flutter, `AnimationController`, `TweenAnimationBuilder`, existing `FindingSource` enum colors/icons.

---

### Task 1: Tools Tab Hero Redesign

**Files:**
- Modify: `lib/screens/tools_view.dart`

**Step 1: Read the full file**

```
Read lib/screens/tools_view.dart fully before editing anything.
```

Understand the current layout: Documentation section (Field Journal big button + Quick Capture / Manual Entry grid), AI & 3D section (Coin AI only), Data & Reports section (Analytics / Export / PDF Report), Settings section, Admin section.

**Step 2: Add `HeroToolCard` widget class**

Add this class at the bottom of `tools_view.dart`, just before the existing `class ToolCard`:

```dart
class HeroToolCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback onTap;

  const HeroToolCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.statusLabel,
    required this.statusColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [color.withAlpha(38), Colors.white.withAlpha(8)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: color.withAlpha(50),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withAlpha(160), fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: statusColor.withAlpha(80)),
              ),
              child: Text(statusLabel,
                  style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}
```

**Step 3: Add `_buildFeaturedSection` method to `ToolsView`**

Add this method to the `ToolsView` class (alongside `_buildToolGrid`, `_buildCategoryHeader`, etc.):

```dart
  Widget _buildFeaturedSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCategoryHeader('Featured'),
        const SizedBox(height: 10),
        HeroToolCard(
          icon: Icons.monetization_on_rounded,
          color: const Color(0xFF7C4DFF),
          title: 'Coin AI Recognition',
          subtitle: 'Identify coins using Google Gemini AI',
          statusLabel: 'Gemini AI',
          statusColor: const Color(0xFF4CAF50),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AIRecognitionScreen()),
          ),
        ),
        HeroToolCard(
          icon: Icons.flash_on_rounded,
          color: const Color(0xFF2196F3),
          title: 'Quick Capture',
          subtitle: 'Record a finding in seconds',
          statusLabel: 'Instant',
          statusColor: const Color(0xFF2196F3),
          onTap: () async {
            final result = await Navigator.push<Map<String, dynamic>>(
              context,
              MaterialPageRoute(builder: (_) => const QuickCaptureScreen()),
            );
            if (result != null && context.mounted) {
              _handleQuickCaptureResult(context, result);
            }
          },
        ),
        HeroToolCard(
          icon: Icons.picture_as_pdf_rounded,
          color: const Color(0xFFE53935),
          title: 'PDF Report',
          subtitle: 'Export all findings as a shareable report',
          statusLabel: 'Ready',
          statusColor: const Color(0xFF4CAF50),
          onTap: () async {
            try {
              await PdfExportService().exportFindingsReport(context);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Export failed: $e')),
                );
              }
            }
          },
        ),
        const SizedBox(height: 18),
      ],
    );
  }
```

**Step 4: Insert `_buildFeaturedSection` into `build()`**

In `build()`, find:
```dart
                    const SizedBox(height: 24),

                    // === DOCUMENTATION (merged Field Work + Capture) ===
```

Replace with:
```dart
                    const SizedBox(height: 24),
                    _buildFeaturedSection(context),

                    // === DOCUMENTATION (merged Field Work + Capture) ===
```

**Step 5: Remove Quick Capture from Documentation grid**

Find in `build()`:
```dart
                      _buildToolGrid(context, [
                        ToolCard(
                          icon: Icons.flash_on_rounded,
                          title: 'Quick Capture',
                          description: 'Photo + note, instantly',
                          color: const Color(0xFF2196F3),
                          onTap: () async {
                            final result = await Navigator.push<Map<String, dynamic>>(
                              context,
                              MaterialPageRoute(builder: (_) => const QuickCaptureScreen()),
                            );
                            if (result != null && context.mounted) {
                              _handleQuickCaptureResult(context, result);
                            }
                          },
                        ),
                        ToolCard(
                          icon: Icons.edit_note_rounded,
                          title: 'Manual Entry',
                          description: 'Full recording form',
                          color: const Color(0xFFFFC107),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ManualEntryFormScreen()),
                          ),
                        ),
                      ]),
```

Replace with (keep only Manual Entry):
```dart
                      _buildToolGrid(context, [
                        ToolCard(
                          icon: Icons.edit_note_rounded,
                          title: 'Manual Entry',
                          description: 'Full recording form',
                          color: const Color(0xFFFFC107),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ManualEntryFormScreen()),
                          ),
                        ),
                      ]),
```

**Step 6: Remove the entire "AI & 3D" section**

Find and remove this entire block (it now only duplicates the hero card):
```dart
                      // === AI & 3D ===
                      _buildCategoryHeader('AI & 3D'),
                      const SizedBox(height: 10),
                      _buildToolGrid(context, [
                        ToolCard(
                          icon: Icons.monetization_on_rounded,
                          title: 'Coin AI',
                          description: 'AI coin identification',
                          color: const Color(0xFF7C4DFF),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const AIRecognitionScreen()),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 18),
```

**Step 7: Remove PDF Report from Data & Reports grid**

Find in the Data & Reports grid:
```dart
                        ToolCard(
                          icon: Icons.picture_as_pdf_rounded,
                          title: 'PDF Report',
                          description: 'Share full findings report',
                          color: const Color(0xFFE53935),
                          onTap: () async {
                            try {
                              await PdfExportService().exportFindingsReport(context);
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Export failed: $e')),
                                );
                              }
                            }
                          },
                        ),
```

Remove that entire ToolCard block (Analytics and Export Data remain).

**Step 8: flutter analyze**

```
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
flutter analyze lib/screens/tools_view.dart
```
Expected: `No issues found!`

**Step 9: Commit**

```bash
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
git add lib/screens/tools_view.dart
git commit -m "$(cat <<'EOF'
feat: Tools tab hero cards for Coin AI, Quick Capture, PDF Report

Adds three full-width HeroToolCard widgets with gradient background,
subtitle, and status badge. Removes duplicated cards from utility grid.
Featured section appears first for immediate judge impact.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Dashboard Animated Counters

**Files:**
- Modify: `lib/screens/dashboard_home_view.dart`

**Step 1: Read the file**

Read `lib/screens/dashboard_home_view.dart` in full. Find where `_totalFindings`, `_todayFindings`, and `_significantFindings` are rendered as `Text` widgets. They are inside the `_buildStatsCard()` method, rendered via `_statChip(label, value, color)`.

**Step 2: Locate `_statChip`**

Find the `_statChip` method. It currently looks like:

```dart
  Widget _statChip(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }
```

**Step 3: Replace `_statChip` with animated version**

Replace the entire `_statChip` method with one that takes an `int` instead of a `String` and animates it:

```dart
  Widget _statChip(String label, int value, Color color) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOut,
      builder: (_, animated, __) => Column(
        children: [
          Text(
            animated.round().toString(),
            style: TextStyle(
                color: color, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }
```

**Step 4: Update `_buildStatsCard` call sites**

In `_buildStatsCard()`, find the three `_statChip` calls that currently pass strings:
```dart
                      _statChip('Total', _totalFindings.toString(), Colors.white70),
                      _statChip('Significant', _significantFindings.toString(), const Color(0xFFFFC107)),
                      _statChip('Today', _todayFindings.toString(), const Color(0xFF2196F3)),
```

Replace with (pass `int` directly — no `.toString()`):
```dart
                      _statChip('Total', _totalFindings, Colors.white70),
                      _statChip('Significant', _significantFindings, const Color(0xFFFFC107)),
                      _statChip('Today', _todayFindings, const Color(0xFF2196F3)),
```

**Step 5: flutter analyze**

```
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
flutter analyze lib/screens/dashboard_home_view.dart
```
Expected: `No issues found!`

**Step 6: Commit**

```bash
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
git add lib/screens/dashboard_home_view.dart
git commit -m "$(cat <<'EOF'
feat: animate dashboard stat counters from 0 to value on load

TweenAnimationBuilder drives Total/Significant/Today counters over
800ms with easeOut curve. Makes the stats feel live, not static.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Findings Source Badges

**Files:**
- Modify: `lib/screens/findings_view.dart`

**Step 1: Read the finding card area**

Read `lib/screens/findings_view.dart` around lines 794–920. The finding card `Row` has this structure:
1. Type color bar (4px strip)
2. `SizedBox(width: 12)`
3. `Expanded` info column (id + name row, type/site/date row)
4. 3D badge (conditional)
5. `SizedBox(width: 8)`
6. Forward arrow `GestureDetector`

You will add a source badge **between the Expanded column and the 3D badge** (after the `),` that closes the Expanded, before the `// 3D model indicator` comment).

**Step 2: Add `_sourceBadge` helper method**

Add this method to `FindingsViewState` (alongside other helper methods):

```dart
  Widget _sourceBadge(FindingSource source) {
    final label = source == FindingSource.manual
        ? 'Manual'
        : source == FindingSource.photo
            ? 'AI'
            : 'Quick';
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: source.color.withAlpha(40),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: source.color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(source.icon, color: source.color, size: 9),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  color: source.color,
                  fontSize: 9,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
```

**Step 3: Insert badge into finding card**

In the finding card `Row`, find the line that closes the `Expanded` column:

```dart
                                      ),
                                      // 3D model indicator
                                      if (f.model3dUrl != null)
```

Insert `_sourceBadge(f.source),` between the closing `)` and the 3D badge comment:

```dart
                                      ),
                                      _sourceBadge(f.source),
                                      // 3D model indicator
                                      if (f.model3dUrl != null)
```

**Step 4: flutter analyze**

```
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
flutter analyze lib/screens/findings_view.dart
```
Expected: `No issues found!`

**Step 5: Commit**

```bash
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
git add lib/screens/findings_view.dart
git commit -m "$(cat <<'EOF'
feat: source badges on finding cards (AI / Quick / Manual)

Colored pill badge on each finding card shows capture method.
Uses FindingSource enum colors and icons. Judges instantly see
the app captures findings three different ways.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Safety Tab Live Pulse Indicator

**Files:**
- Modify: `lib/screens/safety/safety_view.dart`

**Step 1: Read the file**

Read `lib/screens/safety/safety_view.dart`:
- Lines 1–60 (class declaration and imports)
- Lines 160–230 (initState and dispose)
- Search for `_connectionStatus` in the `build()` method to find where to add the dot

**Step 2: Add `TickerProviderStateMixin`**

Find the class declaration:
```dart
class _SafetyViewState extends State<SafetyView> with AutomaticKeepAliveClientMixin {
```

Replace with:
```dart
class _SafetyViewState extends State<SafetyView>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
```

**Step 3: Add `_pulseController` field**

After the existing calibration fields (`_isPpvCalibrating`, `_calibrationSamples`, `_settingsServiceCal`, `_kCalibrationSeconds`), add:
```dart
  late AnimationController _pulseController;
```

**Step 4: Initialize in `initState()`**

In `initState()`, after `super.initState()`, add:
```dart
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
```

**Step 5: Dispose in `dispose()`**

Find `dispose()`. Add `_pulseController.dispose();` as the FIRST line inside dispose (before the existing `_scanSubscription?.cancel()` etc.):
```dart
  @override
  void dispose() {
    _pulseController.dispose();
    _scanSubscription?.cancel();
    // ... rest of existing dispose
```

**Step 6: Add `_livePulseDot()` helper method**

Add this method to `_SafetyViewState`:

```dart
  Widget _livePulseDot() {
    final isConnected = _connectedDevice != null;
    if (!isConnected) {
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
```

**Step 7: Add dot to the Safety header**

In `build()`, search for the Safety tab header area where `_connectionStatus` or the device name is displayed. Look for a `Text` widget that shows the connection status string. Add `_livePulseDot()` with a small spacing immediately before it.

For example, if you find:
```dart
Text(_connectionStatus, style: ...)
```

Replace with:
```dart
Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    _livePulseDot(),
    const SizedBox(width: 6),
    Text(_connectionStatus, style: ...),
  ],
),
```

**IMPORTANT:** Read the actual build() method carefully to find the exact location. The `_connectionStatus` is shown somewhere in the Safety tab header. Find it and add the dot in a way that fits the existing layout (using Row if the text is standalone, or inserting the dot before the text if it's already in a Row).

**Step 8: flutter analyze + full test suite**

```
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
flutter analyze lib/screens/safety/safety_view.dart
```
Expected: `No issues found!`

```
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
flutter test --reporter=compact 2>&1 | python -c "import sys; lines=sys.stdin.readlines(); print(lines[-1].strip())"
```
Expected: `All tests passed!`

**Step 9: Push**

```bash
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
git add lib/screens/safety/safety_view.dart
git commit -m "$(cat <<'EOF'
feat: live pulse dot on Safety tab BLE connection status

Animated green dot pulses when device is connected, grey when
disconnected. Judges instantly know the sensor is live.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
git push
```
