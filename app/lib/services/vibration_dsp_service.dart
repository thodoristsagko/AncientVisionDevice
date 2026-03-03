import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

/// Message sent to the DSP isolate for processing.
class _DspIsolateRequest {
  final List<double> accelX;
  final List<double> accelY;
  final List<double> accelZ;
  final int sampleRate;
  final int windowSize;
  const _DspIsolateRequest(this.accelX, this.accelY, this.accelZ, this.sampleRate, this.windowSize);
}

/// Combined response from the DSP isolate.
class _DspIsolateResponse {
  final DspResult dspResult;
  final double ppv;
  const _DspIsolateResponse(this.dspResult, this.ppv);
}

/// Top-level function for Isolate.run — performs all heavy DSP math off main thread.
_DspIsolateResponse _dspIsolateEntry(_DspIsolateRequest req) {
  final svc = VibrationDspService._forIsolate();
  final dspResult = svc.process(req.accelX, req.accelY, req.accelZ);
  final ppv = svc._computeRawPPV(req.accelX, req.accelY, req.accelZ);
  return _DspIsolateResponse(dspResult, ppv);
}

/// Phone-side DSP engine that processes raw acceleration buffers from BLE.
///
/// Replaces firmware-side FFT, DWT, kurtosis, spectral centroid, Arias
/// intensity, and CAV computations. The phone has orders of magnitude
/// more compute than the ESP32, so we can afford richer analysis.
///
/// Input: 256 tri-axial acceleration samples at 200Hz (1.28s window)
/// Output: Full feature vector for anomaly detection pipeline
class VibrationDspService {
  static const int sampleRate = 200;
  static const int windowSize = 256;
  static const double dt = 1.0 / sampleRate;

  // Running accumulators (persist across windows)
  double ariasIntensity = 0.0;
  double cav = 0.0;
  DateTime _lastAriasReset = DateTime.now();
  static const Duration ariasResetInterval = Duration(seconds: 60);

  // PPV noise floor calibration (same approach as firmware)
  double _ppvNoiseFloor = 0.0;
  bool _ppvCalibrated = false;
  int _calibrationCount = 0;
  double _calibrationSum = 0.0;
  static const int _calibrationWindows = 5;

  /// Internal constructor for isolate (no state carried over).
  VibrationDspService._forIsolate();

  VibrationDspService();

  /// Process acceleration data on a background isolate.
  /// Returns DSP result with Arias/CAV accumulated on main thread,
  /// and PPV with noise floor calibration applied on main thread.
  Future<({DspResult dsp, double ppv})> processAsync(
    List<double> accelX, List<double> accelY, List<double> accelZ,
  ) async {
    final response = await Isolate.run(
      () => _dspIsolateEntry(_DspIsolateRequest(accelX, accelY, accelZ, sampleRate, windowSize)),
    );

    // Apply stateful accumulation on main thread
    ariasIntensity += response.dspResult.ariasIntensity;
    cav += response.dspResult.cav;
    final now = DateTime.now();
    if (now.difference(_lastAriasReset) >= ariasResetInterval) {
      ariasIntensity = 0.0;
      cav = 0.0;
      _lastAriasReset = now;
    }

    // PPV noise floor calibration on main thread
    final rawPPV = response.ppv;
    double calibratedPPV;
    if (!_ppvCalibrated) {
      _calibrationSum += rawPPV;
      _calibrationCount++;
      if (_calibrationCount >= _calibrationWindows) {
        _ppvNoiseFloor = (_calibrationSum / _calibrationCount) * 1.2;
        _ppvCalibrated = true;
      }
      calibratedPPV = 0.0;
    } else {
      final c = rawPPV - _ppvNoiseFloor;
      calibratedPPV = c > 0 ? c : 0.0;
    }

    // Return result with accumulated Arias/CAV from main thread
    final dsp = DspResult(
      rms: response.dspResult.rms,
      peak: response.dspResult.peak,
      crestFactor: response.dspResult.crestFactor,
      kurtosis: response.dspResult.kurtosis,
      dominantFreq: response.dspResult.dominantFreq,
      spectralCentroid: response.dspResult.spectralCentroid,
      fftMagnitudes: response.dspResult.fftMagnitudes,
      dwtEnergy1: response.dspResult.dwtEnergy1,
      dwtEnergy2: response.dspResult.dwtEnergy2,
      dwtEnergy3: response.dspResult.dwtEnergy3,
      ariasIntensity: ariasIntensity,
      cav: cav,
      psdSlope: response.dspResult.psdSlope,
    );

    return (dsp: dsp, ppv: calibratedPPV);
  }

  /// Process a raw acceleration buffer and return all computed features.
  ///
  /// [accelX], [accelY], [accelZ] are filtered acceleration in g units,
  /// each containing [windowSize] samples.
  DspResult process(List<double> accelX, List<double> accelY, List<double> accelZ) {
    assert(accelX.length == windowSize);
    assert(accelY.length == windowSize);
    assert(accelZ.length == windowSize);

    // 1. Compute magnitude signal
    final magnitude = List<double>.filled(windowSize, 0.0);
    for (int i = 0; i < windowSize; i++) {
      magnitude[i] = sqrt(accelX[i] * accelX[i] + accelY[i] * accelY[i] + accelZ[i] * accelZ[i]);
    }

    // 2. RMS and Peak
    double sumSq = 0.0;
    double peak = 0.0;
    for (int i = 0; i < windowSize; i++) {
      sumSq += magnitude[i] * magnitude[i];
      if (magnitude[i] > peak) peak = magnitude[i];
    }
    final rms = sqrt(sumSq / windowSize);
    final crestFactor = rms > 0.0001 ? peak / rms : 1.0;

    // 3. Kurtosis (excess, on magnitude signal)
    double mean = 0.0;
    for (int i = 0; i < windowSize; i++) {
      mean += magnitude[i];
    }
    mean /= windowSize;
    double m2 = 0.0, m4 = 0.0;
    for (int i = 0; i < windowSize; i++) {
      final d = magnitude[i] - mean;
      m2 += d * d;
      m4 += d * d * d * d;
    }
    m2 /= windowSize;
    m4 /= windowSize;
    final kurtosis = m2 > 0.00001 ? (m4 / (m2 * m2)) - 3.0 : 0.0;

    // 4. FFT (radix-2 DIT) on magnitude signal with Hanning window
    final fftMagnitudes = _computeFFT(magnitude);

    // 4b. PSD slope computation (log-log regression in 0.78-5 Hz band)
    // Discriminates: earthquake ~-0.5, landslide ~-3 to -9, noise ~-9
    final binResolution = sampleRate.toDouble() / windowSize;
    double psdSlope = 0.0;
    {
      // PSD[i] = |FFT[i]|² / (sampleRate * windowSize) for proper normalization
      // Fit linear regression on log10(PSD) vs log10(freq) in bins 1-6 (~0.78-5 Hz)
      const int startBin = 1;
      const int endBin = 7; // exclusive, so bins 1-6
      final actualEnd = endBin.clamp(0, fftMagnitudes.length);
      if (actualEnd > startBin) {
        double sumX = 0, sumY = 0, sumXX = 0, sumXY = 0;
        int count = 0;
        for (int i = startBin; i < actualEnd; i++) {
          final freq = i * binResolution;
          // Hanning ENBW correction: divide by 1.5 (energy bandwidth factor)
          final psd = fftMagnitudes[i] * fftMagnitudes[i] / (sampleRate * windowSize * 1.5);
          if (freq > 0 && psd > 1e-20) {
            final logFreq = log(freq) / ln10;
            final logPsd = log(psd) / ln10;
            sumX += logFreq;
            sumY += logPsd;
            sumXX += logFreq * logFreq;
            sumXY += logFreq * logPsd;
            count++;
          }
        }
        if (count >= 2) {
          final denom = count * sumXX - sumX * sumX;
          if (denom.abs() > 1e-12) {
            psdSlope = (count * sumXY - sumX * sumY) / denom;
          }
        }
      }
    }

    // 5. Dominant frequency and spectral centroid
    double maxMag = 0.0;
    int maxBin = 1;
    double magRmsSum = 0.0;
    const halfN = windowSize ~/ 2;

    for (int i = 1; i < halfN; i++) {
      magRmsSum += fftMagnitudes[i] * fftMagnitudes[i];
      if (fftMagnitudes[i] > maxMag) {
        maxMag = fftMagnitudes[i];
        maxBin = i;
      }
    }
    final noiseFloor = sqrt(magRmsSum / (halfN - 1)) * 3.0;

    final dominantFreq = maxMag > noiseFloor ? maxBin * binResolution : 0.0;

    double spectralCentroid = 0.0;
    if (maxMag > noiseFloor) {
      double weightedSum = 0.0, magnitudeSum = 0.0;
      for (int i = 1; i < halfN; i++) {
        final freq = i * binResolution;
        weightedSum += freq * fftMagnitudes[i];
        magnitudeSum += fftMagnitudes[i];
      }
      spectralCentroid = magnitudeSum > 0.001 ? weightedSum / magnitudeSum : 0.0;
    }

    // 6. 3-level Haar DWT
    final dwtResult = _computeHaarDWT(magnitude, 3);

    // 7. Arias Intensity accumulation (per window)
    // AI = (pi / 2g) * integral(a^2 dt), a in g
    double windowArias = 0.0;
    double windowCav = 0.0;
    for (int i = 0; i < windowSize; i++) {
      windowArias += (pi / (2.0 * 9.81)) * magnitude[i] * magnitude[i] * dt;
      windowCav += magnitude[i] * dt;
    }
    ariasIntensity += windowArias;
    cav += windowCav;

    // Auto-reset Arias/CAV every 60s
    final now = DateTime.now();
    if (now.difference(_lastAriasReset) >= ariasResetInterval) {
      ariasIntensity = 0.0;
      cav = 0.0;
      _lastAriasReset = now;
    }

    return DspResult(
      rms: rms,
      peak: peak,
      crestFactor: crestFactor,
      kurtosis: kurtosis,
      dominantFreq: dominantFreq,
      spectralCentroid: spectralCentroid,
      fftMagnitudes: fftMagnitudes.sublist(0, halfN),
      dwtEnergy1: dwtResult.energy1,
      dwtEnergy2: dwtResult.energy2,
      dwtEnergy3: dwtResult.energy3,
      ariasIntensity: ariasIntensity,
      cav: cav,
      psdSlope: psdSlope,
    );
  }

  /// Radix-2 DIT FFT with Hanning window.
  /// Returns magnitude spectrum (full N points, use first N/2).
  List<double> _computeFFT(List<double> signal) {
    final n = signal.length;
    // Apply Hanning window
    final real = Float64List(n);
    final imag = Float64List(n);
    for (int i = 0; i < n; i++) {
      final window = 0.5 * (1.0 - cos(2.0 * pi * i / n));
      real[i] = signal[i] * window;
      imag[i] = 0.0;
    }

    // Bit-reversal permutation
    int j = 0;
    for (int i = 0; i < n - 1; i++) {
      if (i < j) {
        final tmpR = real[i]; real[i] = real[j]; real[j] = tmpR;
        final tmpI = imag[i]; imag[i] = imag[j]; imag[j] = tmpI;
      }
      int k = n >> 1;
      while (k <= j) {
        j -= k;
        k >>= 1;
      }
      j += k;
    }

    // FFT butterfly
    for (int len = 2; len <= n; len <<= 1) {
      final halfLen = len >> 1;
      final angle = -2.0 * pi / len;
      final wR = cos(angle);
      final wI = sin(angle);
      for (int i = 0; i < n; i += len) {
        double curR = 1.0, curI = 0.0;
        for (int k = 0; k < halfLen; k++) {
          final tR = curR * real[i + k + halfLen] - curI * imag[i + k + halfLen];
          final tI = curR * imag[i + k + halfLen] + curI * real[i + k + halfLen];
          real[i + k + halfLen] = real[i + k] - tR;
          imag[i + k + halfLen] = imag[i + k] - tI;
          real[i + k] += tR;
          imag[i + k] += tI;
          final newR = curR * wR - curI * wI;
          curI = curR * wI + curI * wR;
          curR = newR;
        }
      }
    }

    // Compute magnitudes
    final magnitudes = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      magnitudes[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]);
    }
    return magnitudes;
  }

  /// 3-level Haar DWT. Returns detail energies per level.
  _DwtResult _computeHaarDWT(List<double> signal, int levels) {
    final temp = List<double>.from(signal);
    final energies = <double>[];

    int len = temp.length;
    for (int level = 0; level < levels; level++) {
      final halfLen = len ~/ 2;
      final approx = List<double>.filled(halfLen, 0.0);
      final detail = List<double>.filled(halfLen, 0.0);
      const invSqrt2 = 0.70710678118;

      for (int i = 0; i < halfLen; i++) {
        approx[i] = (temp[2 * i] + temp[2 * i + 1]) * invSqrt2;
        detail[i] = (temp[2 * i] - temp[2 * i + 1]) * invSqrt2;
      }

      // Compute energy for this detail level
      double energy = 0.0;
      for (int i = 0; i < halfLen; i++) {
        energy += detail[i] * detail[i];
      }
      energies.add(energy);

      // Copy approx back for next level
      for (int i = 0; i < halfLen; i++) {
        temp[i] = approx[i];
      }
      len = halfLen;
    }

    return _DwtResult(
      energy1: energies.isNotEmpty ? energies[0] : 0.0,
      energy2: energies.length > 1 ? energies[1] : 0.0,
      energy3: energies.length > 2 ? energies[2] : 0.0,
    );
  }

  /// Compute vector magnitude PPV from 3-axis raw acceleration data.
  ///
  /// More conservative than max-of-axes per ISO 4866. Integrates each axis
  /// to velocity using trapezoidal rule, then computes vector magnitude PPV.
  ///
  /// [accelX], [accelY], [accelZ] are filtered acceleration in g units,
  /// each containing [windowSize] samples.
  ///
  /// Returns PPV in mm/s.
  double computeVectorSumPPV(List<double> accelX, List<double> accelY, List<double> accelZ) {
    assert(accelX.length == accelY.length);
    assert(accelY.length == accelZ.length);

    final n = accelX.length;
    if (n < 2) return 0.0;

    // Frequency-domain integration: FFT(accel), divide by jω, IFFT
    // This avoids DC drift from time-domain trapezoidal integration
    // PPV = max per-axis peak velocity (PCPV per DIN 4150-3)
    final peakVelX = _freqDomainPeakVelocity(accelX);
    final peakVelY = _freqDomainPeakVelocity(accelY);
    final peakVelZ = _freqDomainPeakVelocity(accelZ);

    final rawPPV = [peakVelX, peakVelY, peakVelZ].reduce((a, b) => a > b ? a : b);

    // Noise floor calibration: average first N windows, subtract with 20% margin
    if (!_ppvCalibrated) {
      _calibrationSum += rawPPV;
      _calibrationCount++;
      if (_calibrationCount >= _calibrationWindows) {
        _ppvNoiseFloor = (_calibrationSum / _calibrationCount) * 1.2;
        _ppvCalibrated = true;
      }
      return 0.0; // Return 0 during calibration
    }

    final calibrated = rawPPV - _ppvNoiseFloor;
    return calibrated > 0 ? calibrated : 0.0;
  }

  /// Compute peak velocity from acceleration using frequency-domain integration.
  /// accel in g units, returns peak velocity in mm/s.
  double _freqDomainPeakVelocity(List<double> accel) {
    final n = accel.length;
    const double gToMmPerS2 = 9810.0;
    final freqRes = sampleRate / n; // Hz per bin

    // Simple DFT on real signal (only need magnitudes, use Goertzel-like approach)
    // For efficiency, compute velocity RMS from spectral integration
    // V(f) = A(f) / (2πf), so |V|² = |A|² / (2πf)²
    double velSumSq = 0.0;
    for (int k = 1; k <= n ~/ 2; k++) {
      final freq = k * freqRes;
      if (freq < 0.5 || freq > 100.0) continue; // DIN 4150-3 range

      // Compute DFT bin magnitude for this frequency
      double realPart = 0.0, imagPart = 0.0;
      final w = 2.0 * pi * k / n;
      for (int i = 0; i < n; i++) {
        realPart += accel[i] * cos(w * i);
        imagPart -= accel[i] * sin(w * i);
      }
      // Single-sided amplitude spectrum: 2/N² for bins 1..N/2-1
      final accelMagSq = (realPart * realPart + imagPart * imagPart) * 2.0 / (n * n);

      // Integrate in frequency domain: V = A / (2πf)
      final omega = 2.0 * pi * freq;
      final velMagSq = accelMagSq * gToMmPerS2 * gToMmPerS2 / (omega * omega);
      velSumSq += velMagSq;
    }

    // Peak velocity ≈ sqrt(2) * RMS for sinusoidal signals
    // For broadband, use crest factor of ~3 as conservative estimate
    // But simpler: peak = sqrt(2 * sum of squared velocity amplitudes) for Parseval
    return sqrt(velSumSq) * 3.0; // RMS to peak (conservative broadband crest factor)
  }

  /// Compute raw (uncalibrated) PPV for use in isolate.
  double _computeRawPPV(List<double> accelX, List<double> accelY, List<double> accelZ) {
    final n = accelX.length;
    if (n < 2) return 0.0;
    final peakVelX = _freqDomainPeakVelocity(accelX);
    final peakVelY = _freqDomainPeakVelocity(accelY);
    final peakVelZ = _freqDomainPeakVelocity(accelZ);
    return [peakVelX, peakVelY, peakVelZ].reduce((a, b) => a > b ? a : b);
  }

  /// Reset running accumulators (e.g. when reconnecting)
  void reset() {
    ariasIntensity = 0.0;
    cav = 0.0;
    _lastAriasReset = DateTime.now();
    _ppvNoiseFloor = 0.0;
    _ppvCalibrated = false;
    _calibrationCount = 0;
    _calibrationSum = 0.0;
  }

  /// Clean up resources
  void dispose() {
    ariasIntensity = 0.0;
    cav = 0.0;
  }
}

/// Result of phone-side DSP processing on one acceleration window.
class DspResult {
  final double rms;
  final double peak;
  final double crestFactor;
  final double kurtosis;
  final double dominantFreq;
  final double spectralCentroid;
  final List<double> fftMagnitudes; // First N/2 bins
  final double dwtEnergy1; // 50-100Hz band
  final double dwtEnergy2; // 25-50Hz band
  final double dwtEnergy3; // 12.5-25Hz band
  final double ariasIntensity;
  final double cav;
  final double psdSlope; // Log-log PSD slope (β exponent) in 0.78-5 Hz band

  const DspResult({
    required this.rms,
    required this.peak,
    required this.crestFactor,
    required this.kurtosis,
    required this.dominantFreq,
    required this.spectralCentroid,
    required this.fftMagnitudes,
    required this.dwtEnergy1,
    required this.dwtEnergy2,
    required this.dwtEnergy3,
    required this.ariasIntensity,
    required this.cav,
    required this.psdSlope,
  });

  /// Convert to feature map for anomaly detection pipeline.
  Map<String, double> toFeatureMap({
    required double ppv,
    required double stalta,
    required double temp,
  }) {
    return {
      'rms': rms,
      'ppv': ppv,
      'freq': dominantFreq,
      'crest': crestFactor,
      'centroid': spectralCentroid,
      'kurtosis': kurtosis,
      'stalta': stalta,
      'arias': ariasIntensity,
      'cav': cav,
      'temp': temp,
      'psdSlope': psdSlope,
    };
  }
}

class _DwtResult {
  final double energy1;
  final double energy2;
  final double energy3;
  const _DwtResult({required this.energy1, required this.energy2, required this.energy3});
}
