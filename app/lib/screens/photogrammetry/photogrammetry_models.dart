import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class CaptureAngle {
  final int id;
  final String name;
  final double angle; // Horizontal angle (0-360)
  final double elevation; // Vertical angle (0 = eye level, 90 = top)
  final IconData icon;
  final bool isDetail;

  const CaptureAngle({
    required this.id,
    required this.name,
    required this.angle,
    required this.elevation,
    required this.icon,
    this.isDetail = false,
  });
}

class PhotogrammetryCapture {
  final XFile file;
  final CaptureAngle angle;
  final DateTime capturedAt;
  final double qualityScore; // 0.0 - 1.0

  PhotogrammetryCapture({
    required this.file,
    required this.angle,
    required this.capturedAt,
    required this.qualityScore,
  });
}
