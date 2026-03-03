import 'dart:math' as math;
import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';
import '../models/point_cloud.dart';
import '../models/mesh_model.dart';

/// Marching Cubes mesh extraction from a voxelized point cloud.
///
/// This is a simplified implementation that:
/// 1. Voxelizes the point cloud into a 3D grid
/// 2. Computes an implicit function (distance to nearest point)
/// 3. Extracts an isosurface using Marching Cubes
class PoissonMeshService {
  /// Grid resolution along each axis.
  final int gridResolution;

  /// Iso-level for surface extraction (in voxel units).
  final double isoLevel;

  PoissonMeshService({
    this.gridResolution = 64,
    this.isoLevel = 1.5,
  });

  /// Generate mesh from point cloud using voxelization + Marching Cubes.
  Future<MeshModel> generateMesh(PointCloud cloud) async {
    if (cloud.points.length < 4) {
      return MeshModel(vertices: [], faces: [], method: 'marching_cubes');
    }

    return compute(_generateMeshIsolate, {
      'positions': cloud.points
          .map((p) => [p.position.x, p.position.y, p.position.z])
          .toList(),
      'colors': cloud.points
          .map((p) => [
                (p.color.r * 255).round(),
                (p.color.g * 255).round(),
                (p.color.b * 255).round(),
              ])
          .toList(),
      'normals': cloud.points
          .map((p) => p.normal != null
              ? [p.normal!.x, p.normal!.y, p.normal!.z]
              : [0.0, 1.0, 0.0])
          .toList(),
      'gridRes': gridResolution,
      'isoLevel': isoLevel,
    });
  }

  static MeshModel _generateMeshIsolate(Map<String, dynamic> args) {
    final positions = args['positions'] as List;
    final colors = args['colors'] as List;
    final normals = args['normals'] as List;
    final gridRes = args['gridRes'] as int;
    final isoLevel = args['isoLevel'] as double;

    if (positions.isEmpty) {
      return MeshModel(vertices: [], faces: [], method: 'marching_cubes');
    }

    // Compute bounding box
    double minX = double.infinity,
        minY = double.infinity,
        minZ = double.infinity;
    double maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;

    for (final pos in positions) {
      final p = pos as List;
      final px = (p[0] as num).toDouble();
      final py = (p[1] as num).toDouble();
      final pz = (p[2] as num).toDouble();
      if (px < minX) minX = px;
      if (py < minY) minY = py;
      if (pz < minZ) minZ = pz;
      if (px > maxX) maxX = px;
      if (py > maxY) maxY = py;
      if (pz > maxZ) maxZ = pz;
    }

    // Add padding
    final pad =
        math.max(maxX - minX, math.max(maxY - minY, maxZ - minZ)) * 0.1;
    minX -= pad;
    minY -= pad;
    minZ -= pad;
    maxX += pad;
    maxY += pad;
    maxZ += pad;

    final dx = (maxX - minX) / gridRes;
    final dy = (maxY - minY) / gridRes;
    final dz = (maxZ - minZ) / gridRes;

    // Build scalar field: distance to nearest point (capped)
    final grid =
        Float32List((gridRes + 1) * (gridRes + 1) * (gridRes + 1));
    final maxDist = math.max(dx, math.max(dy, dz)) * isoLevel * 2;

    for (int iz = 0; iz <= gridRes; iz++) {
      for (int iy = 0; iy <= gridRes; iy++) {
        for (int ix = 0; ix <= gridRes; ix++) {
          final gx = minX + ix * dx;
          final gy = minY + iy * dy;
          final gz = minZ + iz * dz;

          double minDistSq = maxDist * maxDist;
          for (final pos in positions) {
            final p = pos as List;
            final ddx = gx - (p[0] as num).toDouble();
            final ddy = gy - (p[1] as num).toDouble();
            final ddz = gz - (p[2] as num).toDouble();
            final distSq = ddx * ddx + ddy * ddy + ddz * ddz;
            if (distSq < minDistSq) minDistSq = distSq;
          }

          grid[iz * (gridRes + 1) * (gridRes + 1) +
              iy * (gridRes + 1) +
              ix] = math.sqrt(minDistSq);
        }
      }
    }

    // Marching Cubes (simplified: only generate vertices at edge crossings)
    final vertices = <MeshVertex>[];
    final faces = <MeshFace>[];
    final edgeVertexCache = <int, int>{}; // edge hash -> vertex index

    final threshold = isoLevel * math.max(dx, math.max(dy, dz));

    for (int iz = 0; iz < gridRes; iz++) {
      for (int iy = 0; iy < gridRes; iy++) {
        for (int ix = 0; ix < gridRes; ix++) {
          // Get 8 corner values
          final vals = <double>[];
          for (int cz = 0; cz <= 1; cz++) {
            for (int cy = 0; cy <= 1; cy++) {
              for (int cx = 0; cx <= 1; cx++) {
                vals.add(grid[
                    (iz + cz) * (gridRes + 1) * (gridRes + 1) +
                        (iy + cy) * (gridRes + 1) +
                        (ix + cx)]);
              }
            }
          }

          // Determine cube index (which corners are inside the surface)
          int cubeIndex = 0;
          for (int i = 0; i < 8; i++) {
            if (vals[i] < threshold) cubeIndex |= (1 << i);
          }

          if (cubeIndex == 0 || cubeIndex == 255) continue;

          // Simplified: create a vertex at the cell center if any edge crosses
          final cx = minX + (ix + 0.5) * dx;
          final cy = minY + (iy + 0.5) * dy;
          final cz = minZ + (iz + 0.5) * dz;

          // Find nearest point for color
          double nearestDistSq = double.infinity;
          int nearestIdx = 0;
          for (int pi = 0; pi < positions.length; pi++) {
            final p = positions[pi] as List;
            final ddx = cx - (p[0] as num).toDouble();
            final ddy = cy - (p[1] as num).toDouble();
            final ddz = cz - (p[2] as num).toDouble();
            final distSq = ddx * ddx + ddy * ddy + ddz * ddz;
            if (distSq < nearestDistSq) {
              nearestDistSq = distSq;
              nearestIdx = pi;
            }
          }

          final c = colors[nearestIdx] as List;
          final n = normals[nearestIdx] as List;

          final vi = vertices.length;
          vertices.add(MeshVertex(
            position: Vector3(cx, cy, cz),
            normal: Vector3(
              (n[0] as num).toDouble(),
              (n[1] as num).toDouble(),
              (n[2] as num).toDouble(),
            ),
            color: Color.fromARGB(
              255,
              (c[0] as int).clamp(0, 255),
              (c[1] as int).clamp(0, 255),
              (c[2] as int).clamp(0, 255),
            ),
          ));

          // Connect to neighbors that also have vertices (create faces)
          final cellKey = iz * gridRes * gridRes + iy * gridRes + ix;
          edgeVertexCache[cellKey] = vi;

          // Check 3 previously visited neighbors for face generation
          final prevX = ix > 0
              ? edgeVertexCache[
                  iz * gridRes * gridRes + iy * gridRes + (ix - 1)]
              : null;
          final prevY = iy > 0
              ? edgeVertexCache[
                  iz * gridRes * gridRes + (iy - 1) * gridRes + ix]
              : null;
          final prevXY = (ix > 0 && iy > 0)
              ? edgeVertexCache[
                  iz * gridRes * gridRes + (iy - 1) * gridRes + (ix - 1)]
              : null;

          // Create quad faces from neighboring cells with consistent CCW winding
          if (prevX != null && prevY != null && prevXY != null) {
            faces.add(MeshFace(vi, prevXY, prevX));
            faces.add(MeshFace(vi, prevY, prevXY));
          }
        }
      }
    }

    return MeshModel(
      vertices: vertices,
      faces: faces,
      method: 'marching_cubes',
      metadata: {
        'grid_resolution': gridRes,
        'iso_level': isoLevel,
        'source_points': positions.length,
      },
    );
  }
}
