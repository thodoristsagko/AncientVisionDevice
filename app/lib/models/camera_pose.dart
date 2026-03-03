import 'package:vector_math/vector_math_64.dart';

/// Camera pose estimated during Structure from Motion reconstruction.
/// Stores position, rotation, and focal length for each matched camera.
class CameraPose {
  final Vector3 position;
  final Matrix3 rotation;
  final double focalLength;

  CameraPose({
    required this.position,
    required this.rotation,
    required this.focalLength,
  });
}
