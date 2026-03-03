import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import '../models/finding_model.dart';
import '../services/geojson_service.dart';
import '../services/shapefile_service.dart';
import '../services/cached_tile_provider.dart';

class FindingsMap extends StatefulWidget {
  final List<Finding> findings;
  final int selectedIndex;

  const FindingsMap({
    super.key,
    required this.findings,
    required this.selectedIndex,
  });

  @override
  State<FindingsMap> createState() => _FindingsMapState();
}

class _FindingsMapState extends State<FindingsMap> {
  MapController? _mapController;
  String _locationName = 'Archaeological Site';
  bool _isLoadingLocation = false;
  bool _useSatellite = true;
  bool _showFindings = true;
  bool _showLayerPanel = false;
  String? _selectedFeatureLabel;
  bool _selectedIsCoord = false;
  LatLng? _myLocation;
  StreamSubscription<Position>? _locationSub;

  final GeoJsonService _geoJsonService = GeoJsonService();
  final ShapefileService _shapefileService = ShapefileService();
  final List<_LayerEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    if (widget.findings.isNotEmpty) {
      _reverseGeocode(widget.findings.first.latitude, widget.findings.first.longitude);
    }
    _loadGeoJsonLayers();
    _startLocationTracking();
  }

  Future<void> _loadGeoJsonLayers() async {
    try {
      final sample = await _geoJsonService.loadBundled(
        'assets/geo/sample_trenches.geojson',
        name: 'Kalapodi Trenches',
      );
      final saved = await _geoJsonService.loadSavedLayers();
      if (mounted) {
        setState(() {
          _entries.add(_LayerEntry(layer: sample, isBundled: true));
          for (final l in saved) {
            _entries.add(_LayerEntry(layer: l));
          }
        });
      }
    } catch (e) {
      debugPrint('GeoJSON load error: $e');
    }
  }

  Future<void> _startLocationTracking() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      );

      _locationSub = Geolocator.getPositionStream(locationSettings: settings)
          .listen((pos) {
        if (mounted) {
          setState(() => _myLocation = LatLng(pos.latitude, pos.longitude));
        }
      });
    } catch (_) {
      // Location unavailable — silently ignore
    }
  }

  Future<void> _importGeoData() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final lowerName = file.name.toLowerCase();

      GeoJsonLayer layer;
      String geojsonStr;

      if (lowerName.endsWith('.zip')) {
        // Shapefile ZIP import
        Uint8List? bytes;
        if (file.path != null) {
          bytes = await File(file.path!).readAsBytes();
        } else {
          bytes = file.bytes;
        }
        if (bytes == null) return;

        final name = file.name.replaceAll(RegExp(r'\.shp\.zip$|\.zip$', caseSensitive: false), '');
        layer = _shapefileService.importFromZip(bytes, name: name);
        geojsonStr = _shapefileService.toGeoJsonString(layer);
      } else {
        // GeoJSON import
        String? content;
        if (file.path != null) {
          content = await File(file.path!).readAsString();
        } else if (file.bytes != null) {
          content = utf8.decode(file.bytes!);
        }
        if (content == null) return;

        final geojson = json.decode(content) as Map<String, dynamic>;
        final name = file.name.replaceAll('.geojson', '').replaceAll('.json', '');
        layer = _geoJsonService.parse(geojson, name: name);
        geojsonStr = content;
      }

      await _geoJsonService.saveLayer(layer.name, geojsonStr);

      if (mounted) {
        setState(() => _entries.add(_LayerEntry(layer: layer)));

        if (layer.bounds != null && _mapController != null) {
          _mapController!.fitCamera(
            CameraFit.bounds(
              bounds: layer.bounds!,
              padding: const EdgeInsets.all(50),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import: $e')),
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant FindingsMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex && widget.findings.isNotEmpty) {
      final selected = widget.findings[widget.selectedIndex];
      _mapController?.move(LatLng(selected.latitude, selected.longitude), 17.5);
      _reverseGeocode(selected.latitude, selected.longitude);
    }
  }

  Future<void> _reverseGeocode(double lat, double lon) async {
    if (_isLoadingLocation) return;
    setState(() => _isLoadingLocation = true);
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=18&addressdetails=1',
      );
      final response = await http.get(url, headers: {'User-Agent': 'AncientVision-FLL-App/1.0'});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final address = data['address'] as Map<String, dynamic>?;
        String name = data['name'] as String? ?? '';
        if (name.isEmpty) {
          name = address?['historic'] as String? ??
              address?['tourism'] as String? ??
              address?['archaeological_site'] as String? ??
              address?['amenity'] as String? ??
              address?['suburb'] as String? ??
              address?['neighbourhood'] as String? ??
              address?['village'] as String? ??
              address?['town'] as String? ??
              address?['city'] as String? ??
              'Archaeological Site';
        }
        if (mounted) setState(() => _locationName = name);
      }
    } catch (_) {}
    finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _openInGoogleMaps() async {
    final center = widget.findings[widget.selectedIndex];
    final url = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${center.latitude},${center.longitude}',
    );
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  List<Marker> _buildFindingMarkers() {
    if (!_showFindings) return [];
    return widget.findings.asMap().entries.map((entry) {
      final index = entry.key;
      final finding = entry.value;
      final isSelected = index == widget.selectedIndex;
      final typeColor = Finding.getTypeColor(finding.type);
      return Marker(
        point: LatLng(finding.latitude, finding.longitude),
        width: isSelected ? 48 : 36,
        height: isSelected ? 48 : 36,
        child: GestureDetector(
          onTap: _openInGoogleMaps,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isSelected)
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: typeColor.withAlpha(77)),
                ),
              Icon(Icons.location_pin, size: isSelected ? 40 : 32,
                color: isSelected ? typeColor : typeColor.withAlpha(217),
                shadows: [Shadow(color: Colors.black.withAlpha(128), blurRadius: 4)],
              ),
              Positioned(
                top: isSelected ? 8 : 4,
                child: Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle,
                    border: Border.all(color: typeColor, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  /// Ray-casting point-in-polygon test.
  bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    final x = point.longitude;
    final y = point.latitude;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude, yi = polygon[i].latitude;
      final xj = polygon[j].longitude, yj = polygon[j].latitude;
      if (((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  String _formatCoord(double value, {required bool isLat}) {
    final abs = value.abs();
    final dir = isLat
        ? (value >= 0 ? 'N' : 'S')
        : (value >= 0 ? 'E' : 'W');
    return '${abs.toStringAsFixed(5)}°$dir';
  }

  void _onMapTap(TapPosition tapPos, LatLng tappedPoint) {
    // Check visible polygon layers for a hit.
    for (final entry in _entries.where((e) => e.visible)) {
      for (final poly in entry.layer.polygons) {
        if (_pointInPolygon(tappedPoint, poly.points)) {
          setState(() {
            _selectedFeatureLabel = poly.label ?? entry.layer.name;
            _selectedIsCoord = false;
          });
          return;
        }
      }
    }
    // No polygon hit — show tapped coordinates.
    setState(() {
      _selectedFeatureLabel =
          '${_formatCoord(tappedPoint.latitude, isLat: true)}, '
          '${_formatCoord(tappedPoint.longitude, isLat: false)}';
      _selectedIsCoord = true;
    });
  }

  List<Polygon> _buildGeoJsonPolygons() {
    return _entries
        .where((e) => e.visible)
        .expand((e) => e.layer.polygons.map((p) => Polygon(
              points: p.points,
              color: const Color(0x33FFC107),
              borderColor: const Color(0xFFFFC107),
              borderStrokeWidth: 2,
              isFilled: true,
              label: p.label,
              labelStyle: const TextStyle(
                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            )))
        .toList();
  }

  List<Polyline> _buildGeoJsonPolylines() {
    return _entries
        .where((e) => e.visible)
        .expand((e) => e.layer.polylines.map((p) => Polyline(
              points: p.points,
              color: const Color(0xFFFF9800),
              strokeWidth: 3,
            )))
        .toList();
  }

  List<Marker> _buildGeoJsonPointMarkers() {
    return _entries
        .where((e) => e.visible)
        .expand((e) => e.layer.points.map((p) => Marker(
              point: p.position,
              width: 30,
              height: 30,
              child: GestureDetector(
                onTap: () => setState(() {
                  _selectedFeatureLabel = p.label;
                  _selectedIsCoord = false;
                }),
                child: Tooltip(
                  message: p.label ?? '',
                  child: const Icon(Icons.place, color: Color(0xFFFF9800), size: 28),
                ),
              ),
            )))
        .toList();
  }

  List<Marker> _buildMyLocationMarker() {
    if (_myLocation == null) return [];
    return [
      Marker(
        point: _myLocation!,
        width: 20,
        height: 20,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF2196F3),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x552196F3), blurRadius: 8, spreadRadius: 4),
            ],
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final firstFinding = widget.findings.first;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: LatLng(firstFinding.latitude, firstFinding.longitude),
            initialZoom: 17.5,
            minZoom: 4,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
            onTap: _onMapTap,
          ),
          children: [
            TileLayer(
              urlTemplate: _useSatellite
                  ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.ancient_vision',
              maxZoom: 19,
              tileProvider: CachedTileProvider(),
            ),
            MarkerLayer(markers: _buildMyLocationMarker()),
            PolygonLayer(polygons: _buildGeoJsonPolygons()),
            PolylineLayer(polylines: _buildGeoJsonPolylines()),
            MarkerLayer(markers: _buildGeoJsonPointMarkers()),
            MarkerLayer(markers: _buildFindingMarkers()),
          ],
        ),

        // Location label
        Positioned(
          top: 12, left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(179),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLoadingLocation)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox(width: 10, height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFC107)),
                      ),
                    ),
                  ),
                Text(_locationName, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),

        // Top-right controls
        Positioned(
          top: 12, right: 12,
          child: Column(
            children: [
              _mapButton(
                icon: _useSatellite ? Icons.satellite_alt : Icons.map,
                tooltip: _useSatellite ? 'Street view' : 'Satellite view',
                onTap: () => setState(() => _useSatellite = !_useSatellite),
              ),
              const SizedBox(height: 8),
              _mapButton(
                icon: Icons.layers,
                tooltip: 'Layers',
                onTap: () => setState(() => _showLayerPanel = !_showLayerPanel),
              ),
              const SizedBox(height: 8),
              _mapButton(
                icon: Icons.file_open,
                tooltip: 'Import GIS Data',
                onTap: _importGeoData,
              ),
              const SizedBox(height: 8),
              _mapButton(
                icon: Icons.my_location,
                tooltip: 'Center on my location',
                onTap: () {
                  if (_myLocation != null && _mapController != null) {
                    _mapController!.move(_myLocation!, _mapController!.camera.zoom);
                  }
                },
              ),
            ],
          ),
        ),

        // Layer panel
        if (_showLayerPanel)
          Positioned(
            top: 120, right: 12,
            child: Container(
              width: 200,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(210),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Layers',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                  const SizedBox(height: 8),
                  _layerToggle(
                      'Findings', _showFindings, (v) => setState(() => _showFindings = v)),
                  if (_entries.isNotEmpty) ...[
                    const Divider(color: Colors.white24, height: 16),
                    ..._entries.map((e) => _layerRow(e)),
                  ],
                ],
              ),
            ),
          ),

        // Google Maps button
        Positioned(
          bottom: 12, right: 12,
          child: GestureDetector(
            onTap: _openInGoogleMaps,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFC107),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(77), blurRadius: 8, spreadRadius: 1)],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new, color: Color(0xFF3E2723), size: 16),
                  SizedBox(width: 6),
                  Text('Google Maps', style: TextStyle(color: Color(0xFF3E2723), fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),

        // Feature info popup
        if (_selectedFeatureLabel != null)
          Positioned(
            bottom: 56,
            left: 12,
            right: 12,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(210),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _selectedIsCoord ? Icons.location_on : Icons.info_outline,
                      color: const Color(0xFFFFC107),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _selectedFeatureLabel!,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() {
                        _selectedFeatureLabel = null;
                        _selectedIsCoord = false;
                      }),
                      child: const Icon(Icons.close, color: Colors.white54, size: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _mapButton({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(179),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Widget _layerToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24, height: 24,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            activeColor: const Color(0xFFFFC107),
            checkColor: Colors.black,
            side: const BorderSide(color: Colors.white54),
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ],
    );
  }

  Widget _layerRow(_LayerEntry entry) {
    final count = entry.layer.polygons.length +
        entry.layer.polylines.length +
        entry.layer.points.length;
    return Row(
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: Checkbox(
            value: entry.visible,
            onChanged: (v) => setState(() => entry.visible = v ?? true),
            activeColor: const Color(0xFFFFC107),
            checkColor: Colors.black,
            side: const BorderSide(color: Colors.white54),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${entry.layer.name} ($count)',
            style: const TextStyle(color: Colors.white, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (!entry.isBundled)
          GestureDetector(
            onTap: () => _deleteLayer(entry),
            child: const Icon(Icons.delete_outline,
                color: Colors.white38, size: 18),
          ),
      ],
    );
  }

  Future<void> _deleteLayer(_LayerEntry entry) async {
    await _geoJsonService.removeLayer(entry.layer.name);
    if (mounted) setState(() => _entries.remove(entry));
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }
}

class _LayerEntry {
  final GeoJsonLayer layer;
  bool visible = true;
  final bool isBundled;
  _LayerEntry({required this.layer, this.isBundled = false});
}
