import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../models/point_cloud.dart';
import '../cloud_provider_base.dart';

/// Meshroom/AliceVision local REST API provider.
///
/// Connects to a local Meshroom instance running as a REST service.
/// Users can run this on their desktop machine via Docker or native install.
class MeshroomLocalProvider extends CloudProviderBase {
  final String apiUrl;
  final http.Client _client;

  MeshroomLocalProvider({
    this.apiUrl = 'http://localhost:8080',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get name => 'Meshroom (Local)';

  @override
  String get description => 'AliceVision photogrammetry on local machine';

  @override
  int get maxImages => 200;

  @override
  Duration get processingTimeout => const Duration(minutes: 60);

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
    onProgress?.call(0.05, 'Uploading images to Meshroom...');

    try {
      // Upload images
      final uploadRequest = http.MultipartRequest('POST', Uri.parse('$apiUrl/api/upload'));
      for (final image in request.images) {
        uploadRequest.files.add(await http.MultipartFile.fromPath('images', image.path));
      }

      final uploadResponse = await _client.send(uploadRequest);
      final uploadBody = await uploadResponse.stream.bytesToString();
      final uploadJson = json.decode(uploadBody) as Map<String, dynamic>;
      final jobId = uploadJson['job_id'] as String?;

      if (jobId == null) {
        return CloudProcessingResult(
          success: false,
          errorMessage: 'Failed to create Meshroom job',
          processingTime: DateTime.now().difference(startTime),
        );
      }

      // Poll for completion
      onProgress?.call(0.2, 'Processing with Meshroom...');
      while (true) {
        await Future.delayed(const Duration(seconds: 5));

        final statusResponse = await _client.get(Uri.parse('$apiUrl/api/jobs/$jobId'));
        final statusJson = json.decode(statusResponse.body) as Map<String, dynamic>;
        final status = statusJson['status'] as String?;
        final progress = (statusJson['progress'] as num?)?.toDouble() ?? 0;

        onProgress?.call(0.2 + progress * 0.7, 'Meshroom: $status (${(progress * 100).toInt()}%)');

        if (status == 'completed') {
          // Download result
          onProgress?.call(0.95, 'Downloading result...');
          final resultResponse = await _client.get(Uri.parse('$apiUrl/api/jobs/$jobId/result'));
          final pointCloud = PointCloud.fromPLY(resultResponse.body);

          return CloudProcessingResult(
            success: true,
            pointCloud: pointCloud,
            processingTime: DateTime.now().difference(startTime),
            metadata: {'provider': 'meshroom_local', 'job_id': jobId},
          );
        } else if (status == 'failed') {
          return CloudProcessingResult(
            success: false,
            errorMessage: statusJson['error'] as String? ?? 'Meshroom job failed',
            processingTime: DateTime.now().difference(startTime),
          );
        }
      }
    } catch (e) {
      return CloudProcessingResult(
        success: false,
        errorMessage: 'Meshroom processing failed: $e',
        processingTime: DateTime.now().difference(startTime),
      );
    }
  }
}
