import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// QR Scanner screen for artifact tagging and quick lookup
class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _isProcessing = false;
  bool _torchOn = false;
  String? _lastScannedCode;
  Map<String, dynamic>? _scannedFinding;
  bool _showResult = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    setState(() {
      _torchOn = !_torchOn;
    });
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    if (_isProcessing || _showResult) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final code = barcode.rawValue!;
    if (code == _lastScannedCode) return;

    setState(() {
      _isProcessing = true;
      _lastScannedCode = code;
    });

    // Check if this is an AncientVision finding ID
    if (code.startsWith('AV-') || code.startsWith('A-')) {
      await _lookupFinding(code);
    } else {
      // Generic QR code - offer to create new finding with this ID
      setState(() {
        _isProcessing = false;
        _showResult = true;
        _scannedFinding = {
          'type': 'external',
          'code': code,
        };
      });
    }
  }

  Future<void> _lookupFinding(String findingId) async {
    try {
      // Search by artifactId field
      final snapshot = await FirebaseFirestore.instance
          .collection('findings')
          .where('artifactId', isEqualTo: findingId)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        final doc = snapshot.docs.first;
        setState(() {
          _scannedFinding = {
            'id': doc.id,
            'type': 'finding',
            ...doc.data(),
          };
          _showResult = true;
          _isProcessing = false;
        });
      } else {
        // Not found - offer to create
        setState(() {
          _scannedFinding = {
            'type': 'not_found',
            'code': findingId,
          };
          _showResult = true;
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _scannedFinding = {
          'type': 'error',
          'message': 'Failed to lookup: $e',
        };
        _showResult = true;
      });
    }
  }

  void _resetScanner() {
    setState(() {
      _showResult = false;
      _scannedFinding = null;
      _lastScannedCode = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D3A39),
        title: const Text('QR Scanner', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: Icon(
              _torchOn ? Icons.flash_on : Icons.flash_off,
              color: _torchOn ? const Color(0xFFFFC107) : Colors.white,
            ),
            onPressed: _toggleTorch,
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera preview
          MobileScanner(
            controller: _controller,
            onDetect: _handleBarcode,
          ),

          // Scan overlay
          if (!_showResult)
            Center(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFFFC107), width: 3),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isProcessing)
                      const CircularProgressIndicator(color: Color(0xFFFFC107))
                    else
                      Icon(
                        Icons.qr_code_scanner_rounded,
                        size: 80,
                        color: Colors.white.withAlpha(128),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      _isProcessing ? 'Looking up...' : 'Scan artifact QR code',
                      style: TextStyle(
                        color: Colors.white.withAlpha(204),
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Result overlay
          if (_showResult && _scannedFinding != null)
            _buildResultOverlay(),

          // Bottom instructions
          if (!_showResult)
            Positioned(
              bottom: 40,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(179),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Column(
                  children: [
                    Text(
                      'Point camera at QR code',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Scan artifact tags to view details or link findings',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResultOverlay() {
    final type = _scannedFinding!['type'] as String;

    return Container(
      color: Colors.black.withAlpha(217),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (type == 'finding') ...[
                // Found a finding
                const Icon(Icons.check_circle_rounded, color: Color(0xFF4CAF50), size: 80),
                const SizedBox(height: 20),
                const Text(
                  'Finding Found!',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                _buildFindingCard(),
              ] else if (type == 'not_found') ...[
                // QR code recognized but finding not in database
                const Icon(Icons.search_off_rounded, color: Color(0xFFFFC107), size: 80),
                const SizedBox(height: 20),
                const Text(
                  'Finding Not Found',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  'ID: ${_scannedFinding!['code']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    // Return the code to create a new finding
                    Navigator.pop(context, {'action': 'create', 'id': _scannedFinding!['code']});
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Create New Finding'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFC107),
                    foregroundColor: const Color(0xFF0D3A39),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
              ] else if (type == 'external') ...[
                // External QR code
                const Icon(Icons.qr_code_2_rounded, color: Color(0xFF2196F3), size: 80),
                const SizedBox(height: 20),
                const Text(
                  'External QR Code',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _scannedFinding!['code'] as String,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context, {'action': 'link', 'code': _scannedFinding!['code']});
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Link to Finding'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2196F3),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
              ] else if (type == 'error') ...[
                const Icon(Icons.error_outline_rounded, color: Colors.red, size: 80),
                const SizedBox(height: 20),
                Text(
                  _scannedFinding!['message'] as String,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: _resetScanner,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan Another'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFindingCard() {
    final finding = _scannedFinding!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2523),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFC107).withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  finding['artifactId'] ?? 'Unknown ID',
                  style: const TextStyle(
                    color: Color(0xFF0D3A39),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                finding['type'] ?? '',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            finding['name'] ?? finding['description'] ?? 'Unnamed Finding',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (finding['site'] != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.location_on_outlined, color: Colors.white54, size: 16),
                const SizedBox(width: 4),
                Text(
                  finding['site'] as String,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ],
          if (finding['material'] != null || finding['period'] != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (finding['material'] != null)
                  _buildTag(finding['material'] as String, const Color(0xFF795548)),
                if (finding['period'] != null)
                  _buildTag(finding['period'] as String, const Color(0xFF607D8B)),
              ],
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context, {'action': 'view', 'finding': finding});
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFC107),
                foregroundColor: const Color(0xFF0D3A39),
              ),
              child: const Text('View Full Details'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(77),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }
}
