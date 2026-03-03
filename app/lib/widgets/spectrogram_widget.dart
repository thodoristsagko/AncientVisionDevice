import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../utils/circular_buffer.dart';

// ---------------------------------------------------------------------------
// Color Maps
// ---------------------------------------------------------------------------

/// Perceptually-uniform (or classic) color maps for spectrogram rendering.
/// Each function takes [t] in the range [0, 1] and returns a [Color].
class ColorMaps {
  ColorMaps._(); // prevent instantiation

  // -- viridis: dark purple -> blue -> teal -> green -> yellow ---------------

  static const List<Color> _viridisStops = [
    Color(0xFF440154), // 0.00 - dark purple
    Color(0xFF3B528B), // 0.25 - blue
    Color(0xFF21918C), // 0.50 - teal
    Color(0xFF5EC962), // 0.75 - green
    Color(0xFFFDE725), // 1.00 - yellow
  ];

  /// Viridis colormap. [t] clamped to [0, 1].
  static Color viridis(double t) => _interpolateStops(_viridisStops, t);

  // -- hot: black -> red -> orange -> yellow -> white -----------------------

  static const List<Color> _hotStops = [
    Color(0xFF000000), // 0.00 - black
    Color(0xFFB20000), // 0.25 - dark red
    Color(0xFFFF4500), // 0.50 - orange-red
    Color(0xFFFFD700), // 0.75 - yellow
    Color(0xFFFFFFFF), // 1.00 - white
  ];

  /// Hot colormap. [t] clamped to [0, 1].
  static Color hot(double t) => _interpolateStops(_hotStops, t);

  // -- inferno: black -> dark magenta -> red-orange -> yellow -> pale yellow -

  static const List<Color> _infernoStops = [
    Color(0xFF000004), // 0.00
    Color(0xFF6A176E), // 0.25
    Color(0xFFCF4446), // 0.50
    Color(0xFFF7D13D), // 0.75
    Color(0xFFFCFFA4), // 1.00
  ];

  /// Inferno colormap. [t] clamped to [0, 1].
  static Color inferno(double t) => _interpolateStops(_infernoStops, t);

  // -- helpers ---------------------------------------------------------------

  static Color _interpolateStops(List<Color> stops, double t) {
    final clamped = t.clamp(0.0, 1.0);
    final segments = stops.length - 1;
    final scaled = clamped * segments;
    final index = scaled.floor().clamp(0, segments - 1);
    final localT = scaled - index;
    return Color.lerp(stops[index], stops[index + 1], localT)!;
  }
}

// ---------------------------------------------------------------------------
// Spectrogram Buffer
// ---------------------------------------------------------------------------

/// A rolling buffer that holds the most recent FFT magnitude columns for
/// the spectrogram. Each column is a [List<double>] of FFT magnitudes for
/// one time window.
class SpectrogramBuffer {
  /// Maximum number of time columns retained.
  final int maxColumns;

  // O(1) circular buffer — replaces List + removeAt(0) which was O(N)
  late final CircularBuffer<List<double>> _buf;

  SpectrogramBuffer({this.maxColumns = 120}) {
    _buf = CircularBuffer<List<double>>(maxColumns);
  }

  /// Append a new FFT magnitude column. Oldest evicted automatically. O(1).
  void addColumn(List<double> fftMagnitudes) {
    _buf.add(List<double>.from(fftMagnitudes));
  }

  /// Snapshot of current data as a [List].
  List<List<double>> get data => _buf.toList();

  /// Clear all stored columns.
  void clear() => _buf.clear();

  /// Number of columns currently stored.
  int get length => _buf.length;
}

// ---------------------------------------------------------------------------
// SpectrogramWidget
// ---------------------------------------------------------------------------

/// A real-time spectrogram (waterfall) widget for vibration time-frequency
/// visualization. Renders FFT magnitude data as a color-mapped grid.
class SpectrogramWidget extends StatelessWidget {
  /// Each inner list is FFT magnitudes for one time window. Newest data is
  /// the last element.
  final List<List<double>> spectrogramData;

  /// Sampling rate in Hz. Used to compute frequency axis labels.
  final double sampleRate;

  /// Number of FFT points used to produce each column.
  final int fftSize;

  /// Maximum frequency (Hz) to display on the Y axis.
  final double maxFrequency;

  /// Colormap name: 'viridis', 'inferno', or 'hot'.
  final String colorMap;

  /// Optional explicit height for the widget.
  final double? height;

  /// Optional explicit width for the widget.
  final double? width;

  const SpectrogramWidget({
    super.key,
    required this.spectrogramData,
    this.sampleRate = 200,
    this.fftSize = 256,
    this.maxFrequency = 100,
    this.colorMap = 'viridis',
    this.height,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodySmall?.color ?? Colors.white;

    return SizedBox(
      height: height ?? 280,
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Vibration Spectrogram',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          // Spectrogram plot area
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const double yAxisWidth = 48;
                const double xAxisHeight = 24;
                const double rightPad = 8;

                final plotWidth =
                    constraints.maxWidth - yAxisWidth - rightPad;
                final plotHeight =
                    constraints.maxHeight - xAxisHeight;

                return Stack(
                  children: [
                    // Y-axis labels
                    Positioned(
                      left: 0,
                      top: 0,
                      width: yAxisWidth,
                      height: plotHeight,
                      child: CustomPaint(
                        painter: _YAxisPainter(
                          maxFrequency: maxFrequency,
                          textColor: textColor,
                        ),
                      ),
                    ),
                    // Main plot
                    Positioned(
                      left: yAxisWidth,
                      top: 0,
                      width: plotWidth,
                      height: plotHeight,
                      child: ClipRect(
                        child: CustomPaint(
                          painter: SpectrogramPainter(
                            spectrogramData: spectrogramData,
                            sampleRate: sampleRate,
                            fftSize: fftSize,
                            maxFrequency: maxFrequency,
                            colorMap: colorMap,
                            textColor: textColor,
                          ),
                        ),
                      ),
                    ),
                    // X-axis labels
                    Positioned(
                      left: yAxisWidth,
                      top: plotHeight,
                      width: plotWidth,
                      height: xAxisHeight,
                      child: CustomPaint(
                        painter: _XAxisPainter(
                          columnCount: spectrogramData.length,
                          secondsPerColumn: fftSize / sampleRate,
                          textColor: textColor,
                        ),
                      ),
                    ),
                    // Band legend (right side)
                    Positioned(
                      right: 0,
                      top: 0,
                      width: rightPad,
                      height: plotHeight,
                      child: const SizedBox.shrink(),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SpectrogramPainter
// ---------------------------------------------------------------------------

/// Custom painter that renders the spectrogram color grid and DIN 4150-3
/// frequency band overlays.
class SpectrogramPainter extends CustomPainter {
  final List<List<double>> spectrogramData;
  final double sampleRate;
  final int fftSize;
  final double maxFrequency;
  final String colorMap;
  final Color textColor;

  SpectrogramPainter({
    required this.spectrogramData,
    required this.sampleRate,
    required this.fftSize,
    required this.maxFrequency,
    required this.colorMap,
    required this.textColor,
  });

  /// Convert a raw magnitude to a normalised [0, 1] value via dB mapping.
  /// The range is clamped from -60 dB to 0 dB.
  static double magnitudeToNormalized(double magnitude, double maxMagnitude) {
    if (maxMagnitude <= 0 || magnitude <= 0) return 0;
    final db = 20 * math.log(magnitude / maxMagnitude) / math.ln10;
    // Map -60..0 dB  -->  0..1
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  Color _mapColor(double t) {
    switch (colorMap) {
      case 'hot':
        return ColorMaps.hot(t);
      case 'inferno':
        return ColorMaps.inferno(t);
      case 'viridis':
      default:
        return ColorMaps.viridis(t);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (spectrogramData.isEmpty) return;

    final freqResolution = sampleRate / fftSize; // Hz per bin
    final maxBin = (maxFrequency / freqResolution).ceil();

    // Find global max magnitude for dB normalisation.
    double globalMax = 0;
    for (final col in spectrogramData) {
      for (int i = 0; i < col.length && i < maxBin; i++) {
        if (col[i] > globalMax) globalMax = col[i];
      }
    }
    if (globalMax == 0) globalMax = 1;

    final int numCols = spectrogramData.length;
    final int numRows = maxBin;
    final double cellWidth = size.width / numCols;
    final double cellHeight = size.height / numRows;

    final paint = Paint()..style = PaintingStyle.fill;

    // Draw colour grid (each column = one time window, each row = one freq bin).
    for (int col = 0; col < numCols; col++) {
      final fftCol = spectrogramData[col];
      for (int row = 0; row < numRows; row++) {
        final mag = row < fftCol.length ? fftCol[row] : 0.0;
        final norm = magnitudeToNormalized(mag, globalMax);
        paint.color = _mapColor(norm);

        // Y axis: 0 Hz at bottom, maxFrequency at top  -->  invert row.
        final y = size.height - (row + 1) * cellHeight;
        canvas.drawRect(
          Rect.fromLTWH(col * cellWidth, y, cellWidth + 0.5, cellHeight + 0.5),
          paint,
        );
      }
    }

    // -- DIN 4150-3 frequency band boundary overlays --------------------------
    final dashedPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    void drawDashedLine(double y) {
      const dashWidth = 6.0;
      const gapWidth = 4.0;
      double x = 0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + dashWidth, size.width), y),
          dashedPaint,
        );
        x += dashWidth + gapWidth;
      }
    }

    final y10Hz = size.height - (10 / maxFrequency) * size.height;
    final y50Hz = size.height - (50 / maxFrequency) * size.height;

    drawDashedLine(y10Hz);
    drawDashedLine(y50Hz);

    // Band labels
    final labelStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: 11,
      fontWeight: FontWeight.w600,
      shadows: const [Shadow(blurRadius: 2, color: Colors.black)],
    );

    void drawBandLabel(String text, double y) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, y + 2));
    }

    drawBandLabel('HF (50-100Hz)', y50Hz - 14);
    drawBandLabel('Machinery (10-50Hz)', y10Hz - 14);
    drawBandLabel('Seismic (1-10Hz)', y10Hz + 2);
  }

  @override
  bool shouldRepaint(covariant SpectrogramPainter oldDelegate) {
    return oldDelegate.spectrogramData != spectrogramData ||
        oldDelegate.colorMap != colorMap ||
        oldDelegate.maxFrequency != maxFrequency;
  }
}

// ---------------------------------------------------------------------------
// Y-axis painter
// ---------------------------------------------------------------------------

class _YAxisPainter extends CustomPainter {
  final double maxFrequency;
  final Color textColor;

  _YAxisPainter({required this.maxFrequency, required this.textColor});

  @override
  void paint(Canvas canvas, Size size) {
    final style = TextStyle(color: textColor, fontSize: 12);
    final freqs = [0.0, 25.0, 50.0, 75.0, 100.0]
        .where((f) => f <= maxFrequency)
        .toList();

    for (final f in freqs) {
      final y = size.height - (f / maxFrequency) * size.height;
      final tp = TextPainter(
        text: TextSpan(text: '${f.toInt()} Hz', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(size.width - tp.width - 4, y - tp.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _YAxisPainter oldDelegate) =>
      oldDelegate.maxFrequency != maxFrequency ||
      oldDelegate.textColor != textColor;
}

// ---------------------------------------------------------------------------
// X-axis painter
// ---------------------------------------------------------------------------

class _XAxisPainter extends CustomPainter {
  final int columnCount;
  final double secondsPerColumn;
  final Color textColor;

  _XAxisPainter({
    required this.columnCount,
    required this.secondsPerColumn,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (columnCount == 0) return;

    final style = TextStyle(color: textColor, fontSize: 12);
    final totalSeconds = columnCount * secondsPerColumn;

    // Draw a few time labels.
    const tickCount = 5;
    for (int i = 0; i < tickCount; i++) {
      final frac = i / (tickCount - 1);
      final x = frac * size.width;
      final seconds = -(totalSeconds * (1 - frac));
      final label = '${seconds.toStringAsFixed(0)}s';
      final tp = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, 4));
    }
  }

  @override
  bool shouldRepaint(covariant _XAxisPainter oldDelegate) =>
      oldDelegate.columnCount != columnCount ||
      oldDelegate.secondsPerColumn != secondsPerColumn;
}
