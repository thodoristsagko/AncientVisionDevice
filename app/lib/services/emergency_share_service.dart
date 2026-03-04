import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/location_service.dart';

// ---------------------------------------------------------------------------
// Data class
// ---------------------------------------------------------------------------

/// Structured snapshot of an emergency alert, suitable for serialisation and
/// cross-service transfer.
class EmergencyAlertData {
  final double ppv;
  final double anomalyScore;
  final String deviceId;
  final GpsLocation? location;
  final String? precursorPattern;
  final DateTime timestamp;

  const EmergencyAlertData({
    required this.ppv,
    required this.anomalyScore,
    required this.deviceId,
    this.location,
    this.precursorPattern,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'ppv': ppv,
        'anomaly_score': anomalyScore,
        'device_id': deviceId,
        'location': location == null
            ? null
            : {
                'lat': location!.latitude,
                'lon': location!.longitude,
                'acc': location!.accuracy,
                'ts': location!.timestamp.toIso8601String(),
              },
        'precursor_pattern': precursorPattern,
        'timestamp': timestamp.toIso8601String(),
      };

  factory EmergencyAlertData.fromJson(Map<String, dynamic> json) {
    final locMap = json['location'] as Map<String, dynamic>?;
    return EmergencyAlertData(
      ppv: (json['ppv'] as num).toDouble(),
      anomalyScore: (json['anomaly_score'] as num).toDouble(),
      deviceId: json['device_id'] as String,
      location: locMap == null
          ? null
          : GpsLocation(
              latitude: (locMap['lat'] as num).toDouble(),
              longitude: (locMap['lon'] as num).toDouble(),
              accuracy: (locMap['acc'] as num).toDouble(),
              timestamp: DateTime.parse(locMap['ts'] as String),
            ),
      precursorPattern: json['precursor_pattern'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

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
  // State
  // -----------------------------------------------------------------------

  /// Timestamp of the most recent successful [shareAlert] call.
  static DateTime? lastShareTime;

  /// Time elapsed since the last share action, or null if never shared.
  static Duration? get timeSinceLastShare {
    if (lastShareTime == null) return null;
    return DateTime.now().difference(lastShareTime!);
  }

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

    lastShareTime = DateTime.now();
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
  // Structured alert data
  // -----------------------------------------------------------------------

  /// Share an [EmergencyAlertData] snapshot via the system share sheet.
  ///
  /// Delegates to [shareAlert] using the data object's fields.
  static Future<void> shareAlertData(EmergencyAlertData data) async {
    await shareAlert(
      ppv: data.ppv,
      anomalyScore: data.anomalyScore,
      deviceId: data.deviceId,
      location: data.location,
      precursorPattern: data.precursorPattern,
    );
  }

  // -----------------------------------------------------------------------
  // SMS-optimised message
  // -----------------------------------------------------------------------

  /// Build a compact SMS-ready alert string (≤ 160 characters).
  ///
  /// Example output:
  /// `SEISMIC ALERT! PPV:1.82mm/s [CRITICAL] 37.975,23.735 AncientVision 14:32`
  static String buildSmsMessage({
    required double ppv,
    required double anomalyScore,
    GpsLocation? location,
  }) {
    final level = ppv >= 1.0 ? 'CRITICAL' : 'WARNING';
    final locPart = location != null
        ? ' ${location.latitude.toStringAsFixed(3)},${location.longitude.toStringAsFixed(3)}'
        : '';
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');

    final msg =
        'SEISMIC ALERT! PPV:${ppv.toStringAsFixed(2)}mm/s [$level]$locPart AncientVision $hh:$mm';

    // Truncate hard at 160 to guarantee SMS compliance.
    return msg.length <= 160 ? msg : msg.substring(0, 160);
  }

  // -----------------------------------------------------------------------
  // WhatsApp direct link
  // -----------------------------------------------------------------------

  /// Open WhatsApp with a pre-filled message to [phone].
  ///
  /// [phone] must be in international format without leading '+' (e.g. '30123456789').
  /// [message] is the pre-filled text.
  ///
  /// Returns true if WhatsApp was successfully opened, false otherwise.
  static Future<bool> openWhatsApp(
    String phone, {
    required String message,
  }) async {
    final encoded = Uri.encodeComponent(message);
    final uri = Uri.parse('whatsapp://send?phone=$phone&text=$encoded');
    try {
      if (await canLaunchUrl(uri)) {
        return launchUrl(uri);
      }
    } catch (_) {
      // WhatsApp not installed or scheme not handled — fall through.
    }
    return false;
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
