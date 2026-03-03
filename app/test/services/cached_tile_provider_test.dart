import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:ancient_vision/services/cached_tile_provider.dart';

/// Minimal fake [PathProviderPlatform] that returns a real temp directory so
/// [DefaultCacheManager] can initialise its file-system storage during tests.
class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String _tmp;
  _FakePathProvider(this._tmp);

  @override
  Future<String?> getTemporaryPath() async => _tmp;

  @override
  Future<String?> getApplicationSupportPath() async => _tmp;

  @override
  Future<String?> getApplicationDocumentsPath() async => _tmp;

  @override
  Future<String?> getApplicationCachePath() async => _tmp;

  @override
  Future<String?> getExternalStoragePath() async => _tmp;

  @override
  Future<List<String>?> getExternalCachePaths() async => [_tmp];

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => [_tmp];

  @override
  Future<String?> getDownloadsPath() async => _tmp;
}

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmpDir = Directory.systemTemp.createTempSync('cached_tile_provider_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
  });

  tearDownAll(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

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
      final options = TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      );
      const coords = TileCoordinates(1, 1, 1);
      final image = provider.getImage(coords, options);
      expect(image, isA<ImageProvider>());
    });
  });
}
