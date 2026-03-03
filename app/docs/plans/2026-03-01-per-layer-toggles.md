# Per-Layer Toggles Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the single "GIS Layers" global toggle with per-layer checkboxes and delete buttons inside the map's layer panel.

**Architecture:** Introduce a private `_LayerEntry` wrapper in `findings_map_screen.dart` that pairs a `GeoJsonLayer` with `visible` and `isBundled` flags. Replace `_geoJsonLayers` + `_showGeoJsonLayers` with `List<_LayerEntry> _entries`. Update the three build methods to filter by `entry.visible`. Rebuild the layer panel rows. No new files needed.

**Tech Stack:** Flutter, flutter_map, GeoJsonService (SharedPreferences persistence)

---

### Task 1: Add `_LayerEntry` and migrate state

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Step 1: Add `_LayerEntry` class at the bottom of the file (before the closing `}`)**

Add after the `_layerToggle` widget method, still inside the State class — actually add it as a top-level private class at the very bottom of the file, after the State class closing brace:

```dart
class _LayerEntry {
  final GeoJsonLayer layer;
  bool visible;
  final bool isBundled;
  _LayerEntry({required this.layer, this.visible = true, this.isBundled = false});
}
```

**Step 2: Replace the two old fields with one list**

Old fields to remove:
```dart
bool _showGeoJsonLayers = true;
// ...
final List<GeoJsonLayer> _geoJsonLayers = [];
```

New field to add (near the other state fields):
```dart
final List<_LayerEntry> _entries = [];
```

**Step 3: Update `_loadGeoJsonLayers`**

Replace body with:
```dart
Future<void> _loadGeoJsonLayers() async {
  try {
    final sample = await _geoJsonService.loadBundled(
      'assets/geo/sample_trenches.geojson',
      name: 'Kalapodi Trenches',
    );
    final saved = await _geoJsonService.loadSavedLayers();
    if (mounted) {
      setState(() {
        _entries.add(_LayerEntry(layer: sample, isBundled: true));
        for (final l in saved) {
          _entries.add(_LayerEntry(layer: l));
        }
      });
    }
  } catch (e) {
    debugPrint('GeoJSON load error: $e');
  }
}
```

**Step 4: Update `_importGeoData` — replace `_geoJsonLayers.add(layer)` with `_entries.add(_LayerEntry(layer: layer))`**

Replace:
```dart
setState(() => _geoJsonLayers.add(layer));
```
With:
```dart
setState(() => _entries.add(_LayerEntry(layer: layer)));
```

Also update the camera-fit block: replace `layer.bounds` — no change needed there, `layer` variable still refers to the `GeoJsonLayer`.

**Step 5: Verify no references to `_geoJsonLayers` or `_showGeoJsonLayers` remain**

Run: `grep -n "_geoJsonLayers\|_showGeoJsonLayers" lib/screens/findings_map_screen.dart`
Expected: no output.

---

### Task 2: Update the three map-layer build methods

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Step 1: Replace `_buildGeoJsonPolygons`**

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
          )))
      .toList();
}
```

**Step 2: Replace `_buildGeoJsonPolylines`**

```dart
List<Polyline> _buildGeoJsonPolylines() {
  return _entries
      .where((e) => e.visible)
      .expand((e) => e.layer.polylines.map((p) => Polyline(
            points: p.points,
            color: const Color(0xFFFF9800),
            strokeWidth: 3,
          )))
      .toList();
}
```

**Step 3: Replace `_buildGeoJsonPointMarkers`**

```dart
List<Marker> _buildGeoJsonPointMarkers() {
  return _entries
      .where((e) => e.visible)
      .expand((e) => e.layer.points.map((p) => Marker(
            point: p.position,
            width: 30,
            height: 30,
            child: Tooltip(
              message: p.label ?? '',
              child: const Icon(Icons.place, color: Color(0xFFFF9800), size: 28),
            ),
          )))
      .toList();
}
```

---

### Task 3: Rebuild the layer panel UI

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Step 1: Replace the `if (_showLayerPanel)` Positioned block**

Keep the outer `Container` (width 200, same styling). Inside replace the `Column` children with:

```dart
Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    const Text('Layers',
        style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14)),
    const SizedBox(height: 8),
    _layerToggle(
        'Findings', _showFindings, (v) => setState(() => _showFindings = v)),
    if (_entries.isNotEmpty) ...[
      const Divider(color: Colors.white24, height: 16),
      ..._entries.map((e) => _layerRow(e)),
    ],
  ],
)
```

**Step 2: Add `_layerRow` widget method (alongside `_layerToggle`)**

Keep the UI simple — checkbox on the left, name+count in the middle, trash on the right:

```dart
Widget _layerRow(_LayerEntry entry) {
  final count = entry.layer.polygons.length +
      entry.layer.polylines.length +
      entry.layer.points.length;
  return Row(
    children: [
      SizedBox(
        width: 24,
        height: 24,
        child: Checkbox(
          value: entry.visible,
          onChanged: (v) => setState(() => entry.visible = v ?? true),
          activeColor: const Color(0xFFFFC107),
          checkColor: Colors.black,
          side: const BorderSide(color: Colors.white54),
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          '${entry.layer.name} ($count)',
          style: const TextStyle(color: Colors.white, fontSize: 12),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (!entry.isBundled)
        GestureDetector(
          onTap: () => _deleteLayer(entry),
          child: const Icon(Icons.delete_outline,
              color: Colors.white38, size: 18),
        ),
    ],
  );
}
```

**Step 3: Add `_deleteLayer` method**

```dart
Future<void> _deleteLayer(_LayerEntry entry) async {
  await _geoJsonService.removeLayer(entry.layer.name);
  if (mounted) setState(() => _entries.remove(entry));
}
```

**Step 4: Remove `_showGeoJsonLayers` field and any lingering references** (should already be gone from Task 1).

---

### Task 4: Lint, test, commit

**Step 1: Analyze**

Run: `flutter analyze lib/screens/findings_map_screen.dart`
Expected: `No issues found!`

**Step 2: Run full test suite**

Run: `flutter test --reporter=compact`
Expected: all tests pass (no changes to test files needed — the build methods are internal).

**Step 3: Commit**

```bash
git add lib/screens/findings_map_screen.dart docs/plans/2026-03-01-per-layer-toggles.md
git commit -m "feat: per-layer visibility toggles and delete in map layer panel"
```
