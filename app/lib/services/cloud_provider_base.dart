import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/point_cloud.dart';
import '../models/mesh_model.dart';

/// Status of a cloud provider.
enum ProviderStatus { available, degraded, unavailable, unknown }

/// Health check result for a cloud provider.
class ProviderHealthCheck {
  final ProviderStatus status;
  final Duration latency;
  final String? message;
  final DateTime checkedAt;

  ProviderHealthCheck({
    required this.status,
    required this.latency,
    this.message,
    DateTime? checkedAt,
  }) : checkedAt = checkedAt ?? DateTime.now();

  bool get isAvailable => status == ProviderStatus.available || status == ProviderStatus.degraded;
}

/// Progress callback for cloud processing.
typedef CloudProgressCallback = void Function(double progress, String status);

/// Cloud processing request.
class CloudProcessingRequest {
  final List<File> images;
  final String? sessionId;
  final Map<String, dynamic> options;

  CloudProcessingRequest({
    required this.images,
    this.sessionId,
    this.options = const {},
  });
}

/// Cloud processing result.
class CloudProcessingResult {
  final bool success;
  final PointCloud? pointCloud;
  final MeshModel? mesh;
  final String? errorMessage;
  final Duration processingTime;
  final Map<String, dynamic> metadata;

  CloudProcessingResult({
    required this.success,
    this.pointCloud,
    this.mesh,
    this.errorMessage,
    required this.processingTime,
    this.metadata = const {},
  });
}

/// Abstract base class for cloud photogrammetry providers.
///
/// Implementations must provide:
/// - [name], [description] - human-readable identity
/// - [checkHealth] - verify the provider is reachable
/// - [processImages] - submit images and get results
abstract class CloudProviderBase {
  /// Human-readable provider name.
  String get name;

  /// Description of the provider's capabilities.
  String get description;

  /// Whether this provider requires an API key.
  bool get requiresApiKey => false;

  /// Maximum number of images supported.
  int get maxImages => 100;

  /// Maximum retry attempts for transient failures.
  int get maxRetries => 3;

  /// Timeout for health checks.
  Duration get healthCheckTimeout => const Duration(seconds: 10);

  /// Timeout for processing.
  Duration get processingTimeout => const Duration(minutes: 30);

  /// Cached health check result.
  ProviderHealthCheck? _lastHealthCheck;

  /// Get the last health check result (may be stale).
  ProviderHealthCheck? get lastHealthCheck => _lastHealthCheck;

  /// Check if the provider is currently available.
  Future<ProviderHealthCheck> checkHealth() async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await performHealthCheck()
          .timeout(healthCheckTimeout);
      stopwatch.stop();
      _lastHealthCheck = ProviderHealthCheck(
        status: result ? ProviderStatus.available : ProviderStatus.unavailable,
        latency: stopwatch.elapsed,
      );
    } on TimeoutException {
      stopwatch.stop();
      _lastHealthCheck = ProviderHealthCheck(
        status: ProviderStatus.unavailable,
        latency: stopwatch.elapsed,
        message: 'Health check timed out',
      );
    } catch (e) {
      stopwatch.stop();
      _lastHealthCheck = ProviderHealthCheck(
        status: ProviderStatus.unavailable,
        latency: stopwatch.elapsed,
        message: 'Health check failed: $e',
      );
    }
    return _lastHealthCheck!;
  }

  /// Subclasses implement the actual health check logic.
  @protected
  Future<bool> performHealthCheck();

  /// Process images with automatic retry on transient failures.
  Future<CloudProcessingResult> processImages(
    CloudProcessingRequest request, {
    CloudProgressCallback? onProgress,
  }) async {
    final startTime = DateTime.now();
    Exception? lastError;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final delay = Duration(seconds: (1 << attempt).clamp(1, 30));
          debugPrint('$name: Retry attempt ${attempt + 1}/$maxRetries after ${delay.inSeconds}s');
          await Future.delayed(delay);
          onProgress?.call(0, 'Retrying (${attempt + 1}/$maxRetries)...');
        }

        final result = await performProcessing(request, onProgress: onProgress)
            .timeout(processingTimeout);
        return result;
      } on TimeoutException {
        lastError = TimeoutException('Processing timed out after ${processingTimeout.inMinutes} minutes');
        debugPrint('$name: Timeout on attempt ${attempt + 1}');
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        debugPrint('$name: Error on attempt ${attempt + 1}: $e');

        // Don't retry on non-transient errors
        if (e is FormatException || e is ArgumentError) break;
      }
    }

    return CloudProcessingResult(
      success: false,
      errorMessage: lastError?.toString() ?? 'Unknown error',
      processingTime: DateTime.now().difference(startTime),
    );
  }

  /// Subclasses implement the actual processing logic.
  @protected
  Future<CloudProcessingResult> performProcessing(
    CloudProcessingRequest request, {
    CloudProgressCallback? onProgress,
  });

  /// Get provider diagnostics.
  Map<String, dynamic> getDiagnostics() => {
    'name': name,
    'description': description,
    'requires_api_key': requiresApiKey,
    'max_images': maxImages,
    'max_retries': maxRetries,
    'last_health_status': _lastHealthCheck?.status.name ?? 'unchecked',
    'last_health_latency_ms': _lastHealthCheck?.latency.inMilliseconds,
  };
}
