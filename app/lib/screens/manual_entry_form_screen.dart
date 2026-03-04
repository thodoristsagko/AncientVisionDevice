// ignore_for_file: use_build_context_synchronously
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/local_storage_service.dart';
import '../services/image_service.dart';
import '../services/site_service.dart';
import '../services/critical_event_log_service.dart';
import '../models/reconstruction_result.dart';
import '../config/env_config.dart';

class ManualEntryFormScreen extends StatefulWidget {
  final ReconstructionResult? reconstructionResult;
  final List<XFile>? photoGallery;
  final String? cloudModelUrl;

  const ManualEntryFormScreen({
    super.key,
    this.reconstructionResult,
    this.photoGallery,
    this.cloudModelUrl,
  });

  @override
  State<ManualEntryFormScreen> createState() => _ManualEntryFormScreenState();
}

class _ManualEntryFormScreenState extends State<ManualEntryFormScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _typeController = TextEditingController();
  final _siteController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _dateController = TextEditingController();
  final _latController = TextEditingController();
  final _lngController = TextEditingController();
  bool _hasImage = false;
  XFile? _selectedImage;
  final ImagePicker _imagePicker = ImagePicker();
  final List<XFile> _photoGallery = [];
  String _nextId = 'A-001';
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isSignificant = false;
  bool _isGettingLocation = false;
  bool _isListening = false;
  late AnimationController _micPulseController;
  final _stt = SpeechToText();

  // Auto-save functionality
  Timer? _autoSaveTimer;
  Timer? _editDebounceTimer;

  // Location field focus node — used for auto-suggest GPS on focus
  final FocusNode _locationFocusNode = FocusNode();

  // PPV at discovery — captured from last CriticalEvent when form is opened
  double? _ppvAtDiscovery;
  String _anomalyLevelAtDiscovery = 'Unknown';

  // Whether an explicit "Save Draft" action is in progress
  bool _isSavingDraft = false;

  // Random example hints
  late String _nameHint;
  late String _typeHint;
  late String _siteHint;

  static const _nameTypePairs = [
    {'name': 'Bronze Coin', 'type': 'Coin'},
    {'name': 'Ceramic Vase', 'type': 'Pottery'},
    {'name': 'Marble Statue', 'type': 'Sculpture'},
    {'name': 'Iron Chisel', 'type': 'Tool'},
    {'name': 'Gold Ring', 'type': 'Jewelry'},
    {'name': 'Bronze Sword', 'type': 'Weapon'},
    {'name': 'Stone Tablet', 'type': 'Inscription'},
    {'name': 'Bone Comb', 'type': 'Organic'},
  ];

  static const _siteExamples = ['Trench A1', 'Grid 12-N', 'North Wall'];

  @override
  void initState() {
    super.initState();
    _micPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _loadNextId();
    _generateRandomHints();
    // Set today's date as default
    final now = DateTime.now();
    _dateController.text = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    // Initialize with data from photogrammetry if available
    if (widget.photoGallery != null && widget.photoGallery!.isNotEmpty) {
      _photoGallery.addAll(widget.photoGallery!);
    }

    // Load draft if exists
    _loadDraft();

    // Capture PPV / anomaly level at the moment the form is opened.
    _capturePpvAtDiscovery();

    // Auto-suggest GPS when the location section gains focus (lat field).
    _locationFocusNode.addListener(() {
      if (_locationFocusNode.hasFocus &&
          _latController.text.isEmpty &&
          _lngController.text.isEmpty &&
          !_isGettingLocation) {
        _getCurrentLocation();
      }
    });

    // Pre-fill site from active site (only if draft didn't set it)
    SiteService().getActiveSite().then((site) {
      if (mounted && site.isNotEmpty && _siteController.text.isEmpty) {
        setState(() => _siteController.text = site);
      }
    });

    // Setup auto-save (saves every 30 seconds)
    _autoSaveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _autoSave();
    });

    // Add listeners to controllers for auto-save
    _nameController.addListener(_scheduleAutoSave);
    _typeController.addListener(_scheduleAutoSave);
    _siteController.addListener(_scheduleAutoSave);
  }

  void _scheduleAutoSave() {
    // Schedule auto-save for 2 seconds after last edit (separate from periodic timer)
    _editDebounceTimer?.cancel();
    _editDebounceTimer = Timer(const Duration(seconds: 2), _autoSave);
  }

  Future<void> _autoSave() async {
    if (_nameController.text.isEmpty && _typeController.text.isEmpty) {
      return; // Don't save empty forms
    }

    final storage = LocalStorageService();
    await storage.saveFormDraft(
      formId: 'manual_entry',
      data: {
        'name': _nameController.text,
        'type': _typeController.text,
        'site': _siteController.text,
        'description': _descriptionController.text,
        'date': _dateController.text,
        'latitude': _latController.text,
        'longitude': _lngController.text,
      },
    );
  }

  Future<void> _loadDraft() async {
    final storage = LocalStorageService();
    final draft = storage.getFormDraft('manual_entry');
    if (draft != null && mounted) {
      setState(() {
        _nameController.text = draft['name'] ?? '';
        _typeController.text = draft['type'] ?? '';
        _siteController.text = draft['site'] ?? '';
        _descriptionController.text = draft['description'] ?? '';
        if (draft['date'] != null && (draft['date'] as String).isNotEmpty) {
          _dateController.text = draft['date'];
        }
        _latController.text = draft['latitude'] ?? '';
        _lngController.text = draft['longitude'] ?? '';
      });

      // Show notification (post-frame to avoid initState context issue)
      if (_nameController.text.isNotEmpty || _typeController.text.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Draft restored'),
                backgroundColor: Color(0xFF2196F3),
                duration: Duration(seconds: 2),
              ),
            );
          }
        });
      }
    }
  }

  void _generateRandomHints() {
    final random = Random();
    // Pick a matching name-type pair
    final pair = _nameTypePairs[random.nextInt(_nameTypePairs.length)];
    _nameHint = 'e.g., ${pair['name']}';
    _typeHint = 'e.g., ${pair['type']}';
    _siteHint = 'e.g., ${_siteExamples[random.nextInt(_siteExamples.length)]}';
  }

  // Get current GPS location
  Future<void> _getCurrentLocation() async {
    setState(() => _isGettingLocation = true);

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Location services are disabled. Please enable GPS.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        setState(() => _isGettingLocation = false);
        return;
      }

      // Check permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Location permission denied'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          setState(() => _isGettingLocation = false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Location permissions are permanently denied'),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() => _isGettingLocation = false);
        return;
      }

      // Get current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _latController.text = position.latitude.toStringAsFixed(6);
        _lngController.text = position.longitude.toStringAsFixed(6);
        _isGettingLocation = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location captured successfully!'),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      setState(() => _isGettingLocation = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error getting location: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Pick image from camera
  Future<void> _pickFromCamera() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (image != null) {
        setState(() {
          _selectedImage = image;
          _hasImage = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Photo captured successfully!'),
              backgroundColor: Color(0xFF4CAF50),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error capturing photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Pick image from gallery
  Future<void> _pickFromGallery() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (image != null) {
        setState(() {
          _selectedImage = image;
          _hasImage = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image selected successfully!'),
              backgroundColor: Color(0xFF4CAF50),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error selecting image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Load next ID from Firestore by scanning all documents
  Future<void> _loadNextId() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('findings')
          .get();

      if (snapshot.docs.isEmpty) {
        if (mounted) {
          setState(() {
            _nextId = 'A-001';
            _isLoading = false;
          });
        }
        return;
      }

      // Find the highest ID number from all documents
      int maxNum = 0;
      for (final doc in snapshot.docs) {
        // Check document ID first
        var match = RegExp(r'A-(\d+)').firstMatch(doc.id);
        if (match != null) {
          final num = int.parse(match.group(1)!);
          if (num > maxNum) {
            maxNum = num;
          }
        }

        // Also check 'id' field inside the document
        final data = doc.data() as Map<String, dynamic>?;
        if (data != null && data['id'] != null) {
          match = RegExp(r'A-(\d+)').firstMatch(data['id'].toString());
          if (match != null) {
            final num = int.parse(match.group(1)!);
            if (num > maxNum) {
              maxNum = num;
            }
          }
        }
      }

      // If no matching IDs found, use document count as fallback
      if (maxNum == 0) {
        maxNum = snapshot.docs.length;
      }

      if (mounted) {
        setState(() {
          _nextId = 'A-${(maxNum + 1).toString().padLeft(3, '0')}';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _nextId = 'A-001';
          _isLoading = false;
        });
      }
    }
  }

  // Backup findings to local file
  Future<void> _backupFindings() async {
    try {
      // Get all findings
      final snapshot = await FirebaseFirestore.instance
          .collection('findings')
          .get();

      if (snapshot.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No findings to backup'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Create backup data
      final backupData = snapshot.docs.map((doc) {
        final data = doc.data();
        data['documentId'] = doc.id;
        return data;
      }).toList();

      // Save to local file
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${directory.path}/findings_backup_$timestamp.json');
      await file.writeAsString(jsonEncode(backupData));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backed up ${snapshot.docs.length} findings.\nSaved to: ${file.path}'),
            backgroundColor: const Color(0xFF4CAF50),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Save finding to Firestore
  Future<void> _saveFinding() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    // Parse coordinates from controllers, fallback to defaults if empty
    final lat = double.tryParse(_latController.text) ?? 0.0;
    final lng = double.tryParse(_lngController.text) ?? 0.0;

    try {

      // Upload image to ImgBB and get URL
      String? imageUrl;
      if (_selectedImage != null) {
        try {
          // Compress image for 10x faster upload
          final imageService = ImageService();
          final compressedFile = await imageService.compressImage(
            File(_selectedImage!.path),
            maxWidth: 1920,
            maxHeight: 1920,
            quality: 85,
          );

          final bytes = await compressedFile.readAsBytes();
          final base64Image = base64Encode(bytes);

          final response = await http.post(
            Uri.parse('https://api.imgbb.com/1/upload'),
            body: {
              'key': EnvConfig.imgbbApiKey,
              'image': base64Image,
              'name': _nextId,
            },
          ).timeout(const Duration(seconds: 30));

          debugPrint('ImgBB response: ${response.statusCode}');
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['success'] == true) {
              imageUrl = data['data']['url'];
              debugPrint('Image uploaded: $imageUrl');
            }
          } else {
            debugPrint('ImgBB error: ${response.body}');
          }
        } catch (e) {
          debugPrint('Image upload failed: $e');
        }
      }

      // Upload photo gallery images for photogrammetry
      List<String> galleryUrls = [];
      if (_photoGallery.isNotEmpty) {
        final imageService = ImageService();
        for (int i = 0; i < _photoGallery.length; i++) {
          try {
            // Compress for faster upload (critical for multiple images)
            final compressedFile = await imageService.compressImage(
              File(_photoGallery[i].path),
              maxWidth: 1920,
              maxHeight: 1920,
              quality: 85,
            );

            final bytes = await compressedFile.readAsBytes();
            final base64Image = base64Encode(bytes);
            final response = await http.post(
              Uri.parse('https://api.imgbb.com/1/upload'),
              body: {
                'key': EnvConfig.imgbbApiKey,
                'image': base64Image,
                'name': '${_nextId}_photo_$i',
              },
            ).timeout(const Duration(seconds: 30));

            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              if (data['success'] == true) {
                galleryUrls.add(data['data']['url']);
              }
            }
          } catch (e) {
            debugPrint('Gallery photo $i upload failed: $e');
          }
        }
      }

      // Get 3D model data from reconstruction result if available
      String? model3dUrl;
      Map<String, dynamic>? reconstructionData;

      if (widget.reconstructionResult != null) {
        final result = widget.reconstructionResult!;
        // Save reconstruction metadata
        reconstructionData = {
          'pointCount': result.pointCount,
          'processingTimeSeconds': result.processingTimeSeconds,
          'method': result.isSparse ? 'Sparse SfM (RANSAC)' : 'Dense SfM',
          'qualityMetrics': result.qualityMetrics,
          'inputImageCount': result.inputImageCount,
        };
      }

      // Determine source based on how the form was opened
      final source = widget.photoGallery != null || widget.reconstructionResult != null
          ? 'photo'
          : 'manual';

      final findingData = {
        'name': _nameController.text,
        'type': _typeController.text,
        'site': _siteController.text,
        'date': _dateController.text,
        'description': _descriptionController.text,
        'latitude': lat,
        'longitude': lng,
        'imageUrl': imageUrl,
        'photoGallery': galleryUrls,
        'model3dUrl': model3dUrl,
        'reconstructionData': reconstructionData,
        'createdAt': FieldValue.serverTimestamp(),
        'source': source,
        'isSignificant': _isSignificant,
      };

      try {
        // Try to save to Firebase
        await FirebaseFirestore.instance
            .collection('findings')
            .doc(_nextId)
            .set(findingData)
            .timeout(const Duration(seconds: 15));

        // Success - clear draft and cache locally
        final storage = LocalStorageService();
        await storage.clearFormDraft('manual_entry');
        await storage.cacheFinding(findingId: _nextId, data: findingData);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ Finding $_nextId saved successfully!'),
              backgroundColor: const Color(0xFF4CAF50),
            ),
          );
          Navigator.pop(context);
        }
      } on FirebaseException catch (e) {
        // Firebase error - save offline
        final storage = LocalStorageService();
        await storage.queueForUpload(findingId: _nextId, data: findingData);
        await storage.cacheFinding(findingId: _nextId, data: findingData);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('📱 Saved offline - will sync when online\n${e.message}'),
              backgroundColor: const Color(0xFFFFC107),
              duration: const Duration(seconds: 4),
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      // General error - try to save offline
      try {
        final storage = LocalStorageService();
        final findingData = {
          'name': _nameController.text,
          'type': _typeController.text,
          'site': _siteController.text,
          'date': _dateController.text,
          'description': _descriptionController.text,
          'latitude': lat,
          'longitude': lng,
          'createdAt': DateTime.now().toIso8601String(),
          'source': 'manual',
        };
        await storage.queueForUpload(findingId: _nextId, data: findingData);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('📱 Saved offline - will sync when online'),
              backgroundColor: Color(0xFFFFC107),
              duration: Duration(seconds: 3),
            ),
          );
          Navigator.pop(context);
        }
      } catch (offlineError) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠️ Error: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// Read the most recent PPV from the last CRITICAL event (if any) and
  /// snapshot it as the vibration context at time of discovery entry.
  Future<void> _capturePpvAtDiscovery() async {
    try {
      final events = CriticalEventLogService.instance.events;
      if (events.isNotEmpty) {
        final last = events.first; // newest first
        final age = DateTime.now().difference(last.timestamp);
        // Only use if the event is within the last 30 minutes (still relevant).
        if (age.inMinutes <= 30) {
          if (mounted) {
            setState(() {
              _ppvAtDiscovery = last.ppv;
              // Derive a simple risk label from PPV.
              if (last.ppv >= 2.0) {
                _anomalyLevelAtDiscovery = 'CRITICAL';
              } else if (last.ppv >= 0.5) {
                _anomalyLevelAtDiscovery = 'ANOMALY';
              } else if (last.ppv >= 0.1) {
                _anomalyLevelAtDiscovery = 'UNUSUAL';
              } else {
                _anomalyLevelAtDiscovery = 'NORMAL';
              }
            });
          }
        }
      }
    } catch (_) {
      // Non-critical — form works without PPV data.
    }
  }

  /// Explicitly save the current form data as a draft (user-initiated).
  Future<void> _saveDraftExplicitly() async {
    if (_nameController.text.isEmpty && _typeController.text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter at least a name or type before saving draft'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() => _isSavingDraft = true);
    try {
      await _autoSave();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Draft saved'),
            backgroundColor: Color(0xFF2196F3),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingDraft = false);
    }
  }

  Future<void> _toggleVoice() async {
    if (_isListening) {
      await _stt.stop();
      if (mounted) setState(() => _isListening = false);
      _micPulseController.stop();
      return;
    }
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required for voice input')),
        );
      }
      return;
    }
    final available = await _stt.initialize(
      onError: (_) {
        if (mounted) setState(() => _isListening = false);
        _micPulseController.stop();
      },
    );
    if (!available) return;
    if (mounted) setState(() => _isListening = true);
    _micPulseController.repeat(reverse: true);
    await _stt.listen(
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          final current = _descriptionController.text;
          _descriptionController.text = current.isEmpty
              ? result.recognizedWords
              : '$current ${result.recognizedWords}';
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
    );
    if (mounted) setState(() => _isListening = false);
    _micPulseController.stop();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _editDebounceTimer?.cancel();
    _locationFocusNode.dispose();
    _nameController.dispose();
    _typeController.dispose();
    _siteController.dispose();
    _descriptionController.dispose();
    _dateController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _micPulseController.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0D3A39),
              Color(0xFF1C2523),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // HEADER WITH BACK BUTTON
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(26),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withAlpha(77),
                              width: 1,
                            ),
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Text(
                          'Manual Entry',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      // Backup button
                      GestureDetector(
                        onTap: () {
                          _backupFindings();
                        },
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFC107).withAlpha(51),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFFFC107).withAlpha(128),
                              width: 1,
                            ),
                          ),
                          child: const Icon(
                            Icons.download_rounded,
                            color: Color(0xFFFFC107),
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Add a new finding to the database',
                    style: TextStyle(
                      color: Colors.white.withAlpha(191),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // AUTO-GENERATED ID DISPLAY
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withAlpha(89),
                            width: 1,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white.withAlpha(26),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.tag_rounded,
                                  color: Color(0xFFFFC107),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'ID',
                                          style: TextStyle(
                                            color: Colors.white.withAlpha(179),
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFFC107).withAlpha(51),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Text(
                                            'Auto',
                                            style: TextStyle(
                                              color: Color(0xFFFFC107),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    _isLoading
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Color(0xFFFFC107),
                                            ),
                                          )
                                        : Text(
                                            _nextId,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                            ),
                                          ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // FORM FIELDS
                  _buildFormField(
                    controller: _nameController,
                    label: 'Name',
                    hint: _nameHint,
                    icon: Icons.inventory_2_outlined,
                  ),
                  const SizedBox(height: 16),
                  _buildFormField(
                    controller: _typeController,
                    label: 'Type',
                    hint: _typeHint,
                    icon: Icons.category_outlined,
                  ),
                  const SizedBox(height: 16),
                  _buildFormField(
                    controller: _siteController,
                    label: 'Site',
                    hint: _siteHint,
                    icon: Icons.location_on_outlined,
                  ),
                  const SizedBox(height: 16),
                  _buildFormField(
                    controller: _descriptionController,
                    label: 'Description',
                    hint: 'e.g., Fragment with geometric patterns',
                    icon: Icons.description_outlined,
                    maxLines: 3,
                    isRequired: false,
                    suffixIcon: AnimatedBuilder(
                      animation: _micPulseController,
                      builder: (_, __) => IconButton(
                        icon: Icon(
                          _isListening ? Icons.mic : Icons.mic_none,
                          color: _isListening
                              ? Color.lerp(const Color(0xFFE53935), const Color(0xFFFFC107),
                                  _micPulseController.value)!
                              : Colors.white54,
                        ),
                        onPressed: _toggleVoice,
                        tooltip: _isListening ? 'Stop listening' : 'Voice input',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildFormField(
                    controller: _dateController,
                    label: 'Date',
                    hint: 'e.g., ${_dateController.text}',
                    icon: Icons.calendar_today_outlined,
                  ),

                  const SizedBox(height: 16),

                  // COORDINATES SECTION
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withAlpha(89),
                            width: 1,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withAlpha(26),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(
                                      Icons.my_location_rounded,
                                      color: Color(0xFFFFC107),
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              'Coordinates',
                                              style: TextStyle(
                                                color: Colors.white.withAlpha(179),
                                                fontSize: 12,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Colors.white.withAlpha(26),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                'Optional',
                                                style: TextStyle(
                                                  color: Colors.white.withAlpha(128),
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _latController.text.isEmpty && _lngController.text.isEmpty
                                              ? 'No location set'
                                              : 'Location set',
                                          style: TextStyle(
                                            color: _latController.text.isEmpty && _lngController.text.isEmpty
                                                ? Colors.white.withAlpha(102)
                                                : Colors.white,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              // Latitude field
                              Row(
                                children: [
                                  SizedBox(
                                    width: 80,
                                    child: Text(
                                      'Latitude',
                                      style: TextStyle(
                                        color: Colors.white.withAlpha(179),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withAlpha(26),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.white.withAlpha(51),
                                          width: 1,
                                        ),
                                      ),
                                      child: TextField(
                                        controller: _latController,
                                        focusNode: _locationFocusNode,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                        ),
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                        decoration: InputDecoration(
                                          hintText: 'e.g., 37.9715',
                                          hintStyle: TextStyle(
                                            color: Colors.white.withAlpha(102),
                                            fontSize: 14,
                                          ),
                                          border: InputBorder.none,
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              // Longitude field
                              Row(
                                children: [
                                  SizedBox(
                                    width: 80,
                                    child: Text(
                                      'Longitude',
                                      style: TextStyle(
                                        color: Colors.white.withAlpha(179),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withAlpha(26),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.white.withAlpha(51),
                                          width: 1,
                                        ),
                                      ),
                                      child: TextField(
                                        controller: _lngController,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                        ),
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                        decoration: InputDecoration(
                                          hintText: 'e.g., 23.7267',
                                          hintStyle: TextStyle(
                                            color: Colors.white.withAlpha(102),
                                            fontSize: 14,
                                          ),
                                          border: InputBorder.none,
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              // Use GPS button
                              GestureDetector(
                                onTap: _isGettingLocation ? null : _getCurrentLocation,
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFC107).withAlpha(51),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0xFFFFC107).withAlpha(128),
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _isGettingLocation
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Color(0xFFFFC107),
                                              ),
                                            )
                                          : const Icon(
                                              Icons.gps_fixed_rounded,
                                              color: Color(0xFFFFC107),
                                              size: 18,
                                            ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _isGettingLocation ? 'Getting Location...' : 'Use GPS',
                                        style: const TextStyle(
                                          color: Color(0xFFFFC107),
                                          fontSize: 14,
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
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // OPTIONAL PICTURE FIELD
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(26),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withAlpha(89),
                            width: 1,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withAlpha(26),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(
                                      Icons.photo_camera_outlined,
                                      color: Color(0xFFFFC107),
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              'Picture',
                                              style: TextStyle(
                                                color: Colors.white.withAlpha(179),
                                                fontSize: 12,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Colors.white.withAlpha(26),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                'Optional',
                                                style: TextStyle(
                                                  color: Colors.white.withAlpha(128),
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _hasImage ? 'Image selected' : 'No image selected',
                                          style: TextStyle(
                                            color: _hasImage ? Colors.white : Colors.white.withAlpha(102),
                                            fontSize: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: _pickFromCamera,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withAlpha(26),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: Colors.white.withAlpha(51),
                                            width: 1,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.camera_alt_rounded,
                                              color: Colors.white70,
                                              size: 18,
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              'Take Photo',
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: _pickFromGallery,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withAlpha(26),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: Colors.white.withAlpha(51),
                                            width: 1,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.photo_library_rounded,
                                              color: Colors.white70,
                                              size: 18,
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              'Gallery',
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),


                  // Significant find toggle
                  CheckboxListTile(
                    value: _isSignificant,
                    onChanged: (v) => setState(() => _isSignificant = v ?? false),
                    title: const Text(
                      'Mark as significant find',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'e.g. gold coin, complete ceramic',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    activeColor: const Color(0xFFFFC107),
                    checkColor: const Color(0xFF0D3A39),
                    side: const BorderSide(color: Colors.white38),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 16),

                  // PPV AT DISCOVERY — read-only vibration context card
                  _buildPpvDiscoveryCard(),

                  const SizedBox(height: 16),

                  // SAVE DRAFT BUTTON
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: _isSavingDraft ? null : _saveDraftExplicitly,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(20),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withAlpha(77),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _isSavingDraft
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                                  )
                                : const Icon(Icons.save_alt_rounded, color: Colors.white70, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              _isSavingDraft ? 'Saving...' : 'Save Draft',
                              style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // SUBMIT BUTTON
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: _isSaving ? null : _saveFinding,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFC107),
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFFFC107).withAlpha(77),
                                  blurRadius: 16,
                                  spreadRadius: 0,
                                ),
                              ],
                            ),
                            child: Center(
                              child: _isSaving
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: Color(0xFF3E2723),
                                      ),
                                    )
                                  : const Text(
                                      'Add Finding',
                                      style: TextStyle(
                                        color: Color(0xFF3E2723),
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Read-only card showing vibration context at time of entry.
  Widget _buildPpvDiscoveryCard() {
    Color levelColor;
    switch (_anomalyLevelAtDiscovery) {
      case 'CRITICAL':
        levelColor = const Color(0xFFE53935);
        break;
      case 'ANOMALY':
        levelColor = const Color(0xFFFF7043);
        break;
      case 'UNUSUAL':
        levelColor = const Color(0xFFFFC107);
        break;
      default:
        levelColor = const Color(0xFF4CAF50);
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: levelColor.withAlpha(15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: levelColor.withAlpha(80), width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.sensors, color: levelColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Vibration at Discovery',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  _ppvAtDiscovery != null
                      ? 'PPV ${_ppvAtDiscovery!.toStringAsFixed(3)} mm/s'
                      : 'No recent vibration data',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: levelColor.withAlpha(40),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: levelColor, width: 1),
            ),
            child: Text(
              _anomalyLevelAtDiscovery,
              style: TextStyle(
                color: levelColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    int maxLines = 1,
    bool isRequired = true,
    Widget? suffixIcon,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(26),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withAlpha(89),
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: const Color(0xFFFFC107),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: Colors.white.withAlpha(179),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextFormField(
                        controller: controller,
                        maxLines: maxLines,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                        decoration: InputDecoration(
                          hintText: hint,
                          hintStyle: TextStyle(
                            color: Colors.white.withAlpha(102),
                            fontSize: 16,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          suffixIcon: suffixIcon,
                        ),
                        validator: isRequired ? (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter $label';
                          }
                          return null;
                        } : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
