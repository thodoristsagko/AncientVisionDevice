# GPS Location Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show the device's live GPS position as a blue dot on the map with a "center on me" button.

**Architecture:** Add `LatLng? _myLocation` and a `StreamSubscription<Position>` to `_FindingsMapState`. `initState` calls `_startLocationTracking()` which requests permission then subscribes to `Geolocator.getPositionStream`. Each update calls `setState`. A new `MarkerLayer` renders the blue dot; a fourth map button centers the camera. Subscription is cancelled in `dispose`.

**Tech Stack:** Flutter, `geolocator ^10.1.0` (already in pubspec), `latlong2`, `flutter_map`. Android permissions already present in `AndroidManifest.xml`.

---

### Task 1: Add imports, state fields, and lifecycle hooks

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Step 1: Add import**

At the top of the file, alongside the existing imports, add:
```dart
import 'dart:async';
import 'package:geolocator/geolocator.dart';
```
(`dart:async` may already be imported — check first, only add if missing.)

**Step 2: Add state fields**

In `_FindingsMapState`, alongside the other fields, add:
```dart
LatLng? _myLocation;
StreamSubscription<Position>? _locationSub;
```

**Step 3: Call `_startLocationTracking` from `initState`**

In `initState`, after the existing calls, add:
```dart
_startLocationTracking();
```

**Step 4: Cancel subscription in `dispose`**

In `dispose()`, before `super.dispose()`, add:
```dart
_locationSub?.cancel();
```

**Step 5: Verify**

Confirm:
- `dart:async` and `geolocator` are imported
- `_myLocation` and `_locationSub` fields exist
- `initState` calls `_startLocationTracking()`
- `dispose` cancels `_locationSub`

Do NOT commit yet.

---

### Task 2: Implement `_startLocationTracking`

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Step 1: Add the method**

Add this method to `_FindingsMapState` (alongside the other async methods like `_loadGeoJsonLayers`):

```dart
Future<void> _startLocationTracking() async {
  try {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return; // silently skip — no dot shown
    }

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 2, // update every 2 metres
    );

    _locationSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((pos) {
      if (mounted) {
        setState(() => _myLocation = LatLng(pos.latitude, pos.longitude));
      }
    });
  } catch (_) {
    // Location unavailable — silently ignore
  }
}
```

**Step 2: Verify**

Confirm the method exists and:
- Checks then requests permission, returns silently if denied
- Creates a `LocationSettings` with `accuracy: high` and `distanceFilter: 2`
- Assigns the stream subscription to `_locationSub`
- Guards `setState` with `mounted`

Do NOT commit yet.

---

### Task 3: Render the blue dot marker

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Context:** The `FlutterMap` `children` list currently has: `TileLayer`, `PolygonLayer`, `PolylineLayer`, `MarkerLayer` (GeoJson points), `MarkerLayer` (findings). Add a new `MarkerLayer` for the GPS dot between the tile layer and the polygon layer (so it renders under GeoJson layers).

**Step 1: Add `_buildMyLocationMarker` method**

```dart
List<Marker> _buildMyLocationMarker() {
  if (_myLocation == null) return [];
  return [
    Marker(
      point: _myLocation!,
      width: 20,
      height: 20,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2196F3),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0x552196F3), blurRadius: 8, spreadRadius: 4),
          ],
        ),
      ),
    ),
  ];
}
```

**Step 2: Add a `MarkerLayer` to FlutterMap children**

In `build()`, inside the `FlutterMap` `children` list, insert after `TileLayer` and before `PolygonLayer`:
```dart
MarkerLayer(markers: _buildMyLocationMarker()),
```

The children order should be:
1. `TileLayer`
2. `MarkerLayer(markers: _buildMyLocationMarker())` ← new
3. `PolygonLayer(...)`
4. `PolylineLayer(...)`
5. `MarkerLayer(markers: _buildGeoJsonPointMarkers())`
6. `MarkerLayer(markers: _buildFindingMarkers())`

**Step 3: Verify**

Confirm `_buildMyLocationMarker` exists and the new `MarkerLayer` is inserted correctly in the children list.

Do NOT commit yet.

---

### Task 4: Add "center on me" button

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Context:** The top-right column has three `_mapButton` calls: satellite toggle, layers, import. Add a fourth below them.

**Step 1: Add the button**

In `build()`, find the top-right `Column` with the three existing `_mapButton` calls. After the last `_mapButton` (import), add:

```dart
const SizedBox(height: 8),
_mapButton(
  icon: Icons.my_location,
  tooltip: 'Center on my location',
  onTap: () {
    if (_myLocation != null && _mapController != null) {
      _mapController!.move(_myLocation!, _mapController!.camera.zoom);
    }
  },
),
```

**Step 2: Verify**

Confirm the fourth button exists in the top-right Column with `Icons.my_location` and the move logic.

Do NOT commit yet.

---

### Task 5: Analyze, test, commit

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`
- Modify: `docs/plans/2026-03-01-gps-location.md`

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
Expected: all tests pass.

**Step 3: Commit**

```bash
git add lib/screens/findings_map_screen.dart docs/plans/2026-03-01-gps-location.md
git commit -m "$(cat <<'EOF'
feat: live GPS blue dot and center-on-me button on map

Continuously tracks device location via geolocator stream.
Blue dot renders on map; center-on-me button snaps camera to position.
Silently skips if permission denied or location unavailable.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```
