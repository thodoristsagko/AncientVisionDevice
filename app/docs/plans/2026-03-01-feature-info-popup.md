# Feature Info Popup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show a small popup card with a GIS feature's label when the user taps a polygon or point on the map.

**Architecture:** Add `String? _selectedFeatureLabel` state to `_FindingsMapState`. Polygon widgets get an `onTap` callback; GeoJson point markers get a `GestureDetector`. Tapping the map background (via `MapOptions.onTap`) clears the selection. A `Positioned` card renders at the bottom-center of the map stack when a label is selected. No model or service changes needed.

**Tech Stack:** Flutter, flutter_map (`Polygon.onTap`, `MapOptions.onTap`), existing `_LayerEntry` / `GeoJsonLayer` models.

---

### Task 1: Add state field and map-tap dismiss

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Step 1: Add state field**

In `_FindingsMapState`, alongside the other bool fields (around line 33), add:
```dart
String? _selectedFeatureLabel;
```

**Step 2: Wire `MapOptions.onTap` to clear selection**

In `build()`, find the `MapOptions(...)` block inside `FlutterMap`. Add the `onTap` callback:
```dart
options: MapOptions(
  initialCenter: LatLng(firstFinding.latitude, firstFinding.longitude),
  initialZoom: 17.5,
  minZoom: 4,
  maxZoom: 19,
  interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
  onTap: (_, __) => setState(() => _selectedFeatureLabel = null),
),
```

**Step 3: Verify**

Read the file and confirm:
- `String? _selectedFeatureLabel;` field exists in state
- `MapOptions` has `onTap: (_, __) => setState(() => _selectedFeatureLabel = null)`

Do NOT commit yet.

---

### Task 2: Wire polygon onTap

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Context:** `_buildGeoJsonPolygons()` returns `List<Polygon>`. The `Polygon` widget in flutter_map accepts an `onTap` callback of type `void Function()`.

**Step 1: Update `_buildGeoJsonPolygons`**

Replace the full method with:
```dart
List<Polygon> _buildGeoJsonPolygons() {
  return _entries
      .where((e) => e.visible)
      .expand((e) => e.layer.polygons.map((p) => Polygon(
            points: p.points,
            color: const Color(0x33FFC107),
            borderColor: const Color(0xFFFFC107),
            borderStrokeWidth: 2,
            isFilled: true,
            label: p.label,
            labelStyle: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            onTap: () => setState(() => _selectedFeatureLabel = p.label),
          )))
      .toList();
}
```

**Step 2: Verify**

Confirm `onTap: () => setState(() => _selectedFeatureLabel = p.label)` is present in the Polygon constructor.

Do NOT commit yet.

---

### Task 3: Wire GeoJson point marker onTap

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Context:** `_buildGeoJsonPointMarkers()` currently wraps each point in a `Tooltip`. We need to add a tap handler. Replace `Tooltip` with a `GestureDetector` wrapping the icon.

**Step 1: Update `_buildGeoJsonPointMarkers`**

Replace the full method with:
```dart
List<Marker> _buildGeoJsonPointMarkers() {
  return _entries
      .where((e) => e.visible)
      .expand((e) => e.layer.points.map((p) => Marker(
            point: p.position,
            width: 30,
            height: 30,
            child: GestureDetector(
              onTap: () => setState(() => _selectedFeatureLabel = p.label),
              child: Tooltip(
                message: p.label ?? '',
                child: const Icon(Icons.place, color: Color(0xFFFF9800), size: 28),
              ),
            ),
          )))
      .toList();
}
```

**Step 2: Verify**

Confirm `GestureDetector` wraps `Tooltip` in the point marker builder and `onTap` sets `_selectedFeatureLabel`.

Do NOT commit yet.

---

### Task 4: Build the popup card

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Context:** The `build()` method returns a `Stack`. We add a new `Positioned` child at the bottom-center that renders when `_selectedFeatureLabel != null`. It sits above the existing Google Maps button (which is at `bottom: 12, right: 12`).

**Step 1: Add the popup Positioned block**

In the `Stack`'s `children` list (inside `build()`), add this **after** the Google Maps button Positioned block and **before** the closing `],` of the children array:

```dart
// Feature info popup
if (_selectedFeatureLabel != null)
  Positioned(
    bottom: 56,
    left: 12,
    right: 12,
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(210),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, color: Color(0xFFFFC107), size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _selectedFeatureLabel!,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _selectedFeatureLabel = null),
              child: const Icon(Icons.close, color: Colors.white54, size: 16),
            ),
          ],
        ),
      ),
    ),
  ),
```

**Step 2: Verify**

Read the build method and confirm the popup Positioned block appears in the Stack children.

---

### Task 5: Analyze, test, commit

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`
- Modify: `docs/plans/2026-03-01-feature-info-popup.md`

**Step 1: Run flutter analyze**

```
flutter analyze lib/screens/findings_map_screen.dart
```
Expected: `No issues found!`

Fix any issues before continuing.

**Step 2: Run full test suite**

```
flutter test --reporter=compact
```
Expected: all 237 tests pass.

**Step 3: Commit**

```bash
git add lib/screens/findings_map_screen.dart docs/plans/2026-03-01-feature-info-popup.md
git commit -m "$(cat <<'EOF'
feat: feature info popup on polygon and point tap

Tapping a GeoJson polygon or point shows a bottom-center card with
the feature label. Tapping the map background or the × button dismisses it.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```
