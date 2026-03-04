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

  /// Expose the configured sample rate as an instance getter (same as [sampleRate]).
  int get sampleRateHz => sampleRate;

  // Running accumulators (persist across windows)
  double ariasIntensity = 0.0;
  double cav = 0.0;
  DateTime _lastAriasReset = DateTime.now();
  static const Duration ariasResetInterval = Duration(seconds: 60);

  // Single-entry result cache keyed by first+last 4 sample values of each axis.
  // Avoids redundant heavy DSP when the same buffer arrives twice (e.g. BLE retry).
  _CacheKey? _lastCacheKey;
  DspResult? _lastCachedResult;

  // Signal quality tracking
  int _clipCount = 0;

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
      spectralBandwidth: response.dspResult.spectralBandwidth,
      zeroCrossingRate: response.dspResult.zeroCrossingRate,
      lfRatio: response.dspResult.lfRatio,
      mfRatio: response.dspResult.mfRatio,
      hfRatio: response.dspResult.hfRatio,
      temporalSymmetry: response.dspResult.temporalSymmetry,
    );

    return (dsp: dsp, ppv: calibratedPPV);
  }

  /// Process a raw acceleration buffer and return all computed features.
  ///
  /// [accelX], [accelY], [accelZ] are filtered acceleration in g units,
  /// each containing [windowSize] samples.
  ///
  /// Returns a cached result when the same buffer is submitted twice (detected
  /// via a lightweight hash of the first + last 4 sample values per axis).
  DspResult process(List<double> accelX, List<double> accelY, List<double> accelZ) {
    assert(accelX.length == windowSize);
    assert(accelY.length == windowSize);
    assert(accelZ.length == windowSize);

    // Cache check: hash first+last 4 values of each axis.
    final cacheKey = _CacheKey.from(accelX, accelY, accelZ);
    if (_lastCachedResult != null && _lastCacheKey == cacheKey) {
      return _lastCachedResult!;
    }

    // Count clipped samples (|value| > 15.3 g ≈ 150 m/s²) on any axis.
    // The IMU range is ±16 g; samples above ~95% of FS are treated as saturated.
    _clipCount = 0;
    for (int i = 0; i < windowSize; i++) {
      if (accelX[i].abs() > 15.0 || accelY[i].abs() > 15.0 || accelZ[i].abs() > 15.0) {
        _clipCount++;
      }
    }

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

    // 8. Spectral bandwidth
    // bandwidth = sqrt( Σ(f - fc)² × S(f) / Σ S(f) )
    // where fc = spectralCentroid and S(f) = fftMagnitudes[i] (linear amplitude).
    // Narrow bandwidth → tonal; wide → broadband noise.
    double spectralBandwidth = 0.0;
    {
      double weightedVarSum = 0.0;
      double magSum = 0.0;
      for (int i = 1; i < halfN; i++) {
        final freq = i * binResolution;
        final s = fftMagnitudes[i];
        final diff = freq - spectralCentroid;
        weightedVarSum += diff * diff * s;
        magSum += s;
      }
      spectralBandwidth = magSum > 0.001 ? sqrt(weightedVarSum / magSum) : 0.0;
    }

    // 9. Zero-crossing rate (on raw magnitude signal)
    // ZCR = number of sign changes / windowSize.
    // Uses the mean-removed signal so that a DC offset does not suppress crossings.
    int zeroCrossings = 0;
    {
      final meanMag = rms; // use RMS as a reasonable centre reference
      bool prevPositive = magnitude[0] >= meanMag;
      for (int i = 1; i < windowSize; i++) {
        final currentPositive = magnitude[i] >= meanMag;
        if (currentPositive != prevPositive) zeroCrossings++;
        prevPositive = currentPositive;
      }
    }
    final zeroCrossingRate = zeroCrossings / windowSize.toDouble();

    // 10. Frequency band energy ratios
    // LF: 1–10 Hz, MF: 10–50 Hz, HF: 50–100 Hz
    // Ratios relative to total spectral energy (bins 1..halfN-1).
    // Help distinguish soil movement (LF) from impact events (HF).
    double lfEnergy = 0.0, mfEnergy = 0.0, hfEnergy = 0.0, totalEnergy = 0.0;
    {
      for (int i = 1; i < halfN; i++) {
        final freq = i * binResolution;
        final energyBin = fftMagnitudes[i] * fftMagnitudes[i];
        totalEnergy += energyBin;
        if (freq >= 1.0 && freq < 10.0) {
          lfEnergy += energyBin;
        } else if (freq >= 10.0 && freq < 50.0) {
          mfEnergy += energyBin;
        } else if (freq >= 50.0 && freq <= 100.0) {
          hfEnergy += energyBin;
        }
      }
    }
    final lfRatio = totalEnergy > 1e-20 ? lfEnergy / totalEnergy : 0.0;
    final mfRatio = totalEnergy > 1e-20 ? mfEnergy / totalEnergy : 0.0;
    final hfRatio = totalEnergy > 1e-20 ? hfEnergy / totalEnergy : 0.0;

    // 11. Temporal symmetry index
    // Compares first half with reversed second half of the magnitude signal.
    // 1.0 = symmetric continuous vibration; < 0.5 = asymmetric transient impact.
    final temporalSymmetry = _computeTemporalSymmetry(magnitude);

    final result = DspResult(
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
      spectralBandwidth: spectralBandwidth,
      zeroCrossingRate: zeroCrossingRate,
      lfRatio: lfRatio,
      mfRatio: mfRatio,
      hfRatio: hfRatio,
      temporalSymmetry: temporalSymmetry,
    );

    // Store in single-entry cache.
    _lastCacheKey = cacheKey;
    _lastCachedResult = result;
    return result;
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

  /// Temporal symmetry index.
  ///
  /// Compares the first half of [signal] with the reversed second half.
  /// Returns 1.0 for a perfectly symmetric signal (e.g. continuous sinusoidal
  /// vibration) and approaches 0.0 for highly asymmetric transient impacts.
  ///
  /// Formula: 1 − clamp( Σ|a_i − b_i| / Σ(|a_i| + |b_i| + ε) )
  double _computeTemporalSymmetry(List<double> signal) {
    if (signal.length < 4) return 1.0;
    final half = signal.length ~/ 2;
    double num = 0, den = 0;
    for (int i = 0; i < half; i++) {
      final a = signal[i];
      final b = signal[signal.length - 1 - i]; // reversed second half
      num += (a - b).abs();
      den += a.abs() + b.abs() + 1e-10;
    }
    return 1.0 - (num / den).clamp(0.0, 1.0);
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

  /// Signal quality score in the range 0.0–1.0.
  ///
  /// 1.0 = clean, non-saturated signal with non-Gaussian content (kurtosis > 1).
  /// 0.0 = heavily clipped or no result available.
  ///
  /// Clipping (any sample ≥ 15 g, ~95% of the ±16 g FS range) is penalised
  /// heavily because saturated samples corrupt FFT and kurtosis estimates.
  /// When the signal is clean the score is boosted by excess kurtosis: a flat
  /// Gaussian noise floor (kurtosis ≈ 0) scores 0.5 while a highly impulsive
  /// signal (kurtosis ≥ 9) scores 1.0.
  double get signalQuality {
    if (_lastCachedResult == null) return 0.0;
    if (_clipCount > 0) {
      // Each clipped sample degrades quality; cap at 0.5 ceiling.
      return (1.0 - (_clipCount / windowSize)).clamp(0.0, 1.0) * 0.5;
    }
    // Reward non-trivial signal via excess kurtosis (kurtosis > 1 → non-flat).
    final kScore = ((_lastCachedResult!.kurtosis - 1.0) / 9.0).clamp(0.0, 1.0);
    return 0.5 + kScore * 0.5;
  }

  /// True when more than 10 samples in the most recent window were saturated.
  ///
  /// At that point kurtosis and spectral estimates are unreliable and the
  /// caller should discard the [DspResult] and alert the user.
  bool get isSignalSaturated => _clipCount > 10;

  /// Estimated signal-to-noise ratio in dB, derived from the ratio of RMS
  /// amplitude to an approximated noise floor.
  ///
  /// The "noise floor" is approximated as `rms / kurtosis` — low kurtosis
  /// signals are closer to Gaussian noise, so the effective SNR is low.
  /// Range is 0–40 dB. Returns 0 when no result is available.
  double get snrDb {
    if (_lastCachedResult == null) return 0.0;
    final signal = _lastCachedResult!.rms;
    if (signal <= 0) return 0.0;
    final k = _lastCachedResult!.kurtosis.clamp(1.0, 10.0);
    // noise ≈ rms / k; ratio = signal / noise = k
    final ratio = k;
    return (20.0 * log(ratio) / ln10).clamp(0.0, 40.0);
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
    _lastCacheKey = null;
    _lastCachedResult = null;
    _clipCount = 0;
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

  /// Spectral bandwidth: sqrt(Σ(f-fc)²·S(f) / Σ S(f)) in Hz.
  /// Narrow = tonal; wide = broadband noise.
  final double spectralBandwidth;

  /// Zero-crossing rate: sign-change count / window length (crossings per sample).
  /// High ZCR → high-frequency content; low ZCR → low-frequency / DC content.
  final double zeroCrossingRate;

  /// Fraction of spectral energy in the 1–10 Hz low-frequency band.
  /// Elevated lfRatio is characteristic of soil creep and slow mass movement.
  final double lfRatio;

  /// Fraction of spectral energy in the 10–50 Hz mid-frequency band.
  final double mfRatio;

  /// Fraction of spectral energy in the 50–100 Hz high-frequency band.
  /// Elevated hfRatio is characteristic of impact events and machinery.
  final double hfRatio;

  /// Temporal symmetry index in 0.0–1.0.
  /// 1.0 = perfectly symmetric (continuous vibration); lower = asymmetric (impact).
  final double temporalSymmetry;

  /// Impulse factor: peak / RMS.
  /// Higher values indicate sharp transient impacts (distinct from crest factor
  /// which is peak / mean-absolute).
  double get impulse => rms > 1e-10 ? peak / rms : 0.0;

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
    this.spectralBandwidth = 0.0,
    this.zeroCrossingRate = 0.0,
    this.lfRatio = 0.0,
    this.mfRatio = 0.0,
    this.hfRatio = 0.0,
    this.temporalSymmetry = 1.0,
  });

  /// Human-readable quality label based on excess kurtosis and RMS energy.
  ///
  /// | Label     | Condition                              |
  /// |-----------|----------------------------------------|
  /// | Excellent | kurtosis > 5 and rms > 0.01            |
  /// | Good      | kurtosis > 2                           |
  /// | Fair      | kurtosis > 1.5                         |
  /// | Poor      | otherwise (flat / near-zero signal)    |
  String get qualityLabel {
    if (kurtosis > 5.0 && rms > 0.01) return 'Excellent';
    if (kurtosis > 2.0) return 'Good';
    if (kurtosis > 1.5) return 'Fair';
    return 'Poor';
  }

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
      'spectralBandwidth': spectralBandwidth,
      'zeroCrossingRate': zeroCrossingRate,
      'lfRatio': lfRatio,
      'mfRatio': mfRatio,
      'hfRatio': hfRatio,
      'temporalSymmetry': temporalSymmetry,
      'impulse': impulse,
    };
  }
}

class _DwtResult {
  final double energy1;
  final double energy2;
  final double energy3;
  const _DwtResult({required this.energy1, required this.energy2, required this.energy3});
}

/// Lightweight cache key built from the first + last 4 samples of each axis.
/// Collisions are astronomically unlikely for real sensor data.
class _CacheKey {
  final List<double> _values;

  _CacheKey._(this._values);

  factory _CacheKey.from(
    List<double> x,
    List<double> y,
    List<double> z,
  ) {
    final n = x.length;
    final vals = <double>[];
    // First 4 samples of each axis.
    for (int i = 0; i < 4 && i < n; i++) {
      vals.add(x[i]);
      vals.add(y[i]);
      vals.add(z[i]);
    }
    // Last 4 samples of each axis (guard against n < 8).
    final start = n > 4 ? n - 4 : 4;
    for (int i = start; i < n; i++) {
      vals.add(x[i]);
      vals.add(y[i]);
      vals.add(z[i]);
    }
    return _CacheKey._(vals);
  }

  @override
  bool operator ==(Object other) {
    if (other is! _CacheKey) return false;
    if (_values.length != other._values.length) return false;
    for (int i = 0; i < _values.length; i++) {
      if (_values[i] != other._values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_values);
}
