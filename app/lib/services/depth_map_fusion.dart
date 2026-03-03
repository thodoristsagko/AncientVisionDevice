import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';
import '../models/point_cloud.dart';
import 'patch_match_stereo.dart';

/// Parameters for depth map fusion.
class FusionParams {
  /// Minimum confidence to accept a depth value.
  final double minConfidence;

  /// Maximum reprojection error for multi-view consistency (pixels).
  final double maxReprojError;

  /// Minimum number of views that must agree on a depth.
  final int minConsistentViews;

  /// Voxel size for duplicate removal (world units).
  final double voxelSize;

  const FusionParams({
    this.minConfidence = 0.3,
    this.maxReprojError = 2.0,
    this.minConsistentViews = 2,
    this.voxelSize = 0.01,
  });
}

/// Fuses multiple depth maps into a single consistent point cloud.
class DepthMapFusion {
  final FusionParams params;

  DepthMapFusion({this.params = const FusionParams()});

  /// Fuse depth maps from multiple view pairs.
  ///
  /// [depthMaps] - list of estimated depth maps.
  /// [projections] - corresponding 4x4 projection matrices (K * [R|t]).
  /// [colorImages] - optional color images for point coloring (row-major RGBA).
  /// [imageWidth], [imageHeight] - dimensions of the depth maps.
  Future<PointCloud> fuse({
    required List<DepthMap> depthMaps,
    required List<Matrix4> projections,
    List<Float32List>? colorImages,
    required int imageWidth,
    required int imageHeight,
    required double focalLength,
  }) async {
    final points = <Point3D>[];
    final seen = <int>{};

    for (int v = 0; v < depthMaps.length; v++) {
      final dm = depthMaps[v];
      final proj = projections[v];
      final invProj = Matrix4.copy(proj)..invert();
      final hasColor = colorImages != null && v < colorImages.length;

      for (int y = 0; y < dm.height; y++) {
        for (int x = 0; x < dm.width; x++) {
          final conf = dm.confidenceAt(x, y);
          if (conf < params.minConfidence) continue;

          final depth = dm.depthAt(x, y);
          if (depth <= 0) continue;

          // Unproject to 3D: p = K^-1 * [x, y, 1] * depth
          final cx = imageWidth / 2.0;
          final cy = imageHeight / 2.0;
          final nx = (x - cx) / focalLength;
          final ny = (y - cy) / focalLength;

          final camPoint = Vector3(nx * depth, ny * depth, depth);

          // Transform to world space
          final worldPoint4 = invProj.transform(Vector4(
            camPoint.x,
            camPoint.y,
            camPoint.z,
            1.0,
          ));
          final worldPoint = Vector3(
            worldPoint4.x / worldPoint4.w,
            worldPoint4.y / worldPoint4.w,
            worldPoint4.z / worldPoint4.w,
          );

          // Voxel-based deduplication
          final vx = (worldPoint.x / params.voxelSize).round();
          final vy = (worldPoint.y / params.voxelSize).round();
          final vz = (worldPoint.z / params.voxelSize).round();
          final voxelKey = vx * 73856093 ^ vy * 19349663 ^ vz * 83492791;

          if (seen.contains(voxelKey)) continue;
          seen.add(voxelKey);

          // Get color
          Color color = const Color(0xFF808080);
          if (hasColor) {
            final ci = (y * dm.width + x) * 4;
            final cimg = colorImages[v];
            if (ci + 3 < cimg.length) {
              color = Color.fromARGB(
                255,
                cimg[ci].round().clamp(0, 255),
                cimg[ci + 1].round().clamp(0, 255),
                cimg[ci + 2].round().clamp(0, 255),
              );
            }
          }

          points.add(Point3D(
            position: worldPoint,
            color: color,
            confidence: conf,
          ));
        }
      }
    }

    debugPrint(
        'DepthMapFusion: ${points.length} points from ${depthMaps.length} depth maps');

    return PointCloud(
      points: points,
      method: 'dense_mvs_patchmatch',
      metadata: {
        'depth_maps': depthMaps.length,
        'min_confidence': params.minConfidence,
        'voxel_size': params.voxelSize,
      },
    );
  }
}
