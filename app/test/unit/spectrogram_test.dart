import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/widgets/spectrogram_widget.dart';

void main() {
  // -------------------------------------------------------------------------
  // SpectrogramBuffer tests
  // -------------------------------------------------------------------------

  group('SpectrogramBuffer', () {
    test('respects maxColumns limit', () {
      final buffer = SpectrogramBuffer(maxColumns: 5);
      for (int i = 0; i < 10; i++) {
        buffer.addColumn([i.toDouble()]);
      }
      expect(buffer.length, 5);
      // Oldest columns should have been evicted; newest values are 5..9
      expect(buffer.data.first[0], 5.0);
      expect(buffer.data.last[0], 9.0);
    });

    test('addColumn stores data correctly', () {
      final buffer = SpectrogramBuffer(maxColumns: 120);
      buffer.addColumn([1.0, 2.0, 3.0]);
      buffer.addColumn([4.0, 5.0, 6.0]);

      expect(buffer.length, 2);
      expect(buffer.data[0], [1.0, 2.0, 3.0]);
      expect(buffer.data[1], [4.0, 5.0, 6.0]);
    });

    test('addColumn makes a defensive copy', () {
      final buffer = SpectrogramBuffer(maxColumns: 120);
      final original = [1.0, 2.0, 3.0];
      buffer.addColumn(original);
      original[0] = 999.0; // mutate the source list
      expect(buffer.data[0][0], 1.0); // buffer should be unaffected
    });

    test('clear removes all data', () {
      final buffer = SpectrogramBuffer(maxColumns: 120);
      buffer.addColumn([1.0]);
      buffer.addColumn([2.0]);
      buffer.clear();
      expect(buffer.length, 0);
      expect(buffer.data, isEmpty);
    });

    test('data returns a snapshot copy (modifying it does not affect buffer)', () {
      final buffer = SpectrogramBuffer(maxColumns: 120);
      buffer.addColumn([1.0]);
      final data = buffer.data;
      data.add([2.0]); // mutating the snapshot should not affect the buffer
      expect(buffer.data.length, 1);
    });

    test('default maxColumns is 120', () {
      final buffer = SpectrogramBuffer();
      expect(buffer.maxColumns, 120);
    });
  });

  // -------------------------------------------------------------------------
  // ColorMaps tests
  // -------------------------------------------------------------------------

  group('ColorMaps', () {
    test('viridis(0) is dark (low luminance)', () {
      final c = ColorMaps.viridis(0);
      // Dark purple – all channels should be relatively low (normalized 0-1)
      expect(c.r, lessThan(0.4));
      expect(c.g, lessThan(0.2));
    });

    test('viridis(1) is bright (high luminance)', () {
      final c = ColorMaps.viridis(1);
      // Bright yellow – red and green channels high (normalized 0-1)
      expect(c.r, greaterThan(0.78));
      expect(c.g, greaterThan(0.78));
    });

    test('hot(0) is black', () {
      final c = ColorMaps.hot(0);
      expect(c.r, closeTo(0, 0.01));
      expect(c.g, closeTo(0, 0.01));
      expect(c.b, closeTo(0, 0.01));
    });

    test('hot(1) is white', () {
      final c = ColorMaps.hot(1);
      expect(c.r, closeTo(1.0, 0.01));
      expect(c.g, closeTo(1.0, 0.01));
      expect(c.b, closeTo(1.0, 0.01));
    });

    test('inferno(0) is near-black', () {
      final c = ColorMaps.inferno(0);
      expect(c.r, lessThan(0.02));
      expect(c.g, lessThan(0.02));
      expect(c.b, lessThan(0.04));
    });

    test('inferno(1) is bright', () {
      final c = ColorMaps.inferno(1);
      expect(c.r, greaterThan(0.78));
      expect(c.g, greaterThan(0.78));
    });

    test('all colormaps produce valid colours for full range', () {
      for (final mapFn in [ColorMaps.viridis, ColorMaps.hot, ColorMaps.inferno]) {
        for (double t = 0; t <= 1.0; t += 0.05) {
          final c = mapFn(t);
          expect(c.r, inInclusiveRange(0.0, 1.0));
          expect(c.g, inInclusiveRange(0.0, 1.0));
          expect(c.b, inInclusiveRange(0.0, 1.0));
          expect(c.a, closeTo(1.0, 0.01));
        }
      }
    });

    test('colormaps clamp values outside [0, 1]', () {
      // Should not throw; should clamp.
      final cLow = ColorMaps.viridis(-0.5);
      final cHigh = ColorMaps.viridis(1.5);
      expect(cLow, ColorMaps.viridis(0));
      expect(cHigh, ColorMaps.viridis(1));
    });
  });

  // -------------------------------------------------------------------------
  // dB conversion tests
  // -------------------------------------------------------------------------

  group('dB conversion (magnitudeToNormalized)', () {
    test('magnitude equal to max -> 0 dB -> normalized 1.0', () {
      final norm = SpectrogramPainter.magnitudeToNormalized(1.0, 1.0);
      expect(norm, closeTo(1.0, 1e-6));
    });

    test('magnitude 0.001 of max -> -60 dB -> normalized 0.0', () {
      final norm = SpectrogramPainter.magnitudeToNormalized(0.001, 1.0);
      expect(norm, closeTo(0.0, 0.02)); // 20*log10(0.001) = -60
    });

    test('magnitude 0 returns 0', () {
      final norm = SpectrogramPainter.magnitudeToNormalized(0.0, 1.0);
      expect(norm, 0.0);
    });

    test('maxMagnitude 0 returns 0', () {
      final norm = SpectrogramPainter.magnitudeToNormalized(1.0, 0.0);
      expect(norm, 0.0);
    });

    test('half magnitude -> ~-6 dB -> normalized ~0.9', () {
      final norm = SpectrogramPainter.magnitudeToNormalized(0.5, 1.0);
      // 20*log10(0.5) ≈ -6.02 dB, normalised = (−6.02+60)/60 ≈ 0.8997
      expect(norm, closeTo(0.9, 0.01));
    });

    test('result is clamped to [0, 1]', () {
      // A very tiny magnitude well below -60 dB
      final norm = SpectrogramPainter.magnitudeToNormalized(1e-10, 1.0);
      expect(norm, 0.0);

      // Magnitude greater than max (shouldn't happen, but should clamp to 1)
      final norm2 = SpectrogramPainter.magnitudeToNormalized(2.0, 1.0);
      expect(norm2, 1.0);
    });
  });
}
