# Coordinate Display Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show tapped map coordinates in the existing feature info popup card when the user taps empty map space.

**Architecture:** Add `bool _selectedIsCoord = false` to state. Change `_onMapTap` so a miss (no polygon hit) formats the `LatLng` as a coordinate string and sets it as `_selectedFeatureLabel` (with `_selectedIsCoord = true`) instead of clearing it. Feature taps set `_selectedIsCoord = false`. The popup card swaps its icon based on `_selectedIsCoord`. All changes are in `findings_map_screen.dart`; no new files or tests needed.

**Tech Stack:** Flutter, existing `_FindingsMapState` in `lib/screens/findings_map_screen.dart`.

---

### Task 1: Implement coordinate display

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Step 1: Add `_selectedIsCoord` state field**

In `_FindingsMapState`, alongside `String? _selectedFeatureLabel`, add:
```dart
bool _selectedIsCoord = false;
```

**Step 2: Update `_onMapTap` to show coordinates on a miss**

Find `_onMapTap`. It currently ends with something like:
```dart
setState(() => _selectedFeatureLabel = null);
```
(the fallback when no polygon is hit).

Replace that fallback `setState` call with:
```dart
setState(() {
  _selectedFeatureLabel =
      '${_formatCoord(tappedPoint.latitude, isLat: true)}, '
      '${_formatCoord(tappedPoint.longitude, isLat: false)}';
  _selectedIsCoord = true;
});
```

Also ensure that when a polygon IS hit inside `_onMapTap`, `_selectedIsCoord` is set to false:
```dart
setState(() {
  _selectedFeatureLabel = matchedLabel;
  _selectedIsCoord = false;
});
```

**Step 3: Add `_formatCoord` helper**

Add this private method alongside `_onMapTap`:
```dart
String _formatCoord(double value, {required bool isLat}) {
  final abs = value.abs();
  final dir = isLat
      ? (value >= 0 ? 'N' : 'S')
      : (value >= 0 ? 'E' : 'W');
  return '${abs.toStringAsFixed(5)}°$dir';
}
```

**Step 4: Update point marker taps to set `_selectedIsCoord = false`**

Find `_buildGeoJsonPointMarkers`. Each point marker has:
```dart
onTap: () => setState(() => _selectedFeatureLabel = p.label),
```
Replace with:
```dart
onTap: () => setState(() {
  _selectedFeatureLabel = p.label;
  _selectedIsCoord = false;
}),
```

**Step 5: Update the × close button to reset `_selectedIsCoord`**

Find the popup card's close `GestureDetector`:
```dart
onTap: () => setState(() => _selectedFeatureLabel = null),
```
Replace with:
```dart
onTap: () => setState(() {
  _selectedFeatureLabel = null;
  _selectedIsCoord = false;
}),
```

**Step 6: Update the popup card icon**

Find the popup card's leading icon:
```dart
const Icon(Icons.info_outline, color: Color(0xFFFFC107), size: 16),
```
Replace with:
```dart
Icon(
  _selectedIsCoord ? Icons.location_on : Icons.info_outline,
  color: const Color(0xFFFFC107),
  size: 16,
),
```

**Step 7: Verify**

Read the file and confirm:
- `_selectedIsCoord` field exists
- `_formatCoord` method exists
- `_onMapTap` miss path sets `_selectedIsCoord = true` with formatted coords
- `_onMapTap` hit path sets `_selectedIsCoord = false`
- Point marker tap sets `_selectedIsCoord = false`
- × button sets `_selectedIsCoord = false`
- Popup icon is conditional on `_selectedIsCoord`

Do NOT commit yet.

---

### Task 2: Analyze, test, commit

**Files:**
- `lib/screens/findings_map_screen.dart`
- `docs/plans/2026-03-01-coordinate-display.md`

**Step 1: flutter analyze**
```
flutter analyze lib/screens/findings_map_screen.dart
```
Expected: `No issues found!`

**Step 2: Full test suite**
```
flutter test --reporter=compact
```
Expected: `+255: All tests passed!`

**Step 3: Commit**
```bash
git add lib/screens/findings_map_screen.dart docs/plans/2026-03-01-coordinate-display.md
git commit -m "$(cat <<'EOF'
feat: show tapped coordinates in feature info popup

Tapping empty map space now shows lat/lon in the popup card instead
of dismissing it. Feature taps continue to show the feature label.
Icon switches between location_on and info_outline accordingly.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```
