import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// QR Scanner screen for artifact tagging and quick lookup.
///
/// Supports:
/// - Scanning artifact QR codes (AV-/A- prefixes → Firestore lookup)
/// - External QR codes (offered for linking to a finding)
/// - Torch/flashlight toggle
/// - Camera flip
/// - Manual entry fallback (type a finding ID or device name directly)
/// - Scan history: last 3 scanned codes accessible from a bottom sheet
/// - Robust error handling: invalid/malformed QR shows a snackbar, no crash
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

  /// Last 3 scanned codes (newest first).
  final List<String> _scanHistory = [];

  static const int _maxHistory = 3;
  static const Color _primaryDark = Color(0xFF0D3A39);
  static const Color _accent = Color(0xFFFFC107);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Torch ────────────────────────────────────────────────────────────────────

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (e) {
      _showSnackBar('Torch unavailable on this device');
    }
  }

  // ── Scan history ─────────────────────────────────────────────────────────────

  void _recordHistory(String code) {
    setState(() {
      _scanHistory.removeWhere((c) => c == code);
      _scanHistory.insert(0, code);
      if (_scanHistory.length > _maxHistory) {
        _scanHistory.removeLast();
      }
    });
  }

  void _showScanHistory() {
    if (_scanHistory.isEmpty) {
      _showSnackBar('No scan history yet');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C2523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, color: _accent, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Recent Scans',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() => _scanHistory.clear());
                    Navigator.pop(ctx);
                  },
                  child: const Text('Clear', style: TextStyle(color: Colors.white54)),
                ),
              ],
            ),
            const Divider(color: Colors.white12),
            ..._scanHistory.asMap().entries.map((entry) {
              final idx = entry.key;
              final code = entry.value;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: _accent.withAlpha(40),
                  child: Text(
                    '${idx + 1}',
                    style: const TextStyle(color: _accent, fontSize: 11),
                  ),
                ),
                title: Text(
                  code,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 14),
                onTap: () {
                  Navigator.pop(ctx);
                  _processCode(code);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  // ── Manual entry ─────────────────────────────────────────────────────────────

  Future<void> _showManualEntry() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C2523),
        title: const Text(
          'Enter Finding ID or Device Name',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. AV-2024-001 or AncientVision-3F2A',
            hintStyle: const TextStyle(color: Colors.white38),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _accent.withAlpha(100)),
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: _accent),
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
          ),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.pop(ctx, text);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: _primaryDark,
            ),
            child: const Text('Lookup'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result != null && result.isNotEmpty) {
      _processCode(result);
    }
  }

  // ── QR detection ─────────────────────────────────────────────────────────────

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    if (_isProcessing || _showResult) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final code = barcode.rawValue!.trim();
    if (code.isEmpty) {
      _showSnackBar('Empty QR code — please try again');
      return;
    }
    if (code == _lastScannedCode) return;

    _processCode(code);
  }

  Future<void> _processCode(String code) async {
    if (_isProcessing || _showResult) return;

    // Basic sanity — reject codes that are unreasonably long
    if (code.length > 512) {
      _showSnackBar('QR code content too long to process');
      return;
    }

    setState(() {
      _isProcessing = true;
      _lastScannedCode = code;
    });

    _recordHistory(code);

    if (code.startsWith('AV-') || code.startsWith('A-')) {
      await _lookupFinding(code);
    } else {
      // External / unknown QR code
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _showResult = true;
          _scannedFinding = {'type': 'external', 'code': code};
        });
      }
    }
  }

  Future<void> _lookupFinding(String findingId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('findings')
          .where('artifactId', isEqualTo: findingId)
          .limit(1)
          .get()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Lookup timed out — check connectivity'),
          );

      if (!mounted) return;

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
        setState(() {
          _scannedFinding = {'type': 'not_found', 'code': findingId};
          _showResult = true;
          _isProcessing = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // Show snackbar for the error and return to scanner rather than crashing
      setState(() {
        _isProcessing = false;
        _lastScannedCode = null; // allow re-scan after error
      });
      _showSnackBar('Lookup failed: $e');
    }
  }

  void _resetScanner() {
    setState(() {
      _showResult = false;
      _scannedFinding = null;
      _lastScannedCode = null;
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1C2523),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: _primaryDark,
        title: const Text('QR Scanner', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          // Torch toggle
          IconButton(
            icon: Icon(
              _torchOn ? Icons.flash_on : Icons.flash_off,
              color: _torchOn ? _accent : Colors.white,
            ),
            tooltip: _torchOn ? 'Torch off' : 'Torch on',
            onPressed: _toggleTorch,
          ),
          // Camera flip
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            tooltip: 'Flip camera',
            onPressed: () {
              try {
                _controller.switchCamera();
              } catch (_) {
                _showSnackBar('Camera flip unavailable');
              }
            },
          ),
          // Scan history
          IconButton(
            icon: Badge(
              isLabelVisible: _scanHistory.isNotEmpty,
              label: Text('${_scanHistory.length}'),
              child: const Icon(Icons.history),
            ),
            tooltip: 'Scan history',
            onPressed: _showScanHistory,
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

          // Scan frame overlay (only when not showing result)
          if (!_showResult) _buildScanFrame(),

          // Result overlay
          if (_showResult && _scannedFinding != null) _buildResultOverlay(),

          // Bottom instruction + manual entry button
          if (!_showResult) _buildBottomPanel(),
        ],
      ),
    );
  }

  Widget _buildScanFrame() {
    return Center(
      child: Container(
        width: 280,
        height: 280,
        decoration: BoxDecoration(
          border: Border.all(color: _accent, width: 3),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isProcessing)
              const CircularProgressIndicator(color: _accent)
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
    );
  }

  Widget _buildBottomPanel() {
    return Positioned(
      bottom: 40,
      left: 20,
      right: 20,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(179),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              children: [
                Text(
                  'Point camera at QR code',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
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
          const SizedBox(height: 12),
          // Manual entry fallback
          OutlinedButton.icon(
            onPressed: _showManualEntry,
            icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
            label: const Text('Manual entry'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withAlpha(128)),
              backgroundColor: Colors.black.withAlpha(140),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Result overlay ────────────────────────────────────────────────────────────

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
                const Icon(Icons.check_circle_rounded,
                    color: Color(0xFF4CAF50), size: 80),
                const SizedBox(height: 20),
                const Text(
                  'Finding Found!',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                _buildFindingCard(),
              ] else if (type == 'not_found') ...[
                const Icon(Icons.search_off_rounded,
                    color: Color(0xFFFFC107), size: 80),
                const SizedBox(height: 20),
                const Text(
                  'Finding Not Found',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  'ID: ${_scannedFinding!['code']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context,
                      {'action': 'create', 'id': _scannedFinding!['code']}),
                  icon: const Icon(Icons.add),
                  label: const Text('Create New Finding'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: _primaryDark,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                  ),
                ),
              ] else if (type == 'external') ...[
                const Icon(Icons.qr_code_2_rounded,
                    color: Color(0xFF2196F3), size: 80),
                const SizedBox(height: 20),
                const Text(
                  'External QR Code',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
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
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontFamily: 'monospace'),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context,
                      {'action': 'link', 'code': _scannedFinding!['code']}),
                  icon: const Icon(Icons.link),
                  label: const Text('Link to Finding'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2196F3),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                  ),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Finding card ──────────────────────────────────────────────────────────────

  Widget _buildFindingCard() {
    final finding = _scannedFinding!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2523),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  finding['artifactId'] ?? 'Unknown ID',
                  style: const TextStyle(
                    color: _primaryDark,
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
                const Icon(Icons.location_on_outlined,
                    color: Colors.white54, size: 16),
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
                  _buildTag(
                      finding['material'] as String, const Color(0xFF795548)),
                if (finding['period'] != null)
                  _buildTag(
                      finding['period'] as String, const Color(0xFF607D8B)),
              ],
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(
                  context, {'action': 'view', 'finding': finding}),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: _primaryDark,
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
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }
}
