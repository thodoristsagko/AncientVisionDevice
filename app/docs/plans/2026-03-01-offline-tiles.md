# Offline Tile Caching Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Cache map tiles to disk so the map works offline at the competition venue.

**Architecture:** A new `CachedTileProvider` (extends flutter_map's `TileProvider`) uses `flutter_cache_manager`'s `DefaultCacheManager` to serve tiles from disk when available and fetch+cache from the network otherwise. A private `_CacheImageProvider` (extends `ImageProvider`) does the async cache lookup. The map screen swaps the default `NetworkTileProvider` for `CachedTileProvider` in the `TileLayer`. No new dependencies — `flutter_cache_manager ^3.3.1` is already in the pubspec.

**Tech Stack:** Flutter, `flutter_map ^6.x`, `flutter_cache_manager ^3.3.1` (already in pubspec).

---

### Task 1: Create `CachedTileProvider` with tests

**Files:**
- Create: `lib/services/cached_tile_provider.dart`
- Create: `test/services/cached_tile_provider_test.dart`

**Step 1: Write the failing test**

Create `test/services/cached_tile_provider_test.dart`:

```dart
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ancient_vision/services/cached_tile_provider.dart';

void main() {
  group('CachedTileProvider', () {
    test('creates with default cache manager', () {
      final provider = CachedTileProvider();
      expect(provider, isNotNull);
      expect(provider.cacheManager, isA<DefaultCacheManager>());
    });

    test('accepts injected cache manager', () {
      final manager = DefaultCacheManager();
      final provider = CachedTileProvider(cacheManager: manager);
      expect(provider.cacheManager, same(manager));
    });

    test('getImage returns an ImageProvider for a tile coordinate', () {
      final provider = CachedTileProvider();
      const options = TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      );
      final coords = TileCoordinates(1, 1, 1);
      final image = provider.getImage(coords, options);
      expect(image, isA<ImageProvider>());
    });
  });
}
```

**Step 2: Run test to verify it fails**

```
flutter test test/services/cached_tile_provider_test.dart --reporter=compact
```
Expected: FAIL — `cached_tile_provider.dart` does not exist yet.

**Step 3: Implement `lib/services/cached_tile_provider.dart`**

```dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';

/// A [TileProvider] that caches tiles to disk via [flutter_cache_manager].
///
/// Tiles are served from the disk cache when available; on a cache miss they
/// are fetched from the network and stored for future offline use. If a tile
/// cannot be loaded (no cache, no network) the error propagates and
/// flutter_map renders its built-in error tile.
class CachedTileProvider extends TileProvider {
  final BaseCacheManager cacheManager;

  CachedTileProvider({BaseCacheManager? cacheManager})
      : cacheManager = cacheManager ?? DefaultCacheManager();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _CacheImageProvider(
      getTileUrl(coordinates, options),
      cacheManager,
    );
  }
}

class _CacheImageProvider extends ImageProvider<_CacheImageProvider> {
  final String url;
  final BaseCacheManager cacheManager;

  const _CacheImageProvider(this.url, this.cacheManager);

  @override
  Future<_CacheImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _CacheImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode),
      scale: 1.0,
      informationCollector: () => [DiagnosticsProperty('URL', url)],
    );
  }

  Future<ui.Codec> _loadAsync(ImageDecoderCallback decode) async {
    final file = await cacheManager.getSingleFile(url);
    final bytes = await file.readAsBytes();
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _CacheImageProvider && url == other.url;

  @override
  int get hashCode => url.hashCode;
}
```

**Step 4: Run test to verify it passes**

```
flutter test test/services/cached_tile_provider_test.dart --reporter=compact
```
Expected: `+3: All tests passed!`

---

### Task 2: Wire `CachedTileProvider` into the map screen

**Files:**
- Modify: `lib/screens/findings_map_screen.dart`

**Context:** The map screen uses `TileLayer(urlTemplate: ..., ...)`. By default flutter_map uses `NetworkTileProvider`. We add `tileProvider: CachedTileProvider()` to enable disk caching.

**Step 1: Add import**

At the top of `lib/screens/findings_map_screen.dart`, add:
```dart
import '../services/cached_tile_provider.dart';
```

**Step 2: Add `tileProvider` to `TileLayer`**

Find the `TileLayer(...)` in `build()`. It currently looks like:
```dart
TileLayer(
  urlTemplate: _useSatellite
      ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.example.ancient_vision',
  maxZoom: 19,
),
```

Add `tileProvider: CachedTileProvider()` as the last parameter:
```dart
TileLayer(
  urlTemplate: _useSatellite
      ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.example.ancient_vision',
  maxZoom: 19,
  tileProvider: CachedTileProvider(),
),
```

**Step 3: Verify**

Confirm the import exists and `tileProvider: CachedTileProvider()` is in the `TileLayer`.

---

### Task 3: Analyze, test, commit

**Files:**
- `lib/services/cached_tile_provider.dart`
- `lib/screens/findings_map_screen.dart`
- `test/services/cached_tile_provider_test.dart`
- `docs/plans/2026-03-01-offline-tiles.md`

**Step 1: flutter analyze**

```
flutter analyze lib/services/cached_tile_provider.dart lib/screens/findings_map_screen.dart
```
Expected: `No issues found!`

**Step 2: Full test suite**

```
flutter test --reporter=compact
```
Expected: all tests pass (252 existing + 3 new = 255).

**Step 3: Commit**

```bash
git add lib/services/cached_tile_provider.dart \
        lib/screens/findings_map_screen.dart \
        test/services/cached_tile_provider_test.dart \
        docs/plans/2026-03-01-offline-tiles.md
git commit -m "$(cat <<'EOF'
feat: offline tile caching via flutter_cache_manager

CachedTileProvider caches map tiles to disk as they load.
Browse the venue area on WiFi to pre-load; tiles serve from cache offline.
Uses already-included flutter_cache_manager, no new dependencies.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```
