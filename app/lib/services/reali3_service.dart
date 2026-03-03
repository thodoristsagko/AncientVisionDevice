import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../config/env_config.dart';

/// Cloud photogrammetry service using Reali3 REST API.
///
/// Flow: upload photos → poll status → download PLY + GLTF.
/// API docs: https://reali3.net/api
class Reali3Service {
  static const String _baseUrl = 'https://api.reali3.net/v1';

  String? _lastError;
  String? get lastError => _lastError;
  bool _isCancelled = false;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${EnvConfig.reali3ApiKey}',
      };

  void cancel() => _isCancelled = true;

  /// Upload photos and start reconstruction. Returns reconstruction ID.
  Future<String?> startReconstruction(List<XFile> images) async {
    _isCancelled = false;
    _lastError = null;
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/reconstruction'),
      );
      request.headers.addAll(_headers);

      for (final image in images) {
        request.files.add(await http.MultipartFile.fromPath(
          'files',
          image.path,
          filename: image.name,
        ));
      }

      final streamed =
          await request.send().timeout(const Duration(minutes: 5));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 202 || response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        return body['id'] as String?;
      } else {
        _lastError = 'Upload failed (${response.statusCode})';
        return null;
      }
    } catch (e) {
      _lastError = 'Upload error: $e';
      return null;
    }
  }

  /// Poll reconstruction status.
  Future<({int progress, String status, bool done, bool failed})> checkStatus(
      String id) async {
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/reconstruction/$id/status'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final status = body['status'] as String? ?? 'unknown';
        final progress = body['progress'] as int? ?? 0;
        return (
          progress: progress,
          status: status,
          done: status == 'completed',
          failed: status == 'failed',
        );
      }
      return (progress: 0, status: 'error', done: false, failed: true);
    } catch (e) {
      return (
        progress: 0,
        status: 'connection error',
        done: false,
        failed: true
      );
    }
  }

  /// Download model file to local storage. Returns file path.
  Future<String?> downloadModel(String id, {String format = 'ply'}) async {
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/reconstruction/$id/download/$format'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _lastError = 'Download info failed (${response.statusCode})';
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final downloadUrl = body['download_url'] as String?;
      if (downloadUrl == null) {
        _lastError = 'No download URL in response';
        return null;
      }

      final fileResponse = await http
          .get(Uri.parse(downloadUrl))
          .timeout(const Duration(minutes: 5));
      if (fileResponse.statusCode != 200) {
        _lastError = 'File download failed (${fileResponse.statusCode})';
        return null;
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/reali3_$id.$format');
      await file.writeAsBytes(fileResponse.bodyBytes);
      return file.path;
    } catch (e) {
      _lastError = 'Download error: $e';
      return null;
    }
  }

  /// Full reconstruction: upload → poll → download PLY + GLTF.
  Future<({String? plyPath, String? gltfPath})> reconstruct({
    required List<XFile> images,
    required void Function(double progress, String status) onProgress,
  }) async {
    // Upload
    onProgress(0.05, 'Uploading ${images.length} photos...');
    final id = await startReconstruction(images);
    if (id == null || _isCancelled) {
      return (plyPath: null, gltfPath: null);
    }

    // Poll
    onProgress(0.10, 'Processing...');
    while (!_isCancelled) {
      await Future.delayed(const Duration(seconds: 3));
      final status = await checkStatus(id);

      if (status.failed) {
        _lastError = 'Reconstruction failed on server';
        return (plyPath: null, gltfPath: null);
      }

      final p = 0.10 + (status.progress / 100.0) * 0.70;
      onProgress(p, 'Reconstructing... ${status.progress}%');

      if (status.done) break;
    }
    if (_isCancelled) return (plyPath: null, gltfPath: null);

    // Download PLY
    onProgress(0.85, 'Downloading point cloud...');
    final plyPath = await downloadModel(id, format: 'ply');

    // Download GLTF
    onProgress(0.92, 'Downloading 3D model...');
    final gltfPath = await downloadModel(id, format: 'gltf');

    onProgress(1.0, 'Done!');
    return (plyPath: plyPath, gltfPath: gltfPath);
  }
}
