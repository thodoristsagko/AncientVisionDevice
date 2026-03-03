// Dependency: exif: ^3.3.0 (add to pubspec.yaml)
// ignore_for_file: non_constant_identifier_names

import 'dart:io';
import 'dart:typed_data';
import 'package:exif/exif.dart';

/// Parsed EXIF metadata for photogrammetry camera calibration.
class ExifData {
  final double? focalLengthMM;
  final double? focalLength35mm;
  final double? sensorWidth;
  final int? imageWidth;
  final int? imageHeight;
  final String? cameraMake;
  final String? cameraModel;
  final double? gpsLatitude;
  final double? gpsLongitude;
  final double? gpsAltitude;
  final DateTime? dateTime;
  final int? isoSpeed;
  final double? exposureTime;
  final double? fNumber;

  const ExifData({
    this.focalLengthMM,
    this.focalLength35mm,
    this.sensorWidth,
    this.imageWidth,
    this.imageHeight,
    this.cameraMake,
    this.cameraModel,
    this.gpsLatitude,
    this.gpsLongitude,
    this.gpsAltitude,
    this.dateTime,
    this.isoSpeed,
    this.exposureTime,
    this.fNumber,
  });

  /// Focal length in pixels: (focalLengthMM / sensorWidth) * imageWidth.
  double? get focalLengthPixels {
    if (focalLengthMM == null || sensorWidth == null || imageWidth == null) {
      return null;
    }
    return (focalLengthMM! / sensorWidth!) * imageWidth!;
  }

  /// Ground sample distance in mm/pixel at [distanceMeters] from the camera.
  double? groundSampleDistance(double distanceMeters) {
    if (focalLengthMM == null || sensorWidth == null || imageWidth == null) {
      return null;
    }
    final pixelSize = sensorWidth! / imageWidth!; // mm per pixel on sensor
    return (pixelSize * distanceMeters * 1000) / focalLengthMM!; // mm per pixel on ground
  }

  @override
  String toString() =>
      'ExifData(make=$cameraMake, model=$cameraModel, '
      'focal=${focalLengthMM}mm, sensor=${sensorWidth}mm, '
      '${imageWidth}x$imageHeight)';
}

/// Service for extracting EXIF metadata and computing camera calibration data.
class ExifService {
  /// Database of known smartphone sensor widths (mm).
  /// Keyed by lowercase substring matches against camera make+model.
  static const Map<String, double> _sensorDatabase = {
    // Apple iPhones (main wide camera)
    'iphone 16 pro': 5.7,
    'iphone 15 pro': 5.7,
    'iphone 14 pro': 5.7,
    'iphone 13 pro': 5.7,
    'iphone 12 pro': 5.7,
    'iphone 16': 5.7,
    'iphone 15': 5.7,
    'iphone 14': 5.7,
    'iphone 13': 5.7,
    'iphone 12': 5.7,
    // Samsung Galaxy S series
    'galaxy s24': 6.4,
    'galaxy s23': 6.4,
    'galaxy s22': 6.4,
    'galaxy s21': 6.4,
    'sm-s92': 6.4, // Samsung model numbers for S24
    'sm-s91': 6.4, // Samsung model numbers for S23
    'sm-s90': 6.4, // Samsung model numbers for S22
    // Google Pixel
    'pixel 9': 6.4,
    'pixel 8': 6.4,
    'pixel 7': 6.4,
    'pixel 6': 6.4,
  };

  /// Default sensor width for unknown smartphones (mm).
  static const double defaultSensorWidth = 5.6;

  /// Extract EXIF data from a JPEG file at [filePath].
  static Future<ExifData?> extractFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return extractFromBytes(bytes);
    } catch (e) {
      return null;
    }
  }

  /// Extract EXIF data from raw JPEG [bytes].
  static Future<ExifData?> extractFromBytes(Uint8List bytes) async {
    try {
      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return null;

      final make = _getString(tags, 'Image Make');
      final model = _getString(tags, 'Image Model');
      final sensorWidth = getSensorWidth(make, model);

      return ExifData(
        focalLengthMM: _getRational(tags, 'EXIF FocalLength'),
        focalLength35mm: _getDouble(tags, 'EXIF FocalLengthIn35mmFilm'),
        sensorWidth: sensorWidth,
        imageWidth: _getInt(tags, 'EXIF ExifImageWidth') ??
            _getInt(tags, 'Image ImageWidth'),
        imageHeight: _getInt(tags, 'EXIF ExifImageLength') ??
            _getInt(tags, 'Image ImageLength'),
        cameraMake: make,
        cameraModel: model,
        gpsLatitude: _getGpsCoordinate(tags, 'GPS GPSLatitude', 'GPS GPSLatitudeRef'),
        gpsLongitude: _getGpsCoordinate(tags, 'GPS GPSLongitude', 'GPS GPSLongitudeRef'),
        gpsAltitude: _getRational(tags, 'GPS GPSAltitude'),
        dateTime: _getDateTime(tags, 'EXIF DateTimeOriginal') ??
            _getDateTime(tags, 'Image DateTime'),
        isoSpeed: _getInt(tags, 'EXIF ISOSpeedRatings'),
        exposureTime: _getRational(tags, 'EXIF ExposureTime'),
        fNumber: _getRational(tags, 'EXIF FNumber'),
      );
    } catch (e) {
      return null;
    }
  }

  /// Look up the sensor width (mm) for a given camera [make] and [model].
  /// Returns [defaultSensorWidth] if no match is found.
  static double? getSensorWidth(String? make, String? model) {
    if (make == null && model == null) return defaultSensorWidth;

    final combined = '${make ?? ''} ${model ?? ''}'.toLowerCase().trim();
    if (combined.isEmpty) return defaultSensorWidth;

    for (final entry in _sensorDatabase.entries) {
      if (combined.contains(entry.key)) {
        return entry.value;
      }
    }

    // If make suggests a smartphone brand, return default
    final lowerMake = (make ?? '').toLowerCase();
    if (lowerMake.contains('apple') ||
        lowerMake.contains('samsung') ||
        lowerMake.contains('google') ||
        lowerMake.contains('huawei') ||
        lowerMake.contains('xiaomi') ||
        lowerMake.contains('oneplus') ||
        lowerMake.contains('oppo')) {
      return defaultSensorWidth;
    }

    return defaultSensorWidth;
  }

  /// Compute the 3x3 camera intrinsic matrix K from EXIF data.
  ///
  /// Returns:
  /// ```
  /// K = [[fx,  0, cx],
  ///      [ 0, fy, cy],
  ///      [ 0,  0,  1]]
  /// ```
  /// where fx = fy = focalLengthPixels, cx = imageWidth/2, cy = imageHeight/2.
  static List<List<double>>? computeIntrinsicMatrix(ExifData exif) {
    final f = exif.focalLengthPixels;
    if (f == null || exif.imageWidth == null || exif.imageHeight == null) {
      return null;
    }

    final cx = exif.imageWidth! / 2.0;
    final cy = exif.imageHeight! / 2.0;

    return [
      [f, 0.0, cx],
      [0.0, f, cy],
      [0.0, 0.0, 1.0],
    ];
  }

  // ---------------------------------------------------------------------------
  // Private EXIF parsing helpers
  // ---------------------------------------------------------------------------

  static String? _getString(Map<String, IfdTag> tags, String key) {
    final tag = tags[key];
    if (tag == null) return null;
    final val = tag.printable.trim();
    return val.isEmpty ? null : val;
  }

  static int? _getInt(Map<String, IfdTag> tags, String key) {
    final tag = tags[key];
    if (tag == null) return null;
    try {
      final values = tag.values;
      if (values is IfdInts) {
        return values.firstAsInt();
      }
      return int.tryParse(tag.printable);
    } catch (_) {
      return int.tryParse(tag.printable);
    }
  }

  static double? _getDouble(Map<String, IfdTag> tags, String key) {
    final tag = tags[key];
    if (tag == null) return null;
    try {
      return double.tryParse(tag.printable);
    } catch (_) {
      return null;
    }
  }

  static double? _getRational(Map<String, IfdTag> tags, String key) {
    final tag = tags[key];
    if (tag == null) return null;
    try {
      final values = tag.values;
      if (values is IfdRatios) {
        final ratio = values.ratios.first;
        if (ratio.denominator == 0) return null;
        return ratio.numerator / ratio.denominator;
      }
      return double.tryParse(tag.printable);
    } catch (_) {
      return double.tryParse(tag.printable);
    }
  }

  static double? _getGpsCoordinate(
    Map<String, IfdTag> tags,
    String coordKey,
    String refKey,
  ) {
    final coordTag = tags[coordKey];
    final refTag = tags[refKey];
    if (coordTag == null) return null;

    try {
      final values = coordTag.values;
      if (values is IfdRatios && values.ratios.length >= 3) {
        final degrees = values.ratios[0].numerator / values.ratios[0].denominator;
        final minutes = values.ratios[1].numerator / values.ratios[1].denominator;
        final seconds = values.ratios[2].numerator / values.ratios[2].denominator;

        var decimal = degrees + minutes / 60.0 + seconds / 3600.0;

        final ref = refTag?.printable.trim().toUpperCase() ?? '';
        if (ref == 'S' || ref == 'W') {
          decimal = -decimal;
        }
        return decimal;
      }
    } catch (_) {
      // Fall through
    }
    return null;
  }

  static DateTime? _getDateTime(Map<String, IfdTag> tags, String key) {
    final tag = tags[key];
    if (tag == null) return null;
    try {
      // EXIF date format: "YYYY:MM:DD HH:MM:SS"
      final str = tag.printable.trim();
      if (str.length < 19) return null;
      final formatted = str.replaceFirst(':', '-').replaceFirst(':', '-');
      return DateTime.tryParse(formatted);
    } catch (_) {
      return null;
    }
  }
}
