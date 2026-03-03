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
