import 'package:flutter/material.dart';

/// Quality assessment data for visualization.
class QualityVisualizationData {
  final String qualityGrade; // A, B, C, D, F
  final double meanReprojError;
  final double completeness; // 0-1
  final int pointCount;
  final int matchedImages;
  final int totalImages;
  final List<String> warnings;
  final Duration processingTime;

  const QualityVisualizationData({
    required this.qualityGrade,
    required this.meanReprojError,
    required this.completeness,
    required this.pointCount,
    required this.matchedImages,
    required this.totalImages,
    this.warnings = const [],
    this.processingTime = Duration.zero,
  });
}

/// Quality visualization widget showing reconstruction quality summary.
class QualityVisualizationWidget extends StatelessWidget {
  final QualityVisualizationData data;

  const QualityVisualizationWidget({super.key, required this.data});

  Color _gradeColor(String grade) {
    switch (grade.toUpperCase()) {
      case 'A': return const Color(0xFF4CAF50);
      case 'B': return const Color(0xFF8BC34A);
      case 'C': return const Color(0xFFFFC107);
      case 'D': return const Color(0xFFFF9800);
      default: return const Color(0xFFE53935);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gradeColor = _gradeColor(data.qualityGrade);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2332),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: gradeColor.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with grade
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: gradeColor.withAlpha(30),
                  shape: BoxShape.circle,
                  border: Border.all(color: gradeColor, width: 2),
                ),
                child: Center(
                  child: Text(
                    data.qualityGrade,
                    style: TextStyle(color: gradeColor, fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Reconstruction Quality',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      '${data.pointCount} points from ${data.matchedImages}/${data.totalImages} images',
                      style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Metrics row
          Row(
            children: [
              _buildMetric('Reproj. Error', '${data.meanReprojError.toStringAsFixed(2)} px',
                  data.meanReprojError < 1.0 ? const Color(0xFF4CAF50) :
                  data.meanReprojError < 2.0 ? const Color(0xFFFFC107) : const Color(0xFFE53935)),
              const SizedBox(width: 12),
              _buildMetric('Completeness', '${(data.completeness * 100).toStringAsFixed(0)}%',
                  data.completeness > 0.8 ? const Color(0xFF4CAF50) :
                  data.completeness > 0.5 ? const Color(0xFFFFC107) : const Color(0xFFE53935)),
              const SizedBox(width: 12),
              _buildMetric('Time', _formatDuration(data.processingTime), Colors.white.withAlpha(180)),
            ],
          ),

          // Warnings
          if (data.warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...data.warnings.map((w) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFC107), size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(w, style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 11)),
                  ),
                ],
              ),
            )),
          ],
        ],
      ),
    );
  }

  Widget _buildMetric(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withAlpha(30)),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10)),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }
}
