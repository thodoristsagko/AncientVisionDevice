import 'point_cloud.dart';
import 'mesh_model.dart';
import 'camera_pose.dart';

/// Enum for reconstruction method types
enum ReconstructionMethod {
  auto, // Automatically select best method
  sparseSfM, // Sparse Structure from Motion (on-device preview)
  denseMVS, // Dense Multi-View Stereo (on-device)
  cloudProcessing, // Cloud-based full reconstruction
  huaweiKit, // Huawei 3D Modeling Kit
}

/// Enum for reconstruction status
enum ReconstructionStatus {
  notStarted,
  processing,
  completed,
  failed,
  cancelled,
}

/// Unified result from 3D reconstruction containing point cloud and/or mesh
class ReconstructionResult {
  final String id;
  final ReconstructionMethod method;
  final ReconstructionStatus status;
  final DateTime startedAt;
  final DateTime? completedAt;

  // 3D data (at least one should be present)
  final PointCloud? pointCloud;
  final MeshModel? mesh;

  // Processing info
  final double progress; // 0.0 to 1.0
  final String? statusMessage;
  final String? errorMessage;

  // Quality metrics
  final int? inputImageCount;
  final double? processingTimeSeconds;
  final Map<String, dynamic> qualityMetrics; // reprojection error, coverage, etc.

  // Export paths
  final String? exportPath;
  final List<String> exportedFiles; // List of file paths that were exported

  // Camera poses from SfM (needed for dense reconstruction)
  final List<CameraPose>? cameraPoses;

  // Metadata
  final Map<String, dynamic> metadata;

  ReconstructionResult({
    required this.id,
    required this.method,
    required this.status,
    DateTime? startedAt,
    this.completedAt,
    this.pointCloud,
    this.mesh,
    this.progress = 0.0,
    this.statusMessage,
    this.errorMessage,
    this.inputImageCount,
    this.processingTimeSeconds,
    Map<String, dynamic>? qualityMetrics,
    this.cameraPoses,
    this.exportPath,
    List<String>? exportedFiles,
    Map<String, dynamic>? metadata,
  })  : startedAt = startedAt ?? DateTime.now(),
        qualityMetrics = qualityMetrics ?? {},
        exportedFiles = exportedFiles ?? [],
        metadata = metadata ?? {},
        assert(
          pointCloud != null || mesh != null || status != ReconstructionStatus.completed,
          'Completed reconstruction must have at least point cloud or mesh',
        );

  /// Check if reconstruction has 3D data available
  bool get hasData => pointCloud != null || mesh != null;

  /// Get point count (from point cloud or mesh vertices)
  int get pointCount {
    if (pointCloud != null) return pointCloud!.points.length;
    if (mesh != null) return mesh!.vertices.length;
    return 0;
  }

  /// Get face count (only if mesh is available)
  int? get faceCount => mesh?.faces.length;

  /// Check if this is a sparse preview or full reconstruction
  bool get isSparse => method == ReconstructionMethod.sparseSfM;

  /// Check if reconstruction is complete
  bool get isComplete => status == ReconstructionStatus.completed;

  /// Check if reconstruction is in progress
  bool get isProcessing => status == ReconstructionStatus.processing;

  /// Check if reconstruction failed
  bool get hasFailed => status == ReconstructionStatus.failed;

  /// Create a copy with updated fields
  ReconstructionResult copyWith({
    ReconstructionStatus? status,
    DateTime? completedAt,
    PointCloud? pointCloud,
    MeshModel? mesh,
    double? progress,
    String? statusMessage,
    String? errorMessage,
    int? inputImageCount,
    double? processingTimeSeconds,
    Map<String, dynamic>? qualityMetrics,
    List<CameraPose>? cameraPoses,
    String? exportPath,
    List<String>? exportedFiles,
    Map<String, dynamic>? metadata,
  }) {
    return ReconstructionResult(
      id: id,
      method: method,
      status: status ?? this.status,
      startedAt: startedAt,
      completedAt: completedAt ?? this.completedAt,
      pointCloud: pointCloud ?? this.pointCloud,
      mesh: mesh ?? this.mesh,
      progress: progress ?? this.progress,
      statusMessage: statusMessage ?? this.statusMessage,
      errorMessage: errorMessage ?? this.errorMessage,
      inputImageCount: inputImageCount ?? this.inputImageCount,
      processingTimeSeconds: processingTimeSeconds ?? this.processingTimeSeconds,
      qualityMetrics: qualityMetrics ?? this.qualityMetrics,
      cameraPoses: cameraPoses ?? this.cameraPoses,
      exportPath: exportPath ?? this.exportPath,
      exportedFiles: exportedFiles ?? this.exportedFiles,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Get human-readable method name
  String get methodName {
    switch (method) {
      case ReconstructionMethod.auto:
        return 'Automatic';
      case ReconstructionMethod.sparseSfM:
        return 'Sparse Preview (On-Device)';
      case ReconstructionMethod.denseMVS:
        return 'Dense MVS (On-Device)';
      case ReconstructionMethod.cloudProcessing:
        return 'Cloud Processing';
      case ReconstructionMethod.huaweiKit:
        return 'Huawei 3D Modeling';
    }
  }

  /// Get human-readable status message
  String get statusText {
    switch (status) {
      case ReconstructionStatus.notStarted:
        return 'Not Started';
      case ReconstructionStatus.processing:
        return statusMessage ?? 'Processing...';
      case ReconstructionStatus.completed:
        return 'Completed';
      case ReconstructionStatus.failed:
        return errorMessage ?? 'Failed';
      case ReconstructionStatus.cancelled:
        return 'Cancelled';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'method': method.name,
        'status': status.name,
        'startedAt': startedAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'pointCloud': pointCloud?.toJson(),
        'mesh': mesh?.toJson(),
        'progress': progress,
        'statusMessage': statusMessage,
        'errorMessage': errorMessage,
        'inputImageCount': inputImageCount,
        'processingTimeSeconds': processingTimeSeconds,
        'qualityMetrics': qualityMetrics,
        'exportPath': exportPath,
        'exportedFiles': exportedFiles,
        'metadata': metadata,
        'pointCount': pointCount,
        'faceCount': faceCount,
      };

  factory ReconstructionResult.fromJson(Map<String, dynamic> json) {
    return ReconstructionResult(
      id: json['id'] as String,
      method: ReconstructionMethod.values.firstWhere(
        (m) => m.name == json['method'],
        orElse: () => ReconstructionMethod.auto,
      ),
      status: ReconstructionStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => ReconstructionStatus.notStarted,
      ),
      startedAt: DateTime.parse(json['startedAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
      pointCloud: json['pointCloud'] != null
          ? PointCloud.fromJson(json['pointCloud'] as Map<String, dynamic>)
          : null,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      statusMessage: json['statusMessage'] as String?,
      errorMessage: json['errorMessage'] as String?,
      inputImageCount: json['inputImageCount'] as int?,
      processingTimeSeconds: (json['processingTimeSeconds'] as num?)?.toDouble(),
      qualityMetrics: json['qualityMetrics'] as Map<String, dynamic>? ?? {},
      exportPath: json['exportPath'] as String?,
      exportedFiles: (json['exportedFiles'] as List?)?.cast<String>() ?? [],
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
    );
  }

  @override
  String toString() {
    return 'ReconstructionResult(id: $id, method: $methodName, status: $statusText, '
        'pointCount: $pointCount${faceCount != null ? ", faceCount: $faceCount" : ""})';
  }
}
