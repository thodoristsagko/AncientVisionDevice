import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Voice note recording state
enum VoiceState {
  idle,
  listening,
  processing,
  speaking,
  error,
}

/// A recorded voice note
class VoiceNote {
  final String id;
  final String transcription;
  final DateTime createdAt;
  final double? duration;
  final String? findingId;
  final String? journalId;

  VoiceNote({
    required this.id,
    required this.transcription,
    DateTime? createdAt,
    this.duration,
    this.findingId,
    this.journalId,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'transcription': transcription,
        'createdAt': createdAt.toIso8601String(),
        'duration': duration,
        'findingId': findingId,
        'journalId': journalId,
      };

  factory VoiceNote.fromJson(Map<String, dynamic> json) => VoiceNote(
        id: json['id'],
        transcription: json['transcription'],
        createdAt: DateTime.parse(json['createdAt']),
        duration: json['duration']?.toDouble(),
        findingId: json['findingId'],
        journalId: json['journalId'],
      );
}

/// Service for voice input/output (speech-to-text and text-to-speech)
class VoiceService {
  static final VoiceService _instance = VoiceService._internal();
  factory VoiceService() => _instance;
  VoiceService._internal();

  final SpeechToText _speechToText = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isInitialized = false;
  bool _speechAvailable = false;
  VoiceState _state = VoiceState.idle;
  String _currentTranscription = '';
  double _confidence = 0.0;

  final _stateController = StreamController<VoiceState>.broadcast();
  final _transcriptionController = StreamController<String>.broadcast();

  // Getters
  VoiceState get state => _state;
  String get currentTranscription => _currentTranscription;
  double get confidence => _confidence;
  bool get isListening => _state == VoiceState.listening;
  bool get isSpeaking => _state == VoiceState.speaking;
  Stream<VoiceState> get stateStream => _stateController.stream;
  Stream<String> get transcriptionStream => _transcriptionController.stream;

  /// Initialize the voice service
  Future<bool> initialize() async {
    if (_isInitialized) return _speechAvailable;

    try {
      // Initialize speech-to-text
      _speechAvailable = await _speechToText.initialize(
        onError: (error) {
          debugPrint('Speech recognition error: ${error.errorMsg}');
          _setState(VoiceState.error);
        },
        onStatus: (status) {
          debugPrint('Speech recognition status: $status');
          if (status == 'done' || status == 'notListening') {
            if (_state == VoiceState.listening) {
              _setState(VoiceState.idle);
            }
          }
        },
      );

      // Initialize text-to-speech
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setStartHandler(() {
        _setState(VoiceState.speaking);
      });

      _tts.setCompletionHandler(() {
        _setState(VoiceState.idle);
      });

      _tts.setErrorHandler((msg) {
        debugPrint('TTS error: $msg');
        _setState(VoiceState.error);
      });

      _isInitialized = true;
      debugPrint('VoiceService initialized. Speech available: $_speechAvailable');
      return _speechAvailable;
    } catch (e) {
      debugPrint('Error initializing VoiceService: $e');
      return false;
    }
  }

  /// Start listening for voice input
  Future<bool> startListening({
    String? localeId,
    Function(String text, bool isFinal)? onResult,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (!_speechAvailable) {
      debugPrint('Speech recognition not available');
      return false;
    }

    if (_state == VoiceState.listening) {
      return true;
    }

    _currentTranscription = '';
    _confidence = 0.0;
    _setState(VoiceState.listening);

    try {
      await _speechToText.listen(
        onResult: (SpeechRecognitionResult result) {
          _currentTranscription = result.recognizedWords;
          _confidence = result.confidence;
          _transcriptionController.add(_currentTranscription);

          if (onResult != null) {
            onResult(_currentTranscription, result.finalResult);
          }

          if (result.finalResult) {
            _setState(VoiceState.idle);
          }
        },
        localeId: localeId,
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          partialResults: true,
        ),
      );

      return true;
    } catch (e) {
      debugPrint('Error starting speech recognition: $e');
      _setState(VoiceState.error);
      return false;
    }
  }

  /// Stop listening
  Future<String> stopListening() async {
    if (_state != VoiceState.listening) {
      return _currentTranscription;
    }

    await _speechToText.stop();
    _setState(VoiceState.idle);
    return _currentTranscription;
  }

  /// Cancel listening without keeping the result
  Future<void> cancelListening() async {
    await _speechToText.cancel();
    _currentTranscription = '';
    _setState(VoiceState.idle);
  }

  /// Speak text aloud
  Future<void> speak(String text) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_state == VoiceState.speaking) {
      await stopSpeaking();
    }

    if (_state == VoiceState.listening) {
      await stopListening();
    }

    _setState(VoiceState.speaking);
    await _tts.speak(text);
  }

  /// Stop speaking
  Future<void> stopSpeaking() async {
    await _tts.stop();
    _setState(VoiceState.idle);
  }

  /// Set TTS language
  Future<void> setLanguage(String languageCode) async {
    await _tts.setLanguage(languageCode);
  }

  /// Set TTS speech rate (0.0 - 1.0)
  Future<void> setSpeechRate(double rate) async {
    await _tts.setSpeechRate(rate.clamp(0.0, 1.0));
  }

  /// Set TTS volume (0.0 - 1.0)
  Future<void> setVolume(double volume) async {
    await _tts.setVolume(volume.clamp(0.0, 1.0));
  }

  /// Set TTS pitch (0.5 - 2.0)
  Future<void> setPitch(double pitch) async {
    await _tts.setPitch(pitch.clamp(0.5, 2.0));
  }

  /// Get available TTS languages
  Future<List<String>> getAvailableLanguages() async {
    try {
      final languages = await _tts.getLanguages;
      return List<String>.from(languages ?? []);
    } catch (e) {
      return [];
    }
  }

  /// Get available locales for speech recognition
  Future<List<LocaleName>> getAvailableLocales() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _speechToText.locales();
  }

  /// Read finding details aloud (hands-free mode)
  Future<void> readFinding(Map<String, dynamic> finding) async {
    final buffer = StringBuffer();

    buffer.write('Finding ${finding['id'] ?? 'unknown'}. ');

    if (finding['description'] != null) {
      buffer.write('${finding['description']}. ');
    }

    if (finding['type'] != null) {
      buffer.write('Type: ${finding['type']}. ');
    }

    if (finding['site'] != null || finding['siteName'] != null) {
      buffer.write('Site: ${finding['site'] ?? finding['siteName']}. ');
    }

    if (finding['notes'] != null && finding['notes'].toString().isNotEmpty) {
      buffer.write('Notes: ${finding['notes']}. ');
    }

    await speak(buffer.toString());
  }

  /// Save voice note to local storage
  Future<VoiceNote?> saveVoiceNote({
    required String transcription,
    String? findingId,
    String? journalId,
    double? duration,
  }) async {
    try {
      final id = DateTime.now().millisecondsSinceEpoch.toString();

      final note = VoiceNote(
        id: id,
        transcription: transcription,
        duration: duration,
        findingId: findingId,
        journalId: journalId,
      );

      // Save to preferences
      final prefs = await SharedPreferences.getInstance();
      final notes = prefs.getStringList('voice_notes') ?? [];
      notes.add(jsonEncode(note.toJson()));

      // Keep only last 100 notes
      if (notes.length > 100) {
        notes.removeRange(0, notes.length - 100);
      }

      await prefs.setStringList('voice_notes', notes);

      debugPrint('Voice note saved: $id');
      return note;
    } catch (e) {
      debugPrint('Error saving voice note: $e');
      return null;
    }
  }

  /// Voice command handler for hands-free operation
  Future<String?> parseVoiceCommand(String command) async {
    final lowerCommand = command.toLowerCase().trim();

    // Navigation commands
    if (lowerCommand.contains('go to') || lowerCommand.contains('open')) {
      if (lowerCommand.contains('home')) return 'navigate:home';
      if (lowerCommand.contains('findings')) return 'navigate:findings';
      if (lowerCommand.contains('tools')) return 'navigate:tools';
      if (lowerCommand.contains('safety')) return 'navigate:safety';
      if (lowerCommand.contains('camera')) return 'navigate:camera';
      if (lowerCommand.contains('journal')) return 'navigate:journal';
    }

    // Action commands
    if (lowerCommand.contains('take photo') || lowerCommand.contains('capture')) {
      return 'action:capture_photo';
    }
    if (lowerCommand.contains('new finding') || lowerCommand.contains('add finding')) {
      return 'action:new_finding';
    }
    if (lowerCommand.contains('save')) {
      return 'action:save';
    }
    if (lowerCommand.contains('cancel')) {
      return 'action:cancel';
    }

    // Query commands
    if (lowerCommand.contains('how many') && lowerCommand.contains('findings')) {
      return 'query:finding_count';
    }
    if (lowerCommand.contains('today')) {
      return 'query:today_summary';
    }

    return null;
  }

  void _setState(VoiceState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  /// Dispose resources
  void dispose() {
    _stateController.close();
    _transcriptionController.close();
  }
}

/// Quick voice command templates
class VoiceCommandTemplates {
  static const Map<String, String> commands = {
    'New finding': 'Start recording a new archaeological finding',
    'Add note': 'Add a voice note to the current item',
    'Take photo': 'Capture a photo',
    'Read details': 'Read the current finding details aloud',
    'Go to findings': 'Navigate to the findings list',
    'Save': 'Save the current entry',
    'Cancel': 'Cancel the current operation',
  };

  static List<String> get commandList => commands.keys.toList();
}
