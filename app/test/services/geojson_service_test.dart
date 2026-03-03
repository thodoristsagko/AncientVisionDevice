import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/geojson_service.dart';

void main() {
  group('GeoJsonService', () {
    late GeoJsonService service;

    setUp(() {
      service = GeoJsonService();
    });

    test('parses polygon feature', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'name': 'Trench A'},
            'geometry': {
              'type': 'Polygon',
              'coordinates': [[[23.7, 37.9], [23.701, 37.9], [23.701, 37.901], [23.7, 37.901], [23.7, 37.9]]]
            }
          }
        ]
      };
      final result = service.parse(geojson);
      expect(result.polygons, hasLength(1));
      expect(result.polygons.first.points, hasLength(5));
      expect(result.polygons.first.label, 'Trench A');
    });

    test('parses linestring feature', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'name': 'Wall 1'},
            'geometry': {
              'type': 'LineString',
              'coordinates': [[23.7, 37.9], [23.701, 37.901]]
            }
          }
        ]
      };
      final result = service.parse(geojson);
      expect(result.polylines, hasLength(1));
      expect(result.polylines.first.points, hasLength(2));
    });

    test('parses point feature', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'name': 'Find Spot 1'},
            'geometry': {'type': 'Point', 'coordinates': [23.7, 37.9]}
          }
        ]
      };
      final result = service.parse(geojson);
      expect(result.points, hasLength(1));
      expect(result.points.first.label, 'Find Spot 1');
    });

    test('handles empty feature collection', () {
      final geojson = {'type': 'FeatureCollection', 'features': []};
      final result = service.parse(geojson);
      expect(result.polygons, isEmpty);
      expect(result.polylines, isEmpty);
      expect(result.points, isEmpty);
    });

    test('computes bounding box', () {
      final geojson = {
        'type': 'FeatureCollection',
        'features': [
          {'type': 'Feature', 'properties': {}, 'geometry': {'type': 'Point', 'coordinates': [23.7, 37.9]}},
          {'type': 'Feature', 'properties': {}, 'geometry': {'type': 'Point', 'coordinates': [23.8, 38.0]}},
        ]
      };
      final result = service.parse(geojson);
      expect(result.bounds, isNotNull);
      expect(result.bounds!.south, closeTo(37.9, 0.001));
      expect(result.bounds!.north, closeTo(38.0, 0.001));
    });
  });
}
