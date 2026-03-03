import 'package:flutter/material.dart';
import 'dart:io';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/point_cloud.dart';
import '../models/reconstruction_result.dart';
import '../services/gaussian_splatting_service.dart';
import '../widgets/gaussian_splat_renderer.dart';
import 'point_cloud_painter.dart';
import 'quality_visualization_widget.dart';

/// 3D viewer widget for displaying point clouds and meshes
class Model3DViewer extends StatefulWidget {
  final ReconstructionResult result;
  final VoidCallback? onCompleteForm;
  final String? gltfPath;

  const Model3DViewer({
    super.key,
    required this.result,
    this.onCompleteForm,
    this.gltfPath,
  });

  @override
  State<Model3DViewer> createState() => _Model3DViewerState();
}

class _Model3DViewerState extends State<Model3DViewer> {
  bool _showInfo = true;
  double _pointSize = 3.0;
  bool _autoRotate = false;
  bool _measureMode = false;
  PointCloudRenderMode _renderMode = PointCloudRenderMode.color;
  bool _showGaussians = false;
  GaussianScene? _gaussianScene;
  bool _convertingToGaussians = false;
  bool _showTexturedModel = false;
  final GlobalKey<PointCloudViewerState> _viewerKey = GlobalKey();

  PointCloud? get _pointCloud {
    if (widget.result.pointCloud != null) {
      return widget.result.pointCloud;
    } else if (widget.result.mesh != null) {
      return widget.result.mesh!.toPointCloud();
    }
    return null;
  }

  Future<void> _exportPointCloud() async {
    try {
      final pointCloud = widget.result.pointCloud;
      if (pointCloud == null) {
        _showSnackBar('No point cloud available to export');
        return;
      }

      // Export to PLY format
      final plyContent = pointCloud.toPLY();

      // Save to temporary file
      final tempDir = await getTemporaryDirectory();
      final fileName = 'pointcloud_${DateTime.now().millisecondsSinceEpoch}.ply';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(plyContent);

      // Share the file
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'AncientVision 3D Point Cloud',
        text: 'Generated with AncientVision photogrammetry\n'
            'Points: ${pointCloud.points.length}\n'
            'Method: ${pointCloud.method}',
      );

      _showSnackBar('Point cloud exported successfully');
    } catch (e) {
      _showSnackBar('Export failed: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pointCloud = _pointCloud;
    final hasGltf = widget.gltfPath != null;
    final hasPointCloud = pointCloud != null && pointCloud.points.isNotEmpty;

    // Auto-show GLTF if available and no point cloud
    if (hasGltf && !hasPointCloud && !_showTexturedModel) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showTexturedModel = true);
      });
    }

    if (!hasPointCloud && !hasGltf) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('3D Model Viewer'),
          backgroundColor: Colors.black,
        ),
        body: const Center(
          child: Text(
            'No point cloud data available',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    final showSparseWarning = hasPointCloud && pointCloud.points.length < 10;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('3D Model Viewer'),
        backgroundColor: Colors.black,
        actions: [
          if (hasGltf && hasPointCloud)
            IconButton(
              icon: Icon(_showTexturedModel ? Icons.grain : Icons.view_in_ar),
              onPressed: () => setState(() => _showTexturedModel = !_showTexturedModel),
              tooltip: _showTexturedModel ? 'Point Cloud' : 'Textured Model',
            ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => setState(() => _showInfo = !_showInfo),
            tooltip: 'Toggle info',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _exportPointCloud,
            tooltip: 'Export & Share',
          ),
          if (widget.onCompleteForm != null)
            IconButton(
              icon: const Icon(Icons.edit_note_rounded),
              onPressed: widget.onCompleteForm,
              tooltip: 'Complete Form',
              color: const Color(0xFF4CAF50),
            ),
        ],
      ),
      body: Stack(
        children: [
          // 3D Viewer — GLTF textured, Gaussian Splatting, or Point Cloud
          if (_showTexturedModel && hasGltf)
            ModelViewer(
              src: 'file://${widget.gltfPath}',
              alt: '3D Model',
              ar: false,
              autoRotate: true,
              cameraControls: true,
              backgroundColor: Colors.black,
            )
          else if (_showGaussians && _gaussianScene != null)
            GaussianSplatRenderer(scene: _gaussianScene!)
          else if (hasPointCloud)
            PointCloudViewer(
              key: _viewerKey,
              pointCloud: pointCloud,
              initialPointSize: _pointSize,
              initialShowColors: true,
              renderMode: _renderMode,
            ),

          // Sparse point cloud warning
          if (showSparseWarning)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Very few points reconstructed. Try cloud processing or add more photos with better overlap for improved results.',
                        style: TextStyle(color: Colors.orange, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Info overlay
          if (_showInfo && !showSparseWarning)
            Positioned(
              top: 16,
              left: 16,
              child: _buildInfoPanel(),
            ),
          if (_showInfo && showSparseWarning)
            Positioned(
              top: 80,
              left: 16,
              child: _buildInfoPanel(),
            ),

          // Controls overlay
          Positioned(
            bottom: widget.onCompleteForm != null ? 100 : 16,
            left: 0,
            right: 0,
            child: _buildControlsPanel(),
          ),

          // Instructions
          if (_showInfo)
            Positioned(
              bottom: widget.onCompleteForm != null ? 200 : 120,
              left: 16,
              right: 16,
              child: Center(
                child: Text(
                  _measureMode
                      ? 'Tap two points to measure distance'
                      : 'Drag to rotate • Pinch to zoom',
                  style: TextStyle(
                    color: _measureMode ? const Color(0xFF00E5FF) : Colors.white70,
                    fontSize: 14,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 4),
                    ],
                  ),
                ),
              ),
            ),

          // Prominent Save Finding button
          if (widget.onCompleteForm != null)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: _buildSaveButton(),
            ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4CAF50), Color(0xFF2E7D32)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4CAF50).withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onCompleteForm,
          borderRadius: BorderRadius.circular(16),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.save_rounded, color: Colors.white, size: 24),
                SizedBox(width: 12),
                Text(
                  'Save Finding to Database',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoPanel() {
    final result = widget.result;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                result.isSparse ? Icons.grain : Icons.view_in_ar,
                color: const Color(0xFF00BCD4),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                result.isSparse ? 'Sparse Preview' : 'Full Model',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildInfoRow(Icons.scatter_plot, 'Points', '${result.pointCount}'),
          if (result.faceCount != null)
            _buildInfoRow(Icons.category, 'Faces', '${result.faceCount}'),
          _buildInfoRow(Icons.photo_library, 'Images', '${result.inputImageCount ?? 0}'),
          if (result.processingTimeSeconds != null)
            _buildInfoRow(
              Icons.timer,
              'Time',
              '${result.processingTimeSeconds!.toStringAsFixed(1)}s',
            ),
          if (result.qualityMetrics['average_confidence'] != null)
            _buildInfoRow(
              Icons.verified,
              'Confidence',
              '${(result.qualityMetrics['average_confidence'] * 100).toStringAsFixed(0)}%',
            ),
          // Quality visualization summary
          if (result.qualityMetrics['quality_grade'] != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 260,
              child: QualityVisualizationWidget(
                data: QualityVisualizationData(
                  qualityGrade: _mapGradeToLetter(result.qualityMetrics['quality_grade'] as String),
                  meanReprojError: (result.qualityMetrics['mean_reprojection_error'] as num?)?.toDouble() ?? 0.0,
                  completeness: (result.qualityMetrics['completeness'] as num?)?.toDouble() ?? 0.0,
                  pointCount: result.pointCount,
                  matchedImages: (result.qualityMetrics['matched_images'] as int?) ?? (result.inputImageCount ?? 0),
                  totalImages: result.inputImageCount ?? 0,
                  processingTime: Duration(
                    milliseconds: ((result.processingTimeSeconds ?? 0) * 1000).toInt(),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Map quality grade string to letter grade for the visualization widget.
  String _mapGradeToLetter(String grade) {
    switch (grade.toLowerCase()) {
      case 'excellent': return 'A';
      case 'good': return 'B';
      case 'acceptable': return 'C';
      case 'poor': return 'D';
      default: return 'F';
    }
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 16),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Point size slider
          Row(
            children: [
              const Icon(Icons.fiber_manual_record, color: Colors.white70, size: 16),
              const SizedBox(width: 8),
              const Text(
                'Point Size',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              Expanded(
                child: Slider(
                  value: _pointSize,
                  min: 1.0,
                  max: 10.0,
                  divisions: 9,
                  activeColor: const Color(0xFF00BCD4),
                  onChanged: (value) {
                    setState(() => _pointSize = value);
                  },
                ),
              ),
              Text(
                _pointSize.toStringAsFixed(0),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Render mode toggle row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildMiniToggle('Color', PointCloudRenderMode.color),
              const SizedBox(width: 6),
              _buildMiniToggle('Confidence', PointCloudRenderMode.confidence),
              const SizedBox(width: 6),
              _buildMiniToggle('Error', PointCloudRenderMode.error),
            ],
          ),
          const SizedBox(height: 8),

          // Control buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildControlButton(
                icon: _autoRotate ? Icons.replay : Icons.replay_outlined,
                label: 'Rotate',
                isActive: _autoRotate,
                onTap: () {
                  setState(() => _autoRotate = !_autoRotate);
                  _viewerKey.currentState?.toggleAutoRotate();
                },
              ),
              _buildControlButton(
                icon: Icons.center_focus_strong,
                label: 'Reset',
                onTap: () {
                  _viewerKey.currentState?.resetView();
                },
              ),
              _buildControlButton(
                icon: _measureMode ? Icons.straighten : Icons.straighten_outlined,
                label: 'Measure',
                isActive: _measureMode,
                onTap: () {
                  setState(() => _measureMode = !_measureMode);
                  _viewerKey.currentState?.toggleMeasureMode();
                },
              ),
              _buildControlButton(
                icon: _showGaussians ? Icons.blur_on : Icons.blur_circular,
                label: _convertingToGaussians ? 'Loading...' : 'Gaussians',
                isActive: _showGaussians,
                onTap: _convertingToGaussians ? () {} : _toggleGaussians,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniToggle(String label, PointCloudRenderMode mode) {
    final selected = _renderMode == mode && !_showGaussians;
    return GestureDetector(
      onTap: () => setState(() {
        _renderMode = mode;
        _showGaussians = false;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF00BCD4).withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? const Color(0xFF00BCD4) : Colors.white24),
        ),
        child: Text(label, style: TextStyle(
          color: selected ? const Color(0xFF00BCD4) : Colors.white54,
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        )),
      ),
    );
  }

  Future<void> _toggleGaussians() async {
    if (_showGaussians) {
      setState(() => _showGaussians = false);
      return;
    }

    final pc = _pointCloud;
    if (pc == null) return;

    // Convert on first tap
    if (_gaussianScene == null) {
      setState(() => _convertingToGaussians = true);
      final service = GaussianSplattingService();
      final scene = service.convertFromPointCloud(pc);
      if (mounted) {
        setState(() {
          _gaussianScene = scene;
          _showGaussians = true;
          _convertingToGaussians = false;
        });
      }
    } else {
      setState(() => _showGaussians = true);
    }
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    bool isActive = false,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF00BCD4).withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? const Color(0xFF00BCD4) : Colors.white24,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? const Color(0xFF00BCD4) : Colors.white70,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? const Color(0xFF00BCD4) : Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
