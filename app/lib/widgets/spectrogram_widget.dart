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

  // -- classic blue->green->yellow->red (for color-scale legend) ------------

  static const List<Color> _classicStops = [
    Color(0xFF0000FF), // blue
    Color(0xFF00FF00), // green
    Color(0xFFFFFF00), // yellow
    Color(0xFFFF0000), // red
  ];

  /// Classic blue-green-yellow-red colormap used for the legend bar.
  static Color classic(double t) => _interpolateStops(_classicStops, t);

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
///
/// Improvements over the base version:
///   1. Frequency band annotation overlay (Seismic / Structural / HF Noise)
///   2. Peak frequency marker (red dashed vertical line + label)
///   3. Color scale legend bar below the spectrogram
///   4. Tap-to-inspect: SnackBar shows frequency and time at tap position
///   5. FPS indicator in the top-right corner ("Live" / "Paused")
class SpectrogramWidget extends StatefulWidget {
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

  /// Dominant frequency in Hz for the current frame, or null if unknown.
  /// When provided, a red dashed vertical line is drawn at the corresponding
  /// time column position closest to the most recent frame.
  final double? dominantFreqHz;

  const SpectrogramWidget({
    super.key,
    required this.spectrogramData,
    this.sampleRate = 200,
    this.fftSize = 256,
    this.maxFrequency = 100,
    this.colorMap = 'viridis',
    this.height,
    this.width,
    this.dominantFreqHz,
  });

  @override
  State<SpectrogramWidget> createState() => _SpectrogramWidgetState();
}

class _SpectrogramWidgetState extends State<SpectrogramWidget> {
  // FPS tracking -------------------------------------------------------
  int _frameCount = 0;
  double _fps = 0.0;
  DateTime _lastFpsCheck = DateTime.now();
  int _prevDataLength = 0;

  void _updateFps() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastFpsCheck).inMilliseconds;
    if (elapsed >= 1000) {
      setState(() {
        _fps = _frameCount * 1000.0 / elapsed;
        _frameCount = 0;
        _lastFpsCheck = now;
      });
    }
  }

  @override
  void didUpdateWidget(covariant SpectrogramWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Count a new frame whenever a new column arrives.
    if (widget.spectrogramData.length != _prevDataLength) {
      _prevDataLength = widget.spectrogramData.length;
      _frameCount++;
      _updateFps();
    }
  }

  void _handleTap(BuildContext context, TapDownDetails details,
      double plotWidth, double plotHeight) {
    final dx = details.localPosition.dx.clamp(0.0, plotWidth);
    final dy = details.localPosition.dy.clamp(0.0, plotHeight);

    // Y position → frequency (0 Hz at bottom, maxFrequency at top)
    final freqFrac = 1.0 - dy / plotHeight;
    final freqHz = freqFrac * widget.maxFrequency;

    // X position → time offset (0 = oldest, 1 = newest)
    final timeFrac = dx / plotWidth;
    final totalSeconds =
        widget.spectrogramData.length * widget.fftSize / widget.sampleRate;
    final timeOffsetS = -(totalSeconds * (1.0 - timeFrac));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '~${freqHz.toStringAsFixed(1)} Hz at t${timeOffsetS.toStringAsFixed(0)}s',
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodySmall?.color ?? Colors.white;

    const double colorLegendHeight = 18.0; // legend bar + labels
    const double legendBarHeight = 8.0;

    return SizedBox(
      height: widget.height ?? 300,
      width: widget.width,
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
                    constraints.maxHeight - xAxisHeight - colorLegendHeight;

                final fpsLabel = _fps > 0.5
                    ? '${_fps.toStringAsFixed(1)} fps'
                    : 'Paused';

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
                          maxFrequency: widget.maxFrequency,
                          textColor: textColor,
                        ),
                      ),
                    ),
                    // Main plot with tap detection
                    Positioned(
                      left: yAxisWidth,
                      top: 0,
                      width: plotWidth,
                      height: plotHeight,
                      child: GestureDetector(
                        onTapDown: (details) => _handleTap(
                            context, details, plotWidth, plotHeight),
                        child: ClipRect(
                          child: CustomPaint(
                            painter: SpectrogramPainter(
                              spectrogramData: widget.spectrogramData,
                              sampleRate: widget.sampleRate,
                              fftSize: widget.fftSize,
                              maxFrequency: widget.maxFrequency,
                              colorMap: widget.colorMap,
                              textColor: textColor,
                              dominantFreqHz: widget.dominantFreqHz,
                            ),
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
                          columnCount: widget.spectrogramData.length,
                          secondsPerColumn: widget.fftSize / widget.sampleRate,
                          textColor: textColor,
                        ),
                      ),
                    ),
                    // Color scale legend bar (below X axis)
                    Positioned(
                      left: yAxisWidth,
                      top: plotHeight + xAxisHeight,
                      width: plotWidth,
                      height: colorLegendHeight,
                      child: _ColorScaleLegend(
                        barHeight: legendBarHeight,
                        colorMap: widget.colorMap,
                        textColor: textColor,
                      ),
                    ),
                    // FPS indicator (top-right of plot area)
                    Positioned(
                      left: yAxisWidth,
                      top: 4,
                      width: plotWidth,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            fpsLabel,
                            style: TextStyle(
                              color: _fps > 0.5
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Band legend placeholder (right side)
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
// Color Scale Legend
// ---------------------------------------------------------------------------

/// A horizontal color-gradient bar with "Low" and "High" labels.
/// The gradient uses the classic blue→green→yellow→red ramp regardless of
/// the active colormap so it is always legible.
class _ColorScaleLegend extends StatelessWidget {
  final double barHeight;
  final String colorMap;
  final Color textColor;

  const _ColorScaleLegend({
    required this.barHeight,
    required this.colorMap,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Low',
          style: TextStyle(
            color: textColor.withValues(alpha: 0.7),
            fontSize: 9,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SizedBox(
            height: barHeight,
            child: CustomPaint(
              painter: _ColorBarPainter(colorMap: colorMap),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          'High',
          style: TextStyle(
            color: textColor.withValues(alpha: 0.7),
            fontSize: 9,
          ),
        ),
      ],
    );
  }
}

class _ColorBarPainter extends CustomPainter {
  final String colorMap;

  const _ColorBarPainter({required this.colorMap});

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
    // Draw the gradient in discrete steps for performance.
    const steps = 64;
    final stepWidth = size.width / steps;
    final paint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < steps; i++) {
      final t = i / (steps - 1);
      paint.color = _mapColor(t);
      canvas.drawRect(
        Rect.fromLTWH(i * stepWidth, 0, stepWidth + 0.5, size.height),
        paint,
      );
    }
    // Thin border around the bar
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorBarPainter oldDelegate) =>
      oldDelegate.colorMap != colorMap;
}

// ---------------------------------------------------------------------------
// SpectrogramPainter
// ---------------------------------------------------------------------------

/// Custom painter that renders the spectrogram color grid and frequency-band
/// overlays (Seismic / Structural / HF Noise) plus an optional peak-frequency
/// marker.
class SpectrogramPainter extends CustomPainter {
  final List<List<double>> spectrogramData;
  final double sampleRate;
  final int fftSize;
  final double maxFrequency;
  final String colorMap;
  final Color textColor;

  /// When set, draws a red dashed vertical line at the right edge labeled
  /// "Peak: X.X Hz" to mark the dominant frequency of the latest frame.
  final double? dominantFreqHz;

  SpectrogramPainter({
    required this.spectrogramData,
    required this.sampleRate,
    required this.fftSize,
    required this.maxFrequency,
    required this.colorMap,
    required this.textColor,
    this.dominantFreqHz,
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

    // -------------------------------------------------------------------------
    // 1. Frequency band annotation overlay
    // -------------------------------------------------------------------------
    // Thin solid lines (white, opacity 0.3) at band boundaries.
    final bandLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Only draw band boundaries that lie within the displayed range.
    for (final boundHz in [10.0, 50.0]) {
      if (boundHz >= maxFrequency) continue;
      final y = size.height - (boundHz / maxFrequency) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), bandLinePaint);
    }

    // Small text labels at the left edge (font 9, white opacity 0.6).
    final bandLabelStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.6),
      fontSize: 9,
      fontWeight: FontWeight.w500,
    );

    void drawBandLabel(String text, double yTop) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: bandLabelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      // Keep label inside the canvas vertically.
      final clampedY = yTop.clamp(0.0, size.height - tp.height);
      tp.paint(canvas, Offset(3, clampedY));
    }

    // Label positions: centre of each band.
    final y10 = size.height - (10 / maxFrequency) * size.height;
    final y50 = size.height - (50 / maxFrequency) * size.height;

    // Seismic: 0–10 Hz
    drawBandLabel('Seismic', y10 + 3);
    // Structural: 10–50 Hz (only if band fits)
    if (maxFrequency >= 50) {
      drawBandLabel('Structural', y50 + 3);
    }
    // HF Noise: 50–100 Hz
    if (maxFrequency > 50) {
      drawBandLabel('HF Noise', 3);
    }

    // -------------------------------------------------------------------------
    // 2. Peak frequency marker — red dashed vertical line
    // -------------------------------------------------------------------------
    final domFreq = dominantFreqHz;
    if (domFreq != null && domFreq > 0 && domFreq <= maxFrequency) {
      // Draw the line at the rightmost (most-recent) column position.
      final peakX = size.width - cellWidth / 2;

      final dashedRed = Paint()
        ..color = Colors.red.withValues(alpha: 0.85)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      const dashH = 5.0;
      const gapH = 4.0;
      double yPos = 0;
      while (yPos < size.height) {
        canvas.drawLine(
          Offset(peakX, yPos),
          Offset(peakX, math.min(yPos + dashH, size.height)),
          dashedRed,
        );
        yPos += dashH + gapH;
      }

      // Peak label at the top
      final peakLabel =
          'Peak: ${domFreq.toStringAsFixed(1)} Hz';
      final peakStyle = TextStyle(
        color: Colors.red.withValues(alpha: 0.95),
        fontSize: 10,
        fontWeight: FontWeight.w700,
        shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
      );
      final tp = TextPainter(
        text: TextSpan(text: peakLabel, style: peakStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      // Prefer right of line; fall back to left if near right edge.
      double labelX = peakX + 4;
      if (labelX + tp.width > size.width) {
        labelX = peakX - tp.width - 4;
      }
      tp.paint(canvas, Offset(labelX, 4));
    }
  }

  @override
  bool shouldRepaint(covariant SpectrogramPainter oldDelegate) {
    return oldDelegate.spectrogramData != spectrogramData ||
        oldDelegate.colorMap != colorMap ||
        oldDelegate.maxFrequency != maxFrequency ||
        oldDelegate.dominantFreqHz != dominantFreqHz;
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
