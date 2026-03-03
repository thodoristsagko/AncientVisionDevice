import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import '../models/point_cloud.dart';
import 'dart:math' as math;

/// Render mode for point cloud visualization.
enum PointCloudRenderMode {
  /// Standard color rendering from photo textures.
  color,
  /// Confidence heatmap (green=high, red=low).
  confidence,
  /// Reprojection error visualization.
  error,
}

/// Helper class to store projected point data for depth sorting
class _ProjectedPoint {
  final double x;
  final double y;
  final double z;
  final double scale;
  final ({double r, double g, double b, double a}) color;
  final int originalIndex;

  _ProjectedPoint({
    required this.x,
    required this.y,
    required this.z,
    required this.scale,
    required this.color,
    required this.originalIndex,
  });
}

/// Custom painter for rendering point clouds
class PointCloudPainter extends CustomPainter {
  final PointCloud pointCloud;
  final Matrix4 transform;
  final double pointSize;
  final bool showColors;
  final List<int> measurePointIndices;
  final double? measureDistance;
  final PointCloudRenderMode renderMode;

  PointCloudPainter({
    required this.pointCloud,
    required this.transform,
    this.pointSize = 3.0,
    this.showColors = true,
    this.measurePointIndices = const [],
    this.measureDistance,
    this.renderMode = PointCloudRenderMode.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (pointCloud.points.isEmpty) {
      // Draw "No points" message
      final textPainter = TextPainter(
        text: const TextSpan(
          text: 'No points in cloud',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(size.width / 2 - textPainter.width / 2, size.height / 2),
      );
      return;
    }

    // Get center of point cloud for normalization
    final center = pointCloud.getCenter();

    // Project and collect all points with their depth for sorting
    final List<_ProjectedPoint> projectedPoints = [];
    const focalLength = 500.0;

    for (int i = 0; i < pointCloud.points.length; i++) {
      final point = pointCloud.points[i];
      // Center the point
      final centeredPoint = vector.Vector3(
        point.position.x - center.x,
        point.position.y - center.y,
        point.position.z - center.z,
      );

      // Apply transformation
      final transformedPoint = transform.transform3(centeredPoint);

      // Simple perspective projection
      final scale = focalLength / (focalLength + transformedPoint.z);

      // Skip points behind camera
      if (scale <= 0) continue;

      // Project to 2D screen coordinates
      final x = size.width / 2 + transformedPoint.x * scale;
      final y = size.height / 2 - transformedPoint.y * scale; // Flip Y

      // Check if point is on screen (with small margin)
      if (x < -pointSize * 2 || x > size.width + pointSize * 2 ||
          y < -pointSize * 2 || y > size.height + pointSize * 2) {
        continue;
      }

      final ({double r, double g, double b, double a}) pointColor;
      switch (renderMode) {
        case PointCloudRenderMode.color:
          pointColor = (r: point.color.r, g: point.color.g, b: point.color.b, a: point.color.a);
        case PointCloudRenderMode.confidence:
          pointColor = _mapConfidenceColor(point.confidence);
        case PointCloudRenderMode.error:
          pointColor = _mapErrorColor(point.confidence);
      }

      projectedPoints.add(_ProjectedPoint(
        x: x,
        y: y,
        z: transformedPoint.z,
        scale: scale,
        color: pointColor,
        originalIndex: i,
      ));
    }

    // Sort by depth (back to front - painter's algorithm)
    projectedPoints.sort((a, b) => a.z.compareTo(b.z));

    // Draw all points with proper depth ordering using batch API for better performance
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..strokeWidth = 1;

    // Collect all point positions and colors for batch rendering
    final glowPoints = <Offset>[];
    final glowColors = <Color>[];
    final mainPoints = <Offset>[];
    final mainColors = <Color>[];

    for (final proj in projectedPoints) {
      // Calculate depth-based brightness (simple lighting simulation)
      final depthFactor = 1.0 - (proj.z / (focalLength * 2)).clamp(0.0, 0.5);

      // Set color with depth-based shading
      final Color pointColor;
      if (showColors) {
        pointColor = Color.fromRGBO(
          ((proj.color.r * 255) * depthFactor).toInt().clamp(0, 255),
          ((proj.color.g * 255) * depthFactor).toInt().clamp(0, 255),
          ((proj.color.b * 255) * depthFactor).toInt().clamp(0, 255),
          1.0,
        );
      } else {
        // White with depth shading
        final intensity = (255 * depthFactor).toInt().clamp(0, 255);
        pointColor = Color.fromRGBO(intensity, intensity, intensity, 1.0);
      }

      final position = Offset(proj.x, proj.y);

      // Glow effect (outer circle)
      glowPoints.add(position);
      glowColors.add(Color.fromRGBO(
        (pointColor.r * 255).toInt(),
        (pointColor.g * 255).toInt(),
        (pointColor.b * 255).toInt(),
        0.3,
      ));

      // Main point (inner circle)
      mainPoints.add(position);
      mainColors.add(pointColor);
    }

    // Draw glow layer using batch API
    if (glowPoints.isNotEmpty) {
      // Note: Canvas.drawPoints doesn't support per-point colors in Flutter,
      // so we still need individual drawCircle calls for colored points
      // This optimization would work best for monochrome point clouds
      const glowSize = 1.2;
      for (int i = 0; i < glowPoints.length; i++) {
        paint.color = glowColors[i];
        canvas.drawCircle(glowPoints[i], pointSize * glowSize, paint);
      }
    }

    // Draw main points layer
    if (mainPoints.isNotEmpty) {
      for (int i = 0; i < mainPoints.length; i++) {
        paint.color = mainColors[i];
        canvas.drawCircle(mainPoints[i], pointSize, paint);
      }
    }

    // Draw measurement markers and line
    if (measurePointIndices.isNotEmpty) {
      final markerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = const Color(0xFF00E5FF);
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.4);

      final measureProjected = <_ProjectedPoint>[];
      for (final idx in measurePointIndices) {
        for (final p in projectedPoints) {
          if (p.originalIndex == idx) {
            measureProjected.add(p);
            break;
          }
        }
      }

      for (final mp in measureProjected) {
        canvas.drawCircle(Offset(mp.x, mp.y), 10, fillPaint);
        canvas.drawCircle(Offset(mp.x, mp.y), 10, markerPaint);
        // Crosshair
        canvas.drawLine(Offset(mp.x - 14, mp.y), Offset(mp.x + 14, mp.y), markerPaint);
        canvas.drawLine(Offset(mp.x, mp.y - 14), Offset(mp.x, mp.y + 14), markerPaint);
      }

      if (measureProjected.length == 2) {
        final linePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = const Color(0xFF00E5FF);
        canvas.drawLine(
          Offset(measureProjected[0].x, measureProjected[0].y),
          Offset(measureProjected[1].x, measureProjected[1].y),
          linePaint,
        );

        if (measureDistance != null) {
          final midX = (measureProjected[0].x + measureProjected[1].x) / 2;
          final midY = (measureProjected[0].y + measureProjected[1].y) / 2;
          final distText = '${measureDistance!.toStringAsFixed(2)} units';
          final bgPaint = Paint()
            ..style = PaintingStyle.fill
            ..color = Colors.black.withValues(alpha: 0.7);
          final textPainter2 = TextPainter(
            text: TextSpan(
              text: distText,
              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 14, fontWeight: FontWeight.bold),
            ),
            textDirection: TextDirection.ltr,
          );
          textPainter2.layout();
          final textRect = Rect.fromCenter(
            center: Offset(midX, midY - 16),
            width: textPainter2.width + 12,
            height: textPainter2.height + 8,
          );
          canvas.drawRRect(RRect.fromRectAndRadius(textRect, const Radius.circular(4)), bgPaint);
          textPainter2.paint(canvas, Offset(midX - textPainter2.width / 2, midY - 16 - textPainter2.height / 2));
        }
      }
    }

    final visiblePoints = projectedPoints.length;

    // Draw info overlay
    if (visiblePoints > 0) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: '$visiblePoints / ${pointCloud.points.length} points',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            shadows: [Shadow(color: Colors.black, blurRadius: 2)],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, const Offset(10, 10));
    }
  }

  ({double r, double g, double b, double a}) _mapConfidenceColor(double confidence) {
    // Green (high confidence) to Red (low confidence)
    final c = confidence.clamp(0.0, 1.0);
    return (
      r: 1.0 - c,
      g: c,
      b: 0.0,
      a: 1.0,
    );
  }

  ({double r, double g, double b, double a}) _mapErrorColor(double confidence) {
    // Blue (low error/high confidence) to Red (high error/low confidence)
    final error = 1.0 - confidence.clamp(0.0, 1.0);
    return (
      r: error,
      g: 0.0,
      b: 1.0 - error,
      a: 1.0,
    );
  }

  @override
  bool shouldRepaint(PointCloudPainter oldDelegate) {
    return oldDelegate.transform != transform ||
        oldDelegate.pointSize != pointSize ||
        oldDelegate.showColors != showColors ||
        oldDelegate.measurePointIndices != measurePointIndices ||
        oldDelegate.measureDistance != measureDistance ||
        oldDelegate.renderMode != renderMode;
  }
}

/// Interactive point cloud viewer widget
class PointCloudViewer extends StatefulWidget {
  final PointCloud pointCloud;
  final double initialPointSize;
  final bool initialShowColors;
  final PointCloudRenderMode renderMode;

  const PointCloudViewer({
    super.key,
    required this.pointCloud,
    this.initialPointSize = 3.0,
    this.initialShowColors = true,
    this.renderMode = PointCloudRenderMode.color,
  });

  @override
  State<PointCloudViewer> createState() => PointCloudViewerState();
}

class PointCloudViewerState extends State<PointCloudViewer>
    with SingleTickerProviderStateMixin {
  late Matrix4 _transform;
  double _rotationX = 0.0;
  double _rotationY = 0.0;
  double _zoom = 1.0;
  Offset _lastFocalPoint = Offset.zero;
  late AnimationController _autoRotateController;
  bool _autoRotate = false;
  bool _measureMode = false;
  List<int> _measurePointIndices = [];
  double? _measureDistance;

  @override
  void initState() {
    super.initState();
    _resetTransform();

    // Auto-rotate animation
    _autoRotateController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..addListener(() {
      if (_autoRotate) {
        setState(() {
          _rotationY += 0.01;
          _updateTransform();
        });
      }
    });
  }

  void _resetTransform() {
    _transform = Matrix4.identity();
    _rotationX = -0.3; // Slight downward angle
    _rotationY = 0.0;
    _zoom = 1.0;
    _updateTransform();
  }

  void _updateTransform() {
    _transform = Matrix4.identity()
      ..scale(_zoom)
      ..rotateX(_rotationX)
      ..rotateY(_rotationY);
  }

  @override
  void dispose() {
    _autoRotateController.dispose();
    super.dispose();
  }

  void _handleTapForMeasure(Offset tapPosition, Size size) {
    if (!_measureMode) return;

    final center = widget.pointCloud.getCenter();
    const focalLength = 500.0;
    double bestDist = 30.0; // Max tap distance in pixels
    int bestIndex = -1;

    for (int i = 0; i < widget.pointCloud.points.length; i++) {
      final point = widget.pointCloud.points[i];
      final centeredPoint = vector.Vector3(
        point.position.x - center.x,
        point.position.y - center.y,
        point.position.z - center.z,
      );
      final tp = _transform.transform3(centeredPoint);
      final scale = focalLength / (focalLength + tp.z);
      if (scale <= 0) continue;

      final x = size.width / 2 + tp.x * scale;
      final y = size.height / 2 - tp.y * scale;
      final dist = math.sqrt(math.pow(x - tapPosition.dx, 2) + math.pow(y - tapPosition.dy, 2));
      if (dist < bestDist) {
        bestDist = dist;
        bestIndex = i;
      }
    }

    if (bestIndex < 0) return;

    setState(() {
      if (_measurePointIndices.length >= 2) {
        _measurePointIndices = [bestIndex];
        _measureDistance = null;
      } else {
        _measurePointIndices.add(bestIndex);
      }

      if (_measurePointIndices.length == 2) {
        final p1 = widget.pointCloud.points[_measurePointIndices[0]].position;
        final p2 = widget.pointCloud.points[_measurePointIndices[1]].position;
        _measureDistance = (p1 - p2).length;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onScaleStart: (details) {
            _lastFocalPoint = details.focalPoint;
            if (_autoRotate) {
              setState(() => _autoRotate = false);
              _autoRotateController.stop();
            }
          },
          onScaleUpdate: (details) {
            setState(() {
              if (details.scale != 1.0) {
                _zoom *= details.scale;
                _zoom = _zoom.clamp(0.5, 5.0);
              } else {
                final delta = details.focalPoint - _lastFocalPoint;
                _rotationY += delta.dx * 0.01;
                _rotationX += delta.dy * 0.01;
                _rotationX = _rotationX.clamp(-math.pi / 2, math.pi / 2);
              }
              _lastFocalPoint = details.focalPoint;
              _updateTransform();
            });
          },
          onTapUp: _measureMode
              ? (details) => _handleTapForMeasure(details.localPosition, viewSize)
              : null,
          child: CustomPaint(
            painter: PointCloudPainter(
              pointCloud: widget.pointCloud,
              transform: _transform,
              pointSize: widget.initialPointSize,
              showColors: widget.initialShowColors,
              measurePointIndices: _measurePointIndices,
              measureDistance: _measureDistance,
              renderMode: widget.renderMode,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }

  bool get isMeasuring => _measureMode;

  void toggleMeasureMode() {
    setState(() {
      _measureMode = !_measureMode;
      if (!_measureMode) {
        _measurePointIndices = [];
        _measureDistance = null;
      }
    });
  }

  void toggleAutoRotate() {
    setState(() {
      _autoRotate = !_autoRotate;
      if (_autoRotate) {
        _autoRotateController.repeat();
      } else {
        _autoRotateController.stop();
      }
    });
  }

  void resetView() {
    setState(() {
      _resetTransform();
    });
  }
}
