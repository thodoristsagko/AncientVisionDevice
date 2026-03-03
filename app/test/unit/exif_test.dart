import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/exif_service.dart';

void main() {
  group('ExifService sensor width database', () {
    test('iPhone 14 Pro returns 5.7mm', () {
      final width = ExifService.getSensorWidth('Apple', 'iPhone 14 Pro Max');
      expect(width, 5.7);
    });

    test('iPhone 12 returns 5.7mm', () {
      final width = ExifService.getSensorWidth('Apple', 'iPhone 12');
      expect(width, 5.7);
    });

    test('Samsung Galaxy S23 returns 6.4mm', () {
      final width = ExifService.getSensorWidth('samsung', 'Galaxy S23 Ultra');
      expect(width, 6.4);
    });

    test('Google Pixel 7 returns 6.4mm', () {
      final width = ExifService.getSensorWidth('Google', 'Pixel 7 Pro');
      expect(width, 6.4);
    });

    test('unknown camera model returns default sensor width', () {
      final width = ExifService.getSensorWidth('SomeUnknownBrand', 'Model X');
      expect(width, ExifService.defaultSensorWidth);
    });

    test('null make and model returns default sensor width', () {
      final width = ExifService.getSensorWidth(null, null);
      expect(width, ExifService.defaultSensorWidth);
    });
  });

  group('ExifData focal length in pixels', () {
    test('computes correctly for known values', () {
      // iPhone-like: 4.25mm focal, 5.7mm sensor, 4032px wide
      // Expected: (4.25 / 5.7) * 4032 = 3006.315...
      const exif = ExifData(
        focalLengthMM: 4.25,
        sensorWidth: 5.7,
        imageWidth: 4032,
        imageHeight: 3024,
      );

      final flPixels = exif.focalLengthPixels;
      expect(flPixels, isNotNull);
      expect(flPixels!, closeTo(3006.316, 0.1));
    });

    test('returns null when focalLengthMM is null', () {
      const exif = ExifData(
        focalLengthMM: null,
        sensorWidth: 5.7,
        imageWidth: 4032,
        imageHeight: 3024,
      );
      expect(exif.focalLengthPixels, isNull);
    });

    test('returns null when sensorWidth is null', () {
      const exif = ExifData(
        focalLengthMM: 4.25,
        sensorWidth: null,
        imageWidth: 4032,
        imageHeight: 3024,
      );
      expect(exif.focalLengthPixels, isNull);
    });

    test('returns null when imageWidth is null', () {
      const exif = ExifData(
        focalLengthMM: 4.25,
        sensorWidth: 5.7,
        imageWidth: null,
        imageHeight: 3024,
      );
      expect(exif.focalLengthPixels, isNull);
    });
  });

  group('ExifService intrinsic matrix', () {
    test('has correct structure and values', () {
      const exif = ExifData(
        focalLengthMM: 4.25,
        sensorWidth: 5.7,
        imageWidth: 4032,
        imageHeight: 3024,
      );

      final K = ExifService.computeIntrinsicMatrix(exif);
      expect(K, isNotNull);
      expect(K!.length, 3);
      expect(K[0].length, 3);
      expect(K[1].length, 3);
      expect(K[2].length, 3);

      final f = exif.focalLengthPixels!;
      const cx = 4032 / 2.0;
      const cy = 3024 / 2.0;

      // Row 0: [fx, 0, cx]
      expect(K[0][0], closeTo(f, 0.01));
      expect(K[0][1], 0.0);
      expect(K[0][2], closeTo(cx, 0.01));

      // Row 1: [0, fy, cy]
      expect(K[1][0], 0.0);
      expect(K[1][1], closeTo(f, 0.01));
      expect(K[1][2], closeTo(cy, 0.01));

      // Row 2: [0, 0, 1]
      expect(K[2][0], 0.0);
      expect(K[2][1], 0.0);
      expect(K[2][2], 1.0);
    });

    test('returns null when focal length cannot be computed', () {
      const exif = ExifData(
        focalLengthMM: null,
        sensorWidth: 5.7,
        imageWidth: 4032,
        imageHeight: 3024,
      );
      expect(ExifService.computeIntrinsicMatrix(exif), isNull);
    });
  });

  group('ExifData ground sample distance', () {
    test('matches manual calculation', () {
      // Sensor: 5.7mm wide, 4032px, focal 4.25mm, distance 2m
      // pixelSize = 5.7 / 4032 = 0.001414 mm/px
      // GSD = (0.001414 * 2000) / 4.25 = 0.6655 mm/px
      const exif = ExifData(
        focalLengthMM: 4.25,
        sensorWidth: 5.7,
        imageWidth: 4032,
        imageHeight: 3024,
      );

      final gsd = exif.groundSampleDistance(2.0);
      expect(gsd, isNotNull);

      const pixelSize = 5.7 / 4032;
      const expectedGSD = (pixelSize * 2.0 * 1000) / 4.25;
      expect(gsd!, closeTo(expectedGSD, 0.001));
    });

    test('returns null when parameters are missing', () {
      const exif = ExifData(
        focalLengthMM: null,
        sensorWidth: 5.7,
        imageWidth: 4032,
        imageHeight: 3024,
      );
      expect(exif.groundSampleDistance(2.0), isNull);
    });
  });
}
