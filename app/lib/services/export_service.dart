import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:archive/archive.dart';
import '../models/site.dart';
import '../models/field_journal.dart';
import '../models/context_sheet.dart';
import '../models/measurement.dart';
import '../models/point_cloud.dart';
import '../models/mesh_model.dart';

/// Supported export formats
enum ExportFormat {
  json('JSON', 'json', 'application/json'),
  csv('CSV', 'csv', 'text/csv'),
  geojson('GeoJSON', 'geojson', 'application/geo+json'),
  kml('KML', 'kml', 'application/vnd.google-earth.kml+xml');

  final String label;
  final String extension;
  final String mimeType;

  const ExportFormat(this.label, this.extension, this.mimeType);
}

/// 3D Model export formats
enum Model3DFormat {
  ply('PLY', 'ply', 'application/ply'),
  obj('OBJ', 'obj', 'text/plain'),
  gltf('glTF', 'gltf', 'model/gltf+json'),
  glb('GLB', 'glb', 'model/gltf-binary'),
  stl('STL', 'stl', 'application/sla'),
  xyz('XYZ', 'xyz', 'text/plain');

  final String label;
  final String extension;
  final String mimeType;

  const Model3DFormat(this.label, this.extension, this.mimeType);
}

/// Service for exporting data in various formats
class ExportService {
  static final ExportService _instance = ExportService._internal();
  factory ExportService() => _instance;
  ExportService._internal();

  final _dateFormat = DateFormat('yyyy-MM-dd');
  final _dateTimeFormat = DateFormat('yyyy-MM-dd_HH-mm-ss');

  /// Export findings to JSON
  Future<File?> exportFindingsToJson(List<Map<String, dynamic>> findings) async {
    try {
      final exportData = {
        'exportType': 'findings',
        'exportDate': DateTime.now().toIso8601String(),
        'count': findings.length,
        'data': findings,
        'metadata': {
          'app': 'AncientVision',
          'version': '1.0.0',
          'format': 'json',
        },
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      return await _saveFile(jsonString, 'findings_export', 'json');
    } catch (e) {
      debugPrint('Error exporting findings to JSON: $e');
      return null;
    }
  }

  /// Export findings to CSV
  Future<File?> exportFindingsToCsv(List<Map<String, dynamic>> findings) async {
    try {
      if (findings.isEmpty) return null;

      // Get all unique keys from findings
      final allKeys = <String>{};
      for (final f in findings) {
        allKeys.addAll(f.keys);
      }
      final headers = allKeys.toList()..sort();

      // Build CSV content
      final buffer = StringBuffer();

      // Header row
      buffer.writeln(headers.map(_escapeCsvField).join(','));

      // Data rows
      for (final finding in findings) {
        final row = headers.map((key) {
          final value = finding[key];
          return _escapeCsvField(_formatCsvValue(value));
        }).join(',');
        buffer.writeln(row);
      }

      return await _saveFile(buffer.toString(), 'findings_export', 'csv');
    } catch (e) {
      debugPrint('Error exporting findings to CSV: $e');
      return null;
    }
  }

  /// Export findings to GeoJSON for mapping applications
  Future<File?> exportFindingsToGeoJson(List<Map<String, dynamic>> findings) async {
    try {
      final features = <Map<String, dynamic>>[];

      for (final finding in findings) {
        final lat = finding['latitude'];
        final lng = finding['longitude'];
        if (lat != null && lng != null) {
          features.add({
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [lng, lat],
            },
            'properties': {
              'id': finding['id'],
              'description': finding['description'],
              'type': finding['type'],
              'site': finding['site'] ?? finding['siteName'],
              'date': finding['createdAt'],
            },
          });
        }
      }

      final geoJson = {
        'type': 'FeatureCollection',
        'features': features,
        'metadata': {
          'exportDate': DateTime.now().toIso8601String(),
          'count': features.length,
          'app': 'AncientVision',
        },
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(geoJson);
      return await _saveFile(jsonString, 'findings_export', 'geojson');
    } catch (e) {
      debugPrint('Error exporting to GeoJSON: $e');
      return null;
    }
  }

  /// Export findings to KML for Google Earth
  Future<File?> exportFindingsToKml(List<Map<String, dynamic>> findings) async {
    try {
      final buffer = StringBuffer();

      buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
      buffer.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
      buffer.writeln('  <Document>');
      buffer.writeln('    <name>AncientVision Findings Export</name>');
      buffer.writeln('    <description>Exported on ${DateTime.now().toIso8601String()}</description>');

      // Add placemarks for each finding
      for (final finding in findings) {
        final lat = finding['latitude'];
        final lng = finding['longitude'];
        if (lat != null && lng != null) {
          buffer.writeln('    <Placemark>');
          buffer.writeln('      <name>${_escapeXml(finding['id'] ?? 'Unknown')}</name>');
          buffer.writeln('      <description>${_escapeXml(finding['description'] ?? '')}</description>');
          buffer.writeln('      <Point>');
          buffer.writeln('        <coordinates>$lng,$lat,0</coordinates>');
          buffer.writeln('      </Point>');
          buffer.writeln('    </Placemark>');
        }
      }

      buffer.writeln('  </Document>');
      buffer.writeln('</kml>');

      return await _saveFile(buffer.toString(), 'findings_export', 'kml');
    } catch (e) {
      debugPrint('Error exporting to KML: $e');
      return null;
    }
  }

  /// Export site data
  Future<File?> exportSite(Site site, {ExportFormat format = ExportFormat.json}) async {
    try {
      final data = site.toJson();

      switch (format) {
        case ExportFormat.json:
          final jsonString = const JsonEncoder.withIndent('  ').convert({
            'exportType': 'site',
            'exportDate': DateTime.now().toIso8601String(),
            'data': data,
          });
          return await _saveFile(jsonString, 'site_${site.id}', 'json');

        case ExportFormat.csv:
          final buffer = StringBuffer();
          buffer.writeln(data.keys.map(_escapeCsvField).join(','));
          buffer.writeln(data.values.map((v) => _escapeCsvField(_formatCsvValue(v))).join(','));
          return await _saveFile(buffer.toString(), 'site_${site.id}', 'csv');

        default:
          return await exportSite(site, format: ExportFormat.json);
      }
    } catch (e) {
      debugPrint('Error exporting site: $e');
      return null;
    }
  }

  /// Export context sheets
  Future<File?> exportContextSheets(List<ContextSheet> contexts, {ExportFormat format = ExportFormat.json}) async {
    try {
      final data = contexts.map((c) => c.toJson()).toList();

      switch (format) {
        case ExportFormat.json:
          final jsonString = const JsonEncoder.withIndent('  ').convert({
            'exportType': 'context_sheets',
            'exportDate': DateTime.now().toIso8601String(),
            'count': contexts.length,
            'data': data,
          });
          return await _saveFile(jsonString, 'context_sheets_export', 'json');

        case ExportFormat.csv:
          return _exportListToCsv(data, 'context_sheets_export');

        default:
          return await exportContextSheets(contexts, format: ExportFormat.json);
      }
    } catch (e) {
      debugPrint('Error exporting context sheets: $e');
      return null;
    }
  }

  /// Export journal entries
  Future<File?> exportJournalEntries(List<JournalEntry> entries, {ExportFormat format = ExportFormat.json}) async {
    try {
      final data = entries.map((e) => e.toJson()).toList();

      switch (format) {
        case ExportFormat.json:
          final jsonString = const JsonEncoder.withIndent('  ').convert({
            'exportType': 'field_journal',
            'exportDate': DateTime.now().toIso8601String(),
            'count': entries.length,
            'data': data,
          });
          return await _saveFile(jsonString, 'journal_export', 'json');

        case ExportFormat.csv:
          return _exportListToCsv(data, 'journal_export');

        default:
          return await exportJournalEntries(entries, format: ExportFormat.json);
      }
    } catch (e) {
      debugPrint('Error exporting journal: $e');
      return null;
    }
  }

  /// Export measurements
  Future<File?> exportMeasurements(List<Measurement> measurements, {ExportFormat format = ExportFormat.json}) async {
    try {
      final data = measurements.map((m) => m.toJson()).toList();

      switch (format) {
        case ExportFormat.json:
          final jsonString = const JsonEncoder.withIndent('  ').convert({
            'exportType': 'measurements',
            'exportDate': DateTime.now().toIso8601String(),
            'count': measurements.length,
            'data': data,
          });
          return await _saveFile(jsonString, 'measurements_export', 'json');

        case ExportFormat.csv:
          return _exportListToCsv(data, 'measurements_export');

        default:
          return await exportMeasurements(measurements, format: ExportFormat.json);
      }
    } catch (e) {
      debugPrint('Error exporting measurements: $e');
      return null;
    }
  }

  /// Create a complete project backup (ZIP archive)
  Future<File?> createFullBackup({
    required List<Map<String, dynamic>> findings,
    List<Site>? sites,
    List<ContextSheet>? contexts,
    List<JournalEntry>? journal,
    List<Measurement>? measurements,
  }) async {
    try {
      final archive = Archive();
      final timestamp = _dateTimeFormat.format(DateTime.now());

      // Add manifest
      final manifest = {
        'backupDate': DateTime.now().toIso8601String(),
        'app': 'AncientVision',
        'version': '1.0.0',
        'contents': {
          'findings': findings.length,
          'sites': sites?.length ?? 0,
          'contexts': contexts?.length ?? 0,
          'journal': journal?.length ?? 0,
          'measurements': measurements?.length ?? 0,
        },
      };
      archive.addFile(ArchiveFile(
        'manifest.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)).length,
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
      ));

      // Add findings
      if (findings.isNotEmpty) {
        final findingsJson = const JsonEncoder.withIndent('  ').convert(findings);
        archive.addFile(ArchiveFile(
          'findings.json',
          utf8.encode(findingsJson).length,
          utf8.encode(findingsJson),
        ));
      }

      // Add sites
      if (sites != null && sites.isNotEmpty) {
        final sitesJson = const JsonEncoder.withIndent('  ').convert(
          sites.map((s) => s.toJson()).toList(),
        );
        archive.addFile(ArchiveFile(
          'sites.json',
          utf8.encode(sitesJson).length,
          utf8.encode(sitesJson),
        ));
      }

      // Add contexts
      if (contexts != null && contexts.isNotEmpty) {
        final contextsJson = const JsonEncoder.withIndent('  ').convert(
          contexts.map((c) => c.toJson()).toList(),
        );
        archive.addFile(ArchiveFile(
          'contexts.json',
          utf8.encode(contextsJson).length,
          utf8.encode(contextsJson),
        ));
      }

      // Add journal entries
      if (journal != null && journal.isNotEmpty) {
        final journalJson = const JsonEncoder.withIndent('  ').convert(
          journal.map((j) => j.toJson()).toList(),
        );
        archive.addFile(ArchiveFile(
          'journal.json',
          utf8.encode(journalJson).length,
          utf8.encode(journalJson),
        ));
      }

      // Add measurements
      if (measurements != null && measurements.isNotEmpty) {
        final measurementsJson = const JsonEncoder.withIndent('  ').convert(
          measurements.map((m) => m.toJson()).toList(),
        );
        archive.addFile(ArchiveFile(
          'measurements.json',
          utf8.encode(measurementsJson).length,
          utf8.encode(measurementsJson),
        ));
      }

      // Save ZIP file
      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) return null;

      final dir = await getApplicationDocumentsDirectory();
      final exportDir = Directory('${dir.path}/exports');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      final file = File('${exportDir.path}/ancientvision_backup_$timestamp.zip');
      await file.writeAsBytes(zipData);

      debugPrint('Backup created: ${file.path}');
      return file;
    } catch (e) {
      debugPrint('Error creating backup: $e');
      return null;
    }
  }

  /// Share an exported file
  Future<void> shareFile(File file) async {
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'AncientVision Export',
    );
  }

  // ========== 3D MODEL EXPORT METHODS ==========

  /// Export point cloud to various 3D formats
  Future<File?> exportPointCloud(
    PointCloud pointCloud, {
    Model3DFormat format = Model3DFormat.ply,
    String? projectName,
  }) async {
    try {
      final name = projectName ?? 'pointcloud_${DateTime.now().millisecondsSinceEpoch}';

      switch (format) {
        case Model3DFormat.ply:
          return await _exportPointCloudToPly(pointCloud, name);
        case Model3DFormat.obj:
          return await _exportPointCloudToObj(pointCloud, name);
        case Model3DFormat.gltf:
          return await _exportPointCloudToGltf(pointCloud, name, binary: false);
        case Model3DFormat.glb:
          return await _exportPointCloudToGltf(pointCloud, name, binary: true);
        case Model3DFormat.stl:
          return await _exportPointCloudToStl(pointCloud, name);
        case Model3DFormat.xyz:
          return await _exportPointCloudToXyz(pointCloud, name);
      }
    } catch (e) {
      debugPrint('Error exporting point cloud: $e');
      return null;
    }
  }

  /// Export mesh model to various 3D formats
  Future<File?> exportMesh(
    MeshModel mesh, {
    Model3DFormat format = Model3DFormat.obj,
    String? projectName,
  }) async {
    try {
      final name = projectName ?? 'mesh_${DateTime.now().millisecondsSinceEpoch}';

      switch (format) {
        case Model3DFormat.ply:
          return await _exportMeshToPly(mesh, name);
        case Model3DFormat.obj:
          return await _exportMeshToObj(mesh, name);
        case Model3DFormat.gltf:
          return await _exportMeshToGltf(mesh, name, binary: false);
        case Model3DFormat.glb:
          return await _exportMeshToGltf(mesh, name, binary: true);
        case Model3DFormat.stl:
          return await _exportMeshToStl(mesh, name);
        case Model3DFormat.xyz:
          // Convert mesh to point cloud for XYZ export
          return await _exportPointCloudToXyz(mesh.toPointCloud(), name);
      }
    } catch (e) {
      debugPrint('Error exporting mesh: $e');
      return null;
    }
  }

  /// Export point cloud to PLY format (Stanford Polygon File Format)
  Future<File> _exportPointCloudToPly(PointCloud pointCloud, String name) async {
    final buffer = StringBuffer();

    // PLY header
    buffer.writeln('ply');
    buffer.writeln('format ascii 1.0');
    buffer.writeln('comment Exported by AncientVision');
    buffer.writeln('comment ${DateTime.now().toIso8601String()}');
    buffer.writeln('element vertex ${pointCloud.points.length}');
    buffer.writeln('property float x');
    buffer.writeln('property float y');
    buffer.writeln('property float z');
    buffer.writeln('property uchar red');
    buffer.writeln('property uchar green');
    buffer.writeln('property uchar blue');
    buffer.writeln('property float confidence');
    buffer.writeln('end_header');

    // Vertices
    for (final point in pointCloud.points) {
      buffer.writeln(
        '${point.position.x.toStringAsFixed(6)} '
        '${point.position.y.toStringAsFixed(6)} '
        '${point.position.z.toStringAsFixed(6)} '
        '${(point.color.r * 255).round()} ${(point.color.g * 255).round()} ${(point.color.b * 255).round()} '
        '${point.confidence.toStringAsFixed(4)}',
      );
    }

    return await _saveFile(buffer.toString(), name, 'ply');
  }

  /// Export point cloud to OBJ format (Wavefront)
  Future<File> _exportPointCloudToObj(PointCloud pointCloud, String name) async {
    final buffer = StringBuffer();

    buffer.writeln('# AncientVision Point Cloud Export');
    buffer.writeln('# ${DateTime.now().toIso8601String()}');
    buffer.writeln('# Points: ${pointCloud.points.length}');
    buffer.writeln();

    // Vertices with colors as comments
    for (final point in pointCloud.points) {
      buffer.writeln(
        'v ${point.position.x.toStringAsFixed(6)} '
        '${point.position.y.toStringAsFixed(6)} '
        '${point.position.z.toStringAsFixed(6)} '
        '${point.color.r} ${point.color.g} ${point.color.b}',
      );
    }

    return await _saveFile(buffer.toString(), name, 'obj');
  }

  /// Export point cloud to glTF/GLB format
  Future<File> _exportPointCloudToGltf(
    PointCloud pointCloud,
    String name, {
    bool binary = false,
  }) async {
    // Build glTF JSON structure
    final positions = <double>[];
    final colors = <double>[];

    double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;

    for (final point in pointCloud.points) {
      positions.addAll([point.position.x, point.position.y, point.position.z]);
      colors.addAll([
        point.color.r,
        point.color.g,
        point.color.b,
        1.0,
      ]);

      minX = minX < point.position.x ? minX : point.position.x;
      minY = minY < point.position.y ? minY : point.position.y;
      minZ = minZ < point.position.z ? minZ : point.position.z;
      maxX = maxX > point.position.x ? maxX : point.position.x;
      maxY = maxY > point.position.y ? maxY : point.position.y;
      maxZ = maxZ > point.position.z ? maxZ : point.position.z;
    }

    // Convert to bytes
    final positionBytes = Float32List.fromList(positions.map((d) => d.toDouble()).toList());
    final colorBytes = Float32List.fromList(colors.map((d) => d.toDouble()).toList());

    final positionBuffer = positionBytes.buffer.asUint8List();
    final colorBuffer = colorBytes.buffer.asUint8List();

    final gltf = {
      'asset': {
        'version': '2.0',
        'generator': 'AncientVision Archaeological App',
      },
      'scene': 0,
      'scenes': [
        {
          'nodes': [0],
        }
      ],
      'nodes': [
        {
          'mesh': 0,
          'name': name,
        }
      ],
      'meshes': [
        {
          'primitives': [
            {
              'attributes': {
                'POSITION': 0,
                'COLOR_0': 1,
              },
              'mode': 0, // POINTS
            }
          ],
          'name': name,
        }
      ],
      'accessors': [
        {
          'bufferView': 0,
          'componentType': 5126, // FLOAT
          'count': pointCloud.points.length,
          'type': 'VEC3',
          'min': [minX, minY, minZ],
          'max': [maxX, maxY, maxZ],
        },
        {
          'bufferView': 1,
          'componentType': 5126, // FLOAT
          'count': pointCloud.points.length,
          'type': 'VEC4',
        }
      ],
      'bufferViews': [
        {
          'buffer': 0,
          'byteOffset': 0,
          'byteLength': positionBuffer.length,
        },
        {
          'buffer': 0,
          'byteOffset': positionBuffer.length,
          'byteLength': colorBuffer.length,
        }
      ],
      'buffers': [
        {
          'byteLength': positionBuffer.length + colorBuffer.length,
        }
      ],
    };

    if (binary) {
      // GLB format
      return await _saveGlb(gltf, positionBuffer, colorBuffer, name);
    } else {
      // glTF format with embedded base64 data
      final combinedBuffer = Uint8List(positionBuffer.length + colorBuffer.length);
      combinedBuffer.setAll(0, positionBuffer);
      combinedBuffer.setAll(positionBuffer.length, colorBuffer);

      (gltf['buffers'] as List)[0]['uri'] =
          'data:application/octet-stream;base64,${base64Encode(combinedBuffer)}';

      final jsonString = const JsonEncoder.withIndent('  ').convert(gltf);
      return await _saveFile(jsonString, name, 'gltf');
    }
  }

  /// Save GLB binary file
  Future<File> _saveGlb(
    Map<String, dynamic> gltf,
    Uint8List positionBuffer,
    Uint8List colorBuffer,
    String name,
  ) async {
    final jsonString = jsonEncode(gltf);
    final jsonBytes = utf8.encode(jsonString);

    // Pad JSON to 4-byte alignment
    final jsonPadding = (4 - (jsonBytes.length % 4)) % 4;
    final paddedJson = Uint8List(jsonBytes.length + jsonPadding);
    paddedJson.setAll(0, jsonBytes);
    for (int i = 0; i < jsonPadding; i++) {
      paddedJson[jsonBytes.length + i] = 0x20; // Space
    }

    // Combine binary buffers
    final binBuffer = Uint8List(positionBuffer.length + colorBuffer.length);
    binBuffer.setAll(0, positionBuffer);
    binBuffer.setAll(positionBuffer.length, colorBuffer);

    // Pad binary to 4-byte alignment
    final binPadding = (4 - (binBuffer.length % 4)) % 4;
    final paddedBin = Uint8List(binBuffer.length + binPadding);
    paddedBin.setAll(0, binBuffer);

    // GLB header: magic + version + length
    // JSON chunk: length + type + data
    // BIN chunk: length + type + data
    final totalLength = 12 + 8 + paddedJson.length + 8 + paddedBin.length;

    final glb = ByteData(totalLength);
    int offset = 0;

    // Header
    glb.setUint32(offset, 0x46546C67, Endian.little); // 'glTF'
    offset += 4;
    glb.setUint32(offset, 2, Endian.little); // version
    offset += 4;
    glb.setUint32(offset, totalLength, Endian.little);
    offset += 4;

    // JSON chunk
    glb.setUint32(offset, paddedJson.length, Endian.little);
    offset += 4;
    glb.setUint32(offset, 0x4E4F534A, Endian.little); // 'JSON'
    offset += 4;
    for (int i = 0; i < paddedJson.length; i++) {
      glb.setUint8(offset + i, paddedJson[i]);
    }
    offset += paddedJson.length;

    // BIN chunk
    glb.setUint32(offset, paddedBin.length, Endian.little);
    offset += 4;
    glb.setUint32(offset, 0x004E4942, Endian.little); // 'BIN\0'
    offset += 4;
    for (int i = 0; i < paddedBin.length; i++) {
      glb.setUint8(offset + i, paddedBin[i]);
    }

    final dir = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${dir.path}/exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final timestamp = _dateTimeFormat.format(DateTime.now());
    final file = File('${exportDir.path}/${name}_$timestamp.glb');
    await file.writeAsBytes(glb.buffer.asUint8List());

    debugPrint('GLB exported: ${file.path}');
    return file;
  }

  /// Export point cloud to STL format (for 3D printing preview)
  Future<File> _exportPointCloudToStl(PointCloud pointCloud, String name) async {
    // STL requires triangles, so we create small triangles at each point
    final buffer = StringBuffer();
    buffer.writeln('solid $name');

    // Create tiny triangles at each point location
    const size = 0.001; // 1mm triangles
    for (final point in pointCloud.points) {
      final x = point.position.x;
      final y = point.position.y;
      final z = point.position.z;

      buffer.writeln('  facet normal 0 0 1');
      buffer.writeln('    outer loop');
      buffer.writeln('      vertex $x $y $z');
      buffer.writeln('      vertex ${x + size} $y $z');
      buffer.writeln('      vertex ${x + size / 2} ${y + size} $z');
      buffer.writeln('    endloop');
      buffer.writeln('  endfacet');
    }

    buffer.writeln('endsolid $name');
    return await _saveFile(buffer.toString(), name, 'stl');
  }

  /// Export point cloud to XYZ format (simple text)
  Future<File> _exportPointCloudToXyz(PointCloud pointCloud, String name) async {
    final buffer = StringBuffer();
    buffer.writeln('# XYZ Point Cloud - AncientVision Export');
    buffer.writeln('# X Y Z R G B');

    for (final point in pointCloud.points) {
      buffer.writeln(
        '${point.position.x.toStringAsFixed(6)} '
        '${point.position.y.toStringAsFixed(6)} '
        '${point.position.z.toStringAsFixed(6)} '
        '${(point.color.r * 255).round()} ${(point.color.g * 255).round()} ${(point.color.b * 255).round()}',
      );
    }

    return await _saveFile(buffer.toString(), name, 'xyz');
  }

  /// Export mesh to PLY format
  Future<File> _exportMeshToPly(MeshModel mesh, String name) async {
    final buffer = StringBuffer();

    buffer.writeln('ply');
    buffer.writeln('format ascii 1.0');
    buffer.writeln('comment Exported by AncientVision');
    buffer.writeln('element vertex ${mesh.vertices.length}');
    buffer.writeln('property float x');
    buffer.writeln('property float y');
    buffer.writeln('property float z');
    buffer.writeln('property float nx');
    buffer.writeln('property float ny');
    buffer.writeln('property float nz');
    buffer.writeln('property uchar red');
    buffer.writeln('property uchar green');
    buffer.writeln('property uchar blue');
    buffer.writeln('element face ${mesh.faces.length}');
    buffer.writeln('property list uchar int vertex_indices');
    buffer.writeln('end_header');

    for (final v in mesh.vertices) {
      final nx = v.normal?.x ?? 0.0;
      final ny = v.normal?.y ?? 0.0;
      final nz = v.normal?.z ?? 1.0;
      final r = (v.color?.r ?? 0.5) * 255;
      final g = (v.color?.g ?? 0.5) * 255;
      final b = (v.color?.b ?? 0.5) * 255;
      buffer.writeln(
        '${v.position.x.toStringAsFixed(6)} '
        '${v.position.y.toStringAsFixed(6)} '
        '${v.position.z.toStringAsFixed(6)} '
        '${nx.toStringAsFixed(6)} '
        '${ny.toStringAsFixed(6)} '
        '${nz.toStringAsFixed(6)} '
        '$r $g $b',
      );
    }

    for (final f in mesh.faces) {
      buffer.writeln('3 ${f.v1} ${f.v2} ${f.v3}');
    }

    return await _saveFile(buffer.toString(), name, 'ply');
  }

  /// Export mesh to OBJ format
  Future<File> _exportMeshToObj(MeshModel mesh, String name) async {
    final buffer = StringBuffer();

    buffer.writeln('# AncientVision Mesh Export');
    buffer.writeln('# ${DateTime.now().toIso8601String()}');
    buffer.writeln('# Vertices: ${mesh.vertices.length}');
    buffer.writeln('# Faces: ${mesh.faces.length}');
    buffer.writeln();

    // Vertices
    for (final v in mesh.vertices) {
      buffer.writeln(
        'v ${v.position.x.toStringAsFixed(6)} '
        '${v.position.y.toStringAsFixed(6)} '
        '${v.position.z.toStringAsFixed(6)}',
      );
    }
    buffer.writeln();

    // Normals
    for (final v in mesh.vertices) {
      final nx = v.normal?.x ?? 0.0;
      final ny = v.normal?.y ?? 0.0;
      final nz = v.normal?.z ?? 1.0;
      buffer.writeln(
        'vn ${nx.toStringAsFixed(6)} '
        '${ny.toStringAsFixed(6)} '
        '${nz.toStringAsFixed(6)}',
      );
    }
    buffer.writeln();

    // Faces (OBJ uses 1-based indexing)
    for (final f in mesh.faces) {
      buffer.writeln(
        'f ${f.v1 + 1}//${f.v1 + 1} '
        '${f.v2 + 1}//${f.v2 + 1} '
        '${f.v3 + 1}//${f.v3 + 1}',
      );
    }

    return await _saveFile(buffer.toString(), name, 'obj');
  }

  /// Export mesh to glTF/GLB format
  Future<File> _exportMeshToGltf(
    MeshModel mesh,
    String name, {
    bool binary = false,
  }) async {
    // Convert mesh to point cloud and use point cloud export
    // For a proper mesh, we would need triangle data
    return await _exportPointCloudToGltf(mesh.toPointCloud(), name, binary: binary);
  }

  /// Export mesh to STL format
  Future<File> _exportMeshToStl(MeshModel mesh, String name) async {
    final buffer = StringBuffer();
    buffer.writeln('solid $name');

    for (final face in mesh.faces) {
      final v1 = mesh.vertices[face.v1];
      final v2 = mesh.vertices[face.v2];
      final v3 = mesh.vertices[face.v3];

      // Calculate face normal (use v1's normal or default to Z-up)
      final nx = v1.normal?.x ?? 0.0;
      final ny = v1.normal?.y ?? 0.0;
      final nz = v1.normal?.z ?? 1.0;

      buffer.writeln('  facet normal $nx $ny $nz');
      buffer.writeln('    outer loop');
      buffer.writeln('      vertex ${v1.position.x} ${v1.position.y} ${v1.position.z}');
      buffer.writeln('      vertex ${v2.position.x} ${v2.position.y} ${v2.position.z}');
      buffer.writeln('      vertex ${v3.position.x} ${v3.position.y} ${v3.position.z}');
      buffer.writeln('    endloop');
      buffer.writeln('  endfacet');
    }

    buffer.writeln('endsolid $name');
    return await _saveFile(buffer.toString(), name, 'stl');
  }

  /// Get list of available exports
  Future<List<FileSystemEntity>> getExportedFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final exportDir = Directory('${dir.path}/exports');
      if (!await exportDir.exists()) return [];
      return exportDir.listSync()..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    } catch (e) {
      return [];
    }
  }

  /// Delete an exported file
  Future<bool> deleteExport(File file) async {
    try {
      await file.delete();
      return true;
    } catch (e) {
      return false;
    }
  }

  // ========== HELPER METHODS ==========

  Future<File?> _exportListToCsv(List<Map<String, dynamic>> data, String filename) async {
    if (data.isEmpty) return null;

    // Get all unique keys
    final allKeys = <String>{};
    for (final item in data) {
      allKeys.addAll(_flattenKeys(item));
    }
    final headers = allKeys.toList()..sort();

    // Build CSV
    final buffer = StringBuffer();
    buffer.writeln(headers.map(_escapeCsvField).join(','));

    for (final item in data) {
      final flatItem = _flattenMap(item);
      final row = headers.map((key) {
        return _escapeCsvField(_formatCsvValue(flatItem[key]));
      }).join(',');
      buffer.writeln(row);
    }

    return await _saveFile(buffer.toString(), filename, 'csv');
  }

  Set<String> _flattenKeys(Map<String, dynamic> map, [String prefix = '']) {
    final keys = <String>{};
    for (final entry in map.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        keys.addAll(_flattenKeys(entry.value as Map<String, dynamic>, key));
      } else {
        keys.add(key);
      }
    }
    return keys;
  }

  Map<String, dynamic> _flattenMap(Map<String, dynamic> map, [String prefix = '']) {
    final result = <String, dynamic>{};
    for (final entry in map.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        result.addAll(_flattenMap(entry.value as Map<String, dynamic>, key));
      } else {
        result[key] = entry.value;
      }
    }
    return result;
  }

  Future<File> _saveFile(String content, String baseName, String extension) async {
    final dir = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${dir.path}/exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final timestamp = _dateTimeFormat.format(DateTime.now());
    final filename = '${baseName}_$timestamp.$extension';
    final file = File('${exportDir.path}/$filename');
    await file.writeAsString(content);

    debugPrint('File exported: ${file.path}');
    return file;
  }

  String _escapeCsvField(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  String _formatCsvValue(dynamic value) {
    if (value == null) return '';
    if (value is DateTime) return _dateFormat.format(value);
    if (value is List) return value.join('; ');
    if (value is Map) return const JsonEncoder().convert(value);
    return value.toString();
  }

  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  // ========== BATCH EXPORT METHODS ==========

  /// Export multiple findings as a comprehensive ZIP package
  Future<File?> batchExportFindings({
    required List<Map<String, dynamic>> findings,
    required ExportFormat format,
    bool includePhotos = true,
    bool includeGeoData = true,
    Function(double progress, String status)? onProgress,
  }) async {
    try {
      if (findings.isEmpty) return null;

      final archive = Archive();
      final timestamp = _dateTimeFormat.format(DateTime.now());
      int processedCount = 0;

      onProgress?.call(0.0, 'Preparing export...');

      // Add manifest
      final manifest = {
        'exportType': 'batch_findings',
        'exportDate': DateTime.now().toIso8601String(),
        'count': findings.length,
        'format': format.label,
        'includesPhotos': includePhotos,
        'includesGeoData': includeGeoData,
        'app': 'AncientVision',
        'version': '1.0.0',
      };
      final manifestJson = const JsonEncoder.withIndent('  ').convert(manifest);
      archive.addFile(ArchiveFile(
        'manifest.json',
        utf8.encode(manifestJson).length,
        utf8.encode(manifestJson),
      ));

      // Export findings data based on format
      onProgress?.call(0.1, 'Exporting findings data...');

      switch (format) {
        case ExportFormat.json:
          final jsonData = const JsonEncoder.withIndent('  ').convert({
            'findings': findings,
            'metadata': manifest,
          });
          archive.addFile(ArchiveFile(
            'findings.json',
            utf8.encode(jsonData).length,
            utf8.encode(jsonData),
          ));
          break;

        case ExportFormat.csv:
          final csvContent = _generateCsvFromFindings(findings);
          archive.addFile(ArchiveFile(
            'findings.csv',
            utf8.encode(csvContent).length,
            utf8.encode(csvContent),
          ));
          break;

        case ExportFormat.geojson:
          final geoJson = _generateGeoJsonFromFindings(findings);
          archive.addFile(ArchiveFile(
            'findings.geojson',
            utf8.encode(geoJson).length,
            utf8.encode(geoJson),
          ));
          break;

        case ExportFormat.kml:
          final kml = _generateKmlFromFindings(findings);
          archive.addFile(ArchiveFile(
            'findings.kml',
            utf8.encode(kml).length,
            utf8.encode(kml),
          ));
          break;
      }

      // Include photos if requested
      if (includePhotos) {
        onProgress?.call(0.3, 'Processing photos...');

        for (final finding in findings) {
          final photos = finding['photos'] as List<dynamic>? ?? [];
          final findingId = finding['id'] ?? 'unknown_$processedCount';

          for (int i = 0; i < photos.length; i++) {
            final photoUrl = photos[i] as String?;
            if (photoUrl == null) continue;

            try {
              // Check if it's a local file
              if (photoUrl.startsWith('/') || photoUrl.startsWith('file://')) {
                final localPath = photoUrl.replaceFirst('file://', '');
                final file = File(localPath);
                if (await file.exists()) {
                  final bytes = await file.readAsBytes();
                  final ext = localPath.split('.').last;
                  archive.addFile(ArchiveFile(
                    'photos/${findingId}_photo_$i.$ext',
                    bytes.length,
                    bytes,
                  ));
                }
              }
              // Note: Remote URLs would need http package to download
              // For now, we include them as references in the JSON
            } catch (e) {
              debugPrint('Error processing photo: $e');
            }
          }

          processedCount++;
          final progress = 0.3 + (0.5 * processedCount / findings.length);
          onProgress?.call(progress, 'Processed $processedCount/${findings.length} findings...');
        }
      }

      // Generate summary report
      onProgress?.call(0.85, 'Generating summary...');
      final summary = _generateBatchSummary(findings);
      archive.addFile(ArchiveFile(
        'summary.txt',
        utf8.encode(summary).length,
        utf8.encode(summary),
      ));

      // Create ZIP file
      onProgress?.call(0.9, 'Creating archive...');
      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) return null;

      final dir = await getApplicationDocumentsDirectory();
      final exportDir = Directory('${dir.path}/exports');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      final file = File('${exportDir.path}/batch_export_${findings.length}_findings_$timestamp.zip');
      await file.writeAsBytes(zipData);

      onProgress?.call(1.0, 'Export complete!');
      debugPrint('Batch export created: ${file.path}');
      return file;
    } catch (e) {
      debugPrint('Error creating batch export: $e');
      return null;
    }
  }

  /// Generate CSV content from findings
  String _generateCsvFromFindings(List<Map<String, dynamic>> findings) {
    if (findings.isEmpty) return '';

    final allKeys = <String>{};
    for (final f in findings) {
      allKeys.addAll(_flattenKeys(f));
    }
    final headers = allKeys.toList()..sort();

    final buffer = StringBuffer();
    buffer.writeln(headers.map(_escapeCsvField).join(','));

    for (final finding in findings) {
      final flatItem = _flattenMap(finding);
      final row = headers.map((key) {
        return _escapeCsvField(_formatCsvValue(flatItem[key]));
      }).join(',');
      buffer.writeln(row);
    }

    return buffer.toString();
  }

  /// Generate GeoJSON content from findings
  String _generateGeoJsonFromFindings(List<Map<String, dynamic>> findings) {
    final features = <Map<String, dynamic>>[];

    for (final finding in findings) {
      final lat = finding['latitude'];
      final lng = finding['longitude'];
      if (lat != null && lng != null) {
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lng, lat],
          },
          'properties': finding,
        });
      }
    }

    return const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  /// Generate KML content from findings
  String _generateKmlFromFindings(List<Map<String, dynamic>> findings) {
    final buffer = StringBuffer();

    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
    buffer.writeln('  <Document>');
    buffer.writeln('    <name>AncientVision Batch Export</name>');
    buffer.writeln('    <description>${findings.length} findings exported on ${DateTime.now().toIso8601String()}</description>');

    for (final finding in findings) {
      final lat = finding['latitude'];
      final lng = finding['longitude'];
      if (lat != null && lng != null) {
        buffer.writeln('    <Placemark>');
        buffer.writeln('      <name>${_escapeXml(finding['type'] ?? finding['id'] ?? 'Finding')}</name>');
        buffer.writeln('      <description><![CDATA[');
        buffer.writeln('        Site: ${finding['site'] ?? 'Unknown'}');
        buffer.writeln('        Date: ${finding['date'] ?? 'Unknown'}');
        buffer.writeln('        ${finding['description'] ?? ''}');
        buffer.writeln('      ]]></description>');
        buffer.writeln('      <Point>');
        buffer.writeln('        <coordinates>$lng,$lat,0</coordinates>');
        buffer.writeln('      </Point>');
        buffer.writeln('    </Placemark>');
      }
    }

    buffer.writeln('  </Document>');
    buffer.writeln('</kml>');

    return buffer.toString();
  }

  /// Generate text summary for batch export
  String _generateBatchSummary(List<Map<String, dynamic>> findings) {
    final buffer = StringBuffer();
    final now = DateTime.now();

    buffer.writeln('═══════════════════════════════════════════════════════════');
    buffer.writeln('           ANCIENTVISION BATCH EXPORT SUMMARY');
    buffer.writeln('═══════════════════════════════════════════════════════════');
    buffer.writeln();
    buffer.writeln('Export Date: ${_dateFormat.format(now)} at ${DateFormat('HH:mm:ss').format(now)}');
    buffer.writeln('Total Findings: ${findings.length}');
    buffer.writeln();

    // Group by type
    final typeGroups = <String, int>{};
    final siteGroups = <String, int>{};
    int withPhotos = 0;
    int withLocation = 0;

    for (final finding in findings) {
      final type = finding['type']?.toString() ?? 'Unknown';
      final site = finding['site']?.toString() ?? 'Unknown';

      typeGroups[type] = (typeGroups[type] ?? 0) + 1;
      siteGroups[site] = (siteGroups[site] ?? 0) + 1;

      final photos = finding['photos'] as List?;
      if (photos != null && photos.isNotEmpty) withPhotos++;

      if (finding['latitude'] != null && finding['longitude'] != null) {
        withLocation++;
      }
    }

    buffer.writeln('─────────────────────────────────────────────────────────────');
    buffer.writeln('BY TYPE:');
    buffer.writeln('─────────────────────────────────────────────────────────────');
    for (final entry in typeGroups.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
      buffer.writeln('  ${entry.key}: ${entry.value}');
    }
    buffer.writeln();

    buffer.writeln('─────────────────────────────────────────────────────────────');
    buffer.writeln('BY SITE:');
    buffer.writeln('─────────────────────────────────────────────────────────────');
    for (final entry in siteGroups.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
      buffer.writeln('  ${entry.key}: ${entry.value}');
    }
    buffer.writeln();

    buffer.writeln('─────────────────────────────────────────────────────────────');
    buffer.writeln('STATISTICS:');
    buffer.writeln('─────────────────────────────────────────────────────────────');
    buffer.writeln('  Findings with photos: $withPhotos');
    buffer.writeln('  Findings with GPS location: $withLocation');
    buffer.writeln('  Unique artifact types: ${typeGroups.length}');
    buffer.writeln('  Unique sites: ${siteGroups.length}');
    buffer.writeln();

    buffer.writeln('═══════════════════════════════════════════════════════════');
    buffer.writeln('               Generated by AncientVision v1.0');
    buffer.writeln('═══════════════════════════════════════════════════════════');

    return buffer.toString();
  }
}
