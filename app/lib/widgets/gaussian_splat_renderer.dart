import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../services/gaussian_splatting_service.dart';

/// Projected 2D Gaussian for rendering, sorted by depth.
class _ProjectedGaussian {
  final double screenX;
  final double screenY;
  final double depth;

  /// 2D covariance ellipse parameters: semi-axes and rotation angle.
  final double semiAxisA;
  final double semiAxisB;
  final double ellipseAngle;

  final Color color;
  final double opacity;

  _ProjectedGaussian({
    required this.screenX,
    required this.screenY,
    required this.depth,
    required this.semiAxisA,
    required this.semiAxisB,
    required this.ellipseAngle,
    required this.color,
    required this.opacity,
  });
}

/// CustomPainter that renders a collection of 3D Gaussians via
/// projection to 2D ellipses with alpha compositing front-to-back.
class _GaussianSplatPainter extends CustomPainter {
  final GaussianScene scene;
  final Matrix4 viewMatrix;
  final double focalLength;
  final int maxGaussiansToRender;
  final bool showEllipses;
  final vector.Vector3 cameraPosition;

  _GaussianSplatPainter({
    required this.scene,
    required this.viewMatrix,
    this.focalLength = 500.0,
    this.maxGaussiansToRender = 0,
    this.showEllipses = true,
    required this.cameraPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (scene.gaussians.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'No Gaussians in scene',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(size.width / 2 - tp.width / 2, size.height / 2));
      return;
    }

    final center = scene.getCenter();
    final projected = <_ProjectedGaussian>[];

    final limit = maxGaussiansToRender > 0
        ? math.min(maxGaussiansToRender, scene.gaussians.length)
        : scene.gaussians.length;

    for (int i = 0; i < limit; i++) {
      final g = scene.gaussians[i];

      // Center the position
      final centeredPos = vector.Vector3(
        g.position.x - center.x,
        g.position.y - center.y,
        g.position.z - center.z,
      );

      // Transform to view space
      final viewPos = viewMatrix.transform3(centeredPos);

      // Skip Gaussians behind the camera
      if (viewPos.z <= 0.1) continue;

      // Perspective projection
      final invZ = 1.0 / viewPos.z;
      final screenX = size.width / 2 + viewPos.x * focalLength * invZ;
      final screenY = size.height / 2 - viewPos.y * focalLength * invZ;

      // Project 3D covariance to 2D
      final cov2d = g.projectCovariance2D(
        viewMatrix: viewMatrix,
        focalX: focalLength,
        focalY: focalLength,
        viewSpacePosition: viewPos,
      );

      // Decompose 2x2 covariance into ellipse (eigendecomposition)
      final a = cov2d.a;
      final b = cov2d.b;
      final c = cov2d.c;

      final trace = a + c;
      final det = a * c - b * b;
      // Prevent negative discriminant
      final disc = math.max(0.0, trace * trace / 4.0 - det);
      final sqrtDisc = math.sqrt(disc);

      final lambda1 = math.max(0.1, trace / 2.0 + sqrtDisc);
      final lambda2 = math.max(0.1, trace / 2.0 - sqrtDisc);

      // Semi-axes (in pixels) -- use 2-sigma for visible extent
      final semiA = 2.0 * math.sqrt(lambda1);
      final semiB = 2.0 * math.sqrt(lambda2);

      // Ellipse rotation angle
      final angle = b.abs() < 1e-8 ? 0.0 : math.atan2(2.0 * b, a - c) / 2.0;

      // Frustum culling: skip if ellipse center is far off-screen
      final maxRadius = math.max(semiA, semiB);
      if (screenX + maxRadius < 0 ||
          screenX - maxRadius > size.width ||
          screenY + maxRadius < 0 ||
          screenY - maxRadius > size.height) {
        continue;
      }

      // Skip very tiny Gaussians (< 0.5 px)
      if (maxRadius < 0.5) continue;

      // Evaluate view-dependent color via SH
      final viewDir = (vector.Vector3(
                cameraPosition.x - g.position.x,
                cameraPosition.y - g.position.y,
                cameraPosition.z - g.position.z,
              ))
          .normalized();

      final finalColor = g.evaluateSH(viewDir);

      projected.add(_ProjectedGaussian(
        screenX: screenX,
        screenY: screenY,
        depth: viewPos.z,
        semiAxisA: semiA,
        semiAxisB: semiB,
        ellipseAngle: angle,
        color: Color.fromRGBO(
          (finalColor.r * 255).round().clamp(0, 255),
          (finalColor.g * 255).round().clamp(0, 255),
          (finalColor.b * 255).round().clamp(0, 255),
          1.0,
        ),
        opacity: g.opacity,
      ));
    }

    // Sort front-to-back for alpha compositing
    projected.sort((a, b) => a.depth.compareTo(b.depth));

    // Render each Gaussian as a blurred ellipse
    for (final pg in projected) {
      canvas.save();
      canvas.translate(pg.screenX, pg.screenY);
      canvas.rotate(pg.ellipseAngle);

      if (showEllipses && pg.semiAxisA > 2.0) {
        // Render as a radial-gradient ellipse for smooth Gaussian falloff
        final rect = Rect.fromCenter(
          center: Offset.zero,
          width: pg.semiAxisA * 2,
          height: pg.semiAxisB * 2,
        );

        final paint = Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            1.0, // normalized, we scale via the transform
            [
              pg.color.withValues(alpha: pg.opacity),
              pg.color.withValues(alpha: pg.opacity * 0.6),
              pg.color.withValues(alpha: pg.opacity * 0.1),
              pg.color.withValues(alpha: 0.0),
            ],
            [0.0, 0.3, 0.7, 1.0],
            TileMode.clamp,
            (Matrix4.identity()..scale(pg.semiAxisA, pg.semiAxisB)).storage,
          );

        canvas.drawOval(rect, paint);
      } else {
        // Small Gaussians: render as a simple circle
        final radius = math.max(1.0, (pg.semiAxisA + pg.semiAxisB) / 2);
        final paint = Paint()
          ..color = pg.color.withValues(alpha: pg.opacity)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset.zero, radius, paint);
      }

      canvas.restore();
    }

    // Draw info overlay
    final visibleCount = projected.length;
    final tp = TextPainter(
      text: TextSpan(
        text: '$visibleCount / ${scene.gaussians.length} Gaussians',
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          shadows: [Shadow(color: Colors.black, blurRadius: 2)],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, const Offset(10, 10));
  }

  @override
  bool shouldRepaint(_GaussianSplatPainter oldDelegate) {
    return oldDelegate.viewMatrix != viewMatrix ||
        oldDelegate.maxGaussiansToRender != maxGaussiansToRender ||
        oldDelegate.showEllipses != showEllipses;
  }
}

/// Interactive widget for rendering a [GaussianScene] using 2D-projected
/// Gaussian ellipses with camera controls (pan, zoom, rotate).
///
/// Supports progressive rendering: initially renders a subset of Gaussians
/// for interactive frame rates, then refines to the full set after interaction
/// stops.
class GaussianSplatRenderer extends StatefulWidget {
  final GaussianScene scene;
  final double initialFocalLength;
  final bool initialShowEllipses;

  const GaussianSplatRenderer({
    super.key,
    required this.scene,
    this.initialFocalLength = 500.0,
    this.initialShowEllipses = true,
  });

  @override
  State<GaussianSplatRenderer> createState() => GaussianSplatRendererState();
}

class GaussianSplatRendererState extends State<GaussianSplatRenderer> {
  late Matrix4 _viewMatrix;
  double _rotationX = -0.3;
  double _rotationY = 0.0;
  double _zoom = 1.0;
  double _panX = 0.0;
  double _panY = 0.0;
  Offset _lastFocalPoint = Offset.zero;
  double _lastScale = 1.0;
  bool _showEllipses = true;

  /// Progressive rendering: during interaction, render fewer Gaussians.
  int _renderLimit = 0; // 0 = render all
  bool _isInteracting = false;

  /// Threshold below which we render all Gaussians even during interaction.
  static const int _fastRenderThreshold = 5000;

  /// Fraction of Gaussians to render during interaction for large scenes.
  static const double _interactiveFraction = 0.25;

  @override
  void initState() {
    super.initState();
    _showEllipses = widget.initialShowEllipses;
    _resetView();
  }

  void _resetView() {
    _rotationX = -0.3;
    _rotationY = 0.0;
    _zoom = 1.0;
    _panX = 0.0;
    _panY = 0.0;
    _updateViewMatrix();
  }

  void _updateViewMatrix() {
    _viewMatrix = Matrix4.identity()
      ..translate(_panX, _panY, 0.0)
      ..scale(_zoom)
      ..rotateX(_rotationX)
      ..rotateY(_rotationY);
  }

  /// Camera position in world space (approximate, for SH evaluation).
  vector.Vector3 get _cameraPosition {
    // Inverse of view rotation applied to (0, 0, -distance)
    final invRot = Matrix4.identity()
      ..rotateY(-_rotationY)
      ..rotateX(-_rotationX);
    final camDir = invRot.transform3(vector.Vector3(0, 0, -500.0 / _zoom));
    final center = widget.scene.getCenter();
    return center + camDir;
  }

  int get _interactiveLimit {
    final total = widget.scene.gaussians.length;
    if (total <= _fastRenderThreshold) return 0; // render all
    return (total * _interactiveFraction).round();
  }

  void _startInteraction() {
    if (!_isInteracting) {
      _isInteracting = true;
      _renderLimit = _interactiveLimit;
    }
  }

  void _endInteraction() {
    // Refine to full resolution after a short delay
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _isInteracting = false;
          _renderLimit = 0;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (details) {
        _lastFocalPoint = details.focalPoint;
        _lastScale = _zoom;
        _startInteraction();
      },
      onScaleUpdate: (details) {
        setState(() {
          if ((details.scale - 1.0).abs() > 0.01) {
            // Pinch zoom
            _zoom = (_lastScale * details.scale).clamp(0.1, 10.0);
          }

          final delta = details.focalPoint - _lastFocalPoint;

          if (details.pointerCount == 1) {
            // Single finger: rotate
            _rotationY += delta.dx * 0.01;
            _rotationX += delta.dy * 0.01;
            _rotationX = _rotationX.clamp(-math.pi / 2, math.pi / 2);
          } else if (details.pointerCount >= 2 &&
              (details.scale - 1.0).abs() <= 0.01) {
            // Two fingers without pinch: pan
            _panX += delta.dx * 0.5;
            _panY += delta.dy * 0.5;
          }

          _lastFocalPoint = details.focalPoint;
          _updateViewMatrix();
        });
      },
      onScaleEnd: (_) => _endInteraction(),
      child: CustomPaint(
        painter: _GaussianSplatPainter(
          scene: widget.scene,
          viewMatrix: _viewMatrix,
          focalLength: widget.initialFocalLength,
          maxGaussiansToRender: _renderLimit,
          showEllipses: _showEllipses,
          cameraPosition: _cameraPosition,
        ),
        size: Size.infinite,
      ),
    );
  }

  // --- Public API for external controls ---

  void resetView() {
    setState(() {
      _resetView();
    });
  }

  void toggleEllipseMode() {
    setState(() {
      _showEllipses = !_showEllipses;
    });
  }

  bool get showEllipses => _showEllipses;
}
