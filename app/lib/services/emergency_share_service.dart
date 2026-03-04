import 'package:share_plus/share_plus.dart';
import '../services/location_service.dart';

/// Emergency share service — broadcasts a CRITICAL seismic hazard alert
/// via the system share sheet (SMS, WhatsApp, email, etc.).
///
/// Triggered automatically when the anomaly level reaches CRITICAL, or
/// manually by the user via the safety screen's emergency button.
///
/// Usage:
/// ```dart
/// await EmergencyShareService.shareAlert(
///   ppv: 1.82,
///   anomalyScore: 0.91,
///   deviceId: 'AncientVision-A4:CF:12',
///   location: LocationService.instance.lastLocation,
/// );
/// ```
class EmergencyShareService {
  // Private constructor — static-only utility class.
  EmergencyShareService._();

  // -----------------------------------------------------------------------
  // Core share action
  // -----------------------------------------------------------------------

  /// Share a formatted CRITICAL hazard alert via the system share sheet.
  ///
  /// [ppv]          Peak particle velocity in mm/s.
  /// [anomalyScore] Normalised anomaly score 0.0–1.0.
  /// [deviceId]     BLE device identifier string (MAC or name).
  /// [location]     Last known GPS fix, or null if unavailable.
  /// [precursorPattern] Optional pattern label, e.g. 'imminent_failure'.
  static Future<void> shareAlert({
    required double ppv,
    required double anomalyScore,
    required String deviceId,
    GpsLocation? location,
    String? precursorPattern,
  }) async {
    final locationStr = location != null
        ? 'Location: ${location.latitude.toStringAsFixed(6)}, '
              '${location.longitude.toStringAsFixed(6)} '
              '(±${location.accuracy.toStringAsFixed(0)} m)'
        : 'Location: unavailable';

    final patternStr = precursorPattern != null
        ? 'Pattern: ${_formatPatternName(precursorPattern)}'
        : '';

    final message = '''
SEISMIC HAZARD ALERT
AncientVision Safety System

CRITICAL anomaly detected
PPV: ${ppv.toStringAsFixed(3)} mm/s
Risk Score: ${(anomalyScore * 100).toStringAsFixed(1)}%${patternStr.isNotEmpty ? '\n$patternStr' : ''}
$locationStr
Time: ${DateTime.now().toIso8601String()}
Device: $deviceId

EVACUATE AREA IMMEDIATELY
Contact site safety officer and archaeological authority.
''';

    await Share.share(
      message,
      subject: 'AncientVision CRITICAL Seismic Alert',
    );
  }

  // -----------------------------------------------------------------------
  // Convenience overload — pulls location automatically
  // -----------------------------------------------------------------------

  /// Share a critical alert, automatically using [LocationService.instance]
  /// for the current GPS fix.
  static Future<void> shareAlertAutoLocation({
    required double ppv,
    required double anomalyScore,
    required String deviceId,
    String? precursorPattern,
  }) async {
    await shareAlert(
      ppv: ppv,
      anomalyScore: anomalyScore,
      deviceId: deviceId,
      location: LocationService.instance.lastLocation,
      precursorPattern: precursorPattern,
    );
  }

  // -----------------------------------------------------------------------
  // Helper
  // -----------------------------------------------------------------------

  static String _formatPatternName(String raw) {
    return raw
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty
            ? '${w[0].toUpperCase()}${w.substring(1)}'
            : '')
        .join(' ');
  }
}
