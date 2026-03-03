# Alert Screen Redesign + GIS/GeoJSON Integration

**Date**: 2026-03-01
**Target**: Thessaloniki FLL Finals, March 21-22, 2026

## Feature 1: Information-Rich Alert Screen

### Problem
The current full-screen alert overlay shows a generic message ("Seismic activity detected") with no context about why it triggered or what specific action to take. Archaeologists need to understand what's happening to make informed decisions.

### Design

Replace the current overlay with a glassmorphism-styled alert that includes:

1. **"Why This Triggered" box** — shows the specific metrics that crossed thresholds:
   - PPV value vs limit (e.g., "4.2 mm/s, limit: 3.0")
   - Dominant frequency and classification band
   - STA/LTA ratio if relevant
2. **PPV sparkline** — last 10 seconds of PPV history as a mini chart with threshold line, so the user can visually see the spike
3. **Type-specific action guidance** — based on alert type:
   - `seismic` → "Evacuate the trench. Move to safe distance (>15m)."
   - `machinery` → "Stop all equipment. Inspect vibration source."
   - `impact` → "Check for structural damage. Do not resume until inspected."
   - `moisture_high` → "Collapse risk. Exit trench and assess drainage."
   - `cav_damage` → "Cumulative damage threshold exceeded. Structural assessment required."
   - `structural` → "EVACUATE IMMEDIATELY. Do not re-enter."
4. **Glassmorphism styling** — frosted glass card on dark gradient, smoother pulsing animation

### Data Flow
SafetyView already tracks `_ppv`, `_dominantFreq`, `_staLtaRatio`, `_ppvKalmanHistory`. The `onAlert` callback will be expanded to pass these values alongside the message and level. The alert overlay widget receives them and renders the metrics box and sparkline.

### Files
- **Modify**: `lib/widgets/full_screen_alert_overlay.dart` — full redesign
- **Modify**: `lib/main.dart` — expand alert state to include metrics
- **Modify**: `lib/screens/safety/safety_view.dart` — pass metrics in alert callback
- **Create**: `lib/widgets/ppv_sparkline.dart` — sparkline chart widget

## Feature 2: GIS/GeoJSON Integration + Satellite Map

### Problem
9 out of 10 archaeologists work with GIS (QGIS/ArcGIS). The app's map currently shows only finding markers on street tiles. Adding GeoJSON overlay support and satellite imagery makes the map useful for real excavation contexts.

### Design

1. **Satellite basemap** — switch default tiles from OpenStreetMap to Esri World Imagery (`server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}`). Add toggle to switch back to street view.
2. **GeoJSON import** — file picker to load `.geojson` files from device storage. Parse and render as polygon/polyline/point overlays on flutter_map.
3. **Layer controls** — toggle visibility of GeoJSON layers and finding markers independently.
4. **Persistence** — store imported GeoJSON in local storage so layers persist across app restarts.
5. **Demo data** — bundle `assets/geo/sample_trenches.geojson` with example excavation trench polygons for the competition demo.

### Implementation
- GeoJSON is standard JSON — parse with `dart:convert`, extract geometry coordinates, convert to `flutter_map` `Polygon`/`Polyline`/`Marker` objects
- `flutter_map` natively supports `PolygonLayer` and `PolylineLayer` — no additional map plugins needed
- `file_picker` package for device file selection

### Files
- **Modify**: `lib/screens/findings_map_screen.dart` — satellite tiles, GeoJSON layers, toggle controls
- **Create**: `lib/services/geojson_service.dart` — parse, convert, persist GeoJSON
- **Create**: `assets/geo/sample_trenches.geojson` — bundled demo data
- **Add package**: `file_picker` in pubspec.yaml
