import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/shapefile_service.dart';

/// Build a minimal SHP file with the given shape type and records.
Uint8List _buildShp(int shapeType, List<Uint8List> records) {
  // Calculate total file length in 16-bit words
  var contentBytes = 0;
  for (final r in records) {
    contentBytes += 8 + r.length; // 8-byte record header + content
  }
  final fileLength = (100 + contentBytes) ~/ 2;

  final builder = BytesBuilder();
  final header = ByteData(100);
  header.setInt32(0, 9994, Endian.big); // file code
  header.setInt32(24, fileLength, Endian.big); // file length in 16-bit words
  header.setInt32(28, 1000, Endian.little); // version
  header.setInt32(32, shapeType, Endian.little); // shape type
  // Bounding box (doubles at 36-68) — left as zeros for tests
  builder.add(Uint8List.view(header.buffer));

  for (var i = 0; i < records.length; i++) {
    final recHeader = ByteData(8);
    recHeader.setInt32(0, i + 1, Endian.big); // record number (1-based)
    recHeader.setInt32(4, records[i].length ~/ 2, Endian.big); // content length in 16-bit words
    builder.add(Uint8List.view(recHeader.buffer));
    builder.add(records[i]);
  }

  return Uint8List.fromList(builder.toBytes());
}

/// Build a Point record (shape type 1): 4 bytes type + 8 bytes x + 8 bytes y
Uint8List _buildPointRecord(double x, double y) {
  final data = ByteData(20);
  data.setInt32(0, 1, Endian.little); // shape type
  data.setFloat64(4, x, Endian.little);
  data.setFloat64(12, y, Endian.little);
  return Uint8List.view(data.buffer);
}

/// Build a Polygon record (shape type 5) with a single ring.
Uint8List _buildPolygonRecord(List<List<double>> coords) {
  final numPoints = coords.length;
  // 4 (type) + 32 (bbox) + 4 (numParts) + 4 (numPoints) + 4 (parts[0]) + numPoints*16
  final size = 4 + 32 + 4 + 4 + 4 + numPoints * 16;
  final data = ByteData(size);
  data.setInt32(0, 5, Endian.little); // shape type

  // Bounding box
  double minX = coords[0][0], maxX = coords[0][0];
  double minY = coords[0][1], maxY = coords[0][1];
  for (final c in coords) {
    if (c[0] < minX) minX = c[0];
    if (c[0] > maxX) maxX = c[0];
    if (c[1] < minY) minY = c[1];
    if (c[1] > maxY) maxY = c[1];
  }
  data.setFloat64(4, minX, Endian.little);
  data.setFloat64(12, minY, Endian.little);
  data.setFloat64(20, maxX, Endian.little);
  data.setFloat64(28, maxY, Endian.little);

  data.setInt32(36, 1, Endian.little); // numParts
  data.setInt32(40, numPoints, Endian.little); // numPoints
  data.setInt32(44, 0, Endian.little); // parts[0] = 0

  var offset = 48;
  for (final c in coords) {
    data.setFloat64(offset, c[0], Endian.little); // x (lon)
    data.setFloat64(offset + 8, c[1], Endian.little); // y (lat)
    offset += 16;
  }

  return Uint8List.view(data.buffer);
}

/// Build a PolyLine record (shape type 3) with a single part.
Uint8List _buildPolyLineRecord(List<List<double>> coords) {
  final numPoints = coords.length;
  final size = 4 + 32 + 4 + 4 + 4 + numPoints * 16;
  final data = ByteData(size);
  data.setInt32(0, 3, Endian.little);

  double minX = coords[0][0], maxX = coords[0][0];
  double minY = coords[0][1], maxY = coords[0][1];
  for (final c in coords) {
    if (c[0] < minX) minX = c[0];
    if (c[0] > maxX) maxX = c[0];
    if (c[1] < minY) minY = c[1];
    if (c[1] > maxY) maxY = c[1];
  }
  data.setFloat64(4, minX, Endian.little);
  data.setFloat64(12, minY, Endian.little);
  data.setFloat64(20, maxX, Endian.little);
  data.setFloat64(28, maxY, Endian.little);

  data.setInt32(36, 1, Endian.little);
  data.setInt32(40, numPoints, Endian.little);
  data.setInt32(44, 0, Endian.little);

  var offset = 48;
  for (final c in coords) {
    data.setFloat64(offset, c[0], Endian.little);
    data.setFloat64(offset + 8, c[1], Endian.little);
    offset += 16;
  }

  return Uint8List.view(data.buffer);
}

/// Build a minimal DBF file with a single NAME field.
Uint8List _buildDbf(List<String> names) {
  const fieldLen = 20;
  const headerSize = 32 + 32 + 1; // header + 1 field descriptor + terminator
  const recordSize = 1 + fieldLen; // delete flag + field

  final builder = BytesBuilder();
  final header = ByteData(32);
  header.setInt8(0, 0x03); // version
  header.setInt32(4, names.length, Endian.little); // num records
  header.setInt16(8, headerSize, Endian.little); // header size
  header.setInt16(10, recordSize, Endian.little); // record size
  builder.add(Uint8List.view(header.buffer));

  // Field descriptor for NAME
  final fieldDesc = Uint8List(32);
  final nameAscii = ascii.encode('NAME');
  fieldDesc.setRange(0, nameAscii.length, nameAscii);
  fieldDesc[11] = 0x43; // type 'C' (character)
  fieldDesc[16] = fieldLen; // field length
  builder.add(fieldDesc);

  // Header terminator
  builder.addByte(0x0D);

  // Records
  for (final name in names) {
    builder.addByte(0x20); // not deleted
    final padded = name.padRight(fieldLen).substring(0, fieldLen);
    builder.add(ascii.encode(padded));
  }

  return Uint8List.fromList(builder.toBytes());
}

/// Create a ZIP archive containing .shp and optionally .dbf bytes.
Uint8List _buildZip(Uint8List shpBytes, {Uint8List? dbfBytes, String? prjContent}) {
  final archive = Archive();
  archive.addFile(ArchiveFile('layer.shp', shpBytes.length, shpBytes));
  if (dbfBytes != null) {
    archive.addFile(ArchiveFile('layer.dbf', dbfBytes.length, dbfBytes));
  }
  if (prjContent != null) {
    final prjBytes = utf8.encode(prjContent);
    archive.addFile(ArchiveFile('layer.prj', prjBytes.length, prjBytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  group('ShapefileService', () {
    late ShapefileService service;

    setUp(() {
      service = ShapefileService();
    });

    group('parse', () {
      test('parses single point', () {
        final shp = _buildShp(1, [_buildPointRecord(23.7, 37.9)]);
        final layer = service.parse(shp, null, name: 'Test');

        expect(layer.points, hasLength(1));
        expect(layer.points.first.position.latitude, closeTo(37.9, 0.001));
        expect(layer.points.first.position.longitude, closeTo(23.7, 0.001));
        expect(layer.polygons, isEmpty);
        expect(layer.polylines, isEmpty);
        expect(layer.name, 'Test');
      });

      test('parses multiple points', () {
        final shp = _buildShp(1, [
          _buildPointRecord(23.7, 37.9),
          _buildPointRecord(23.8, 38.0),
        ]);
        final layer = service.parse(shp, null);
        expect(layer.points, hasLength(2));
        expect(layer.bounds, isNotNull);
      });

      test('parses polygon', () {
        final coords = [
          [23.7, 37.9], [23.701, 37.9], [23.701, 37.901],
          [23.7, 37.901], [23.7, 37.9],
        ];
        final shp = _buildShp(5, [_buildPolygonRecord(coords)]);
        final layer = service.parse(shp, null);

        expect(layer.polygons, hasLength(1));
        expect(layer.polygons.first.points, hasLength(5));
      });

      test('parses polyline', () {
        final coords = [[23.7, 37.9], [23.701, 37.901]];
        final shp = _buildShp(3, [_buildPolyLineRecord(coords)]);
        final layer = service.parse(shp, null);

        expect(layer.polylines, hasLength(1));
        expect(layer.polylines.first.points, hasLength(2));
      });

      test('reads labels from DBF', () {
        final shp = _buildShp(1, [
          _buildPointRecord(23.7, 37.9),
          _buildPointRecord(23.8, 38.0),
        ]);
        final dbf = _buildDbf(['Find Spot A', 'Find Spot B']);
        final layer = service.parse(shp, dbf);

        expect(layer.points[0].label, 'Find Spot A');
        expect(layer.points[1].label, 'Find Spot B');
      });

      test('handles DBF with no matching records gracefully', () {
        final shp = _buildShp(1, [
          _buildPointRecord(23.7, 37.9),
          _buildPointRecord(23.8, 38.0),
        ]);
        final dbf = _buildDbf(['Only One']);
        final layer = service.parse(shp, dbf);

        expect(layer.points[0].label, 'Only One');
        expect(layer.points[1].label, isNull);
      });

      test('rejects invalid SHP file code', () {
        final bad = Uint8List(100);
        expect(() => service.parse(bad, null), throwsFormatException);
      });

      test('computes bounding box', () {
        final shp = _buildShp(1, [
          _buildPointRecord(23.7, 37.9),
          _buildPointRecord(23.8, 38.0),
        ]);
        final layer = service.parse(shp, null);
        expect(layer.bounds, isNotNull);
        expect(layer.bounds!.south, closeTo(37.9, 0.001));
        expect(layer.bounds!.north, closeTo(38.0, 0.001));
      });
    });

    group('importFromZip', () {
      test('extracts and parses SHP from ZIP', () {
        final shp = _buildShp(1, [_buildPointRecord(23.7, 37.9)]);
        final zip = _buildZip(shp);
        final layer = service.importFromZip(zip, name: 'FromZip');

        expect(layer.points, hasLength(1));
        expect(layer.name, 'FromZip');
      });

      test('extracts SHP and DBF from ZIP', () {
        final shp = _buildShp(1, [_buildPointRecord(23.7, 37.9)]);
        final dbf = _buildDbf(['Temple']);
        final zip = _buildZip(shp, dbfBytes: dbf);
        final layer = service.importFromZip(zip);

        expect(layer.points.first.label, 'Temple');
      });

      test('throws on ZIP without SHP', () {
        final archive = Archive();
        archive.addFile(ArchiveFile('readme.txt', 5, utf8.encode('hello')));
        final zip = Uint8List.fromList(ZipEncoder().encode(archive)!);

        expect(() => service.importFromZip(zip), throwsFormatException);
      });
    });

    group('toGeoJsonString', () {
      test('round-trips points through GeoJSON', () {
        final shp = _buildShp(1, [_buildPointRecord(23.7, 37.9)]);
        final dbf = _buildDbf(['Test Point']);
        final layer = service.parse(shp, dbf);
        final geojsonStr = service.toGeoJsonString(layer);
        final geojson = json.decode(geojsonStr) as Map<String, dynamic>;

        expect(geojson['type'], 'FeatureCollection');
        final features = geojson['features'] as List;
        expect(features, hasLength(1));
        expect(features[0]['geometry']['type'], 'Point');
        expect(features[0]['properties']['name'], 'Test Point');
      });

      test('round-trips polygons through GeoJSON', () {
        final coords = [
          [23.7, 37.9], [23.701, 37.9], [23.701, 37.901],
          [23.7, 37.901], [23.7, 37.9],
        ];
        final shp = _buildShp(5, [_buildPolygonRecord(coords)]);
        final layer = service.parse(shp, null);
        final geojsonStr = service.toGeoJsonString(layer);
        final geojson = json.decode(geojsonStr) as Map<String, dynamic>;

        final features = geojson['features'] as List;
        expect(features[0]['geometry']['type'], 'Polygon');
        final ring = features[0]['geometry']['coordinates'][0] as List;
        expect(ring, hasLength(5));
      });

      test('round-trips polylines through GeoJSON', () {
        final coords = [[23.7, 37.9], [23.701, 37.901]];
        final shp = _buildShp(3, [_buildPolyLineRecord(coords)]);
        final layer = service.parse(shp, null);
        final geojsonStr = service.toGeoJsonString(layer);
        final geojson = json.decode(geojsonStr) as Map<String, dynamic>;

        expect(geojson['features'][0]['geometry']['type'], 'LineString');
      });
    });

    group('polygon with labels from DBF', () {
      test('attaches labels to polygons', () {
        final coords = [
          [23.7, 37.9], [23.701, 37.9], [23.701, 37.901],
          [23.7, 37.901], [23.7, 37.9],
        ];
        final shp = _buildShp(5, [_buildPolygonRecord(coords)]);
        final dbf = _buildDbf(['Trench A']);
        final layer = service.parse(shp, dbf);

        expect(layer.polygons.first.label, 'Trench A');
      });
    });
  });
}
