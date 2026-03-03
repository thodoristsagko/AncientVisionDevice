import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'geojson_service.dart';

/// Pure-Dart SHP + DBF parser that converts shapefiles into [GeoJsonLayer].
///
/// Supports shape types: Point (1), PolyLine (3), Polygon (5), MultiPoint (8).
/// Assumes WGS84 coordinates (EPSG:4326).
class ShapefileService {
  /// Import from ZIP bytes containing .shp and .dbf files.
  GeoJsonLayer importFromZip(Uint8List zipBytes, {String name = 'Layer'}) {
    final archive = ZipDecoder().decodeBytes(zipBytes);

    Uint8List? shpBytes;
    Uint8List? dbfBytes;

    for (final file in archive) {
      if (!file.isFile) continue;
      final lower = file.name.toLowerCase();
      if (lower.endsWith('.shp')) {
        shpBytes = Uint8List.fromList(file.content as List<int>);
      } else if (lower.endsWith('.dbf')) {
        dbfBytes = Uint8List.fromList(file.content as List<int>);
      }
    }

    if (shpBytes == null) {
      throw const FormatException('ZIP does not contain a .shp file');
    }

    return parse(shpBytes, dbfBytes, name: name);
  }

  /// Parse SHP + optional DBF bytes into a [GeoJsonLayer].
  GeoJsonLayer parse(Uint8List shpBytes, Uint8List? dbfBytes,
      {String name = 'Layer'}) {
    final shp = ByteData.sublistView(shpBytes);

    // Validate SHP header
    final fileCode = shp.getInt32(0, Endian.big);
    if (fileCode != 9994) {
      throw FormatException('Invalid SHP file code: $fileCode');
    }

    // Parse DBF records for labels
    final dbfRecords = dbfBytes != null ? _parseDbf(dbfBytes) : <Map<String, String>>[];

    final polygons = <GeoJsonPolygon>[];
    final polylines = <GeoJsonPolyline>[];
    final points = <GeoJsonPoint>[];
    final allCoords = <LatLng>[];

    // Read records starting at offset 100
    var offset = 100;
    var recordIndex = 0;

    while (offset + 8 <= shpBytes.length) {
      // Record header (big-endian)
      final contentLength = shp.getInt32(offset + 4, Endian.big) * 2; // in bytes
      offset += 8;

      if (offset + contentLength > shpBytes.length) break;

      final recShapeType = shp.getInt32(offset, Endian.little);
      final label = _getLabel(dbfRecords, recordIndex);

      if (recShapeType == 0) {
        // Null shape — skip
      } else if (recShapeType == 1) {
        // Point
        final x = shp.getFloat64(offset + 4, Endian.little);
        final y = shp.getFloat64(offset + 12, Endian.little);
        final pt = LatLng(y, x);
        points.add(GeoJsonPoint(position: pt, label: label));
        allCoords.add(pt);
      } else if (recShapeType == 3 || recShapeType == 5) {
        // PolyLine (3) or Polygon (5)
        final numParts = shp.getInt32(offset + 36, Endian.little);
        final numPoints = shp.getInt32(offset + 40, Endian.little);

        final partsOffset = offset + 44;
        final pointsOffset = partsOffset + numParts * 4;

        final parts = <int>[];
        for (var i = 0; i < numParts; i++) {
          parts.add(shp.getInt32(partsOffset + i * 4, Endian.little));
        }

        for (var p = 0; p < numParts; p++) {
          final start = parts[p];
          final end = p + 1 < numParts ? parts[p + 1] : numPoints;
          final ring = <LatLng>[];
          for (var i = start; i < end; i++) {
            final px = shp.getFloat64(pointsOffset + i * 16, Endian.little);
            final py = shp.getFloat64(pointsOffset + i * 16 + 8, Endian.little);
            ring.add(LatLng(py, px));
          }
          allCoords.addAll(ring);
          if (recShapeType == 5) {
            polygons.add(GeoJsonPolygon(points: ring, label: label));
          } else {
            polylines.add(GeoJsonPolyline(points: ring, label: label));
          }
        }
      } else if (recShapeType == 8) {
        // MultiPoint
        final numPoints = shp.getInt32(offset + 36, Endian.little);
        for (var i = 0; i < numPoints; i++) {
          final px = shp.getFloat64(offset + 40 + i * 16, Endian.little);
          final py = shp.getFloat64(offset + 40 + i * 16 + 8, Endian.little);
          final pt = LatLng(py, px);
          points.add(GeoJsonPoint(position: pt, label: label));
          allCoords.add(pt);
        }
      }

      offset += contentLength;
      recordIndex++;
    }

    LatLngBounds? bounds;
    if (allCoords.isNotEmpty) {
      bounds = LatLngBounds.fromPoints(allCoords);
    }

    return GeoJsonLayer(
      name: name,
      polygons: polygons,
      polylines: polylines,
      points: points,
      bounds: bounds,
    );
  }

  /// Convert a [GeoJsonLayer] to a GeoJSON string for persistence.
  String toGeoJsonString(GeoJsonLayer layer) {
    final features = <Map<String, dynamic>>[];

    for (final p in layer.polygons) {
      features.add({
        'type': 'Feature',
        'properties': {'name': p.label},
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            p.points.map((pt) => [pt.longitude, pt.latitude]).toList()
          ],
        },
      });
    }

    for (final l in layer.polylines) {
      features.add({
        'type': 'Feature',
        'properties': {'name': l.label},
        'geometry': {
          'type': 'LineString',
          'coordinates':
              l.points.map((pt) => [pt.longitude, pt.latitude]).toList(),
        },
      });
    }

    for (final pt in layer.points) {
      features.add({
        'type': 'Feature',
        'properties': {'name': pt.label},
        'geometry': {
          'type': 'Point',
          'coordinates': [pt.position.longitude, pt.position.latitude],
        },
      });
    }

    return json.encode({'type': 'FeatureCollection', 'features': features});
  }

  String? _getLabel(List<Map<String, String>> dbfRecords, int index) {
    if (index >= dbfRecords.length) return null;
    final rec = dbfRecords[index];
    return rec['NAME'] ?? rec['Name'] ?? rec['name'] ?? rec['LABEL'] ?? rec['label'] ?? rec.values.firstOrNull;
  }

  /// Parse dBASE III DBF file into list of field-value maps.
  List<Map<String, String>> _parseDbf(Uint8List dbfBytes) {
    if (dbfBytes.length < 32) return [];

    final dbf = ByteData.sublistView(dbfBytes);
    final numRecords = dbf.getInt32(4, Endian.little);
    final headerSize = dbf.getInt16(8, Endian.little);
    final recordSize = dbf.getInt16(10, Endian.little);

    // Parse field descriptors (start at byte 32, each 32 bytes, terminated by 0x0D)
    final fields = <_DbfField>[];
    var pos = 32;
    while (pos + 32 <= headerSize && dbfBytes[pos] != 0x0D) {
      final nameBytes = dbfBytes.sublist(pos, pos + 11);
      final nameEnd = nameBytes.indexOf(0);
      final fieldName = ascii.decode(nameBytes.sublist(0, nameEnd > 0 ? nameEnd : 11)).trim();
      final fieldLength = dbfBytes[pos + 16];
      fields.add(_DbfField(fieldName, fieldLength));
      pos += 32;
    }

    final records = <Map<String, String>>[];
    var dataOffset = headerSize;

    for (var r = 0; r < numRecords; r++) {
      if (dataOffset + recordSize > dbfBytes.length) break;

      // Skip delete flag byte
      var fieldOffset = dataOffset + 1;
      final record = <String, String>{};

      for (final field in fields) {
        if (fieldOffset + field.length > dbfBytes.length) break;
        final value = ascii.decode(
          dbfBytes.sublist(fieldOffset, fieldOffset + field.length),
          allowInvalid: true,
        ).trim();
        if (value.isNotEmpty) {
          record[field.name] = value;
        }
        fieldOffset += field.length;
      }

      records.add(record);
      dataOffset += recordSize;
    }

    return records;
  }
}

class _DbfField {
  final String name;
  final int length;
  _DbfField(this.name, this.length);
}
