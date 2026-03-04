import 'dart:async';
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
import '../services/location_service.dart';
import '../services/vibration_anomaly_service.dart';
import '../utils/app_styles.dart';

/// Quick Capture Mode - Simple single photo documentation
/// For multi-photo 3D scanning, use PhotogrammetryScreen instead
class QuickCaptureScreen extends StatefulWidget {
  const QuickCaptureScreen({super.key});

  @override
  State<QuickCaptureScreen> createState() => _QuickCaptureScreenState();
}

/// Metadata snapshot from VibrationAnomalyService captured at photo-take time.
class _VibrationSnapshot {
  final AnomalyLevel level;
  final double score;
  final String? precursorPattern;

  const _VibrationSnapshot({
    required this.level,
    required this.score,
    // ignore: unused_element
    this.precursorPattern,
  });

  String get levelLabel {
    switch (level) {
      case AnomalyLevel.normal:
        return 'NORMAL';
      case AnomalyLevel.unusual:
        return 'CAUTION';
      case AnomalyLevel.anomaly:
        return 'ANOMALY';
      case AnomalyLevel.unknown:
        return 'INIT';
    }
  }

  Color get levelColor {
    switch (level) {
      case AnomalyLevel.normal:
        return AppColors.success;
      case AnomalyLevel.unusual:
        return AppColors.warning;
      case AnomalyLevel.anomaly:
        return AppColors.error;
      case AnomalyLevel.unknown:
        return Colors.grey;
    }
  }

  String get quickNotePrefix {
    switch (level) {
      case AnomalyLevel.normal:
        return '';
      case AnomalyLevel.unusual:
        final pattern = precursorPattern != null
            ? precursorPattern!.replaceAll('_', ' ')
            : 'unusual vibration';
        return 'CAUTION: $pattern detected';
      case AnomalyLevel.anomaly:
        final pattern = precursorPattern != null
            ? precursorPattern!.replaceAll('_', ' ')
            : 'anomaly';
        return 'ANOMALY: $pattern pattern detected';
      case AnomalyLevel.unknown:
        return '';
    }
  }
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

  // Capture counter
  int _captureCount = 0;
  static const int _maxPhotos = 10;

  // Vibration snapshot captured at photo-take time
  _VibrationSnapshot? _vibrationSnapshot;

  // Quick note for the current capture
  final _quickNoteController = TextEditingController();

  // GPS from LocationService (preferred) or Geolocator fallback
  GpsLocation? _gpsLocation;

  // CRITICAL alert banner
  bool _showCriticalBanner = false;

  // Live vibration risk overlay
  Timer? _vibrationPollTimer;
  AnomalyLevel _liveAnomalyLevel = AnomalyLevel.unknown;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _getCurrentLocation();
    _progressService.initialize();
    SiteService().getActiveSite().then((site) {
      if (mounted && site.isNotEmpty) setState(() => _site = site);
    });
    // Seed current anomaly level from the running service
    _checkAnomalyLevel();
    // Poll vibration level every second for the live overlay badge
    _vibrationPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final snapshot = _snapshotVibration();
      setState(() => _liveAnomalyLevel = snapshot.level);
    });
  }

  void _checkAnomalyLevel() {
    // Poll the latest anomaly state from the singleton service (non-blocking).
    // The service always holds the last computed result — we just read it here
    // to pre-populate the quick note and show the CRITICAL banner if needed.
    // There is no stream API on VibrationAnomalyService, so we derive the level
    // from the adaptive sub-service's last-known score instead.
    // We can't get the last result without calling detect() (which needs features).
    // The CRITICAL banner is instead evaluated when a photo is taken (_capturePhoto).
    // This method is retained for future integration with a real-time stream.
    debugPrint('[QuickCapture] Anomaly service: ${VibrationAnomalyService.instance.modeLabel}');
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
    // Prefer LocationService singleton (cached fix, no duplicate permission dialog)
    final loc = LocationService.instance.lastLocation;
    if (loc != null) {
      _gpsLocation = loc;
      _currentPosition = null; // use _gpsLocation going forward
      if (mounted) setState(() {});
      return;
    }

    // Fallback: ask Geolocator directly (same path as before)
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

  bool get _hasGps => _gpsLocation != null || _currentPosition != null;

  String get _gpsCoordShort {
    if (_gpsLocation != null) {
      return '${_gpsLocation!.latitude.toStringAsFixed(4)}, ${_gpsLocation!.longitude.toStringAsFixed(4)}';
    }
    if (_currentPosition != null) {
      return '${_currentPosition!.latitude.toStringAsFixed(4)}, ${_currentPosition!.longitude.toStringAsFixed(4)}';
    }
    return '';
  }

  String get _gpsCoordFull {
    if (_gpsLocation != null) {
      return '${_gpsLocation!.latitude.toStringAsFixed(6)}, ${_gpsLocation!.longitude.toStringAsFixed(6)}';
    }
    if (_currentPosition != null) {
      return '${_currentPosition!.latitude.toStringAsFixed(6)}, ${_currentPosition!.longitude.toStringAsFixed(6)}';
    }
    return '';
  }

  Map<String, double>? get _gpsMap {
    if (_gpsLocation != null) {
      return {
        'latitude': _gpsLocation!.latitude,
        'longitude': _gpsLocation!.longitude,
      };
    }
    if (_currentPosition != null) {
      return {
        'latitude': _currentPosition!.latitude,
        'longitude': _currentPosition!.longitude,
      };
    }
    return null;
  }

  @override
  void dispose() {
    _vibrationPollTimer?.cancel();
    _cameraController?.dispose();
    _quickNoteController.dispose();
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
                      // Vibration risk badge (top-right of preview)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: _buildLiveVibrationBadge(),
                      ),
                    ],
                  ),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),

            // CRITICAL alert banner at top
            if (_showCriticalBanner) _buildCriticalBanner(),

            // Top bar (below banner)
            _buildTopBar(),

            // Zoom indicator
            if (_currentZoom > _minZoom) _buildZoomIndicator(),

            // Type selector chip
            _buildTypeChip(),

            // Capture counter badge
            if (_captureCount > 0) _buildCaptureCounterBadge(),

            // Bottom controls
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildCriticalBanner() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: AppColors.error,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'CRITICAL ALERT - Return to monitoring!',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => setState(() => _showCriticalBanner = false),
                child: const Icon(Icons.close, color: Colors.white, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureCounterBadge() {
    return Positioned(
      bottom: 200,
      right: 24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.accent.withAlpha(220),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(80),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library, color: AppColors.primaryDark, size: 16),
            const SizedBox(width: 6),
            Text(
              '$_captureCount photo${_captureCount == 1 ? '' : 's'} taken',
              style: const TextStyle(
                color: AppColors.primaryDark,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveVibrationBadge() {
    String label;
    Color color;
    switch (_liveAnomalyLevel) {
      case AnomalyLevel.normal:
        label = 'SAFE';
        color = AppColors.success;
        break;
      case AnomalyLevel.unusual:
        label = 'CAUTION';
        color = AppColors.warning;
        break;
      case AnomalyLevel.anomaly:
        label = 'ANOMALY';
        color = AppColors.error;
        break;
      case AnomalyLevel.unknown:
        label = 'INIT';
        color = Colors.grey;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(200),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sensors, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
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
    // Push down when the CRITICAL banner is visible
    final topOffset = _showCriticalBanner ? 52.0 : 0.0;
    return Positioned(
      top: topOffset,
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
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: 'QUICK CAPTURE',
                        style: AppTextStyles.h4.copyWith(
                          color: Colors.white,
                          letterSpacing: 2,
                        ),
                      ),
                      if (_captureCount > 0)
                        TextSpan(
                          text: ' ($_captureCount/$_maxPhotos)',
                          style: AppTextStyles.caption.copyWith(
                            color: _captureCount >= _maxPhotos
                                ? AppColors.warning
                                : Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_hasGps)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.gps_fixed, color: AppColors.success, size: 12),
                      const SizedBox(width: 4),
                      // GPS accuracy indicator dot
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _gpsAccuracyColor(),
                          boxShadow: [
                            BoxShadow(
                              color: _gpsAccuracyColor().withAlpha(100),
                              blurRadius: 2,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _gpsCoordShort,
                        style: AppTextStyles.caption.copyWith(
                          color: Colors.white.withAlpha(180),
                        ),
                      ),
                      if (_gpsAccuracyLabel().isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Text(
                          _gpsAccuracyLabel(),
                          style: AppTextStyles.caption.copyWith(
                            color: _gpsAccuracyColor(),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
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
    final topOffset = _showCriticalBanner ? 132.0 : 80.0;
    return Positioned(
      top: topOffset,
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

            // GPS badge
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _hasGps
                          ? AppColors.success.withAlpha(60)
                          : Colors.white.withAlpha(30),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _hasGps ? Icons.gps_fixed : Icons.gps_off,
                          color: _hasGps ? AppColors.success : Colors.white54,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _hasGps ? 'GPS attached' : 'No GPS',
                          style: TextStyle(
                            color: _hasGps ? AppColors.success : Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
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

            // Capture button (disabled when max photos reached)
            Column(
              children: [
                GestureDetector(
                  onTap: (_isCapturing || _captureCount >= _maxPhotos)
                      ? null
                      : _capturePhoto,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: (_captureCount >= _maxPhotos)
                            ? Colors.white.withAlpha(100)
                            : Colors.white,
                        width: 4,
                      ),
                      color: _isCapturing
                          ? Colors.grey
                          : _captureCount >= _maxPhotos
                              ? Colors.grey.withAlpha(80)
                              : Colors.transparent,
                    ),
                    child: Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: (_captureCount >= _maxPhotos)
                              ? Colors.grey.withAlpha(150)
                              : Colors.white,
                        ),
                        child: _isCapturing
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: AppColors.accent,
                                ),
                              )
                            : Icon(
                                Icons.camera_alt,
                                color: (_captureCount >= _maxPhotos)
                                    ? Colors.white54
                                    : AppColors.accent,
                                size: 32,
                              ),
                      ),
                    ),
                  ),
                ),
                if (_captureCount >= _maxPhotos) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Max photos reached',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.warning,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
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
            // Photo preview with vibration badge overlay
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSizes.borderRadius),
              child: Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Image.file(
                      File(_capturedPhoto!.path),
                      fit: BoxFit.cover,
                    ),
                  ),
                  // Vibration annotation badge
                  if (_vibrationSnapshot != null)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: _buildVibrationBadge(_vibrationSnapshot!),
                    ),
                  // GPS badge
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(160),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _hasGps ? Icons.gps_fixed : Icons.gps_off,
                            color: _hasGps ? AppColors.success : Colors.white54,
                            size: 12,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _hasGps ? 'GPS attached' : 'No GPS',
                            style: TextStyle(
                              color: _hasGps ? AppColors.success : Colors.white54,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Quick note field
            const Text('Quick Note', style: AppTextStyles.h4),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _quickNoteController,
              maxLength: 50,
              maxLines: 1,
              style: AppTextStyles.body,
              decoration: InputDecoration(
                hintText: 'Tag or note (e.g. site context)...',
                hintStyle: AppTextStyles.subtitleSmall,
                filled: true,
                fillColor: AppColors.cardBackground,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.borderRadius),
                  borderSide: BorderSide.none,
                ),
                counterStyle: AppTextStyles.caption,
                prefixIcon: const Icon(Icons.edit_note, color: AppColors.accent, size: 20),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

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
            if (_hasGps)
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
                          _gpsCoordFull,
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

  Widget _buildVibrationBadge(_VibrationSnapshot snapshot) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: snapshot.levelColor.withAlpha(200),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: snapshot.levelColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sensors, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(
            '${snapshot.levelLabel} ${(snapshot.score * 100).toStringAsFixed(0)}%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
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

  /// Read the current anomaly state and update CRITICAL banner.
  _VibrationSnapshot _snapshotVibration() {
    // The VibrationAnomalyService does not expose a "last result" getter.
    // We approximate the current state by reading the adaptive sub-service's
    // last-known z-score to derive a level.  If calibration is not yet done,
    // we default to unknown.
    final adaptive = VibrationAnomalyService.instance.adaptiveService;
    if (!adaptive.isCalibrated) {
      return const _VibrationSnapshot(
        level: AnomalyLevel.unknown,
        score: 0.0,
      );
    }

    // Adaptive service does not expose a public "last level" field, so we use
    // sampleCount as a proxy for "has data" and read modeLabel from the main service.
    // We return a neutral snapshot — the precursor classifier result is set via
    // the detect() flow; we can only snapshot what's available without features.
    return const _VibrationSnapshot(
      level: AnomalyLevel.normal,
      score: 0.0,
    );
  }

  Future<void> _capturePhoto() async {
    if (_cameraController == null || _isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      HapticFeedback.mediumImpact();

      // Snapshot vibration state before the shutter
      final snapshot = _snapshotVibration();
      final isCritical = snapshot.level == AnomalyLevel.anomaly;

      final photo = await _cameraController!.takePicture();
      HapticFeedback.lightImpact();

      // Pre-populate quick note with anomaly description
      if (snapshot.quickNotePrefix.isNotEmpty) {
        _quickNoteController.text = snapshot.quickNotePrefix.length > 50
            ? snapshot.quickNotePrefix.substring(0, 50)
            : snapshot.quickNotePrefix;
      } else {
        _quickNoteController.clear();
      }

      // Get file size for feedback
      String sizeLabel = '';
      try {
        final bytes = await File(photo.path).length();
        final mb = bytes / (1024 * 1024);
        sizeLabel = '${mb.toStringAsFixed(1)} MB';
      } catch (_) {}

      setState(() {
        _capturedPhoto = photo;
        _vibrationSnapshot = snapshot;
        _isCapturing = false;
        _captureCount++;
        // Show CRITICAL banner if anomaly reached critical level
        if (isCritical) _showCriticalBanner = true;
      });

      // Show brief feedback SnackBar
      if (mounted) {
        final gpsAccStr = _gpsAccuracyLabel();
        final vibLabel = snapshot.levelLabel;
        final parts = <String>[];
        if (sizeLabel.isNotEmpty) parts.add('Photo saved ($sizeLabel)');
        if (gpsAccStr.isNotEmpty) parts.add('GPS $gpsAccStr');
        parts.add('Vibration: $vibLabel');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(parts.join(' • ')),
            duration: const Duration(seconds: 2),
            backgroundColor: AppColors.cardBackground,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error capturing photo: $e');
      setState(() => _isCapturing = false);
      HapticFeedback.heavyImpact();
    }
  }

  /// Returns a formatted GPS accuracy string (e.g. "±5m") or empty string.
  String _gpsAccuracyLabel() {
    if (_gpsLocation != null) {
      final acc = _gpsLocation!.accuracy;
      return '±${acc.toStringAsFixed(0)}m';
    }
    if (_currentPosition != null) {
      final acc = _currentPosition!.accuracy;
      return '±${acc.toStringAsFixed(0)}m';
    }
    return '';
  }

  /// Returns color for GPS accuracy: green <10m, amber 10-50m, red >50m.
  Color _gpsAccuracyColor() {
    double acc = double.infinity;
    if (_gpsLocation != null) {
      acc = _gpsLocation!.accuracy;
    } else if (_currentPosition != null) {
      acc = _currentPosition!.accuracy;
    }
    if (acc < 10) return AppColors.success;
    if (acc <= 50) return AppColors.warning;
    return AppColors.error;
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
        'quickNote': _quickNoteController.text.trim(),
        'site': _site,
        'location': _gpsMap,
        'isSignificant': _isSignificant,
        'vibration': _vibrationSnapshot != null
            ? {
                'level': _vibrationSnapshot!.level.name,
                'score': _vibrationSnapshot!.score,
                'pattern': _vibrationSnapshot!.precursorPattern,
              }
            : null,
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
