/// Application-wide constants for the AncientVision safety monitoring system.
///
/// Centralizes hardcoded values scattered across the codebase for easier
/// maintenance and configuration. Values derived from firmware specs, BLE
/// protocol design, safety standards (DIN 4150-3), and photogrammetry
/// requirements.
class AppConstants {
  // Prevent instantiation
  AppConstants._();

  // ============================================================================
  // BLE (Bluetooth Low Energy) Configuration
  // ============================================================================

  /// BLE service UUID for AncientVision sensor device.
  /// Matches firmware `BLE_SERVICE_UUID` in main.cpp.
  static const String bleServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';

  /// Primary BLE characteristic UUID for IMU/sensor JSON data.
  /// Matches firmware `BLE_CHARACTERISTIC_UUID` in main.cpp.
  static const String bleCharacteristicUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

  /// BLE characteristic UUID for raw acceleration FFT data (v5.0+).
  /// Used for multi-packet 256-sample raw accel transfer.
  /// Matches firmware `BLE_FFT_CHARACTERISTIC_UUID` in main.cpp.
  static const String bleFftCharacteristicUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26ac';

  /// BLE MTU (Maximum Transmission Unit) request size in bytes.
  /// Android/iOS default is 23 bytes (20 payload), we request 512 to avoid
  /// JSON truncation. Firmware sends payloads up to ~300 bytes in v4.0+.
  /// NOTE: Actual negotiated MTU may be lower depending on device/OS.
  static const int bleMtu = 512;

  /// BLE keepalive check interval.
  /// If no data received within this window, connection is considered stale.
  /// Firmware sends IMU updates at ~5-10Hz, so 3s allows 15-30 missed packets.
  static const Duration bleKeepaliveInterval = Duration(seconds: 3);

  // ============================================================================
  // IMU & DSP (Digital Signal Processing) Configuration
  // ============================================================================

  /// IMU sampling rate in Hz (samples per second).
  /// M5StickC Plus 2 MPU6886 IMU configured at 200Hz in firmware.
  /// Nyquist theorem: can detect vibrations up to 100Hz.
  static const int imuSampleRate = 200;

  /// FFT window size (number of samples per analysis window).
  /// Power-of-2 required for radix-2 FFT algorithm.
  /// 256 samples @ 200Hz = 1.28 second analysis window.
  /// Frequency resolution: 200/256 = 0.78125 Hz/bin.
  static const int fftSize = 256;

  // ============================================================================
  // Safety Thresholds (DIN 4150-3 & Field-Tuned)
  // ============================================================================

  /// Maximum SAFE Peak Particle Velocity (PPV) in mm/s.
  /// DIN 4150-3 threshold for historical structures.
  /// Below this value: vibration is considered safe, can skip heavy DSP.
  /// Firmware uses this for low-power mode decision (main.cpp).
  static const double ppvSafeMax = 0.3;

  /// WARNING threshold for PPV in mm/s.
  /// DIN 4150-3 threshold where monitoring becomes critical.
  /// Above this: user should be alerted to check site conditions.
  static const double ppvWarning = 3.0;

  /// CRITICAL threshold for PPV in mm/s.
  /// DIN 4150-3 threshold for severe damage risk to historical structures.
  /// Above this: immediate evacuation or work stoppage recommended.
  static const double ppvCritical = 5.0;

  // ============================================================================
  // Photogrammetry Configuration
  // ============================================================================

  /// Minimum number of photos required for 3D reconstruction.
  /// Structure-from-Motion needs at least 3 views for triangulation,
  /// but 8+ recommended for robust pose estimation.
  static const int minPhotosForReconstruction = 3;

  /// Recommended minimum for production-quality reconstruction.
  /// Below this, user gets a warning about insufficient coverage.
  static const int recommendedPhotosForReconstruction = 8;

  /// Maximum resolution for stereo reconstruction (PatchMatch algorithm).
  /// Larger resolutions cause exponential memory/compute cost on mobile.
  /// 512x512 is a sweet spot for quality vs performance.
  static const int maxStereoResolution = 512;

  /// Maximum dimension (width or height) for sparse preview reconstruction.
  /// Images are downsampled to this size before feature extraction.
  /// Balances feature detectability with memory usage.
  static const int sparsePreviewMaxDim = 1024;

  /// Maximum dimension for color sampling during multi-view processing.
  /// Lower than preview to reduce memory footprint during triangulation.
  static const int colorSampleMaxDim = 512;

  // ============================================================================
  // Timeouts
  // ============================================================================

  /// Firestore write operation timeout.
  /// Prevents indefinite hangs when offline or network is slow.
  static const Duration firestoreTimeout = Duration(seconds: 10);

  /// 3D reconstruction processing timeout.
  /// Sparse SfM on mobile can take 30-60s for 12-16 images.
  /// Cloud reconstruction uploads have separate HTTP timeouts.
  static const Duration reconstructionTimeout = Duration(seconds: 60);

  /// HTTP timeout for external API calls (Numista, etc.).
  static const Duration httpTimeout = Duration(seconds: 10);

  // ============================================================================
  // Wavelet & Advanced Analysis
  // ============================================================================

  /// Rolling buffer size for wavelet analysis.
  /// Same as FFT size for 1:1 time-frequency comparison.
  static const int waveletBufferSize = 256;

  /// Spectrogram display columns (time axis).
  /// Roughly 2 minutes of history at 5Hz update rate.
  static const int spectrogramMaxColumns = 120;

  // ============================================================================
  // Device Naming Patterns (BLE Discovery)
  // ============================================================================

  /// BLE device name patterns for AncientVision sensor.
  /// Firmware sets device name to "AncientVision-XXXX" by default,
  /// but M5StickC may use "m5stick", "m5-", etc. before first flash.
  static const List<String> bleDeviceNamePatterns = [
    'ancientvision',
    'ancient',
    'm5stick',
    'm5-',
  ];

  // ============================================================================
  // Version Info
  // ============================================================================

  /// Current firmware protocol version.
  /// v5.0: DSP moved to phone, raw accel sent over BLE FFT characteristic.
  static const String firmwareProtocolVersion = '5.0';

  /// App version (should match pubspec.yaml).
  /// Update manually when releasing new versions.
  static const String appVersion = '5.0.0';
}
