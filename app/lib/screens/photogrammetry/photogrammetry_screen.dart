// ignore_for_file: use_build_context_synchronously
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:archive/archive_io.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/reconstruction_result.dart';
import '../../services/reconstruction/index.dart';
import '../../services/reali3_service.dart';
import '../../services/notification_service.dart';
import '../../services/metadata_export_service.dart';
import '../../utils/quality_analyzer.dart';
import '../../widgets/model_3d_viewer.dart';
import '../../widgets/reconstruction_progress_widget.dart';
import '../../widgets/point_cloud_painter.dart';
import '../../models/point_cloud.dart';
import '../../services/incremental_sfm_service.dart';
import '../../services/dense_reconstruction_service.dart';
import '../../services/image_service.dart';
import '../manual_entry_form_screen.dart';
import 'photogrammetry_models.dart';

class PhotogrammetryScreen extends StatefulWidget {
  final String? findingId;
  final String? findingName;

  const PhotogrammetryScreen({
    super.key,
    this.findingId,
    this.findingName,
  });

  @override
  State<PhotogrammetryScreen> createState() => _PhotogrammetryScreenState();
}

class _PhotogrammetryScreenState extends State<PhotogrammetryScreen>
    with SingleTickerProviderStateMixin {
  static const String _tutorialSeenKey = 'photogrammetry_tutorial_seen';
  final ImagePicker _imagePicker = ImagePicker();
  final List<PhotogrammetryCapture> _captures = [];
  int _currentAngleIndex = 0;
  bool _showTutorial = true;
  bool _isCapturing = false;
  late AnimationController _pulseController;

  // Feature cache for real overlap computation
  List<ImageFeature>? _lastImageFeatures;

  // CAPTURE SETTINGS
  stt.SpeechToText? _speechToText; // Voice commands
  FlutterTts? _flutterTts; // Text-to-speech feedback
  bool _voiceEnabled = false; // Voice commands enabled
  bool _isListening = false; // Currently listening for voice command
  String _lastVoiceCommand = '';

  // 3D RECONSTRUCTION
  final ReconstructionService _reconstructionService = ReconstructionService();
  bool _isReconstructing = false; // Currently generating 3D model
  double _reconstructionProgress = 0.0; // Progress 0.0 to 1.0
  String _reconstructionStatus = ''; // Current status message
  ReconstructionResult? _lastReconstructionResult; // Last successful result for metadata export


  // Incremental SfM real-time preview
  final IncrementalSfMService _incrementalSfm = IncrementalSfMService();
  bool _showIncrementalPreview = false;
  PointCloud? _incrementalPreviewCloud;

  // Dense reconstruction
  final DenseReconstructionService _denseService = DenseReconstructionService();
  bool _isDenseReconstructing = false;
  double _denseProgress = 0.0;
  String _denseStatus = '';

  // Reali3 cloud result
  String? _gltfPath;


  // Define the optimal capture angles for photogrammetry
  // 12 angles around the object + 2 top angles + 2 detail angles = 16 total
  static const List<CaptureAngle> _captureAngles = [
    // Ring 1: Eye level (0°) - 8 positions around the object
    CaptureAngle(id: 0, name: 'Front', angle: 0, elevation: 0, icon: Icons.arrow_upward),
    CaptureAngle(id: 1, name: 'Front-Right', angle: 45, elevation: 0, icon: Icons.arrow_forward),
    CaptureAngle(id: 2, name: 'Right', angle: 90, elevation: 0, icon: Icons.arrow_forward),
    CaptureAngle(id: 3, name: 'Back-Right', angle: 135, elevation: 0, icon: Icons.arrow_forward),
    CaptureAngle(id: 4, name: 'Back', angle: 180, elevation: 0, icon: Icons.arrow_downward),
    CaptureAngle(id: 5, name: 'Back-Left', angle: 225, elevation: 0, icon: Icons.arrow_back),
    CaptureAngle(id: 6, name: 'Left', angle: 270, elevation: 0, icon: Icons.arrow_back),
    CaptureAngle(id: 7, name: 'Front-Left', angle: 315, elevation: 0, icon: Icons.arrow_back),
    // Ring 2: High angle (45°) - 4 positions
    CaptureAngle(id: 8, name: 'Top-Front', angle: 0, elevation: 45, icon: Icons.north_east),
    CaptureAngle(id: 9, name: 'Top-Right', angle: 90, elevation: 45, icon: Icons.north_east),
    CaptureAngle(id: 10, name: 'Top-Back', angle: 180, elevation: 45, icon: Icons.south_east),
    CaptureAngle(id: 11, name: 'Top-Left', angle: 270, elevation: 45, icon: Icons.north_west),
    // Top down views
    CaptureAngle(id: 12, name: 'Top Center', angle: 0, elevation: 80, icon: Icons.vertical_align_bottom),
    CaptureAngle(id: 13, name: 'Top Angled', angle: 45, elevation: 70, icon: Icons.vertical_align_bottom),
    // Detail shots
    CaptureAngle(id: 14, name: 'Detail 1', angle: 0, elevation: 20, icon: Icons.zoom_in, isDetail: true),
    CaptureAngle(id: 15, name: 'Detail 2', angle: 180, elevation: 20, icon: Icons.zoom_in, isDetail: true),
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _initializeVoiceCommands();
    _loadTutorialPreference();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _speechToText?.stop();
    _flutterTts?.stop();
    _incrementalSfm.reset();
    ImageService().cleanupTempFiles();
    super.dispose();
  }

  Future<void> _loadTutorialPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool(_tutorialSeenKey) ?? false;
    if (seen && mounted) {
      setState(() => _showTutorial = false);
    }
  }

  // Initialize voice commands for hands-free operation
  Future<void> _initializeVoiceCommands() async {
    final sttInstance = stt.SpeechToText();
    final ttsInstance = FlutterTts();
    _speechToText = sttInstance;
    _flutterTts = ttsInstance;

    // Initialize speech-to-text
    bool available = await sttInstance.initialize(
      onStatus: (status) {
        if (status == 'notListening' && _voiceEnabled && mounted) {
          // Auto-restart listening if voice is enabled
          _startListening();
        }
      },
      onError: (error) {
        debugPrint('Voice recognition error: $error');
        if (mounted) setState(() => _isListening = false);
      },
    );

    // Configure text-to-speech
    await ttsInstance.setLanguage('en-US');
    await ttsInstance.setSpeechRate(0.5); // Slower for clarity in field
    await ttsInstance.setVolume(1.0);
    await ttsInstance.setPitch(1.0);

    if (available) {
      debugPrint(' Voice commands initialized successfully');
    } else {
      debugPrint(' Voice recognition not available on this device');
    }
  }

  // Start listening for voice commands
  Future<void> _startListening() async {
    if (!_voiceEnabled || _isListening || _speechToText == null) return;

    if (mounted) {
      setState(() => _isListening = true);

      _speechToText!.listen(
        onResult: (result) {
          setState(() {
            _lastVoiceCommand = result.recognizedWords.toLowerCase();
          });

          if (result.finalResult) {
            _handleVoiceCommand(_lastVoiceCommand);
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
        ),
      );
    }
  }

  // Stop listening for voice commands
  Future<void> _stopListening() async {
    if (_isListening) {
      await _speechToText?.stop();
      if (mounted) setState(() => _isListening = false);
    }
  }

  // Handle recognized voice commands
  Future<void> _handleVoiceCommand(String command) async {
    command = command.toLowerCase().trim();

    // Capture commands
    if (command.contains('capture') || command.contains('photo') || command.contains('take picture')) {
      await _speak('Capturing now');
      _capturePhoto();
    }
    // Navigation commands
    else if (command.contains('next') || command.contains('next angle')) {
      if (_currentAngleIndex < _captureAngles.length - 1) {
        setState(() => _currentAngleIndex++);
        await _speak('Moving to ${_currentAngle.name}');
      } else {
        await _speak('This is the last angle');
      }
    }
    else if (command.contains('previous') || command.contains('back') || command.contains('go back')) {
      if (_currentAngleIndex > 0) {
        setState(() => _currentAngleIndex--);
        await _speak('Moving back to ${_currentAngle.name}');
      } else {
        await _speak('Already at first angle');
      }
    }
    // Progress and info commands
    else if (command.contains('progress') || command.contains('how many')) {
      await _speak('${_captures.length} of ${_captureAngles.length} angles captured');
    }
    else if (command.contains('current angle') || command.contains('what angle')) {
      await _speak('Current angle is ${_currentAngle.name}');
    }
    else if (command.contains('skip') || command.contains('skip angle')) {
      if (_currentAngleIndex < _captureAngles.length - 1) {
        setState(() => _currentAngleIndex++);
        await _speak('Skipped to ${_currentAngle.name}');
      }
    }
    // Export commands
    else if (command.contains('export') || command.contains('save') || command.contains('finish')) {
      if (_captures.length >= 8) {
        await _speak('Exporting ${_captures.length} photos');
        _exportPhotos();
      } else {
        await _speak('Need at least 8 captures to export. You have ${_captures.length}');
      }
    }
    // Help command
    else if (command.contains('help') || command.contains('what can i say')) {
      await _speak('Say capture, next, previous, progress, skip, or export');
    }
    else {
      // Unknown command
      await _speak('Command not recognized. Say help for available commands');
    }
  }

  // Text-to-speech helper
  Future<void> _speak(String text) async {
    await _flutterTts?.speak(text);
  }


  // Calculate progress percentage
  double get _progress => _captures.length / _captureAngles.length;

  // Get the next recommended angle
  CaptureAngle get _currentAngle => _captureAngles[_currentAngleIndex];

  // Check if enough photos for generation (minimum 4)
  bool get _canGenerate => _captures.length >= 4;

  // Check if all required angles are captured
  bool get _isComplete => _captures.length >= _captureAngles.length;

  Future<void> _capturePhoto() async {
    if (_isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      // Standard photo capture - optimized for photogrammetry
      final finalImage = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear, // Back camera
        maxWidth: 2048, // High resolution for 3D reconstruction
        maxHeight: 2048,
        imageQuality: 95, // High quality
      );

      if (finalImage != null) {
        // Analyze image quality
        final quality = await _analyzeImageQuality(finalImage);

        // Extract features for overlap tracking (used by incremental SfM)
        _computeOverlapAsync(finalImage);

        final capture = PhotogrammetryCapture(
          file: finalImage,
          angle: _currentAngle,
          capturedAt: DateTime.now(),
          qualityScore: quality,
        );

        setState(() {
          _captures.add(capture);
          // Auto-advance to next angle
          if (_currentAngleIndex < _captureAngles.length - 1) {
            _currentAngleIndex++;
          }
        });

        // Feed to incremental SfM for real-time preview
        _incrementalSfm.addImage(
          File(finalImage.path),
          onUpdate: (cloud, poses, count) {
            if (mounted) {
              setState(() => _incrementalPreviewCloud = cloud);
            }
          },
        );

        // Minimal quality feedback
        if (mounted) {
          final qualityText = quality >= 0.8 ? 'Sharp' : quality >= 0.6 ? 'OK' : 'Blurry';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${_captures.length}/${_captureAngles.length} $qualityText'),
              backgroundColor: quality >= 0.6 ? const Color(0xFF4CAF50) : Colors.orange,
              duration: const Duration(seconds: 1),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isCapturing = false);
    }
  }

  /// Compute overlap with previous image in background (non-blocking).
  /// Updates _lastImageFeatures for subsequent captures.
  Future<void> _computeOverlapAsync(XFile image) async {
    try {
      final file = File(image.path);
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;

      final small = img.copyResize(decoded, width: 512);
      final currentFeatures = await compute<img.Image, List<ImageFeature>>(
        extractFeaturesFromImage, small,
      );

      if (_lastImageFeatures != null && currentFeatures.isNotEmpty) {
        final matches = matchFeaturePair({
          'features1': _lastImageFeatures!,
          'features2': currentFeatures,
        });
        final maxF = _lastImageFeatures!.length > currentFeatures.length
            ? _lastImageFeatures!.length : currentFeatures.length;
        final overlap = maxF > 0 ? (matches.length / maxF) : 0.0;
        debugPrint('Overlap: ${(overlap * 100).toInt()}% (${matches.length} matches, ${currentFeatures.length} features)');
      }
      _lastImageFeatures = currentFeatures;
    } catch (e) {
      debugPrint('Overlap computation failed: $e');
    }
  }

  // Advanced image quality analysis using QualityAnalyzer
  Future<double> _analyzeImageQuality(XFile image) async {
    try {
      final file = File(image.path);
      final bytes = await file.readAsBytes();

      // Decode image
      img.Image? decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) return 0.5;

      // Use advanced QualityAnalyzer for comprehensive metrics
      final metrics = await QualityAnalyzer.analyzeImage(decodedImage);

      // Debug output
      debugPrint('📸 Quality Analysis:');
      debugPrint('   Sharpness: ${(metrics.sharpness * 100).toInt()}%');
      debugPrint('   Exposure: ${(metrics.exposure * 100).toInt()}%');
      debugPrint('   Motion Blur: ${(metrics.motionBlur * 100).toInt()}%');
      debugPrint('   Noise: ${(metrics.noise * 100).toInt()}%');
      debugPrint('   ⭐ Overall: ${(metrics.overallScore * 100).toInt()}%');

      // Return overall score
      return metrics.overallScore;
    } catch (e) {
      debugPrint(' Quality analysis error: $e');
      return 0.5;
    }
  }

  void _retakePhoto(int index) async {
    final capture = _captures[index];

    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 95,
    );

    if (image != null) {
      final quality = await _analyzeImageQuality(image);
      if (!mounted) return;

      setState(() {
        _captures[index] = PhotogrammetryCapture(
          file: image,
          angle: capture.angle,
          capturedAt: DateTime.now(),
          qualityScore: quality,
        );
      });
    }
  }

  void _deletePhoto(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: const Text('Delete Photo?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Remove ${_captures[index].angle.name} photo?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _captures.removeAt(index));
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _exportPhotos() async {
    if (_captures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No photos to export'), backgroundColor: Colors.orange),
      );
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final exportDir = Directory('${directory.path}/photogrammetry_$timestamp');
      await exportDir.create(recursive: true);

      // === Advanced Export ===

      // Copy all photos to export directory
      for (int i = 0; i < _captures.length; i++) {
        final capture = _captures[i];
        final newPath = '${exportDir.path}/${capture.angle.name.replaceAll(' ', '_')}_${i + 1}.jpg';
        await File(capture.file.path).copy(newPath);
      }

      // Create COMPREHENSIVE metadata file
      final metadata = StringBuffer();
      metadata.writeln('=' * 70);
      metadata.writeln('ANCIENTVISION PHOTOGRAMMETRY CAPTURE SET');
      metadata.writeln('=' * 70);
      metadata.writeln('Generated: ${DateTime.now().toIso8601String()}');
      if (widget.findingName != null) {
        metadata.writeln('Finding: ${widget.findingName}');
      }
      metadata.writeln('Total Photos: ${_captures.length}');

      // Calculate average quality
      double avgQuality = _captures.fold(0.0, (acc, c) => acc + c.qualityScore) / _captures.length;
      metadata.writeln('Average Quality: ${(avgQuality * 100).toInt()}%');
      metadata.writeln('');

      metadata.writeln('CAPTURE DETAILS');
      metadata.writeln('-' * 70);
      for (int i = 0; i < _captures.length; i++) {
        final capture = _captures[i];
        metadata.writeln('${i + 1}. ${capture.angle.name}');
        metadata.writeln('   Angle: ${capture.angle.angle}° | Elevation: ${capture.angle.elevation}°');
        metadata.writeln('   Quality: ${(capture.qualityScore * 100).toInt()}%');
        metadata.writeln('   Captured: ${capture.capturedAt.toIso8601String()}');
        metadata.writeln('');
      }

      metadata.writeln('PROCESSING INSTRUCTIONS');
      metadata.writeln('-' * 70);
      metadata.writeln('');
      metadata.writeln('OPTION 1: Automated Processing (Recommended)');
      metadata.writeln('   python photogrammetry_process.py .');
      metadata.writeln('   Or: python photogrammetry_process.py . --quality high');
      metadata.writeln('');
      metadata.writeln('OPTION 2: Meshroom GUI');
      metadata.writeln('   1. Open Meshroom application');
      metadata.writeln('   2. Drag this folder into Meshroom window');
      metadata.writeln('   3. Click "Start" button');
      metadata.writeln('   4. Wait 10-60 minutes for processing');
      metadata.writeln('');
      metadata.writeln('OPTION 3: COLMAP Command-line');
      metadata.writeln('   colmap automatic_reconstructor \\');
      metadata.writeln('     --workspace_path . \\');
      metadata.writeln('     --image_path . \\');
      metadata.writeln('     --quality high');
      metadata.writeln('');

      metadata.writeln('FREE SOFTWARE');
      metadata.writeln('-' * 70);
      metadata.writeln('Meshroom (Free, Open Source): https://alicevision.org/');
      metadata.writeln('COLMAP (Free, Open Source): https://colmap.github.io/');
      metadata.writeln('Regard3D (Free, Open Source): http://www.regard3d.org/');
      metadata.writeln('3DF Zephyr Free: https://www.3dflow.net/3df-zephyr-free/');
      metadata.writeln('');
      metadata.writeln('VIEWING & EDITING');
      metadata.writeln('-' * 70);
      metadata.writeln('MeshLab: https://www.meshlab.net/');
      metadata.writeln('CloudCompare: https://www.cloudcompare.org/');
      metadata.writeln('Blender: https://www.blender.org/');
      metadata.writeln('');
      metadata.writeln('HOSTING (FREE)');
      metadata.writeln('-' * 70);
      metadata.writeln('Sketchfab: https://sketchfab.com/');
      metadata.writeln('GitHub Pages + Three.js viewer');
      metadata.writeln('');
      metadata.writeln('=' * 70);
      metadata.writeln('Generated by AncientVision - Professional Photogrammetry System');
      metadata.writeln('=' * 70);

      await File('${exportDir.path}/README.txt').writeAsString(metadata.toString());

      // Create JSON metadata for automated processing
      final jsonMetadata = {
        'generated': DateTime.now().toIso8601String(),
        'findingName': widget.findingName,
        'totalPhotos': _captures.length,
        'averageQuality': avgQuality,
        'captures': _captures.map((c) => {
          'fileName': '${c.angle.name.replaceAll(' ', '_')}_${_captures.indexOf(c) + 1}.jpg',
          'angle': c.angle.angle,
          'elevation': c.angle.elevation,
          'quality': c.qualityScore,
          'timestamp': c.capturedAt.toIso8601String(),
        }).toList(),
      };
      await File('${exportDir.path}/metadata.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(jsonMetadata)
      );

      // Create ZIP archive for easy sharing
      final zipPath = '${directory.path}/photogrammetry_$timestamp.zip';
      try {
        final encoder = ZipFileEncoder();
        encoder.create(zipPath);
        encoder.addDirectory(exportDir);
        encoder.close();
        debugPrint(' ZIP created: $zipPath');
      } catch (e) {
        debugPrint(' ZIP creation failed: $e');
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1C2523),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 28),
                SizedBox(width: 12),
                Text('Export Complete!', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_captures.length} photos exported successfully!',
                  style: TextStyle(color: Colors.white.withAlpha(204)),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C4DFF).withAlpha(51),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Next Steps:',
                        style: TextStyle(color: Color(0xFF7C4DFF), fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '1. Transfer photos to your computer\n'
                        '2. Use Meshroom (free) for 3D reconstruction\n'
                        '3. Upload the 3D model to Sketchfab',
                        style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder, color: Color(0xFFFFC107), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          exportDir.path,
                          style: TextStyle(color: Colors.white.withAlpha(128), fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done', style: TextStyle(color: Color(0xFFFFC107))),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Navigate to 3D viewer with a reconstruction result.
  void _showResultViewer(ReconstructionResult result) {
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Model3DViewer(
          result: result,
          gltfPath: _gltfPath,
          onCompleteForm: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => ManualEntryFormScreen(
                  reconstructionResult: result,
                  photoGallery: _captures.map((c) => c.file).toList(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Generate 3D model — choose cloud or on-device.
  Future<void> _generate3DModel() async {
    if (_captures.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Need at least 4 photos'), backgroundColor: Colors.orange),
      );
      return;
    }

    final method = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            const Text('Create 3D Model', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.cloud_upload_rounded, color: Color(0xFF7C4DFF)),
              title: const Text('Cloud — Reali3 (Best Quality)', style: TextStyle(color: Colors.white)),
              subtitle: Text('1-5 min, requires internet, textured 3D model', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'cloud'),
            ),
            ListTile(
              leading: const Icon(Icons.phone_android_rounded, color: Color(0xFF4CAF50)),
              title: const Text('On-Device (Quick)', style: TextStyle(color: Colors.white)),
              subtitle: Text('1-3 min, works offline', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'device'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (method == null) return;
    if (method == 'cloud') {
      await _generateCloudModel();
    } else {
      await _runOnDeviceReconstruction();
    }
  }

  /// Cloud reconstruction via Reali3 API.
  Future<void> _generateCloudModel() async {
    _incrementalSfm.reset();

    setState(() {
      _isReconstructing = true;
      _reconstructionProgress = 0.0;
      _reconstructionStatus = 'Preparing upload...';
      _incrementalPreviewCloud = null;
      _gltfPath = null;
    });

    try {
      final reali3 = Reali3Service();
      final images = _captures.map((c) => c.file).toList();

      final result = await reali3.reconstruct(
        images: images,
        onProgress: (progress, status) {
          if (mounted) {
            setState(() {
              _reconstructionProgress = progress;
              _reconstructionStatus = status;
            });
          }
        },
      );

      if (!mounted) return;

      if (result.plyPath == null && result.gltfPath == null) {
        setState(() => _isReconstructing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reali3.lastError ?? 'Reconstruction failed'),
            backgroundColor: Colors.orange,
            action: SnackBarAction(
              label: 'Try On-Device',
              textColor: Colors.white,
              onPressed: () => _runOnDeviceReconstruction(),
            ),
          ),
        );
        return;
      }

      // Parse PLY if available
      PointCloud? pointCloud;
      if (result.plyPath != null) {
        final plyData = await File(result.plyPath!).readAsString();
        pointCloud = PointCloud.fromPLY(plyData);
      }

      final reconstructionResult = ReconstructionResult(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        method: ReconstructionMethod.cloudProcessing,
        status: ReconstructionStatus.completed,
        startedAt: DateTime.now(),
        completedAt: DateTime.now(),
        pointCloud: pointCloud,
        inputImageCount: images.length,
      );

      setState(() {
        _isReconstructing = false;
        _gltfPath = result.gltfPath;
        _lastReconstructionResult = reconstructionResult;
      });

      await NotificationService().showProcessingComplete(projectName: 'Reali3 Model');
      _showResultViewer(reconstructionResult);
    } catch (e) {
      if (mounted) {
        setState(() => _isReconstructing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cloud error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// On-device sparse reconstruction with optional validation.
  Future<void> _runOnDeviceReconstruction({bool validate = true}) async {
    final imageFiles = _captures.map((c) => File(c.file.path)).toList();
    _incrementalSfm.reset();

    setState(() {
      _isReconstructing = true;
      _reconstructionProgress = 0.0;
      _reconstructionStatus = 'Validating photos...';
      _incrementalPreviewCloud = null;
    });

    try {
      // Optional validation
      if (validate) {
        final validation = await _reconstructionService.validatePhotosForReconstruction(imageFiles);
        if (validation['warnings'].isNotEmpty || validation['recommendedFixes'].isNotEmpty) {
          final issues = <String>[
            ...(validation['errors'] as List).cast<String>(),
            ...(validation['warnings'] as List).cast<String>(),
          ];
          if (issues.isNotEmpty && mounted) {
            final shouldContinue = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1C2523),
                title: const Text('Quality Check', style: TextStyle(color: Colors.white)),
                content: Text(
                  issues.join('\n'),
                  style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                  ),
                  if (validation['isValid'] as bool)
                    ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7C4DFF)),
                      child: const Text('Continue'),
                    ),
                ],
              ),
            );
            if (shouldContinue != true) {
              setState(() => _isReconstructing = false);
              return;
            }
          }
        }
      }

      setState(() {
        _reconstructionProgress = 0.1;
        _reconstructionStatus = 'Reconstructing...';
      });

      final result = await _reconstructionService.generateSparsePreview(
        imageFiles: imageFiles,
        onProgress: (progress, status) {
          if (mounted) {
            setState(() {
              _reconstructionProgress = progress;
              _reconstructionStatus = status;
            });
          }
        },
      ).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('Reconstruction timed out after 60s'),
      );

      setState(() {
        _isReconstructing = false;
        if (result.isComplete) _lastReconstructionResult = result;
      });

      if (result.isComplete) {
        await _reconstructionService.persistResult(result);
        await NotificationService().showProcessingComplete(
          projectName: 'On-Device Model',
          pointCount: result.pointCount,
        );

        if (mounted) {
          final grade = result.qualityMetrics['quality_grade'] as String?;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${result.pointCount} points${grade != null ? " [$grade]" : ""}'),
              backgroundColor: const Color(0xFF4CAF50),
              duration: const Duration(seconds: 3),
            ),
          );
          _showResultViewer(result);

          // Auto-enhance to dense in background
          if (result.pointCount > 50) {
            _enhanceToDense(result);
          }
        }
      } else if (result.hasFailed && mounted) {
        await NotificationService().showProcessingFailed(
          projectName: 'On-Device Model',
          errorMessage: result.errorMessage,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${result.errorMessage}'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      setState(() => _isReconstructing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Enhance sparse result to dense (background, no navigation — just notifies).
  Future<void> _enhanceToDense(ReconstructionResult sparseResult) async {
    final imageFiles = _captures.map((c) => File(c.file.path)).toList();

    setState(() {
      _isDenseReconstructing = true;
      _denseProgress = 0.0;
      _denseStatus = 'Starting dense reconstruction...';
    });

    try {
      final denseResult = await _denseService.reconstruct(
        imageFiles: imageFiles,
        poses: sparseResult.cameraPoses ?? [],
        focalLength: sparseResult.qualityMetrics['focal_length']?.toDouble() ?? 800.0,
        onProgress: (progress, status) {
          if (mounted) {
            setState(() {
              _denseProgress = progress;
              _denseStatus = status;
            });
          }
        },
      );

      setState(() => _isDenseReconstructing = false);

      if (mounted && denseResult.pointCloud.points.isNotEmpty) {
        final result = ReconstructionResult(
          id: 'dense_${DateTime.now().millisecondsSinceEpoch}',
          method: ReconstructionMethod.denseMVS,
          status: ReconstructionStatus.completed,
          pointCloud: denseResult.pointCloud,
          mesh: denseResult.mesh,
          inputImageCount: imageFiles.length,
          processingTimeSeconds: denseResult.processingTime.inMilliseconds / 1000.0,
          qualityMetrics: {
            'depth_maps': denseResult.depthMapsComputed,
            'dense_points': denseResult.pointCloud.points.length,
          },
        );
        _lastReconstructionResult = result;

        // Notify user — don't push another viewer on top
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Dense model ready (${denseResult.pointCloud.points.length} points)'),
            backgroundColor: const Color(0xFF00E5FF),
            action: SnackBarAction(
              label: 'View',
              textColor: Colors.white,
              onPressed: () => _showResultViewer(result),
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _isDenseReconstructing = false);
      debugPrint('Dense reconstruction failed: $e');
    }
  }

  /// Show metadata export options dialog
  Future<void> _showMetadataExportDialog(ReconstructionResult result) async {
    final format = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Export Metadata', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description, color: Color(0xFF00BCD4)),
              title: const Text('Dublin Core XML', style: TextStyle(color: Colors.white)),
              subtitle: Text('Standard library metadata', style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
              onTap: () => Navigator.pop(ctx, 'dublin_core'),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance, color: Color(0xFF7C4DFF)),
              title: const Text('CIDOC-CRM RDF/XML', style: TextStyle(color: Colors.white)),
              subtitle: Text('ISO 21127 heritage standard', style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
              onTap: () => Navigator.pop(ctx, 'cidoc_crm'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );

    if (format == null || !mounted) return;

    try {
      final id = result.id;
      final title = widget.findingName ?? 'Archaeological Finding';
      final date = result.startedAt;
      final lat = result.qualityMetrics['gps_latitude'] as double?;
      final lon = result.qualityMetrics['gps_longitude'] as double?;
      final grade = result.qualityMetrics['quality_grade'] as String?;

      String xml;
      String filename;

      if (format == 'dublin_core') {
        xml = MetadataExportService.exportDublinCore(
          id: id,
          title: title,
          description: 'Photogrammetric reconstruction with ${result.pointCount} points. '
              'Quality: ${grade ?? "unknown"}.',
          date: date,
          latitude: lat,
          longitude: lon,
          additionalFields: {
            'source': 'AncientVision on-device photogrammetry',
            if (grade != null) 'quality': grade,
          },
        );
        filename = 'finding_${id.substring(0, 8)}_dublin_core.xml';
      } else {
        xml = MetadataExportService.exportCidocCRM(
          id: id,
          title: title,
          description: 'Photogrammetric reconstruction with ${result.pointCount} points. '
              'Quality: ${grade ?? "unknown"}.',
          objectType: 'Archaeological Object',
          dateFound: date,
          latitude: lat,
          longitude: lon,
          additionalProperties: {
            'reconstruction_method': result.methodName,
            'point_count': result.pointCount.toString(),
            if (grade != null) 'quality_grade': grade,
          },
        );
        filename = 'finding_${id.substring(0, 8)}_cidoc_crm.xml';
      }

      // Save to app documents directory
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsString(xml);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported: $filename'),
            backgroundColor: const Color(0xFF4CAF50),
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showTutorial) {
      return _buildTutorialScreen();
    }
    return _buildCaptureScreen();
  }

  Widget _buildTutorialScreen() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D3A39), Color(0xFF1C2523)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Header
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    const Expanded(
                      child: Text(
                        'Photogrammetry Capture',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 32),

                // 3D Icon
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C4DFF).withAlpha(51),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF7C4DFF), width: 3),
                  ),
                  child: const Icon(Icons.view_in_ar, color: Color(0xFF7C4DFF), size: 60),
                ),
                const SizedBox(height: 32),

                const Text(
                  'Create 3D Models from Photos',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'Photogrammetry creates accurate 3D models by analyzing multiple photos taken from different angles.',
                  style: TextStyle(
                    color: Colors.white.withAlpha(179),
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // Tips
                Expanded(
                  child: ListView(
                    children: [
                      _buildTipCard(
                        Icons.wb_sunny_outlined,
                        'Good Lighting',
                        'Use natural, diffused light. Avoid harsh shadows and direct sunlight.',
                        const Color(0xFFFFC107),
                      ),
                      _buildTipCard(
                        Icons.rotate_90_degrees_ccw,
                        '360° Coverage',
                        'Capture photos from all angles: front, back, sides, and top views.',
                        const Color(0xFF4CAF50),
                      ),
                      _buildTipCard(
                        Icons.blur_off,
                        'Sharp Focus',
                        'Keep the camera steady. Wait for focus before capturing.',
                        const Color(0xFF2196F3),
                      ),
                      _buildTipCard(
                        Icons.photo_size_select_large,
                        '50-70% Overlap',
                        'Each photo should overlap with adjacent photos for best results.',
                        const Color(0xFFE91E63),
                      ),
                    ],
                  ),
                ),

                // Start button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool(_tutorialSeenKey, true);
                      if (mounted) setState(() => _showTutorial = false);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C4DFF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt),
                        SizedBox(width: 8),
                        Text('Start Capture Session', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTipCard(IconData icon, String title, String description, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(77)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withAlpha(51),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 4),
                Text(description, style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureScreen() {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0D3A39), Color(0xFF1C2523)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  // --- Header ---
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                        ),
                        Expanded(
                          child: Text(
                            widget.findingName ?? 'Photogrammetry',
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert, color: Colors.white54),
                          color: const Color(0xFF1C2523),
                          onSelected: (value) {
                            switch (value) {
                              case 'export':
                                _exportPhotos();
                              case 'metadata':
                                if (_lastReconstructionResult != null) {
                                  _showMetadataExportDialog(_lastReconstructionResult!);
                                }
                              case 'voice':
                                setState(() => _voiceEnabled = !_voiceEnabled);
                                if (_voiceEnabled) {
                                  _startListening();
                                  _speak('Voice commands enabled');
                                } else {
                                  _stopListening();
                                }
                              case 'preview':
                                setState(() => _showIncrementalPreview = !_showIncrementalPreview);
                              case 'help':
                                setState(() => _showTutorial = true);
                            }
                          },
                          itemBuilder: (_) => [
                            if (_captures.isNotEmpty)
                              const PopupMenuItem(value: 'export', child: Text('Export Photos', style: TextStyle(color: Colors.white))),
                            if (_lastReconstructionResult != null)
                              const PopupMenuItem(value: 'metadata', child: Text('Export Metadata', style: TextStyle(color: Colors.white))),
                            PopupMenuItem(
                              value: 'voice',
                              child: Text(
                                _voiceEnabled ? 'Voice OFF' : 'Voice ON',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'preview',
                              child: Text(
                                _showIncrementalPreview ? '3D Preview OFF' : '3D Preview ON',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            const PopupMenuItem(value: 'help', child: Text('Help', style: TextStyle(color: Colors.white))),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // --- Progress bar ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${_captures.length} / ${_captureAngles.length}',
                              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            if (!_isComplete)
                              Text(
                                _currentAngle.name,
                                style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 13),
                              ),
                            if (_isComplete)
                              const Text('Complete', style: TextStyle(color: Color(0xFF4CAF50), fontSize: 13, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _progress,
                            backgroundColor: Colors.white.withAlpha(30),
                            valueColor: AlwaysStoppedAnimation(
                              _isComplete ? const Color(0xFF4CAF50) : const Color(0xFF7C4DFF),
                            ),
                            minHeight: 6,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // --- Angle instruction ---
                  if (!_isComplete)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                      child: Text(
                        _getAngleInstruction(_currentAngle),
                        style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  // --- Photo grid ---
                  Expanded(
                    child: _captures.isEmpty
                        ? Center(
                            child: Text(
                              'Tap the button below to capture',
                              style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 14),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.all(12),
                            child: GridView.builder(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 6,
                                crossAxisSpacing: 6,
                              ),
                              itemCount: _captures.length,
                              itemBuilder: (context, index) {
                                final capture = _captures[index];
                                return GestureDetector(
                                  onTap: () => _showPhotoOptions(index),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.file(File(capture.file.path), fit: BoxFit.cover),
                                      ),
                                      // Quality dot
                                      Positioned(
                                        top: 3,
                                        right: 3,
                                        child: Container(
                                          width: 10,
                                          height: 10,
                                          decoration: BoxDecoration(
                                            color: capture.qualityScore >= 0.8
                                                ? const Color(0xFF4CAF50)
                                                : capture.qualityScore >= 0.6
                                                    ? const Color(0xFFFFC107)
                                                    : Colors.orange,
                                            shape: BoxShape.circle,
                                            border: Border.all(color: Colors.white, width: 1),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                  ),

                  // --- Capture controls ---
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!_isComplete && _currentAngleIndex > 0)
                          TextButton(
                            onPressed: () => setState(() => _currentAngleIndex--),
                            child: const Text('Back', style: TextStyle(color: Colors.white54)),
                          ),
                        const SizedBox(width: 16),
                        // Main capture button
                        GestureDetector(
                          onTap: _isCapturing ? null : _capturePhoto,
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: _isCapturing ? Colors.grey : const Color(0xFF7C4DFF),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF7C4DFF).withAlpha(80),
                                  blurRadius: 16,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: _isCapturing
                                ? const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                                : const Icon(Icons.camera_alt, color: Colors.white, size: 32),
                          ),
                        ),
                        const SizedBox(width: 16),
                        if (!_isComplete && _captures.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              if (_currentAngleIndex < _captureAngles.length - 1) {
                                setState(() => _currentAngleIndex++);
                              }
                            },
                            child: const Text('Skip', style: TextStyle(color: Colors.white54)),
                          ),
                      ],
                    ),
                  ),

                  // --- Reconstruct button ---
                  if (_canGenerate)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isReconstructing ? null : _generate3DModel,
                          icon: const Icon(Icons.view_in_ar, size: 22),
                          label: Text(
                            _isComplete ? 'Create 3D Model' : 'Create 3D Model (${_captures.length} photos)',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7C4DFF),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Incremental SfM mini preview
          if (_showIncrementalPreview && _incrementalPreviewCloud != null && _incrementalPreviewCloud!.points.isNotEmpty)
            Positioned(
              bottom: _canGenerate ? 100 : 20,
              right: 12,
              child: GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => Model3DViewer(
                        result: ReconstructionResult(
                          id: 'incremental-preview',
                          method: ReconstructionMethod.sparseSfM,
                          status: ReconstructionStatus.completed,
                          pointCloud: _incrementalPreviewCloud!,
                          inputImageCount: _captures.length,
                        ),
                      ),
                    ),
                  );
                },
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF7C4DFF), width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      children: [
                        PointCloudViewer(
                          pointCloud: _incrementalPreviewCloud!,
                          initialPointSize: 2.0,
                        ),
                        Positioned(
                          bottom: 3,
                          left: 3,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '${_incrementalPreviewCloud!.points.length} pts',
                              style: const TextStyle(color: Colors.white, fontSize: 8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Reconstruction progress overlay
          if (_isReconstructing)
            Container(
              color: Colors.black87,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReconstructionProgressWidget(
                        progress: _reconstructionProgress,
                        statusMessage: _reconstructionStatus,
                        isProcessing: _isReconstructing,
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () {
                          _reconstructionService.cancelReconstruction();
                          setState(() => _isReconstructing = false);
                        },
                        child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Dense reconstruction progress overlay
          if (_isDenseReconstructing)
            Container(
              color: Colors.black87,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.auto_awesome, color: Color(0xFF00E5FF), size: 48),
                      const SizedBox(height: 16),
                      const Text('Enhancing to Dense',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_denseStatus, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: _denseProgress,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation(Color(0xFF00E5FF)),
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('${(_denseProgress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getAngleInstruction(CaptureAngle angle) {
    if (angle.isDetail) {
      return 'Get close for a detailed shot of interesting features';
    }
    if (angle.elevation >= 70) {
      return 'Position camera directly above the object';
    }
    if (angle.elevation >= 40) {
      return 'Angle camera down at ~45° from ${angle.angle}°';
    }
    return 'Position at ${angle.angle}° around the object at eye level';
  }

  void _showPhotoOptions(int index) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _captures[index].angle.name,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              'Quality: ${(_captures[index].qualityScore * 100).toInt()}%',
              style: TextStyle(color: Colors.white.withAlpha(153)),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _retakePhoto(index);
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retake'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFFC107),
                      side: const BorderSide(color: Color(0xFFFFC107)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _deletePhoto(index);
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// Custom painter for the angle progress ring
