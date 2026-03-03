import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../models/artifact_classification.dart';
import '../services/progress_service.dart';
import '../services/site_service.dart';
import '../utils/app_styles.dart';

/// Quick Capture Mode - Simple single photo documentation
/// For multi-photo 3D scanning, use PhotogrammetryScreen instead
class QuickCaptureScreen extends StatefulWidget {
  const QuickCaptureScreen({super.key});

  @override
  State<QuickCaptureScreen> createState() => _QuickCaptureScreenState();
}

class _QuickCaptureScreenState extends State<QuickCaptureScreen> {
  CameraController? _cameraController;
  bool _isInitialized = false;
  bool _isCapturing = false;
  XFile? _capturedPhoto;
  ArtifactType? _selectedType;
  String _description = '';
  bool _isSignificant = false;
  Position? _currentPosition;
  final _progressService = ProgressService();

  String _site = '';

  // Camera controls
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _baseZoom = 1.0;
  bool _showGrid = false;
  FlashMode _currentFlashMode = FlashMode.auto;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _getCurrentLocation();
    _progressService.initialize();
    SiteService().getActiveSite().then((site) {
      if (mounted && site.isNotEmpty) setState(() => _site = site);
    });
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      _minZoom = await _cameraController!.getMinZoomLevel();
      _maxZoom = await _cameraController!.getMaxZoomLevel();
      _currentZoom = _minZoom;

      if (mounted) {
        setState(() => _isInitialized = true);
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }

      _currentPosition = await Geolocator.getCurrentPosition();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Show captured photo review screen
    if (_capturedPhoto != null) {
      return _buildReviewScreen();
    }

    // Show camera capture screen
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Camera preview
            if (_isInitialized && _cameraController != null)
              Positioned.fill(
                child: GestureDetector(
                  onScaleStart: (details) => _baseZoom = _currentZoom,
                  onScaleUpdate: (details) => _setZoom(_baseZoom * details.scale),
                  onDoubleTap: () {
                    if (_currentZoom > _minZoom) {
                      _setZoom(_minZoom);
                    } else {
                      _setZoom((_maxZoom - _minZoom) / 2 + _minZoom);
                    }
                  },
                  child: Stack(
                    children: [
                      CameraPreview(_cameraController!),
                      if (_showGrid) _buildGridOverlay(),
                      // Simple center crosshair
                      Center(child: _buildCrosshair()),
                    ],
                  ),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),

            // Top bar
            _buildTopBar(),

            // Zoom indicator
            if (_currentZoom > _minZoom) _buildZoomIndicator(),

            // Type selector chip
            _buildTypeChip(),

            // Bottom controls
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildCrosshair() {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withAlpha(150), width: 2),
      ),
      child: Center(
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(200),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _buildGridOverlay() {
    return CustomPaint(
      size: Size.infinite,
      painter: _GridPainter(),
    );
  }

  Widget _buildZoomIndicator() {
    return Positioned(
      top: 100,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(150),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${_currentZoom.toStringAsFixed(1)}x',
            style: AppTextStyles.body.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withAlpha(200),
              Colors.transparent,
            ],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
            Column(
              children: [
                Text(
                  'QUICK CAPTURE',
                  style: AppTextStyles.h4.copyWith(
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                ),
                if (_currentPosition != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.gps_fixed, color: AppColors.success, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        '${_currentPosition!.latitude.toStringAsFixed(4)}, ${_currentPosition!.longitude.toStringAsFixed(4)}',
                        style: AppTextStyles.caption.copyWith(
                          color: Colors.white.withAlpha(180),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Grid toggle
                IconButton(
                  icon: Icon(
                    _showGrid ? Icons.grid_on : Icons.grid_off,
                    color: _showGrid ? AppColors.accent : Colors.white,
                    size: 24,
                  ),
                  onPressed: () {
                    setState(() => _showGrid = !_showGrid);
                    HapticFeedback.selectionClick();
                  },
                ),
                // Flash toggle
                IconButton(
                  icon: Icon(
                    _getFlashIcon(),
                    color: _currentFlashMode != FlashMode.off
                        ? AppColors.accent
                        : Colors.white,
                    size: 28,
                  ),
                  onPressed: _toggleFlash,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getFlashIcon() {
    switch (_currentFlashMode) {
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.torch:
        return Icons.highlight;
    }
  }

  Widget _buildTypeChip() {
    return Positioned(
      top: 80,
      left: 16,
      child: GestureDetector(
        onTap: _showTypeSelector,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _selectedType?.color.withAlpha(204) ?? Colors.white.withAlpha(51),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _selectedType?.icon ?? Icons.category,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                _selectedType?.name.split(' ').first ?? 'Type',
                style: AppTextStyles.body.copyWith(color: Colors.white),
              ),
              const Icon(Icons.arrow_drop_down, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withAlpha(230),
              Colors.transparent,
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Zoom slider
            if (_maxZoom > _minZoom)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    const Icon(Icons.zoom_out, color: Colors.white54, size: 20),
                    Expanded(
                      child: Slider(
                        value: _currentZoom,
                        min: _minZoom,
                        max: _maxZoom,
                        activeColor: AppColors.accent,
                        inactiveColor: Colors.white24,
                        onChanged: _setZoom,
                      ),
                    ),
                    const Icon(Icons.zoom_in, color: Colors.white54, size: 20),
                  ],
                ),
              ),

            // Simple tip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(100),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lightbulb_outline, color: AppColors.accent, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'Take one clear photo of the artifact',
                    style: AppTextStyles.caption.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),

            // Capture button
            GestureDetector(
              onTap: _isCapturing ? null : _capturePhoto,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                  color: _isCapturing ? Colors.grey : Colors.transparent,
                ),
                child: Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: _isCapturing
                        ? const Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: AppColors.accent,
                            ),
                          )
                        : const Icon(
                            Icons.camera_alt,
                            color: AppColors.accent,
                            size: 32,
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Review screen after photo is captured
  Widget _buildReviewScreen() {
    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () {
            setState(() => _capturedPhoto = null);
          },
        ),
        title: const Text(
          'Review & Save',
          style: AppTextStyles.h3,
        ),
        actions: [
          TextButton(
            onPressed: _saveFinding,
            child: Text(
              'SAVE',
              style: AppTextStyles.button.copyWith(
                color: AppColors.success,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Photo preview
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSizes.borderRadius),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.file(
                  File(_capturedPhoto!.path),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Type selector
            const Text('Artifact Type', style: AppTextStyles.h4),
            const SizedBox(height: AppSpacing.sm),
            _buildTypeGrid(),
            const SizedBox(height: AppSpacing.xl),

            // Description
            const Text('Description', style: AppTextStyles.h4),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              maxLines: 3,
              style: AppTextStyles.body,
              decoration: InputDecoration(
                hintText: 'Describe the artifact (optional)...',
                hintStyle: AppTextStyles.subtitleSmall,
                filled: true,
                fillColor: AppColors.cardBackground,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadius),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) => _description = value,
            ),
            const SizedBox(height: AppSpacing.xl),

            // GPS info
            if (_currentPosition != null)
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: AppDecorations.card,
                child: Row(
                  children: [
                    const Icon(Icons.gps_fixed, color: AppColors.success, size: 24),
                    const SizedBox(width: AppSpacing.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('GPS Location', style: AppTextStyles.subtitle),
                        Text(
                          '${_currentPosition!.latitude.toStringAsFixed(6)}, ${_currentPosition!.longitude.toStringAsFixed(6)}',
                          style: AppTextStyles.caption,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.xl),

            // Significant find toggle
            CheckboxListTile(
              value: _isSignificant,
              onChanged: (v) => setState(() => _isSignificant = v ?? false),
              title: const Text(
                'Mark as significant find',
                style: AppTextStyles.body,
              ),
              subtitle: const Text(
                'e.g. gold coin, complete ceramic',
                style: AppTextStyles.subtitleSmall,
              ),
              activeColor: AppColors.warning,
              checkColor: AppColors.primaryDark,
              side: const BorderSide(color: Colors.white38),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeGrid() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: ArtifactClassification.artifactTypes.take(10).map((type) {
        final isSelected = _selectedType == type;
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _selectedType = type);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? type.color : AppColors.cardBackground,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? type.color : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(type.icon, size: 18, color: isSelected ? Colors.white : type.color),
                const SizedBox(width: 6),
                Text(
                  type.name.split(' ').first,
                  style: AppTextStyles.caption.copyWith(
                    color: isSelected ? Colors.white : AppColors.textSecondary,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  void _setZoom(double zoom) async {
    final newZoom = zoom.clamp(_minZoom, _maxZoom);
    setState(() => _currentZoom = newZoom);
    await _cameraController?.setZoomLevel(newZoom);
  }

  Future<void> _capturePhoto() async {
    if (_cameraController == null || _isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      HapticFeedback.mediumImpact();
      final photo = await _cameraController!.takePicture();
      HapticFeedback.lightImpact();

      setState(() {
        _capturedPhoto = photo;
        _isCapturing = false;
      });
    } catch (e) {
      debugPrint('Error capturing photo: $e');
      setState(() => _isCapturing = false);
      HapticFeedback.heavyImpact();
    }
  }

  void _toggleFlash() async {
    if (_cameraController == null) return;

    HapticFeedback.selectionClick();

    try {
      FlashMode newMode;

      switch (_currentFlashMode) {
        case FlashMode.off:
          newMode = FlashMode.auto;
          break;
        case FlashMode.auto:
          newMode = FlashMode.always;
          break;
        case FlashMode.always:
          newMode = FlashMode.torch;
          break;
        default:
          newMode = FlashMode.off;
      }

      await _cameraController!.setFlashMode(newMode);
      setState(() => _currentFlashMode = newMode);
    } catch (e) {
      debugPrint('Error toggling flash: $e');
    }
  }

  void _showTypeSelector() {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select Artifact Type', style: AppTextStyles.h3),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ArtifactClassification.artifactTypes.take(10).map((type) {
                final isSelected = _selectedType == type;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _selectedType = type);
                    Navigator.pop(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? type.color : AppColors.primaryDark,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(type.icon, size: 18, color: isSelected ? Colors.white : type.color),
                        const SizedBox(width: 6),
                        Text(
                          type.name.split(' ').first,
                          style: AppTextStyles.caption.copyWith(
                            color: isSelected ? Colors.white : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }

  void _saveFinding() async {
    if (_capturedPhoto == null) return;

    HapticFeedback.mediumImpact();

    // Persist photo to permanent storage
    String persistedPath = _capturedPhoto!.path;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final photosDir = Directory('${appDir.path}/quick_captures');
      if (!await photosDir.exists()) {
        await photosDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = path.extension(_capturedPhoto!.path);
      persistedPath = '${photosDir.path}/quick_$timestamp$extension';
      await File(_capturedPhoto!.path).copy(persistedPath);
    } catch (e) {
      debugPrint('Error persisting photo: $e');
    }

    // Record finding in progress service
    final achievements = await _progressService.recordFinding();
    await _progressService.recordPhotos(1);

    // Return data to parent screen
    if (mounted) {
      final result = {
        'photo': _capturedPhoto,
        'persistedPath': persistedPath,
        'type': _selectedType,
        'description': _description,
        'site': _site,
        'location': _currentPosition != null
            ? {
                'latitude': _currentPosition!.latitude,
                'longitude': _currentPosition!.longitude,
              }
            : null,
        'isSignificant': _isSignificant,
      };

      // Show achievement if earned, then pop; otherwise just pop
      if (achievements.isNotEmpty) {
        _showAchievementDialog(achievements.first).then((_) {
          if (mounted) Navigator.pop(context, result);
        });
      } else {
        Navigator.pop(context, result);
      }
    }
  }

  Future<void> _showAchievementDialog(Achievement achievement) {
    return
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.accent.withAlpha(50),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Icon(
                achievement.type.icon,
                color: AppColors.accent,
                size: 48,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Achievement Unlocked!',
              style: AppTextStyles.h3.copyWith(color: AppColors.accent),
            ),
            const SizedBox(height: 8),
            Text(
              achievement.type.title,
              style: AppTextStyles.body,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Awesome!', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for rule of thirds grid
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(80)
      ..strokeWidth = 1;

    // Vertical lines
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      paint,
    );

    // Horizontal lines
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height * 2 / 3),
      Offset(size.width, size.height * 2 / 3),
      paint,
    );

    // Intersection points
    final dotPaint = Paint()
      ..color = Colors.white.withAlpha(150)
      ..style = PaintingStyle.fill;

    final points = [
      Offset(size.width / 3, size.height / 3),
      Offset(size.width * 2 / 3, size.height / 3),
      Offset(size.width / 3, size.height * 2 / 3),
      Offset(size.width * 2 / 3, size.height * 2 / 3),
    ];

    for (final point in points) {
      canvas.drawCircle(point, 4, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
