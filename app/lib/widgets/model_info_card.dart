import 'package:flutter/material.dart';

/// A reusable card that displays ML model diagnostic information.
///
/// Collapsed view: model name + coloured status dot.
/// Expanded view: version badge, input dimension, fingerprint, load status,
/// average inference time, and optional error box.
class ModelInfoCard extends StatefulWidget {
  /// Human-readable model name shown as the card title.
  final String modelName;

  /// Version string (e.g. "2026-03-04-a1b2c3d").
  final String version;

  /// Number of input features the model expects.
  final int inputDim;

  /// SHA-256 / MD5 fingerprint of the model file.
  final String fingerprint;

  /// Whether the model has been loaded and is ready for inference.
  final bool isLoaded;

  /// Running average inference duration in milliseconds, or null if no
  /// inferences have been run yet.
  final double? avgInferenceMs;

  /// Last error message from loading or inference. When non-null an error
  /// box is rendered inside the expanded view.
  final String? lastError;

  /// Whether the card starts expanded. Defaults to false (collapsed).
  final bool initiallyExpanded;

  const ModelInfoCard({
    super.key,
    required this.modelName,
    required this.version,
    required this.inputDim,
    required this.fingerprint,
    required this.isLoaded,
    this.avgInferenceMs,
    this.lastError,
    this.initiallyExpanded = false,
  });

  @override
  State<ModelInfoCard> createState() => _ModelInfoCardState();
}

class _ModelInfoCardState extends State<ModelInfoCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  /// First 8 characters of the fingerprint for the compact view.
  String get _shortFingerprint {
    if (widget.fingerprint.isEmpty) return 'N/A';
    return widget.fingerprint.length > 8
        ? widget.fingerprint.substring(0, 8)
        : widget.fingerprint;
  }

  Color get _statusColor =>
      widget.isLoaded ? const Color(0xFF4CAF50) : const Color(0xFFEF5350);

  String get _statusLabel => widget.isLoaded ? 'Loaded' : 'Failed';

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1C2523),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          if (_expanded) ...[
            Divider(color: Colors.white.withAlpha(30), height: 1),
            _buildDetails(),
          ],
        ],
      ),
    );
  }

  // ── Header (always visible) ────────────────────────────────────────────────

  Widget _buildHeader() {
    return InkWell(
      borderRadius: _expanded
          ? const BorderRadius.vertical(top: Radius.circular(12))
          : BorderRadius.circular(12),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Status dot
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            // Model name
            Expanded(
              child: Text(
                widget.modelName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            // Collapsed summary: fingerprint prefix + chevron
            if (!_expanded) ...[
              Text(
                _shortFingerprint,
                style: TextStyle(
                  color: Colors.white.withAlpha(120),
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 8),
            ],
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              color: Colors.white54,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  // ── Expanded detail rows ───────────────────────────────────────────────────

  Widget _buildDetails() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Version badge
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'Version',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF9C27B0).withAlpha(50),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: const Color(0xFF9C27B0).withAlpha(120),
                  ),
                ),
                child: Text(
                  widget.version.isEmpty ? 'unknown' : widget.version,
                  style: const TextStyle(
                    color: Color(0xFFCE93D8),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _detailRow('Input dim', '${widget.inputDim} features'),
          _detailRow(
            'Fingerprint',
            widget.fingerprint.isEmpty ? 'N/A' : _shortFingerprint,
            mono: true,
          ),
          _detailRow('Status', _statusLabel, valueColor: _statusColor),
          _detailRow(
            'Avg inference',
            widget.avgInferenceMs != null
                ? '${widget.avgInferenceMs!.toStringAsFixed(1)} ms'
                : 'N/A',
          ),
          // Error box (only when there is an error)
          if (widget.lastError != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFEF5350).withAlpha(30),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFFEF5350).withAlpha(100),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Color(0xFFEF5350),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.lastError!,
                      style: const TextStyle(
                        color: Color(0xFFEF9A9A),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(
    String key,
    String value, {
    Color? valueColor,
    bool mono = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              key,
              style: TextStyle(
                color: Colors.white.withAlpha(140),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
