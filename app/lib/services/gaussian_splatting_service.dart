import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:vector_math/vector_math_64.dart';
import '../models/point_cloud.dart';

/// A single 3D Gaussian primitive for Gaussian Splatting rendering.
///
/// Each Gaussian is defined by:
/// - position: center in world space
/// - rotation: orientation quaternion (determines covariance axes)
/// - scale: radii along the three principal axes
/// - opacity: alpha value after sigmoid activation
/// - color: base diffuse color
/// - shCoeffs: spherical harmonics coefficients for view-dependent color
///   Layout: 3 bands x 3 channels (RGB) = up to 48 floats for degree-3 SH.
///   Band 0 (DC) is stored separately in [color]; shCoeffs holds bands 1-3.
class Gaussian3D {
  final Vector3 position;
  final Quaternion rotation;
  final Vector3 scale;
  final double opacity;
  final Color color;

  /// Spherical harmonics coefficients beyond the DC (band-0) term.
  /// For degree-1 SH: 9 floats (3 coeffs x 3 channels).
  /// For degree-2 SH: 24 floats. For degree-3 SH: 45 floats.
  /// Empty list means no view-dependent color (DC only).
  final Float32List shCoeffs;

  Gaussian3D({
    required this.position,
    required this.rotation,
    required this.scale,
    required this.opacity,
    required this.color,
    Float32List? shCoeffs,
  }) : shCoeffs = shCoeffs ?? Float32List(0);

  /// Compute the 3x3 covariance matrix from rotation and scale.
  /// Sigma = R * S * S^T * R^T  where S = diag(scale).
  Matrix3 get covariance3D {
    final r = rotation.asRotationMatrix();
    // S = diag(scale)
    final s = Matrix3.zero()
      ..setEntry(0, 0, scale.x)
      ..setEntry(1, 1, scale.y)
      ..setEntry(2, 2, scale.z);
    // RS = R * S
    final rs = r * s;
    // Sigma = RS * RS^T
    final rsT = rs.clone()..transpose();
    return rs * rsT;
  }

  /// Compute projected 2D covariance given a view matrix and focal lengths.
  /// Returns a 2x2 symmetric matrix as (a, b, c) where:
  ///   [[a, b],
  ///    [b, c]]
  ({double a, double b, double c}) projectCovariance2D({
    required Matrix4 viewMatrix,
    required double focalX,
    required double focalY,
    required Vector3 viewSpacePosition,
  }) {
    final tx = viewSpacePosition.x;
    final ty = viewSpacePosition.y;
    final tz = viewSpacePosition.z;
    if (tz.abs() < 1e-6) {
      return (a: 1.0, b: 0.0, c: 1.0);
    }

    // Jacobian of the projection: J = d(proj)/d(cam)
    final invZ = 1.0 / tz;
    final invZ2 = invZ * invZ;
    // J is 2x3:
    // [[fx/z, 0, -fx*tx/z^2],
    //  [0, fy/z, -fy*ty/z^2]]
    final j00 = focalX * invZ;
    final j02 = -focalX * tx * invZ2;
    final j11 = focalY * invZ;
    final j12 = -focalY * ty * invZ2;

    // Transform 3D covariance to view space: V = W * Sigma * W^T
    // where W is the upper-left 3x3 of viewMatrix
    final w = viewMatrix.getRotation();
    final sigma = covariance3D;
    final wSigma = w * sigma;
    final wT = w.clone()..transpose();
    final vCov = wSigma * wT;

    // Project: cov2D = J * vCov * J^T (2x2)
    // Expand manually for speed:
    final v00 = vCov.entry(0, 0);
    final v01 = vCov.entry(0, 1);
    final v02 = vCov.entry(0, 2);
    final v11 = vCov.entry(1, 1);
    final v12 = vCov.entry(1, 2);
    final v22 = vCov.entry(2, 2);

    final a = j00 * j00 * v00 + 2 * j00 * j02 * v02 + j02 * j02 * v22;
    final b = j00 * j11 * v01 + j00 * j12 * v02 + j02 * j11 * v12 + j02 * j12 * v22;
    final c = j11 * j11 * v11 + 2 * j11 * j12 * v12 + j12 * j12 * v22;

    // Add a small value to the diagonal for numerical stability (low-pass filter)
    const lowPassFilter = 0.3;
    return (a: a + lowPassFilter, b: b, c: c + lowPassFilter);
  }

  /// Evaluate spherical harmonics for view-dependent color.
  /// [viewDir] should be the normalized direction from the Gaussian to the camera.
  /// Returns the final RGB color including SH contribution.
  Color evaluateSH(Vector3 viewDir) {
    if (shCoeffs.isEmpty) return color;

    // SH basis functions (real, orthonormal)
    final x = viewDir.x;
    final y = viewDir.y;
    final z = viewDir.z;

    // Band 0 DC is already in color. We add higher bands as offsets.
    double dr = 0, dg = 0, db = 0;

    // Band 1 (3 coefficients per channel = 9 total)
    if (shCoeffs.length >= 9) {
      // Y_1^{-1} = sqrt(3/4pi) * y
      // Y_1^{0}  = sqrt(3/4pi) * z
      // Y_1^{1}  = sqrt(3/4pi) * x
      const c1 = 0.4886025119029199; // sqrt(3/(4*pi))
      final sh1_0 = c1 * y;
      final sh1_1 = c1 * z;
      final sh1_2 = c1 * x;

      dr += shCoeffs[0] * sh1_0 + shCoeffs[1] * sh1_1 + shCoeffs[2] * sh1_2;
      dg += shCoeffs[3] * sh1_0 + shCoeffs[4] * sh1_1 + shCoeffs[5] * sh1_2;
      db += shCoeffs[6] * sh1_0 + shCoeffs[7] * sh1_1 + shCoeffs[8] * sh1_2;
    }

    // Band 2 (5 coefficients per channel = 15 total, indices 9..23)
    if (shCoeffs.length >= 24) {
      const c2_0 = 1.0925484305920792;  // sqrt(15/(4*pi))
      const c2_1 = 0.31539156525252005; // sqrt(5/(16*pi))
      const c2_2 = 0.5462742152960396;  // sqrt(15/(16*pi))

      final sh2_0 = c2_0 * x * y;
      final sh2_1 = c2_0 * y * z;
      final sh2_2 = c2_1 * (3.0 * z * z - 1.0);
      final sh2_3 = c2_0 * x * z;
      final sh2_4 = c2_2 * (x * x - y * y);

      for (int ch = 0; ch < 3; ch++) {
        final base = 9 + ch * 5;
        final val = shCoeffs[base] * sh2_0 +
            shCoeffs[base + 1] * sh2_1 +
            shCoeffs[base + 2] * sh2_2 +
            shCoeffs[base + 3] * sh2_3 +
            shCoeffs[base + 4] * sh2_4;
        if (ch == 0) {
          dr += val;
        } else if (ch == 1) {
          dg += val;
        } else {
          db += val;
        }
      }
    }

    // Clamp to [0, 1]
    final r = ((color.r + dr)).clamp(0.0, 1.0);
    final g = ((color.g + dg)).clamp(0.0, 1.0);
    final b = ((color.b + db)).clamp(0.0, 1.0);

    return Color.fromRGBO(
      (r * 255).round(),
      (g * 255).round(),
      (b * 255).round(),
      opacity,
    );
  }

  Map<String, dynamic> toJson() => {
        'position': [position.x, position.y, position.z],
        'rotation': [rotation.x, rotation.y, rotation.z, rotation.w],
        'scale': [scale.x, scale.y, scale.z],
        'opacity': opacity,
        'color': [
          (color.r * 255).round(),
          (color.g * 255).round(),
          (color.b * 255).round(),
        ],
        'sh_coeffs': shCoeffs.toList(),
      };

  factory Gaussian3D.fromJson(Map<String, dynamic> json) {
    final pos = json['position'] as List;
    final rot = json['rotation'] as List;
    final sc = json['scale'] as List;
    final col = json['color'] as List;
    final sh = json['sh_coeffs'] as List? ?? [];

    return Gaussian3D(
      position: Vector3(
        (pos[0] as num).toDouble(),
        (pos[1] as num).toDouble(),
        (pos[2] as num).toDouble(),
      ),
      rotation: Quaternion(
        (rot[0] as num).toDouble(),
        (rot[1] as num).toDouble(),
        (rot[2] as num).toDouble(),
        (rot[3] as num).toDouble(),
      ),
      scale: Vector3(
        (sc[0] as num).toDouble(),
        (sc[1] as num).toDouble(),
        (sc[2] as num).toDouble(),
      ),
      opacity: (json['opacity'] as num).toDouble(),
      color: Color.fromARGB(
        255,
        (col[0] as num).toInt(),
        (col[1] as num).toInt(),
        (col[2] as num).toInt(),
      ),
      shCoeffs: Float32List.fromList(
        sh.map((e) => (e as num).toDouble()).toList(),
      ),
    );
  }
}

/// A scene composed of 3D Gaussians with associated metadata.
class GaussianScene {
  final List<Gaussian3D> gaussians;
  final DateTime createdAt;
  final String method;
  final Map<String, dynamic> metadata;

  GaussianScene({
    required this.gaussians,
    DateTime? createdAt,
    this.method = 'unknown',
    Map<String, dynamic>? metadata,
  })  : createdAt = createdAt ?? DateTime.now(),
        metadata = metadata ?? {};

  /// Bounding box of all Gaussian centers.
  ({Vector3 min, Vector3 max}) getBoundingBox() {
    if (gaussians.isEmpty) {
      return (min: Vector3.zero(), max: Vector3.zero());
    }

    double minX = gaussians.first.position.x;
    double minY = gaussians.first.position.y;
    double minZ = gaussians.first.position.z;
    double maxX = minX, maxY = minY, maxZ = minZ;

    for (final g in gaussians) {
      final p = g.position;
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.z < minZ) minZ = p.z;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
      if (p.z > maxZ) maxZ = p.z;
    }

    return (min: Vector3(minX, minY, minZ), max: Vector3(maxX, maxY, maxZ));
  }

  Vector3 getCenter() {
    final bbox = getBoundingBox();
    return (bbox.min + bbox.max) / 2;
  }

  /// Convert this scene back to a PointCloud (positions and colors only).
  PointCloud toPointCloud() {
    return PointCloud(
      points: gaussians.map((g) => Point3D(
        position: g.position.clone(),
        color: g.color,
        confidence: g.opacity,
      )).toList(),
      method: '3dgs_to_pointcloud',
      metadata: {'source_method': method, 'gaussian_count': gaussians.length},
    );
  }

  Map<String, dynamic> toJson() => {
        'gaussians': gaussians.map((g) => g.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'method': method,
        'metadata': metadata,
        'gaussianCount': gaussians.length,
      };

  factory GaussianScene.fromJson(Map<String, dynamic> json) => GaussianScene(
        gaussians: (json['gaussians'] as List)
            .map((g) => Gaussian3D.fromJson(g as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        method: json['method'] as String? ?? 'unknown',
        metadata: json['metadata'] as Map<String, dynamic>? ?? {},
      );
}

/// Service for creating, loading, and exporting 3D Gaussian Splatting scenes.
class GaussianSplattingService {
  /// Convert an existing [PointCloud] to a [GaussianScene].
  ///
  /// Each point becomes a Gaussian with:
  /// - Isotropic scale based on average nearest-neighbor distance (or [defaultScale])
  /// - Identity rotation
  /// - Opacity from point confidence
  /// - Color from point color
  GaussianScene convertFromPointCloud(
    PointCloud cloud, {
    double? defaultScale,
  }) {
    try {
      if (cloud.points.isEmpty) {
        return GaussianScene(
          gaussians: [],
          method: '3dgs_from_${cloud.method}',
          metadata: {'source_method': cloud.method},
        );
      }

      // Estimate a reasonable default scale from point cloud density.
      // Sample a subset to estimate average nearest-neighbor distance.
      final scale = defaultScale ?? _estimateScale(cloud);

      final gaussians = cloud.points.map((point) {
        return Gaussian3D(
          position: point.position.clone(),
          rotation: Quaternion.identity(),
          scale: Vector3(scale, scale, scale),
          opacity: point.confidence,
          color: point.color,
        );
      }).toList();

      return GaussianScene(
        gaussians: gaussians,
        method: '3dgs_from_${cloud.method}',
        metadata: {
          'source_method': cloud.method,
          'source_point_count': cloud.points.length,
          'initial_scale': scale,
        },
      );
    } catch (e) {
      debugPrint('GaussianSplattingService: convertFromPointCloud failed: $e');
      return GaussianScene(
        gaussians: [],
        method: '3dgs_from_${cloud.method}_error',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Estimate a reasonable isotropic scale from average nearest-neighbor distance.
  double _estimateScale(PointCloud cloud) {
    if (cloud.points.length < 2) return 0.01;

    final rng = math.Random(42);
    final sampleCount = math.min(100, cloud.points.length);
    double totalDist = 0;
    int count = 0;

    for (int i = 0; i < sampleCount; i++) {
      final idx = rng.nextInt(cloud.points.length);
      final p = cloud.points[idx].position;

      double minDist = double.infinity;
      // Check a random subset of neighbors
      for (int j = 0; j < math.min(20, cloud.points.length); j++) {
        final nIdx = rng.nextInt(cloud.points.length);
        if (nIdx == idx) continue;
        final d = (cloud.points[nIdx].position - p).length;
        if (d < minDist && d > 1e-10) minDist = d;
      }

      if (minDist < double.infinity) {
        totalDist += minDist;
        count++;
      }
    }

    // Use half the average nearest-neighbor distance as scale
    return count > 0 ? (totalDist / count) * 0.5 : 0.01;
  }

  /// Load a .splat file (compact binary format used by web viewers).
  ///
  /// .splat format per Gaussian (32 bytes):
  ///   position: 3 x float32 (12 bytes)
  ///   scale:    3 x float32 (12 bytes)
  ///   color:    4 x uint8   (RGBA, 4 bytes)
  ///   rotation: 4 x uint8   (normalized quaternion xyzw, 4 bytes) -- [NOT USED, some formats vary]
  ///
  /// Note: The .splat format is not fully standardized; this implements the
  /// common web-viewer variant (antimatter15/splat).
  Future<GaussianScene> loadFromSplat(String path, {Duration timeout = const Duration(seconds: 60)}) async {
    try {
      return await _loadFromSplatImpl(path).timeout(timeout, onTimeout: () {
        debugPrint('GaussianSplattingService: loadFromSplat timed out after ${timeout.inSeconds}s');
        return GaussianScene(gaussians: [], method: 'splat_import_timeout', metadata: {'source': path});
      });
    } catch (e) {
      debugPrint('GaussianSplattingService: loadFromSplat failed: $e');
      return GaussianScene(gaussians: [], method: 'splat_import_error', metadata: {'error': e.toString()});
    }
  }

  Future<GaussianScene> _loadFromSplatImpl(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('File not found', path);
    }

    final bytes = await file.readAsBytes();
    const bytesPerGaussian = 32;

    if (bytes.length % bytesPerGaussian != 0) {
      throw FormatException(
        '.splat file size (${bytes.length}) is not a multiple of $bytesPerGaussian bytes',
      );
    }

    final gaussianCount = bytes.length ~/ bytesPerGaussian;
    final data = ByteData.sublistView(bytes);
    final gaussians = <Gaussian3D>[];

    for (int i = 0; i < gaussianCount; i++) {
      final offset = i * bytesPerGaussian;

      // Position (3 x float32, little-endian)
      final px = data.getFloat32(offset + 0, Endian.little);
      final py = data.getFloat32(offset + 4, Endian.little);
      final pz = data.getFloat32(offset + 8, Endian.little);

      // Scale (3 x float32, stored as log-scale in some formats)
      final sx = data.getFloat32(offset + 12, Endian.little);
      final sy = data.getFloat32(offset + 16, Endian.little);
      final sz = data.getFloat32(offset + 20, Endian.little);

      // Color (4 x uint8 RGBA)
      final r = bytes[offset + 24];
      final g = bytes[offset + 25];
      final b = bytes[offset + 26];
      final a = bytes[offset + 27];

      // Rotation (4 x uint8, map from [0,255] to [-1,1])
      final qx = (bytes[offset + 28] - 128) / 128.0;
      final qy = (bytes[offset + 29] - 128) / 128.0;
      final qz = (bytes[offset + 30] - 128) / 128.0;
      final qw = (bytes[offset + 31] - 128) / 128.0;

      // Normalize quaternion
      final qLen = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
      final nqx = qLen > 1e-8 ? qx / qLen : 0.0;
      final nqy = qLen > 1e-8 ? qy / qLen : 0.0;
      final nqz = qLen > 1e-8 ? qz / qLen : 0.0;
      final nqw = qLen > 1e-8 ? qw / qLen : 1.0;

      gaussians.add(Gaussian3D(
        position: Vector3(px, py, pz),
        rotation: Quaternion(nqx, nqy, nqz, nqw),
        scale: Vector3(
          math.exp(sx).clamp(1e-6, 10.0),
          math.exp(sy).clamp(1e-6, 10.0),
          math.exp(sz).clamp(1e-6, 10.0),
        ),
        opacity: a / 255.0,
        color: Color.fromARGB(255, r, g, b),
      ));
    }

    return GaussianScene(
      gaussians: gaussians,
      method: 'splat_import',
      metadata: {'source': path, 'gaussian_count': gaussianCount},
    );
  }

  /// Load a .ply file in the 3DGS format (as output by the original
  /// 3D Gaussian Splatting codebase).
  ///
  /// Expected properties: x, y, z, nx, ny, nz, f_dc_0..f_dc_2,
  /// f_rest_0..f_rest_N, opacity, scale_0..scale_2, rot_0..rot_3.
  Future<GaussianScene> loadFromPly(String path, {Duration timeout = const Duration(seconds: 60)}) async {
    try {
      return await _loadFromPlyImpl(path).timeout(timeout, onTimeout: () {
        debugPrint('GaussianSplattingService: loadFromPly timed out after ${timeout.inSeconds}s');
        return GaussianScene(gaussians: [], method: 'ply_3dgs_import_timeout', metadata: {'source': path});
      });
    } catch (e) {
      debugPrint('GaussianSplattingService: loadFromPly failed: $e');
      return GaussianScene(gaussians: [], method: 'ply_3dgs_import_error', metadata: {'error': e.toString()});
    }
  }

  Future<GaussianScene> _loadFromPlyImpl(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('File not found', path);
    }

    final bytes = await file.readAsBytes();
    final content = utf8.decode(bytes, allowMalformed: true);

    // Parse header
    final headerEndIndex = content.indexOf('end_header');
    if (headerEndIndex < 0) {
      throw const FormatException('Invalid PLY file: missing end_header');
    }
    final headerStr = content.substring(0, headerEndIndex + 'end_header'.length);
    final headerLines = headerStr.split('\n').map((l) => l.trim()).toList();

    // Determine format
    bool isBinary = false;
    bool isLittleEndian = true;
    int vertexCount = 0;
    final propertyNames = <String>[];
    final propertyTypes = <String>[];

    for (final line in headerLines) {
      if (line.startsWith('format')) {
        if (line.contains('binary_little_endian')) {
          isBinary = true;
          isLittleEndian = true;
        } else if (line.contains('binary_big_endian')) {
          isBinary = true;
          isLittleEndian = false;
        }
      } else if (line.startsWith('element vertex')) {
        vertexCount = int.parse(line.split(' ').last);
      } else if (line.startsWith('property')) {
        final parts = line.split(' ');
        if (parts.length >= 3) {
          propertyTypes.add(parts[1]);
          propertyNames.add(parts[2]);
        }
      }
    }

    // Build property index map
    final propIndex = <String, int>{};
    for (int i = 0; i < propertyNames.length; i++) {
      propIndex[propertyNames[i]] = i;
    }

    // Calculate bytes per property type
    int sizeOf(String type) {
      switch (type) {
        case 'float':
        case 'float32':
        case 'int':
        case 'int32':
        case 'uint':
        case 'uint32':
          return 4;
        case 'double':
        case 'float64':
        case 'int64':
        case 'uint64':
          return 8;
        case 'short':
        case 'int16':
        case 'uint16':
        case 'ushort':
          return 2;
        case 'char':
        case 'int8':
        case 'uchar':
        case 'uint8':
          return 1;
        default:
          return 4;
      }
    }

    double readProperty(ByteData data, int offset, String type, Endian endian) {
      switch (type) {
        case 'float':
        case 'float32':
          return data.getFloat32(offset, endian);
        case 'double':
        case 'float64':
          return data.getFloat64(offset, endian);
        case 'int':
        case 'int32':
          return data.getInt32(offset, endian).toDouble();
        case 'uint':
        case 'uint32':
          return data.getUint32(offset, endian).toDouble();
        case 'short':
        case 'int16':
          return data.getInt16(offset, endian).toDouble();
        case 'ushort':
        case 'uint16':
          return data.getUint16(offset, endian).toDouble();
        case 'uchar':
        case 'uint8':
          return data.getUint8(offset).toDouble();
        case 'char':
        case 'int8':
          return data.getInt8(offset).toDouble();
        default:
          return data.getFloat32(offset, endian);
      }
    }

    final gaussians = <Gaussian3D>[];

    if (isBinary) {
      // Find the byte offset where data starts (after "end_header\n")
      int dataStart = 0;
      for (int i = 0; i < bytes.length - 10; i++) {
        if (bytes[i] == 0x65 && // 'e'
            bytes[i + 1] == 0x6E && // 'n'
            bytes[i + 2] == 0x64 && // 'd'
            bytes[i + 3] == 0x5F && // '_'
            bytes[i + 4] == 0x68 && // 'h'
            bytes[i + 5] == 0x65 && // 'e'
            bytes[i + 6] == 0x61 && // 'a'
            bytes[i + 7] == 0x64 && // 'd'
            bytes[i + 8] == 0x65 && // 'e'
            bytes[i + 9] == 0x72) {
          // 'r'
          dataStart = i + 10;
          // Skip newline
          if (dataStart < bytes.length && bytes[dataStart] == 0x0A) {
            dataStart++;
          } else if (dataStart < bytes.length && bytes[dataStart] == 0x0D) {
            dataStart++;
            if (dataStart < bytes.length && bytes[dataStart] == 0x0A) {
              dataStart++;
            }
          }
          break;
        }
      }

      final endian = isLittleEndian ? Endian.little : Endian.big;
      final bytesPerVertex =
          List.generate(propertyTypes.length, (i) => sizeOf(propertyTypes[i]))
              .fold<int>(0, (a, b) => a + b);
      final byteData = ByteData.sublistView(bytes);

      for (int v = 0; v < vertexCount; v++) {
        final vOffset = dataStart + v * bytesPerVertex;
        if (vOffset + bytesPerVertex > bytes.length) break;

        // Read all properties for this vertex into a list
        final values = <double>[];
        int pOffset = vOffset;
        for (int p = 0; p < propertyTypes.length; p++) {
          values.add(readProperty(byteData, pOffset, propertyTypes[p], endian));
          pOffset += sizeOf(propertyTypes[p]);
        }

        gaussians.add(_buildGaussian(values, propIndex, propertyNames));
      }
    } else {
      // ASCII format
      final dataLines = content
          .substring(headerEndIndex + 'end_header'.length)
          .trim()
          .split('\n');

      for (int v = 0; v < vertexCount && v < dataLines.length; v++) {
        final parts = dataLines[v].trim().split(RegExp(r'\s+'));
        if (parts.length < propertyNames.length) continue;

        final values = parts.map((s) => double.parse(s)).toList();
        gaussians.add(_buildGaussian(values, propIndex, propertyNames));
      }
    }

    return GaussianScene(
      gaussians: gaussians,
      method: 'ply_3dgs_import',
      metadata: {
        'source': path,
        'gaussian_count': gaussians.length,
        'properties': propertyNames,
      },
    );
  }

  /// Build a [Gaussian3D] from a list of property values and index map.
  Gaussian3D _buildGaussian(
    List<double> values,
    Map<String, int> propIndex,
    List<String> propertyNames,
  ) {
    double prop(String name, [double fallback = 0.0]) {
      final idx = propIndex[name];
      return idx != null && idx < values.length ? values[idx] : fallback;
    }

    final px = prop('x');
    final py = prop('y');
    final pz = prop('z');

    // Scale (stored as log in 3DGS format)
    final sx = math.exp(prop('scale_0')).clamp(1e-6, 10.0);
    final sy = math.exp(prop('scale_1')).clamp(1e-6, 10.0);
    final sz = math.exp(prop('scale_2')).clamp(1e-6, 10.0);

    // Rotation quaternion (wxyz in 3DGS format)
    final rw = prop('rot_0', 1.0);
    final rx = prop('rot_1');
    final ry = prop('rot_2');
    final rz = prop('rot_3');
    final rLen = math.sqrt(rx * rx + ry * ry + rz * rz + rw * rw);
    final nrx = rLen > 1e-8 ? rx / rLen : 0.0;
    final nry = rLen > 1e-8 ? ry / rLen : 0.0;
    final nrz = rLen > 1e-8 ? rz / rLen : 0.0;
    final nrw = rLen > 1e-8 ? rw / rLen : 1.0;

    // Opacity (stored as logit in 3DGS format, apply sigmoid)
    final opacityLogit = prop('opacity');
    final opacity = 1.0 / (1.0 + math.exp(-opacityLogit));

    // DC color from SH band-0 (f_dc_0, f_dc_1, f_dc_2)
    // 3DGS stores these as SH coefficients; convert to RGB via:
    // color = 0.5 + C0 * sh_dc, where C0 = 0.28209479177387814
    const c0 = 0.28209479177387814;
    final dcR = (0.5 + c0 * prop('f_dc_0')).clamp(0.0, 1.0);
    final dcG = (0.5 + c0 * prop('f_dc_1')).clamp(0.0, 1.0);
    final dcB = (0.5 + c0 * prop('f_dc_2')).clamp(0.0, 1.0);

    // Collect higher-order SH coefficients (f_rest_0, f_rest_1, ...)
    final shCoeffs = <double>[];
    for (int i = 0; i < 45; i++) {
      final name = 'f_rest_$i';
      if (propIndex.containsKey(name)) {
        shCoeffs.add(prop(name));
      } else {
        break;
      }
    }

    // If no DC SH properties exist, try regular color properties
    Color color;
    if (propIndex.containsKey('f_dc_0')) {
      color = Color.fromRGBO(
        (dcR * 255).round(),
        (dcG * 255).round(),
        (dcB * 255).round(),
        1.0,
      );
    } else {
      color = Color.fromARGB(
        255,
        prop('red', 128).round().clamp(0, 255),
        prop('green', 128).round().clamp(0, 255),
        prop('blue', 128).round().clamp(0, 255),
      );
    }

    return Gaussian3D(
      position: Vector3(px, py, pz),
      rotation: Quaternion(nrx, nry, nrz, nrw),
      scale: Vector3(sx.toDouble(), sy.toDouble(), sz.toDouble()),
      opacity: opacity,
      color: color,
      shCoeffs: shCoeffs.isNotEmpty ? Float32List.fromList(shCoeffs) : null,
    );
  }

  /// Export a [GaussianScene] to a glTF 2.0 file with the
  /// KHR_gaussian_splatting extension.
  ///
  /// The extension encodes Gaussians as a point primitive with accessors for
  /// position, rotation (quaternion), scale, opacity, and SH coefficients.
  /// Reference: https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_gaussian_splatting
  Future<void> exportToGltf(GaussianScene scene, String outputPath, {Duration timeout = const Duration(seconds: 60)}) async {
    try {
      await _exportToGltfImpl(scene, outputPath).timeout(timeout, onTimeout: () {
        debugPrint('GaussianSplattingService: exportToGltf timed out after ${timeout.inSeconds}s');
      });
    } catch (e) {
      debugPrint('GaussianSplattingService: exportToGltf failed: $e');
    }
  }

  Future<void> _exportToGltfImpl(GaussianScene scene, String outputPath) async {
    final count = scene.gaussians.length;
    if (count == 0) {
      debugPrint('GaussianSplattingService: Cannot export empty scene');
      return;
    }

    // Build binary buffer containing all Gaussian data.
    // Layout per Gaussian:
    //   position: 3 x float32 (12 bytes)
    //   rotation: 4 x float32 (16 bytes)  -- xyzw
    //   scale:    3 x float32 (12 bytes)
    //   opacity:  1 x float32 (4 bytes)
    //   color:    3 x float32 (12 bytes)   -- linear RGB [0,1]
    // Total: 56 bytes per Gaussian
    const bytesPerGaussian = 56;
    final bufferLength = count * bytesPerGaussian;
    final buffer = Uint8List(bufferLength);
    final byteData = ByteData.sublistView(buffer);

    // Compute min/max for accessors
    final posMin = Vector3(double.infinity, double.infinity, double.infinity);
    final posMax =
        Vector3(-double.infinity, -double.infinity, -double.infinity);

    for (int i = 0; i < count; i++) {
      final g = scene.gaussians[i];
      final off = i * bytesPerGaussian;

      // Position
      byteData.setFloat32(off + 0, g.position.x, Endian.little);
      byteData.setFloat32(off + 4, g.position.y, Endian.little);
      byteData.setFloat32(off + 8, g.position.z, Endian.little);

      // Rotation (xyzw)
      byteData.setFloat32(off + 12, g.rotation.x, Endian.little);
      byteData.setFloat32(off + 16, g.rotation.y, Endian.little);
      byteData.setFloat32(off + 20, g.rotation.z, Endian.little);
      byteData.setFloat32(off + 24, g.rotation.w, Endian.little);

      // Scale
      byteData.setFloat32(off + 28, g.scale.x, Endian.little);
      byteData.setFloat32(off + 32, g.scale.y, Endian.little);
      byteData.setFloat32(off + 36, g.scale.z, Endian.little);

      // Opacity
      byteData.setFloat32(off + 40, g.opacity, Endian.little);

      // Color (linear RGB)
      byteData.setFloat32(off + 44, g.color.r, Endian.little);
      byteData.setFloat32(off + 48, g.color.g, Endian.little);
      byteData.setFloat32(off + 52, g.color.b, Endian.little);

      // Track min/max
      if (g.position.x < posMin.x) posMin.x = g.position.x;
      if (g.position.y < posMin.y) posMin.y = g.position.y;
      if (g.position.z < posMin.z) posMin.z = g.position.z;
      if (g.position.x > posMax.x) posMax.x = g.position.x;
      if (g.position.y > posMax.y) posMax.y = g.position.y;
      if (g.position.z > posMax.z) posMax.z = g.position.z;
    }

    // Encode buffer as base64 data URI for embedded glTF
    final bufferBase64 = base64Encode(buffer);

    // Build glTF JSON
    // Buffer views (all interleaved in one buffer, stride = bytesPerGaussian):
    // 0: position  (offset 0,  length 12)
    // 1: rotation  (offset 12, length 16)
    // 2: scale     (offset 28, length 12)
    // 3: opacity   (offset 40, length 4)
    // 4: color     (offset 44, length 12)
    final gltf = {
      'asset': {
        'version': '2.0',
        'generator': 'AncientVision GaussianSplattingService',
      },
      'extensionsUsed': ['KHR_gaussian_splatting'],
      'extensionsRequired': ['KHR_gaussian_splatting'],
      'scene': 0,
      'scenes': [
        {
          'nodes': [0],
        }
      ],
      'nodes': [
        {
          'mesh': 0,
          'name': 'GaussianSplat',
        }
      ],
      'meshes': [
        {
          'primitives': [
            {
              'mode': 0, // POINTS
              'attributes': {
                'POSITION': 0,
              },
              'extensions': {
                'KHR_gaussian_splatting': {
                  'rotation': 1,
                  'scale': 2,
                  'opacity': 3,
                  'color': 4,
                },
              },
            }
          ],
        }
      ],
      'accessors': [
        // 0: POSITION
        {
          'bufferView': 0,
          'byteOffset': 0,
          'componentType': 5126, // FLOAT
          'count': count,
          'type': 'VEC3',
          'min': [posMin.x, posMin.y, posMin.z],
          'max': [posMax.x, posMax.y, posMax.z],
        },
        // 1: rotation
        {
          'bufferView': 1,
          'byteOffset': 0,
          'componentType': 5126,
          'count': count,
          'type': 'VEC4',
        },
        // 2: scale
        {
          'bufferView': 2,
          'byteOffset': 0,
          'componentType': 5126,
          'count': count,
          'type': 'VEC3',
        },
        // 3: opacity
        {
          'bufferView': 3,
          'byteOffset': 0,
          'componentType': 5126,
          'count': count,
          'type': 'SCALAR',
        },
        // 4: color
        {
          'bufferView': 4,
          'byteOffset': 0,
          'componentType': 5126,
          'count': count,
          'type': 'VEC3',
        },
      ],
      'bufferViews': [
        // 0: position
        {
          'buffer': 0,
          'byteOffset': 0,
          'byteLength': bufferLength,
          'byteStride': bytesPerGaussian,
        },
        // 1: rotation
        {
          'buffer': 0,
          'byteOffset': 12,
          'byteLength': bufferLength,
          'byteStride': bytesPerGaussian,
        },
        // 2: scale
        {
          'buffer': 0,
          'byteOffset': 28,
          'byteLength': bufferLength,
          'byteStride': bytesPerGaussian,
        },
        // 3: opacity
        {
          'buffer': 0,
          'byteOffset': 40,
          'byteLength': bufferLength,
          'byteStride': bytesPerGaussian,
        },
        // 4: color
        {
          'buffer': 0,
          'byteOffset': 44,
          'byteLength': bufferLength,
          'byteStride': bytesPerGaussian,
        },
      ],
      'buffers': [
        {
          'uri': 'data:application/octet-stream;base64,$bufferBase64',
          'byteLength': bufferLength,
        }
      ],
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(gltf);
    final outFile = File(outputPath);
    await outFile.parent.create(recursive: true);
    await outFile.writeAsString(jsonStr);
  }
}
