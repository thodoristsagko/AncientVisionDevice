import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/ai_classification_service.dart';
import '../services/gemini_coin_service.dart';
import '../services/site_service.dart';

/// AI-powered COIN recognition screen
/// Captures front and back photos, then identifies the coin using Gemini AI
class AIRecognitionScreen extends StatefulWidget {
  const AIRecognitionScreen({super.key});

  @override
  State<AIRecognitionScreen> createState() => _AIRecognitionScreenState();
}

class _AIRecognitionScreenState extends State<AIRecognitionScreen>
    with SingleTickerProviderStateMixin {
  final _geminiService = GeminiCoinService();
  final _imagePicker = ImagePicker();

  File? _obverseImage; // Front side
  File? _reverseImage; // Back side
  CoinClassificationResult? _coinResult;
  bool _isProcessing = false;
  bool _isSignificant = false;
  String _site = '';
  late AnimationController _ringController;
  late Animation<double> _ringAnimation;
  String? _error;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _geminiService.initialize();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _ringAnimation = CurvedAnimation(parent: _ringController, curve: Curves.easeOut);
    SiteService().getActiveSite().then((site) {
      if (mounted && site.isNotEmpty) setState(() => _site = site);
    });
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  Future<void> _pickObverse(ImageSource source) async {
    try {
      final picked = await _imagePicker.pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );
      if (picked != null && mounted) {
        setState(() {
          _obverseImage = File(picked.path);
          _coinResult = null;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to pick image: $e');
    }
  }

  Future<void> _pickReverse(ImageSource source) async {
    try {
      final picked = await _imagePicker.pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );
      if (picked != null && mounted) {
        setState(() {
          _reverseImage = File(picked.path);
          _coinResult = null;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to pick image: $e');
    }
  }

  Future<void> _classifyCoin() async {
    if (_obverseImage == null) return;

    setState(() {
      _isProcessing = true;
      _error = null;
      _coinResult = null;
      _isSignificant = false;
      _statusMessage = _reverseImage != null
          ? 'Analyzing both sides with Gemini AI...'
          : 'Analyzing coin with Gemini AI...';
    });

    try {
      final result = await _geminiService.classifyCoin(
        _obverseImage!,
        reverseFile: _reverseImage,
      );
      if (mounted) {
        setState(() {
          _coinResult = result;
          _isProcessing = false;
        });
        _ringController.forward(from: 0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e'.replaceFirst('Exception: ', '');
          _isProcessing = false;
        });
      }
    }
  }

  void _useClassification() {
    if (_coinResult == null) return;

    Navigator.pop(context, {
      'type': 'Coin',
      'material': _coinResult!.material,
      'period': _coinResult!.period,
      'dateRange': _coinResult!.dateRange,
      'description': _coinResult!.description,
      'confidence': _coinResult!.confidence / 100,
      'imagePath': _obverseImage?.path,
      'isCoin': _coinResult!.isCoin,
      'characteristics': _coinResult!.characteristics,
      'regions': _coinResult!.regions,
      'isSignificant': _isSignificant,
      'site': _site,
    });
  }

  void _reset() {
    setState(() {
      _obverseImage = null;
      _reverseImage = null;
      _coinResult = null;
      _isSignificant = false;
      _error = null;
    });
    _ringController.reset();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D3A39),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D3A39),
        elevation: 0,
        title: const Text(
          'Coin Recognition',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_coinResult != null)
            TextButton(
              onPressed: _useClassification,
              child: const Text(
                'Use Result',
                style: TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.bold),
              ),
            ),
          if (_obverseImage != null)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _isProcessing ? null : _reset,
              tooltip: 'Start over',
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // === TWO-SIDED CAPTURE ===
            Row(
              children: [
                // FRONT (Obverse)
                Expanded(child: _buildImageSlot(
                  label: 'Front (Obverse)',
                  image: _obverseImage,
                  icon: Icons.person_rounded,
                  onCamera: () => _pickObverse(ImageSource.camera),
                  onGallery: () => _pickObverse(ImageSource.gallery),
                )),
                const SizedBox(width: 12),
                // BACK (Reverse)
                Expanded(child: _buildImageSlot(
                  label: 'Back (Reverse)',
                  image: _reverseImage,
                  icon: Icons.shield_rounded,
                  onCamera: () => _pickReverse(ImageSource.camera),
                  onGallery: () => _pickReverse(ImageSource.gallery),
                )),
              ],
            ),

            const SizedBox(height: 20),

            // === IDENTIFY BUTTON ===
            if (_obverseImage != null) ...[
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _classifyCoin,
                icon: _isProcessing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF0D3A39),
                        ),
                      )
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(_isProcessing
                    ? _statusMessage
                    : (_reverseImage != null
                        ? 'Identify Coin (Both Sides)'
                        : 'Identify Coin (Front Only)')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFC107),
                  foregroundColor: const Color(0xFF0D3A39),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              if (_reverseImage == null && !_isProcessing) ...[
                const SizedBox(height: 8),
                Text(
                  'Add the back side for better accuracy',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withAlpha(128),
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],

            // Error message
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(51),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ],

            // Results
            if (_coinResult != null) ...[
              const SizedBox(height: 24),
              _buildCoinResultCard(),
            ],

            if (_coinResult != null) ...[
              const SizedBox(height: 16),
              CheckboxListTile(
                value: _isSignificant,
                onChanged: (v) => setState(() => _isSignificant = v ?? false),
                title: const Text(
                  'Mark as significant find',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: const Text(
                  'e.g. rare coin, exceptional condition',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                activeColor: const Color(0xFFFFC107),
                checkColor: const Color(0xFF0D3A39),
                side: const BorderSide(color: Colors.white38),
                contentPadding: EdgeInsets.zero,
              ),
            ],

            // Info
            const SizedBox(height: 24),
            _buildInfoCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSlot({
    required String label,
    required File? image,
    required IconData icon,
    required VoidCallback onCamera,
    required VoidCallback onGallery,
  }) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _isProcessing ? null : onCamera,
          child: Container(
            height: 180,
            decoration: BoxDecoration(
              color: const Color(0xFF1C2523),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: image != null
                    ? const Color(0xFF4CAF50).withAlpha(153)
                    : const Color(0xFFFFC107).withAlpha(77),
                width: 2,
              ),
            ),
            child: image != null
                ? Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          image,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.check, color: Colors.white, size: 14),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 40,
                          color: Colors.white.withAlpha(64),
                        ),
                        const SizedBox(height: 8),
                        Icon(
                          Icons.camera_alt_rounded,
                          size: 24,
                          color: Colors.white.withAlpha(102),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap to capture',
                          style: TextStyle(
                            color: Colors.white.withAlpha(102),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        if (!_isProcessing)
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: onCamera,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFC107).withAlpha(38),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.camera_alt_rounded, color: Color(0xFFFFC107), size: 18),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GestureDetector(
                  onTap: onGallery,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.photo_library_rounded, color: Colors.white.withAlpha(153), size: 18),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildConfidenceRing() {
    final confidence = _coinResult!.confidence / 100.0;
    final color = confidence >= 0.70
        ? Colors.green
        : confidence >= 0.50
            ? const Color(0xFFFFC107)
            : Colors.red;
    return AnimatedBuilder(
      animation: _ringAnimation,
      builder: (_, __) {
        final animated = _ringAnimation.value * confidence;
        return SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: animated,
                backgroundColor: Colors.white12,
                valueColor: AlwaysStoppedAnimation<Color>(color),
                strokeWidth: 8,
              ),
              Text(
                '${(_ringAnimation.value * _coinResult!.confidence).round()}%',
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCoinResultCard() {
    if (_coinResult == null) return const SizedBox.shrink();

    // "Not a coin" result
    if (_coinResult!.isCoin == false) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.orange.withAlpha(38),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.orange.withAlpha(102)),
        ),
        child: Column(
          children: [
            const Icon(Icons.cancel_outlined, color: Colors.orange, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Not a Coin',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _coinResult!.characteristics.isNotEmpty
                  ? _coinResult!.characteristics.first
                  : 'This object does not appear to be a coin.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withAlpha(153), fontSize: 13),
            ),
          ],
        ),
      );
    }

    // Low confidence / no data
    if (_coinResult!.period == null && _coinResult!.confidence <= 30) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.grey.withAlpha(51),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.withAlpha(77)),
        ),
        child: Column(
          children: [
            Icon(Icons.help_outline, color: Colors.grey[400], size: 48),
            const SizedBox(height: 12),
            const Text(
              'Could not identify coin',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Try clearer photos with good lighting.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withAlpha(153), fontSize: 13),
            ),
          ],
        ),
      );
    }

    final coinType = _coinResult!.characteristics.isNotEmpty
        ? _coinResult!.characteristics.first
        : 'Unknown Coin';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF8B4513).withAlpha(77),
            const Color(0xFFD4AF37).withAlpha(51),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFD4AF37).withAlpha(128),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4AF37).withAlpha(77),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xFFD4AF37),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      coinType,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _reverseImage != null
                          ? 'Identified by Gemini AI (both sides)'
                          : 'Identified by Gemini AI',
                      style: TextStyle(
                        color: Colors.white.withAlpha(153),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              _buildConfidenceRing(),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(color: Colors.white24),
          const SizedBox(height: 12),

          if (_coinResult!.period != null) ...[
            _buildCoinInfoRow(Icons.history_edu_rounded, 'Period', _coinResult!.period!),
            const SizedBox(height: 8),
          ],
          if (_coinResult!.dateRange != null) ...[
            _buildCoinInfoRow(Icons.calendar_today_rounded, 'Date Range', _coinResult!.dateRange!),
            const SizedBox(height: 8),
          ],
          _buildCoinInfoRow(Icons.texture_rounded, 'Material', _coinResult!.material),
          if (_coinResult!.denomination != null) ...[
            const SizedBox(height: 8),
            _buildCoinInfoRow(Icons.paid_rounded, 'Denomination', _coinResult!.denomination!),
          ],
          if (_coinResult!.ruler != null) ...[
            const SizedBox(height: 8),
            _buildCoinInfoRow(Icons.person_rounded, 'Ruler', _coinResult!.ruler!),
          ],

          // Detailed description
          if (_coinResult!.detailedDescription != null &&
              _coinResult!.detailedDescription!.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              'About This Coin',
              style: TextStyle(
                color: Colors.white.withAlpha(179),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _coinResult!.detailedDescription!,
              style: TextStyle(
                color: Colors.white.withAlpha(217),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],

          // Notable characteristics
          if (_coinResult!.characteristics.length > 1) ...[
            const SizedBox(height: 16),
            const Divider(color: Colors.white24),
            const SizedBox(height: 8),
            Text(
              'Notable Features',
              style: TextStyle(
                color: Colors.white.withAlpha(179),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _coinResult!.characteristics.skip(1).map((c) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D3A39),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFD4AF37).withAlpha(77)),
                ),
                child: Text(c, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              )).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoinInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFD4AF37).withAlpha(179), size: 18),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(color: Colors.white.withAlpha(153), fontSize: 13),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2196F3).withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2196F3).withAlpha(77)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: Color(0xFF2196F3)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Capture both sides of the coin for the most accurate identification. Gemini AI analyzes inscriptions, portraits, symbols, and material to identify the coin.',
              style: TextStyle(
                color: Colors.white.withAlpha(204),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
