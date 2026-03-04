import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/finding_model.dart';
import '../services/geojson_service.dart';
import '../services/shapefile_service.dart';
import '../services/cached_tile_provider.dart';
import '../services/location_service.dart';
import '../services/critical_event_log_service.dart';
import '../services/geofencing_service.dart';

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
  bool _showAlerts = true;
  bool _showSensorMarker = true;
  String? _selectedFeatureLabel;
  bool _selectedIsCoord = false;

  /// Phone user GPS location (blue dot).
  LatLng? _myLocation;
  StreamSubscription<Position>? _locationSub;

  /// Sensor device location from LocationService (orange marker).
  LatLng? _sensorLocation;

  /// Loaded CRITICAL events for alert history markers.
  List<CriticalEvent> _criticalEvents = [];

  /// Geofence zones drawn as semi-transparent circles on the map.
  List<GeofenceZone> _geofenceZones = [];
  bool _showGeofenceZones = true;

  final GeoJsonService _geoJsonService = GeoJsonService();
  final ShapefileService _shapefileService = ShapefileService();
  final List<_LayerEntry> _entries = [];

  // ── Measure-distance mode ─────────────────────────────────────────────────
  bool _measureMode = false;
  final List<LatLng> _measureWaypoints = [];

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    if (widget.findings.isNotEmpty) {
      _reverseGeocode(widget.findings.first.latitude, widget.findings.first.longitude);
    }
    _loadGeoJsonLayers();
    _startLocationTracking();
    _loadSensorLocation();
    _loadCriticalEvents();
    _loadGeofenceZones();
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

  /// Grab the last fix from the shared LocationService singleton — this
  /// reflects the monitoring device's GPS position (used throughout the app
  /// for event logging, etc.).
  Future<void> _loadSensorLocation() async {
    try {
      final loc = LocationService.instance.lastLocation;
      if (loc != null && mounted) {
        setState(() => _sensorLocation = LatLng(loc.latitude, loc.longitude));
        return;
      }
      // No cached fix yet — try to get one (non-blocking).
      final fix = await LocationService.instance.getCurrentLocation();
      if (fix != null && mounted) {
        setState(() => _sensorLocation = LatLng(fix.latitude, fix.longitude));
      }
    } catch (e) {
      debugPrint('[FindingsMap] _loadSensorLocation: $e');
    }
  }

  /// Load persisted CRITICAL events from CriticalEventLogService.
  Future<void> _loadCriticalEvents() async {
    try {
      final all = await CriticalEventLogService.instance.loadEvents();
      final withGps = all.where((e) => e.location != null).toList();
      if (mounted) {
        setState(() => _criticalEvents = withGps);
      }
    } catch (e) {
      debugPrint('[FindingsMap] _loadCriticalEvents: $e');
    }
  }

  /// Load zones from GeofencingService singleton (in-memory, always fast).
  void _loadGeofenceZones() {
    final zones = GeofencingService.instance.zones;
    if (mounted) {
      setState(() => _geofenceZones = List<GeofenceZone>.from(zones));
    }
  }

  /// Add a danger zone at the current GPS position and refresh the circle layer.
  Future<void> _addDangerZoneHere() async {
    final loc = LocationService.instance.lastLocation ?? (_myLocation != null
        ? GpsLocation(
            latitude: _myLocation!.latitude,
            longitude: _myLocation!.longitude,
            accuracy: 10.0,
            timestamp: DateTime.now(),
          )
        : null);

    if (loc == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No GPS fix — cannot add zone')),
        );
      }
      return;
    }

    GeofencingService.instance.addCriticalEventZone(loc.latitude, loc.longitude);
    _loadGeofenceZones();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Danger zone added at '
            '${_formatCoord(loc.latitude, isLat: true)}, '
            '${_formatCoord(loc.longitude, isLat: false)}',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Show a bottom sheet with zone details when a zone circle is tapped.
  void _showZoneInfo(GeofenceZone zone) {
    final location = LocationService.instance.lastLocation ?? (_myLocation != null
        ? GpsLocation(
            latitude: _myLocation!.latitude,
            longitude: _myLocation!.longitude,
            accuracy: 10.0,
            timestamp: DateTime.now(),
          )
        : null);

    GeofenceStatus? status;
    if (location != null) {
      // Recompute status using simple Haversine for display.
      final distM = _haversineMeters(
        location.latitude, location.longitude,
        zone.center.latitude, zone.center.longitude,
      );
      if (distM <= zone.radiusMeters) {
        status = GeofenceStatus.inside;
      } else if (distM <= zone.radiusMeters * 2.0) {
        status = GeofenceStatus.approaching;
      } else {
        status = GeofenceStatus.outside;
      }
    }

    final severityColors = {
      GeofenceSeverity.info: Colors.blue,
      GeofenceSeverity.warning: Colors.amber,
      GeofenceSeverity.danger: Colors.red,
      GeofenceSeverity.critical: Colors.red,
    };
    final severityColor = severityColors[zone.severity] ?? Colors.grey;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(Icons.radar, color: severityColor, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    zone.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _zoneInfoRow('Severity',
                zone.severity.name.toUpperCase(), severityColor),
            _zoneInfoRow('Radius', '${zone.radiusMeters.toStringAsFixed(0)} m',
                Colors.white70),
            _zoneInfoRow(
              'Centre',
              '${_formatCoord(zone.center.latitude, isLat: true)}, '
                  '${_formatCoord(zone.center.longitude, isLat: false)}',
              Colors.white70,
            ),
            if (status != null)
              _zoneInfoRow(
                'Your status',
                status == GeofenceStatus.inside
                    ? 'INSIDE — Retreat immediately!'
                    : status == GeofenceStatus.approaching
                        ? 'Approaching — Exercise caution'
                        : 'Outside zone',
                status == GeofenceStatus.inside
                    ? Colors.red
                    : status == GeofenceStatus.approaching
                        ? Colors.amber
                        : Colors.green,
              ),
          ],
        ),
      ),
    );
  }

  Widget _zoneInfoRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: valueColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
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

  /// Export visible findings as GeoJSON and share via OS share sheet.
  Future<void> _exportGeoJson() async {
    try {
      final features = widget.findings.map((f) {
        // Determine a simple risk_level label.
        final riskLevel = _riskLevelForFinding(f);
        return {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [f.longitude, f.latitude],
          },
          'properties': {
            'id': f.id,
            'name': f.name,
            'type': f.type,
            'site': f.site,
            'date': f.date,
            'description': f.description,
            'source': f.source.name,
            'risk_level': riskLevel,
            if (f.locusNumber != null) 'locus': f.locusNumber,
            if (f.isSignificant) 'significant': true,
          },
        };
      }).toList();

      final collection = {
        'type': 'FeatureCollection',
        'features': features,
        'metadata': {
          'exported_by': 'AncientVision',
          'exported_at': DateTime.now().toIso8601String(),
          'site': widget.findings.isNotEmpty ? widget.findings.first.site : 'Unknown',
          'finding_count': features.length,
        },
      };

      final jsonStr = const JsonEncoder.withIndent('  ').convert(collection);

      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/findings_$ts.geojson');
      await file.writeAsString(jsonStr);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/geo+json')],
        subject: 'AncientVision Findings — GeoJSON',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('GeoJSON export failed: $e')),
        );
      }
    }
  }

  /// Simple risk level derived from finding type.  When PPV data is attached
  /// to findings in future, this can use that instead.
  String _riskLevelForFinding(Finding f) {
    if (f.isSignificant) return 'high';
    final t = f.type.toLowerCase();
    if (t.contains('coin') || t.contains('jewelry')) return 'medium';
    return 'low';
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

  // ── Map tap handler (supports measure mode) ───────────────────────────────

  void _onMapTap(TapPosition tapPos, LatLng tappedPoint) {
    if (_measureMode) {
      setState(() => _measureWaypoints.add(tappedPoint));
      return;
    }

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

  void _onMapLongPress(TapPosition tapPos, LatLng tappedPoint) {
    if (!_measureMode) {
      // Enter measure mode on long-press if not already active.
      setState(() {
        _measureMode = true;
        _measureWaypoints.clear();
        _measureWaypoints.add(tappedPoint);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Measure mode: tap to add waypoints'),
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      setState(() => _measureWaypoints.add(tappedPoint));
    }
  }

  // ── Geofence zone circle builders ─────────────────────────────────────────

  /// Build flutter_map Circle overlays for each registered geofence zone.
  List<CircleMarker> _buildGeofenceCircles() {
    if (!_showGeofenceZones || _geofenceZones.isEmpty) return [];

    return _geofenceZones.map((zone) {
      final Color fillColor;
      final Color borderColor;

      switch (zone.severity) {
        case GeofenceSeverity.danger:
        case GeofenceSeverity.critical:
          fillColor = const Color(0x33F44336); // red 20% opacity
          borderColor = const Color(0xCCF44336);
        case GeofenceSeverity.warning:
          fillColor = const Color(0x26FFC107); // amber 15% opacity
          borderColor = const Color(0xCCFFC107);
        case GeofenceSeverity.info:
          fillColor = const Color(0x1A2196F3); // blue 10% opacity
          borderColor = const Color(0xCC2196F3);
      }

      return CircleMarker(
        point: LatLng(zone.center.latitude, zone.center.longitude),
        radius: zone.radiusMeters,
        useRadiusInMeter: true,
        color: fillColor,
        borderColor: borderColor,
        borderStrokeWidth: 1.5,
      );
    }).toList();
  }

  /// Build tap-target markers centred on each geofence zone (invisible but
  /// tappable, sitting above the circles in the layer stack).
  List<Marker> _buildGeofenceZoneTapTargets() {
    if (!_showGeofenceZones || _geofenceZones.isEmpty) return [];

    return _geofenceZones.map((zone) {
      return Marker(
        point: LatLng(zone.center.latitude, zone.center.longitude),
        width: 44,
        height: 44,
        child: GestureDetector(
          onTap: () => _showZoneInfo(zone),
          child: const SizedBox.expand(), // transparent hit area
        ),
      );
    }).toList();
  }

  // ── Marker builders ───────────────────────────────────────────────────────

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

  /// Sensor device location — distinct orange diamond marker with border.
  List<Marker> _buildSensorMarker() {
    if (!_showSensorMarker || _sensorLocation == null) return [];
    return [
      Marker(
        point: _sensorLocation!,
        width: 44,
        height: 44,
        child: GestureDetector(
          onTap: () => setState(() {
            _selectedFeatureLabel =
                'Sensor: ${_formatCoord(_sensorLocation!.latitude, isLat: true)}, '
                '${_formatCoord(_sensorLocation!.longitude, isLat: false)}';
            _selectedIsCoord = false;
          }),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 44, height: 44,
                decoration: const BoxDecoration(
                  color: Color(0x44FF6D00),
                  shape: BoxShape.circle,
                ),
              ),
              const Icon(
                Icons.sensors,
                size: 28,
                color: Color(0xFFFF6D00),
                shadows: [
                  Shadow(color: Colors.black54, blurRadius: 6),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  /// Alert history markers — warning icon for each CRITICAL event with GPS.
  List<Marker> _buildAlertMarkers() {
    if (!_showAlerts) return [];
    return _criticalEvents.map((ev) {
      final loc = ev.location!; // only events with location are in the list
      final point = LatLng(loc.latitude, loc.longitude);
      return Marker(
        point: point,
        width: 36,
        height: 36,
        child: GestureDetector(
          onTap: () {
            final ts = ev.timestamp.toLocal();
            final label = 'CRITICAL ${ts.day}/${ts.month} ${ts.hour}:${ts.minute.toString().padLeft(2, '0')} '
                '— PPV ${ev.ppv.toStringAsFixed(2)} mm/s';
            setState(() {
              _selectedFeatureLabel = label;
              _selectedIsCoord = false;
            });
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0x55F44336),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFF44336), width: 1.5),
                ),
              ),
              const Icon(
                Icons.warning_amber_rounded,
                size: 22,
                color: Color(0xFFF44336),
                shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ],
          ),
        ),
      );
    }).toList();
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

  /// Waypoint markers for the distance-measure tool.
  List<Marker> _buildMeasureMarkers() {
    if (!_measureMode || _measureWaypoints.isEmpty) return [];
    return _measureWaypoints.asMap().entries.map((e) {
      final index = e.key;
      final pt = e.value;
      return Marker(
        point: pt,
        width: 28,
        height: 28,
        child: GestureDetector(
          onTap: () => setState(() => _measureWaypoints.removeAt(index)),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF00BCD4),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Center(
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  // ── Polyline builders ─────────────────────────────────────────────────────

  List<Polyline> _buildMeasurePolyline() {
    if (!_measureMode || _measureWaypoints.length < 2) return [];
    return [
      Polyline(
        points: _measureWaypoints,
        color: const Color(0xFF00BCD4),
        strokeWidth: 2.5,
        isDotted: true,
      ),
    ];
  }

  // ── GeoJSON layer builders ────────────────────────────────────────────────

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

  // ── Helpers ───────────────────────────────────────────────────────────────

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

  /// Haversine great-circle distance in metres (used for zone status display).
  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * 3.141592653589793 / 180;
    final dLon = (lon2 - lon1) * 3.141592653589793 / 180;
    final a = (dLat / 2) * (dLat / 2) +
        (lat1 * 3.141592653589793 / 180).abs() *
            (lat2 * 3.141592653589793 / 180).abs() *
            (dLon / 2) *
            (dLon / 2);
    // Simplified — accurate enough for display at short range.
    return r * 2 * (a < 1 ? a : 1);
  }

  /// Total geodetic distance along the measure waypoints in metres.
  double _measureTotalMetres() {
    double total = 0;
    const distance = Distance();
    for (int i = 1; i < _measureWaypoints.length; i++) {
      total += distance.as(
        LengthUnit.Meter,
        _measureWaypoints[i - 1],
        _measureWaypoints[i],
      );
    }
    return total;
  }

  String _formatMetres(double m) {
    if (m < 1000) return '${m.toStringAsFixed(1)} m';
    return '${(m / 1000).toStringAsFixed(3)} km';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final firstFinding = widget.findings.first;

    // All polylines for the map (GeoJSON + measure).
    final allPolylines = [
      ..._buildGeoJsonPolylines(),
      ..._buildMeasurePolyline(),
    ];

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
            onLongPress: _onMapLongPress,
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
            // Geofence zone circles below all other overlays.
            CircleLayer(circles: _buildGeofenceCircles()),
            PolygonLayer(polygons: _buildGeoJsonPolygons()),
            PolylineLayer(polylines: allPolylines),
            MarkerLayer(markers: _buildGeoJsonPointMarkers()),
            // Alert history markers below findings so findings are on top.
            MarkerLayer(markers: _buildAlertMarkers()),
            MarkerLayer(markers: _buildFindingMarkers()),
            // Sensor marker on top of findings.
            MarkerLayer(markers: _buildSensorMarker()),
            // Geofence tap targets above all map content.
            MarkerLayer(markers: _buildGeofenceZoneTapTargets()),
            // Measure waypoints on top of everything.
            MarkerLayer(markers: _buildMeasureMarkers()),
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
              const SizedBox(height: 8),
              _mapButton(
                icon: Icons.upload_file,
                tooltip: 'Export findings as GeoJSON',
                onTap: _exportGeoJson,
              ),
              const SizedBox(height: 8),
              _mapButton(
                icon: _measureMode ? Icons.straighten : Icons.space_bar,
                tooltip: _measureMode ? 'Exit measure mode' : 'Measure distance',
                active: _measureMode,
                onTap: () => setState(() {
                  _measureMode = !_measureMode;
                  if (!_measureMode) _measureWaypoints.clear();
                }),
              ),
              const SizedBox(height: 8),
              // Add danger zone at current GPS location.
              _mapButton(
                icon: Icons.add_location_alt,
                tooltip: 'Add danger zone here',
                onTap: _addDangerZoneHere,
              ),
            ],
          ),
        ),

        // Layer panel
        if (_showLayerPanel)
          Positioned(
            top: 12, right: 60,
            child: Container(
              width: 210,
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
                  _layerToggle(
                      'Sensor', _showSensorMarker, (v) => setState(() => _showSensorMarker = v)),
                  _layerToggle(
                      'Alert History', _showAlerts, (v) => setState(() => _showAlerts = v)),
                  _layerToggle(
                      'Geofence Zones', _showGeofenceZones,
                      (v) => setState(() => _showGeofenceZones = v)),
                  if (_entries.isNotEmpty) ...[
                    const Divider(color: Colors.white24, height: 16),
                    ..._entries.map((e) => _layerRow(e)),
                  ],
                ],
              ),
            ),
          ),

        // Measure distance readout
        if (_measureMode)
          Positioned(
            top: 12, left: 12,
            child: Padding(
              padding: const EdgeInsets.only(top: 44),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xE000BCD4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.straighten, color: Colors.white, size: 14),
                        SizedBox(width: 6),
                        Text('Measure', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    if (_measureWaypoints.length >= 2) ...[
                      const SizedBox(height: 4),
                      Text(
                        _formatMetres(_measureTotalMetres()),
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${_measureWaypoints.length} waypoints',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ] else
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('Tap map to add\nwaypoints', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => setState(() => _measureWaypoints.clear()),
                      child: const Text('Clear', style: TextStyle(color: Colors.white54, fontSize: 11, decoration: TextDecoration.underline)),
                    ),
                  ],
                ),
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

        // Alert count badge (bottom-left)
        if (_criticalEvents.isNotEmpty && _showAlerts)
          Positioned(
            bottom: 12, left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xCCF44336),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    '${_criticalEvents.length} alert${_criticalEvents.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ── Reusable widgets ──────────────────────────────────────────────────────

  Widget _mapButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: active ? const Color(0xCC00BCD4) : Colors.black.withAlpha(179),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: active ? Colors.cyan : Colors.white24),
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
