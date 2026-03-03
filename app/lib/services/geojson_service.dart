import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:shared_preferences/shared_preferences.dart';

class GeoJsonPoint {
  final LatLng position;
  final String? label;
  GeoJsonPoint({required this.position, this.label});
}

class GeoJsonPolygon {
  final List<LatLng> points;
  final String? label;
  GeoJsonPolygon({required this.points, this.label});
}

class GeoJsonPolyline {
  final List<LatLng> points;
  final String? label;
  GeoJsonPolyline({required this.points, this.label});
}

class GeoJsonLayer {
  final String name;
  final List<GeoJsonPolygon> polygons;
  final List<GeoJsonPolyline> polylines;
  final List<GeoJsonPoint> points;
  final LatLngBounds? bounds;

  GeoJsonLayer({
    required this.name,
    required this.polygons,
    required this.polylines,
    required this.points,
    this.bounds,
  });
}

class GeoJsonService {
  static const _storageKey = 'geojson_layers';

  GeoJsonLayer parse(Map<String, dynamic> geojson, {String name = 'Layer'}) {
    final features = geojson['features'] as List? ?? [];
    final polygons = <GeoJsonPolygon>[];
    final polylines = <GeoJsonPolyline>[];
    final points = <GeoJsonPoint>[];
    final allCoords = <LatLng>[];

    for (final feature in features) {
      final props = Map<String, dynamic>.from(feature['properties'] as Map? ?? {});
      final geom = feature['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;

      final label = props['name'] as String? ?? props['label'] as String?;
      final type = geom['type'] as String;
      final coords = geom['coordinates'];

      switch (type) {
        case 'Polygon':
          final ring = (coords[0] as List)
              .map((c) =>
                  LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList();
          polygons.add(GeoJsonPolygon(points: ring, label: label));
          allCoords.addAll(ring);
        case 'MultiPolygon':
          for (final poly in coords) {
            final ring = (poly[0] as List)
                .map((c) =>
                    LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            polygons.add(GeoJsonPolygon(points: ring, label: label));
            allCoords.addAll(ring);
          }
        case 'LineString':
          final pts = (coords as List)
              .map((c) =>
                  LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList();
          polylines.add(GeoJsonPolyline(points: pts, label: label));
          allCoords.addAll(pts);
        case 'MultiLineString':
          for (final line in coords) {
            final pts = (line as List)
                .map((c) =>
                    LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            polylines.add(GeoJsonPolyline(points: pts, label: label));
            allCoords.addAll(pts);
          }
        case 'Point':
          final pt = LatLng(
              (coords[1] as num).toDouble(), (coords[0] as num).toDouble());
          points.add(GeoJsonPoint(position: pt, label: label));
          allCoords.add(pt);
      }
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

  Future<GeoJsonLayer> loadBundled(String assetPath,
      {String name = 'Sample'}) async {
    final raw = await rootBundle.loadString(assetPath);
    return parse(json.decode(raw), name: name);
  }

  Future<void> saveLayer(String name, String geojsonString) async {
    final prefs = await SharedPreferences.getInstance();
    final layers = prefs.getStringList(_storageKey) ?? [];
    layers.removeWhere((l) => l.startsWith('$name|||'));
    layers.add('$name|||$geojsonString');
    await prefs.setStringList(_storageKey, layers);
  }

  Future<List<GeoJsonLayer>> loadSavedLayers() async {
    final prefs = await SharedPreferences.getInstance();
    final layers = prefs.getStringList(_storageKey) ?? [];
    return layers.map((entry) {
      final sep = entry.indexOf('|||');
      final name = entry.substring(0, sep);
      final jsonStr = entry.substring(sep + 3);
      return parse(json.decode(jsonStr), name: name);
    }).toList();
  }

  Future<void> removeLayer(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final layers = prefs.getStringList(_storageKey) ?? [];
    layers.removeWhere((l) => l.startsWith('$name|||'));
    await prefs.setStringList(_storageKey, layers);
  }
}
