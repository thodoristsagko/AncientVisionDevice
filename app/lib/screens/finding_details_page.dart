// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/finding_model.dart';
import '../services/critical_event_log_service.dart';

/// Full-screen details page for a finding
class FindingDetailsPage extends StatefulWidget {
  final Finding finding;

  const FindingDetailsPage({super.key, required this.finding});

  @override
  State<FindingDetailsPage> createState() => _FindingDetailsPageState();
}

class _FindingDetailsPageState extends State<FindingDetailsPage> {
  // Vibration risk data loaded from CriticalEventLogService
  List<CriticalEvent> _nearbyEvents = [];
  bool _riskLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadRiskData();
  }

  /// Load critical events and filter to those near this finding (within ~500 m and ±30 s window).
  Future<void> _loadRiskData() async {
    try {
      final svc = CriticalEventLogService.instance;
      // ensureLoaded is handled internally by the service
      final events = svc.events;

      // Parse finding date (assumed format: "YYYY-MM-DD" or ISO 8601).
      // If time-of-day is unknown, we assume the whole day is the recording window.
      DateTime? findingDateTime;
      try {
        findingDateTime = DateTime.parse(widget.finding.date);
      } catch (_) {
        // If date parsing fails, use current date as fallback
        findingDateTime = DateTime.now();
      }

      // Filter events that have a GPS location and are within ~500 m of the finding,
      // and occurred within ±30 seconds of the finding's recorded time.
      // We use a simple bounding-box filter (0.005 deg ≈ 500 m).
      const threshold = 0.005;
      const timeWindowSeconds = 30;

      final nearby = events.where((e) {
        final loc = e.location;
        if (loc == null) return false;

        // GPS proximity check
        final dLat = (loc.latitude - widget.finding.latitude).abs();
        final dLon = (loc.longitude - widget.finding.longitude).abs();
        if (dLat > threshold || dLon > threshold) return false;

        // Time window check: if date string has no time component, use whole-day window.
        // Otherwise, check ±30 seconds from the parsed timestamp.
        if (widget.finding.date.length <= 10) {
          // Date only (YYYY-MM-DD), so include any event on that day
          return e.timestamp.year == findingDateTime!.year &&
              e.timestamp.month == findingDateTime.month &&
              e.timestamp.day == findingDateTime.day;
        } else {
          // Has time component; check ±30 second window
          final diff = e.timestamp.difference(findingDateTime!).abs();
          return diff.inSeconds <= timeWindowSeconds;
        }
      }).toList();

      if (mounted) {
        setState(() {
          _nearbyEvents = nearby;
          _riskLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _riskLoaded = true);
    }
  }

  /// Check if any critical events occurred very close in time (±5 seconds) to this finding.
  bool get _recordedDuringAnomaly {
    if (!_riskLoaded || widget.finding.date.isEmpty) return false;

    // Only return true if there are nearby events within a tight 5-second window
    try {
      DateTime? findingDateTime;
      try {
        findingDateTime = DateTime.parse(widget.finding.date);
      } catch (_) {
        findingDateTime = DateTime.now();
      }

      // If only date is available (no time), we can't determine tight correlation
      if (widget.finding.date.length <= 10) return false;

      // Check for events within ±5 seconds
      const tightWindowSeconds = 5;
      return _nearbyEvents.any((e) {
        final diff = e.timestamp.difference(findingDateTime!).abs();
        return diff.inSeconds <= tightWindowSeconds;
      });
    } catch (_) {
      return false;
    }
  }

  /// Compute risk badge label from nearby CRITICAL events.
  String get _riskLabel {
    if (_nearbyEvents.isEmpty) return 'LOW';
    final maxPpv = _nearbyEvents.map((e) => e.ppv).reduce((a, b) => a > b ? a : b);
    if (maxPpv >= 2.0) return 'HIGH';
    if (maxPpv >= 0.5) return 'MEDIUM';
    return 'LOW';
  }

  Color get _riskColor {
    switch (_riskLabel) {
      case 'HIGH':
        return const Color(0xFFE53935);
      case 'MEDIUM':
        return const Color(0xFFFFC107);
      default:
        return const Color(0xFF4CAF50);
    }
  }

  double get _peakPpv {
    if (_nearbyEvents.isEmpty) return 0.0;
    return _nearbyEvents.map((e) => e.ppv).reduce((a, b) => a > b ? a : b);
  }

  CriticalEvent? get _lastEvent =>
      _nearbyEvents.isEmpty ? null : _nearbyEvents.first; // list is newest-first

  /// Export finding details as JSON and share via OS share sheet.
  Future<void> _exportAsJson() async {
    try {
      final f = widget.finding;
      final data = <String, dynamic>{
        'id': f.id,
        'name': f.name,
        'type': f.type,
        'site': f.site,
        'date': f.date,
        'description': f.description,
        'latitude': f.latitude,
        'longitude': f.longitude,
        'source': f.source.label,
        'photos_count':
            f.photoGallery.length + (f.imageUrl != null && f.imageUrl!.isNotEmpty ? 1 : 0),
        'model3d_available': f.model3dUrl != null,
        'vibration_risk': {
          'risk_level': _riskLabel,
          'peak_ppv_mm_s': _peakPpv,
          'nearby_critical_events': _nearbyEvents.length,
          'last_critical_event': _lastEvent?.timestamp.toIso8601String(),
        },
        'exported_at': DateTime.now().toIso8601String(),
      };

      final json = const JsonEncoder.withIndent('  ').convert(data);
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/finding_${f.id}_$ts.json');
      await file.writeAsString(json);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'AncientVision Finding — ${f.id}: ${f.name}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Show a detailed explanation dialog for a measurement row.
  void _showMeasurementDialog(String label, String value) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          value,
          style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFFFFC107))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final typeColor = Finding.getTypeColor(widget.finding.type);
    final f = widget.finding;
    final totalPhotos = f.photoGallery.length + (f.imageUrl != null && f.imageUrl!.isNotEmpty ? 1 : 0);

    return Scaffold(
      backgroundColor: const Color(0xFF0D3A39),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(f.id, style: const TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share, color: Colors.white),
            tooltip: 'Export as JSON',
            onPressed: _exportAsJson,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top section: Description (left) and Photo (right)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Name and Description
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Finding name with type color
                      Row(
                        children: [
                          Container(
                            width: 4,
                            height: 24,
                            decoration: BoxDecoration(
                              color: typeColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              f.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Type badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: typeColor.withAlpha(50),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: typeColor, width: 1),
                        ),
                        child: Text(
                          f.type,
                          style: TextStyle(
                            color: typeColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Description
                      const Text(
                        'Description',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(13),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          f.description.isNotEmpty
                              ? f.description
                              : 'No description available',
                          style: TextStyle(
                            color: f.description.isNotEmpty
                                ? Colors.white
                                : Colors.white54,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Right: Photo + photo count badge
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: f.imageUrl != null && f.imageUrl!.isNotEmpty
                            ? Image.network(
                                f.imageUrl!,
                                height: 180,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => Container(
                                  height: 180,
                                  color: const Color(0xFF1C2523),
                                  child: const Center(
                                    child: Icon(Icons.broken_image, color: Colors.white38, size: 48),
                                  ),
                                ),
                              )
                            : Container(
                                height: 180,
                                color: const Color(0xFF1C2523),
                                child: const Center(
                                  child: Icon(Icons.image_not_supported, color: Colors.white38, size: 48),
                                ),
                              ),
                      ),
                      // Photo gallery header with count badge
                      if (f.photoGallery.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Text(
                              'Gallery',
                              style: TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFC107).withAlpha(51),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFFFC107).withAlpha(128),
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                '$totalPhotos photos',
                                style: const TextStyle(
                                  color: Color(0xFFFFC107),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 50,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: f.photoGallery.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    f.photoGallery[index],
                                    width: 50,
                                    height: 50,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      width: 50,
                                      height: 50,
                                      color: const Color(0xFF1C2523),
                                      child: const Icon(Icons.broken_image, color: Colors.white38, size: 20),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Vibration Risk Assessment section
            _buildVibrationRiskCard(),

            const SizedBox(height: 12),

            // "Recorded During" warning if applicable
            if (_recordedDuringAnomaly)
              _buildRecordedDuringWarning(),

            if (_recordedDuringAnomaly)
              const SizedBox(height: 12),

            // Location card
            _buildDetailCard(
              icon: Icons.location_on,
              title: 'Location',
              children: [
                _buildDetailRow('Site', f.site),
                _buildDetailRow(
                  'Coordinates',
                  '${f.latitude.toStringAsFixed(6)}, ${f.longitude.toStringAsFixed(6)}',
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Date & Source card
            _buildDetailCard(
              icon: Icons.info_outline,
              title: 'Information',
              children: [
                _buildDetailRow('Date Found', f.date),
                _buildDetailRow('Source', f.source.label),
                if (f.model3dUrl != null)
                  _buildDetailRow('3D Model', 'Available'),
              ],
            ),

            // Coin details card (shown only for coins)
            if (f.isCoin && _hasCoinData()) ...[
              const SizedBox(height: 12),
              _buildDetailCard(
                icon: Icons.paid,
                title: 'Coin Details',
                children: [
                  if (f.denomination != null)
                    _buildDetailRow('Denomination', f.denomination!),
                  if (f.mint != null)
                    _buildDetailRow('Mint', f.mint!),
                  if (f.ruler != null)
                    _buildDetailRow('Ruler/Authority', f.ruler!),
                  if (f.obverseLegend != null)
                    _buildDetailRow('Obverse Legend', f.obverseLegend!),
                  if (f.reverseLegend != null)
                    _buildDetailRow('Reverse Legend', f.reverseLegend!),
                  if (f.dieAxis != null)
                    _buildDetailRow('Die Axis', "${f.dieAxis} o'clock"),
                  if (f.obverseDescription != null)
                    _buildDetailRow('Obverse Desc.', f.obverseDescription!),
                  if (f.reverseDescription != null)
                    _buildDetailRow('Reverse Desc.', f.reverseDescription!),
                ],
              ),
            ],

            // Fragment details card (shown only for fragments)
            if (f.isFragment && _hasFragmentData()) ...[
              const SizedBox(height: 12),
              _buildDetailCard(
                icon: Icons.broken_image,
                title: 'Fragment Details',
                children: [
                  if (f.vesselPart != null)
                    _buildDetailRow('Vessel Part', f.vesselPart!),
                  if (f.wareType != null)
                    _buildDetailRow('Ware Type', f.wareType!),
                  if (f.decorationStyle != null)
                    _buildDetailRow('Decoration', f.decorationStyle!),
                  if (f.rimDiameter != null)
                    _buildTappableMeasurementRow(
                      'Rim Diameter',
                      '${f.rimDiameter} mm',
                      'Rim Diameter: ${f.rimDiameter} mm\n\nThe outer diameter of the vessel opening, measured in millimetres. Used for vessel typology and capacity estimation.',
                    ),
                  if (f.wallThickness != null)
                    _buildTappableMeasurementRow(
                      'Wall Thickness',
                      '${f.wallThickness} mm',
                      'Wall Thickness: ${f.wallThickness} mm\n\nThe thickness of the ceramic wall at the measurement point. Thinner walls often indicate wheel-thrown fine ware; thicker walls suggest coarser hand-built vessels.',
                    ),
                  if (f.fabricColorInt != null)
                    _buildDetailRow('Interior Color', f.fabricColorInt!),
                  if (f.fabricColorExt != null)
                    _buildDetailRow('Exterior Color', f.fabricColorExt!),
                  if (f.surfaceTreatment != null)
                    _buildDetailRow('Surface Treatment', f.surfaceTreatment!),
                ],
              ),
            ],

            // Context details card (shown if context data exists)
            if (_hasContextData()) ...[
              const SizedBox(height: 12),
              _buildDetailCard(
                icon: Icons.layers,
                title: 'Stratigraphic Context',
                children: [
                  if (f.locusNumber != null)
                    _buildDetailRow('Locus/Context', f.locusNumber!),
                  if (f.soilType != null)
                    _buildDetailRow('Soil Type', f.soilType!),
                  if (f.matrixDescription != null)
                    _buildDetailRow('Matrix', f.matrixDescription!),
                  if (f.harrisPosition != null)
                    _buildDetailRow('Harris Position', f.harrisPosition!),
                  if (f.associatedFeatures != null && f.associatedFeatures!.isNotEmpty)
                    _buildDetailRow('Associated', f.associatedFeatures!.join(', ')),
                ],
              ),
            ],

            const SizedBox(height: 12),

            // 3D Model button if available
            if (f.model3dUrl != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF).withAlpha(30),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF7C4DFF), width: 1),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.view_in_ar, color: Color(0xFF7C4DFF), size: 32),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '3D Model Available',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'View the reconstructed 3D model',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.arrow_forward_ios, color: Color(0xFF7C4DFF), size: 20),
                  ],
                ),
              ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Vibration Risk Assessment card
  // ---------------------------------------------------------------------------

  Widget _buildVibrationRiskCard() {
    final riskColor = _riskColor;
    final label = _riskLabel;
    final lastEvt = _lastEvent;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: riskColor.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: riskColor.withAlpha(128), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.vibration, color: riskColor, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Vibration Risk Assessment',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // Risk badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: riskColor.withAlpha(51),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: riskColor, width: 1),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: riskColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!_riskLoaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                  ),
                  SizedBox(width: 8),
                  Text('Loading risk data...', style: TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),
            )
          else ...[
            _buildRiskRow(
              'Nearby CRITICAL events',
              _nearbyEvents.isEmpty ? 'None recorded' : '${_nearbyEvents.length}',
            ),
            _buildRiskRow(
              'Peak PPV near finding',
              _peakPpv > 0 ? '${_peakPpv.toStringAsFixed(3)} mm/s' : 'No data',
            ),
            _buildRiskRow(
              'Last event',
              lastEvt != null
                  ? _formatEventTime(lastEvt.timestamp)
                  : 'No events recorded',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRiskRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  String _formatEventTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} days ago';
  }

  /// Build warning card if finding was recorded during ANOMALY event.
  Widget _buildRecordedDuringWarning() {
    final tightEvent = _nearbyEvents.firstWhere(
      (e) {
        try {
          DateTime findingDateTime;
          try {
            findingDateTime = DateTime.parse(widget.finding.date);
          } catch (_) {
            findingDateTime = DateTime.now();
          }
          final diff = e.timestamp.difference(findingDateTime).abs();
          return diff.inSeconds <= 5;
        } catch (_) {
          return false;
        }
      },
      orElse: () => _nearbyEvents.first,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE53935).withAlpha(25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFE53935).withAlpha(128),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFE53935), size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Recorded During ANOMALY',
                  style: TextStyle(
                    color: Color(0xFFE53935),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'This finding was recorded within seconds of a critical vibration anomaly (PPV: ${tightEvent.ppv.toStringAsFixed(3)} mm/s). '
            'Site conditions may have been unstable at the time of discovery.',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared card / row helpers
  // ---------------------------------------------------------------------------

  Widget _buildDetailCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(13),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFFFFC107), size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Tappable measurement row: shows a full explanation dialog on tap.
  Widget _buildTappableMeasurementRow(
      String label, String value, String explanation) {
    return InkWell(
      onTap: () => _showMeasurementDialog(label, explanation),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Text(
                    value,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.info_outline, color: Colors.white38, size: 14),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Guard predicates (unchanged from original)
  // ---------------------------------------------------------------------------

  bool _hasCoinData() {
    final f = widget.finding;
    return f.denomination != null ||
        f.mint != null ||
        f.ruler != null ||
        f.obverseLegend != null ||
        f.reverseLegend != null ||
        f.dieAxis != null ||
        f.obverseDescription != null ||
        f.reverseDescription != null;
  }

  bool _hasFragmentData() {
    final f = widget.finding;
    return f.vesselPart != null ||
        f.wareType != null ||
        f.decorationStyle != null ||
        f.rimDiameter != null ||
        f.wallThickness != null ||
        f.fabricColorInt != null ||
        f.fabricColorExt != null ||
        f.surfaceTreatment != null;
  }

  bool _hasContextData() {
    final f = widget.finding;
    return f.locusNumber != null ||
        f.soilType != null ||
        f.matrixDescription != null ||
        f.harrisPosition != null ||
        (f.associatedFeatures != null && f.associatedFeatures!.isNotEmpty);
  }
}
