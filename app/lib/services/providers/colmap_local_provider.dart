import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../models/point_cloud.dart';
import '../cloud_provider_base.dart';

/// COLMAP local REST API provider.
///
/// Connects to a local COLMAP instance running as a REST service.
class ColmapLocalProvider extends CloudProviderBase {
  final String apiUrl;
  final http.Client _client;

  ColmapLocalProvider({
    this.apiUrl = 'http://localhost:8081',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get name => 'COLMAP (Local)';

  @override
  String get description => 'Gold-standard SfM/MVS on local machine';

  @override
  int get maxImages => 500;

  @override
  Duration get processingTimeout => const Duration(minutes: 120);

  @override
  Future<bool> performHealthCheck() async {
    try {
      final response = await _client.get(Uri.parse('$apiUrl/health'));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<CloudProcessingResult> performProcessing(
    CloudProcessingRequest request, {
    CloudProgressCallback? onProgress,
  }) async {
    final startTime = DateTime.now();
    onProgress?.call(0.05, 'Uploading images to COLMAP...');

    try {
      final uploadRequest = http.MultipartRequest('POST', Uri.parse('$apiUrl/api/reconstruct'));
      for (final image in request.images) {
        uploadRequest.files.add(await http.MultipartFile.fromPath('images', image.path));
      }

      // Add COLMAP-specific options
      uploadRequest.fields['quality'] = request.options['quality']?.toString() ?? 'medium';
      uploadRequest.fields['dense'] = (request.options['dense'] ?? true).toString();

      final uploadResponse = await _client.send(uploadRequest);
      final uploadBody = await uploadResponse.stream.bytesToString();
      final uploadJson = json.decode(uploadBody) as Map<String, dynamic>;
      final jobId = uploadJson['job_id'] as String?;

      if (jobId == null) {
        return CloudProcessingResult(
          success: false,
          errorMessage: 'Failed to create COLMAP job',
          processingTime: DateTime.now().difference(startTime),
        );
      }

      // Poll for completion
      onProgress?.call(0.15, 'Running COLMAP pipeline...');
      while (true) {
        await Future.delayed(const Duration(seconds: 5));

        final statusResponse = await _client.get(Uri.parse('$apiUrl/api/jobs/$jobId'));
        final statusJson = json.decode(statusResponse.body) as Map<String, dynamic>;
        final status = statusJson['status'] as String?;
        final progress = (statusJson['progress'] as num?)?.toDouble() ?? 0;
        final stage = statusJson['stage'] as String? ?? 'processing';

        onProgress?.call(0.15 + progress * 0.75, 'COLMAP $stage (${(progress * 100).toInt()}%)');

        if (status == 'completed') {
          onProgress?.call(0.95, 'Downloading COLMAP result...');
          final resultResponse = await _client.get(Uri.parse('$apiUrl/api/jobs/$jobId/pointcloud'));
          final pointCloud = PointCloud.fromPLY(resultResponse.body);

          return CloudProcessingResult(
            success: true,
            pointCloud: pointCloud,
            processingTime: DateTime.now().difference(startTime),
            metadata: {'provider': 'colmap_local', 'job_id': jobId},
          );
        } else if (status == 'failed') {
          return CloudProcessingResult(
            success: false,
            errorMessage: statusJson['error'] as String? ?? 'COLMAP job failed',
            processingTime: DateTime.now().difference(startTime),
          );
        }
      }
    } catch (e) {
      return CloudProcessingResult(
        success: false,
        errorMessage: 'COLMAP processing failed: $e',
        processingTime: DateTime.now().difference(startTime),
      );
    }
  }
}
