import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../../models/reconstruction_result.dart';
import '../../models/point_cloud.dart';

/// Save reconstruction result to persistent storage
Future<void> saveResult(ReconstructionResult result) async {
  final dir = await getApplicationDocumentsDirectory();
  final reconstructionsDir = Directory(path.join(dir.path, 'reconstructions'));
  await reconstructionsDir.create(recursive: true);

  final resultDir = Directory(path.join(reconstructionsDir.path, result.id));
  await resultDir.create(recursive: true);

  // Save metadata as JSON
  final metadataPath = path.join(resultDir.path, 'metadata.json');
  await File(metadataPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(result.toJson()),
  );

  // Save point cloud as PLY
  if (result.pointCloud != null) {
    final plyPath = path.join(resultDir.path, 'point_cloud.ply');
    await File(plyPath).writeAsString(result.pointCloud!.toPLY());
  }

  // Save mesh as OBJ (if available)
  if (result.mesh != null) {
    final objPath = path.join(resultDir.path, 'mesh.obj');
    await File(objPath).writeAsString(result.mesh!.toOBJ());
  }
}

/// Load all saved reconstruction results
Future<List<ReconstructionResult>> loadSavedResults() async {
  final dir = await getApplicationDocumentsDirectory();
  final reconstructionsDir = Directory(path.join(dir.path, 'reconstructions'));

  if (!await reconstructionsDir.exists()) {
    return [];
  }

  final results = <ReconstructionResult>[];

  await for (final entity in reconstructionsDir.list()) {
    if (entity is Directory) {
      try {
        final metadataPath = path.join(entity.path, 'metadata.json');
        final metadataFile = File(metadataPath);

        if (await metadataFile.exists()) {
          final jsonString = await metadataFile.readAsString();
          final json = jsonDecode(jsonString) as Map<String, dynamic>;
          final result = ReconstructionResult.fromJson(json);
          results.add(result);
        }
      } catch (e) {
        debugPrint('Error loading reconstruction ${entity.path}: $e');
      }
    }
  }

  // Sort by date, newest first
  results.sort((a, b) => b.startedAt.compareTo(a.startedAt));

  return results;
}

/// Load a specific reconstruction result with its point cloud
Future<ReconstructionResult?> loadResult(String resultId) async {
  final dir = await getApplicationDocumentsDirectory();
  final resultDir = Directory(path.join(dir.path, 'reconstructions', resultId));

  if (!await resultDir.exists()) {
    return null;
  }

  try {
    // Load metadata
    final metadataPath = path.join(resultDir.path, 'metadata.json');
    final jsonString = await File(metadataPath).readAsString();
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    var result = ReconstructionResult.fromJson(json);

    // Load point cloud from PLY
    final plyPath = path.join(resultDir.path, 'point_cloud.ply');
    if (await File(plyPath).exists()) {
      final plyContent = await File(plyPath).readAsString();
      final pointCloud = PointCloud.fromPLY(plyContent);
      result = result.copyWith(pointCloud: pointCloud);
    }

    return result;
  } catch (e) {
    debugPrint('Error loading result $resultId: $e');
    return null;
  }
}

/// Delete a saved reconstruction result
Future<void> deleteResult(String resultId) async {
  final dir = await getApplicationDocumentsDirectory();
  final resultDir = Directory(path.join(dir.path, 'reconstructions', resultId));

  if (await resultDir.exists()) {
    await resultDir.delete(recursive: true);
  }
}

/// Export reconstruction result to files (for sharing)
Future<String> exportResult(ReconstructionResult result) async {
  final dir = await getApplicationDocumentsDirectory();
  final exportDir = Directory(path.join(dir.path, 'exports', result.id));
  await exportDir.create(recursive: true);

  final files = <String>[];

  // Export point cloud as PLY
  if (result.pointCloud != null) {
    final plyPath = path.join(exportDir.path, 'point_cloud.ply');
    final plyFile = File(plyPath);
    await plyFile.writeAsString(result.pointCloud!.toPLY());
    files.add(plyPath);
  }

  // Export mesh as OBJ (if available)
  if (result.mesh != null) {
    final objPath = path.join(exportDir.path, 'mesh.obj');
    final objFile = File(objPath);
    await objFile.writeAsString(result.mesh!.toOBJ());
    files.add(objPath);
  }

  // Export metadata
  final metadataPath = path.join(exportDir.path, 'metadata.json');
  await File(metadataPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(result.toJson()),
  );
  files.add(metadataPath);

  return exportDir.path;
}
