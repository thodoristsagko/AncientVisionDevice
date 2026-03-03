import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/point_cloud.dart';
import 'reconstruction/index.dart';

/// Callback for incremental reconstruction updates.
typedef IncrementalUpdateCallback = void Function(
  PointCloud currentCloud,
  List<CameraPose> currentPoses,
  int registeredImages,
);

/// Incremental Structure from Motion service.
///
/// Maintains a running sparse reconstruction that updates as new images
/// are added, providing real-time preview during capture.
class IncrementalSfMService {
  final ReconstructionService _reconstructionService = ReconstructionService();

  PointCloud? _currentCloud;
  List<CameraPose> _currentPoses = [];
  List<File> _registeredImages = [];
  bool _isProcessing = false;

  /// Current sparse point cloud preview.
  PointCloud? get currentCloud => _currentCloud;

  /// Current estimated camera poses.
  List<CameraPose> get currentPoses => _currentPoses;

  /// Number of successfully registered images.
  int get registeredCount => _registeredImages.length;

  /// Whether the service is currently processing a new image.
  bool get isProcessing => _isProcessing;

  /// Add a new image to the incremental reconstruction.
  ///
  /// Returns true if the image was successfully registered (enough
  /// feature matches with existing images).
  Future<bool> addImage(
    File imageFile, {
    IncrementalUpdateCallback? onUpdate,
  }) async {
    if (_isProcessing) return false;
    _isProcessing = true;

    try {
      // For the first 3 images, just collect them
      _registeredImages.add(imageFile);

      if (_registeredImages.length < 3) {
        _isProcessing = false;
        return true;
      }

      // Run sparse reconstruction on all collected images
      final result = await _reconstructionService.generateSparsePreview(
        imageFiles: _registeredImages,
        onProgress: (progress, status) {
          if (kDebugMode) {
          debugPrint('IncrementalSfM: $status (${(progress * 100).toInt()}%)');
          }
        },
      );

      if (result.pointCloud != null && result.pointCloud!.points.isNotEmpty) {
        _currentCloud = result.pointCloud;
        if (result.cameraPoses != null && result.cameraPoses!.isNotEmpty) {
          _currentPoses = List.from(result.cameraPoses!);
        }

        onUpdate?.call(
          _currentCloud!,
          _currentPoses,
          _registeredImages.length,
        );

        _isProcessing = false;
        return true;
      }

      // If reconstruction failed with this image, remove it
      _registeredImages.removeLast();
      _isProcessing = false;
      return false;
    } catch (e) {
      if (kDebugMode) {
      debugPrint('IncrementalSfM: Failed to add image: $e');
      }
      _registeredImages.removeLast();
      _isProcessing = false;
      return false;
    }
  }

  /// Reset the incremental reconstruction.
  void reset() {
    _currentCloud = null;
    _currentPoses = [];
    _registeredImages = [];
    _isProcessing = false;
  }

  /// Get registered image files for final dense reconstruction.
  List<File> get registeredImages => List.unmodifiable(_registeredImages);
}
