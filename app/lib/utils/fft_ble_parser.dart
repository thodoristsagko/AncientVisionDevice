/// Parsed FFT data from binary BLE characteristic (UUID ...26ac).
///
/// The firmware sends 64 FFT magnitude bins covering 0–100 Hz as
/// normalized uint16 values (0–65535). This class decodes the binary
/// payload and provides magnitude and frequency arrays.
class FftBleData {
  /// Number of FFT bins.
  final int binCount;

  /// Normalized magnitudes (0.0–1.0) for each bin.
  final List<double> magnitudes;

  /// Sample rate used on firmware (Hz).
  final double sampleRate;

  /// FFT size used on firmware.
  final int fftSize;

  const FftBleData({
    required this.binCount,
    required this.magnitudes,
    this.sampleRate = 200.0,
    this.fftSize = 256,
  });

  /// Frequency resolution (Hz per bin).
  double get binResolution => sampleRate / fftSize;

  /// Maximum frequency covered.
  double get maxFrequency => binCount * binResolution;

  /// Get the center frequency for a given bin index.
  double frequencyAt(int bin) => bin * binResolution;

  /// Get the frequency array for all bins.
  List<double> get frequencies =>
      List.generate(binCount, (i) => i * binResolution);

  /// Find the dominant frequency (bin with highest magnitude).
  double get dominantFrequency {
    if (magnitudes.isEmpty) return 0;
    int maxIdx = 0;
    double maxVal = 0;
    for (int i = 1; i < magnitudes.length; i++) {
      if (magnitudes[i] > maxVal) {
        maxVal = magnitudes[i];
        maxIdx = i;
      }
    }
    return frequencyAt(maxIdx);
  }

  /// Convert to spectrogram column (scaled magnitudes for display).
  ///
  /// Returns 128 bins (zero-padded if needed) for compatibility with
  /// the existing SpectrogramBuffer which expects 128 bins.
  List<double> toSpectrogramColumn({double scale = 100.0}) {
    final column = List<double>.filled(128, 0.0);
    for (int i = 0; i < magnitudes.length && i < 128; i++) {
      column[i] = magnitudes[i] * scale;
    }
    return column;
  }

  @override
  String toString() =>
      'FftBleData($binCount bins, dominant=${dominantFrequency.toStringAsFixed(1)}Hz)';
}

/// Parse binary FFT BLE payload into [FftBleData].
///
/// Expected format: [binCount(u8), reserved(u8), mag0_lo, mag0_hi, mag1_lo, mag1_hi, ...]
/// Total length: 2 + binCount * 2 bytes.
///
/// Returns null if the data is too short or malformed.
FftBleData? parseFftBlePayload(List<int> rawBytes) {
  if (rawBytes.length < 4) return null; // need at least header + 1 bin

  final binCount = rawBytes[0];
  // Validate: expected length = 2 + binCount * 2
  final expectedLength = 2 + binCount * 2;
  if (rawBytes.length < expectedLength) return null;
  if (binCount == 0 || binCount > 128) return null;

  final magnitudes = <double>[];
  for (int i = 0; i < binCount; i++) {
    final lo = rawBytes[2 + i * 2];
    final hi = rawBytes[2 + i * 2 + 1];
    final uint16Val = lo | (hi << 8);
    magnitudes.add(uint16Val / 65535.0);
  }

  return FftBleData(
    binCount: binCount,
    magnitudes: magnitudes,
  );
}

/// Check if a BLE characteristic UUID corresponds to the FFT characteristic.
bool isFftCharacteristic(String charUuid) {
  return charUuid.endsWith('26ac') || charUuid.contains('b26ac');
}
