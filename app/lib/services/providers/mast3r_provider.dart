import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../models/point_cloud.dart';
import '../cloud_provider_base.dart';

/// MASt3R 3D reconstruction via Gradio API.
///
/// MASt3R (Matching And Stereo 3D Reconstruction) is a SOTA model from
/// Naver Labs that performs dense 3D reconstruction from image pairs.
///
/// Requires a running Gradio server (e.g., HuggingFace Space or local).
class MASt3RProvider extends CloudProviderBase {
  /// Gradio API endpoint URL.
  final String apiUrl;

  /// Optional API token for authenticated access.
  final String? apiToken;

  final http.Client _client;

  MASt3RProvider({
    this.apiUrl = 'https://naver-mast3r.hf.space',
    this.apiToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get name => 'MASt3R';

  @override
  String get description => 'SOTA dense 3D from image pairs (Naver Labs)';

  @override
  bool get requiresApiKey => apiToken != null;

  @override
  int get maxImages => 20; // MASt3R processes pairs; supports multi-view

  @override
  Duration get processingTimeout => const Duration(minutes: 15);

  @override
  Future<bool> performHealthCheck() async {
    try {
      final response = await _client.get(
        Uri.parse('$apiUrl/api/'),
        headers: _headers,
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('MASt3R health check failed: $e');
      return false;
    }
  }

  @override
  Future<CloudProcessingResult> performProcessing(
    CloudProcessingRequest request, {
    CloudProgressCallback? onProgress,
  }) async {
    final startTime = DateTime.now();

    if (request.images.length < 2) {
      return CloudProcessingResult(
        success: false,
        errorMessage: 'MASt3R requires at least 2 images',
        processingTime: DateTime.now().difference(startTime),
      );
    }

    onProgress?.call(0.1, 'Uploading images to MASt3R...');

    try {
      // Upload images via Gradio API
      final uploadedPaths = <String>[];
      for (int i = 0; i < request.images.length; i++) {
        final file = request.images[i];
        final uploadRequest = http.MultipartRequest(
          'POST',
          Uri.parse('$apiUrl/upload'),
        );
        uploadRequest.headers.addAll(_headers);
        uploadRequest.files.add(
          await http.MultipartFile.fromPath('files', file.path),
        );

        final uploadResponse = await _client.send(uploadRequest);
        final uploadBody = await uploadResponse.stream.bytesToString();
        final uploadJson = json.decode(uploadBody) as List;
        if (uploadJson.isNotEmpty) {
          uploadedPaths.add(uploadJson[0] as String);
        }

        onProgress?.call(
          0.1 + 0.2 * ((i + 1) / request.images.length),
          'Uploaded ${i + 1}/${request.images.length} images',
        );
      }

      if (uploadedPaths.length < 2) {
        return CloudProcessingResult(
          success: false,
          errorMessage: 'Failed to upload images',
          processingTime: DateTime.now().difference(startTime),
        );
      }

      // Submit reconstruction job via Gradio predict API
      onProgress?.call(0.35, 'Starting MASt3R reconstruction...');

      final predictBody = json.encode({
        'data': [
          uploadedPaths, // image paths
          request.options['scene_scale'] ?? 1.0, // scene scale
          request.options['min_confidence'] ?? 1.5, // confidence threshold
        ],
        'fn_index': 0,
        'session_hash': request.sessionId ?? DateTime.now().millisecondsSinceEpoch.toString(),
      });

      final predictResponse = await _client.post(
        Uri.parse('$apiUrl/api/predict'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: predictBody,
      );

      if (predictResponse.statusCode != 200) {
        return CloudProcessingResult(
          success: false,
          errorMessage: 'MASt3R API error: ${predictResponse.statusCode}',
          processingTime: DateTime.now().difference(startTime),
        );
      }

      onProgress?.call(0.7, 'Parsing MASt3R results...');

      // Parse response - MASt3R returns a PLY point cloud
      final responseJson = json.decode(predictResponse.body);
      final data = responseJson['data'] as List?;

      if (data == null || data.isEmpty) {
        return CloudProcessingResult(
          success: false,
          errorMessage: 'Empty response from MASt3R',
          processingTime: DateTime.now().difference(startTime),
        );
      }

      // Download the PLY result
      final plyUrl = data[0] as String?;
      if (plyUrl == null) {
        return CloudProcessingResult(
          success: false,
          errorMessage: 'No PLY output from MASt3R',
          processingTime: DateTime.now().difference(startTime),
        );
      }

      final plyResponse = await _client.get(
        Uri.parse(plyUrl.startsWith('http') ? plyUrl : '$apiUrl/file=$plyUrl'),
        headers: _headers,
      );

      if (plyResponse.statusCode != 200) {
        return CloudProcessingResult(
          success: false,
          errorMessage: 'Failed to download PLY result',
          processingTime: DateTime.now().difference(startTime),
        );
      }

      onProgress?.call(0.9, 'Loading point cloud...');

      // Parse PLY
      final pointCloud = PointCloud.fromPLY(plyResponse.body);

      onProgress?.call(1.0, 'MASt3R reconstruction complete!');

      return CloudProcessingResult(
        success: true,
        pointCloud: pointCloud,
        processingTime: DateTime.now().difference(startTime),
        metadata: {
          'provider': 'mast3r',
          'images': request.images.length,
          'points': pointCloud.points.length,
        },
      );
    } catch (e) {
      return CloudProcessingResult(
        success: false,
        errorMessage: 'MASt3R processing failed: $e',
        processingTime: DateTime.now().difference(startTime),
      );
    }
  }

  Map<String, String> get _headers => {
    if (apiToken != null) 'Authorization': 'Bearer $apiToken',
  };
}
