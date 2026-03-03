# Vibration Noise Isolation & Hazard Detection System
## Comprehensive Research Document

**Project:** AncientVision - Archaeological Site Safety Monitor
**Version:** 3.0
**Standard:** DIN 4150-3:1999
**Date:** February 2026

> **Note:** This document covers the v2.0/v3.0 firmware architecture. For the current v4.0 features (Arias Intensity, CAV, 3-level DWT, IMU temperature compensation, recursive STA/LTA, VAE anomaly detection), see [VIBRATION_RESEARCH_2026.md](VIBRATION_RESEARCH_2026.md).

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [The Problem (Before v2.0)](#2-the-problem-before-v20)
3. [International Standards Research](#3-international-standards-research)
4. [Signal Processing Pipeline (Firmware)](#4-signal-processing-pipeline-firmware)
5. [Hazard Classification (Tier 1 - Firmware Rules)](#5-hazard-classification-tier-1---firmware-rules)
6. [ML Anomaly Detection (Tier 2 - Flutter App)](#6-ml-anomaly-detection-tier-2---flutter-app)
7. [BLE Protocol (v2.0)](#7-ble-protocol-v20)
8. [Flutter App UI Components](#8-flutter-app-ui-components)
9. [Known Limitations & Future Work](#9-known-limitations--future-work)
10. [Academic References](#10-academic-references)
11. [File Inventory](#11-file-inventory)

---

## 1. Executive Summary

The AncientVision Vibration Analysis System is a two-tier vibration monitoring solution designed for archaeological excavation safety. It replaces a naive single-threshold approach (0.3g/0.8g magnitude) with a scientifically grounded pipeline that can distinguish between footsteps, wind, heavy machinery, seismic events, and structural collapse.

**What was built:**
- **Tier 1 (Firmware):** Real-time digital signal processing on ESP32 (M5StickC Plus 2) - 200 Hz sampling, hardware DLPF, Butterworth bandpass filter, 256-point FFT, PPV computation, and DIN 4150-3 rule-based hazard classification
- **Tier 2 (App ML):** TensorFlow Lite autoencoder running on the phone to detect subtle anomalies that fixed thresholds cannot catch

**Why:**
- The v1.0 system sampled at only 10 Hz and used a simple `sqrt(x^2 + y^2 + z^2) - 1g` magnitude with fixed thresholds
- It could not determine vibration frequency, source type, or actual structural risk
- A person walking near the sensor triggered the same alert as heavy machinery operating at dangerous levels
- Archaeological sites protected by international heritage standards (DIN 4150-3) require frequency-dependent PPV analysis, not simple acceleration thresholds

**Key achievement:** The world's first open-source, DIN 4150-3 compliant archaeological site vibration monitor running on a $20 microcontroller with ML anomaly detection on a smartphone.

---

## 2. The Problem (Before v2.0)

### v1.0 Implementation Analysis

The original firmware had critical limitations for vibration safety monitoring:

| Parameter | v1.0 | v2.0 |
|-----------|------|------|
| Sample rate | 10 Hz (100ms interval) | 200 Hz (5ms interval) |
| Max detectable frequency | 5 Hz (Nyquist) | 100 Hz (Nyquist) |
| Filtering | None | Hardware DLPF + Butterworth bandpass |
| Frequency analysis | None | 256-point FFT |
| Primary metric | Raw acceleration magnitude (g) | PPV (mm/s) per DIN 4150-3 |
| Source identification | Impossible | 7 hazard types classified |
| Anti-aliasing | None | Hardware DLPF at 99 Hz |
| Alert logic | 2 fixed thresholds | Priority-ordered rule tree |

### Why 10 Hz Sampling Was Useless

The Nyquist theorem states that to capture a vibration at frequency `f`, you must sample at least `2f`. At 10 Hz sampling:
- Maximum detectable frequency: 5 Hz
- Heavy machinery vibrations (10-50 Hz): **invisible**
- Structural resonance (20-80 Hz): **invisible**
- Pile driving (25-50 Hz): **invisible**
- Only earthquake-like events (0.1-5 Hz) could potentially be detected, but without filtering or FFT, even these were unreliable

### Why Magnitude Thresholds Were Wrong

The v1.0 approach computed:
```
vibration = sqrt(accX^2 + accY^2 + accZ^2) - 1.0
```

Problems:
1. **No frequency information** - a 0.5g vibration at 2 Hz (footstep) is harmless, but 0.5g at 30 Hz (machinery) can damage heritage structures
2. **Gravity removal assumes fixed orientation** - tilting the sensor 30 degrees causes ~0.13g error, triggering false alerts
3. **No velocity computation** - international standards use PPV (Peak Particle Velocity) in mm/s, not acceleration in g
4. **No source discrimination** - wind, footsteps, trucks, and earthquakes all produce the same scalar output

---

## 3. International Standards Research

### 3.1 DIN 4150-3:1999 - Structural Vibration Effects on Structures

DIN 4150-3 is the German standard (adopted internationally) for evaluating the effects of vibration on structures. Part 3 specifically covers "Effects on structures" and provides PPV (Peak Particle Velocity) guideline values.

**Guideline values for heritage/archaeological structures (Line 3 - most sensitive):**

| Frequency Range | PPV Limit (mm/s) | Rationale |
|----------------|-------------------|-----------|
| 1 - 10 Hz | 3.0 | Low-frequency resonance of masonry/stone |
| 10 - 50 Hz | 3.0 - 8.0 | Interpolated (linear) |
| 50 - 100 Hz | 8.0 - 10.0 | Higher frequencies less damaging |
| Continuous vibration | 2.5 | Long-term fatigue limit, any frequency |

**Key points:**
- PPV (Peak Particle Velocity) is the standard metric, not acceleration
- Limits are frequency-dependent - this is why FFT analysis is essential
- Heritage structures have the lowest limits (Line 3)
- Human perception threshold: 0.14 - 0.3 mm/s PPV
- Below 0.3 mm/s, vibrations are imperceptible and structurally irrelevant

**Why PPV and not acceleration?**
Structural damage correlates better with particle velocity than acceleration. Velocity is proportional to strain in the structure, while acceleration is proportional to force. A high-frequency, low-amplitude vibration produces high acceleration but low velocity (low strain), making it less damaging than a low-frequency, high-amplitude vibration with the same acceleration.

### 3.2 ISO 2631-1:1997 - Human Whole-Body Vibration

While DIN 4150-3 protects structures, ISO 2631-1 protects people. It defines frequency-weighted acceleration limits for human exposure:

- **Perception threshold:** 0.015 m/s^2 (0.0015g) at 1-80 Hz
- **Discomfort threshold:** 0.315 m/s^2 (0.032g)
- **Health risk (8h exposure):** 1.15 m/s^2 (0.117g)

These values are much lower than structural damage thresholds, meaning human discomfort is detectable before structural risk. Our system operates in the overlap where both standards are relevant.

### 3.3 Vibration Source Frequency Signatures

Research literature provides characteristic frequency ranges for common vibration sources at archaeological sites:

| Source | Frequency Range | Typical PPV | Danger to Heritage |
|--------|----------------|-------------|-------------------|
| Earthquake | 0.1 - 30 Hz | 1 - 100+ mm/s | Critical |
| Ground collapse | 0.1 - 1 Hz | Variable | Critical |
| Blasting (nearby) | 1 - 300 Hz | 5 - 50+ mm/s | Critical |
| Pile driving | 25 - 50 Hz | 2 - 20 mm/s | High |
| Heavy machinery (excavator) | 10 - 50 Hz | 1 - 10 mm/s | Warning |
| Road traffic (heavy trucks) | 5 - 25 Hz | 0.5 - 5 mm/s | Warning |
| Footsteps | 1 - 5 Hz | 0.01 - 0.3 mm/s | Safe |
| Wind/ambient | 0.01 - 1 Hz | 0.001 - 0.05 mm/s | Safe |
| Hand tools (trowels/brushes) | 3 - 20 Hz | 0.1 - 0.8 mm/s | Safe |

This table is the foundation of our hazard classification rules. The frequency ranges allow us to identify the source type, while the PPV values determine the severity level.

---

## 4. Signal Processing Pipeline (Firmware)

The complete DSP pipeline runs on the ESP32-PICO-V3 processor inside the M5StickC Plus 2 (240 MHz dual-core, 520 KB SRAM).

```
Raw IMU (200Hz) --> DLPF (99Hz HW) --> HPF 0.5Hz --> LPF 100Hz --> FFT (256-pt)
                                                                        |
                     BLE JSON <-- DIN 4150-3 Classification <-- PPV/RMS/Crest/Freq
```

### 4.1 Sampling: 200 Hz with Hardware DLPF

**IMU sampling at 200 Hz:**
- Timer: `micros()` with 5000 us interval (5 ms = 200 Hz)
- Read: `M5.Imu.getAccelData(&accX, &accY, &accZ)` returns 3-axis acceleration in g
- The MPU6886 IMU chip can output data at up to 1 kHz; we read at 200 Hz

**Hardware DLPF (Digital Low-Pass Filter):**
- The MPU6886 has a built-in configurable DLPF
- We configure it via direct I2C register writes:
  ```cpp
  // Register 0x1A (CONFIG) - set DLPF bandwidth
  Wire1.beginTransmission(0x68);  // MPU6886 I2C address
  Wire1.write(0x1A);              // CONFIG register
  Wire1.write(0x02);              // DLPF_CFG = 2 -> 99 Hz bandwidth, 2.9 ms delay
  Wire1.endTransmission();

  // Register 0x1D (ACCEL_CONFIG2) - set accelerometer bandwidth
  Wire1.beginTransmission(0x68);
  Wire1.write(0x1D);              // ACCEL_CONFIG2 register
  Wire1.write(0x02);              // A_DLPF_CFG = 2 -> 99 Hz bandwidth
  Wire1.endTransmission();
  ```
- This provides hardware anti-aliasing: any frequency above 99 Hz is attenuated before our 200 Hz sampling, preventing aliasing artifacts
- The 2.9 ms group delay is negligible for our 1.28 s analysis windows

### 4.2 Butterworth Bandpass Filter (0.5-100 Hz)

After sampling, we apply a software bandpass filter implemented as two cascaded 2nd-order IIR (Infinite Impulse Response) biquad filters:

**High-pass filter at 0.5 Hz** (removes gravity and DC drift):
```
Transfer function: H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)

Coefficients (bilinear transform, fs=200 Hz, fc=0.5 Hz):
  b0 =  0.99222
  b1 = -1.98443
  b2 =  0.99222
  a1 = -1.98439
  a2 =  0.98448
```

**Low-pass filter at 100 Hz** (removes high-frequency electrical noise):
```
Coefficients (bilinear transform, fs=200 Hz, fc=100 Hz):
  b0 = 0.29289
  b1 = 0.58579
  b2 = 0.29289
  a1 = 0.0
  a2 = 0.17157
```

**Implementation** - zero external library dependency:
```cpp
struct BiquadFilter {
  float b0, b1, b2, a1, a2;
  float x1, x2, y1, y2;  // state variables (previous I/O)

  float process(float input) {
    float output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = input;
    y2 = y1; y1 = output;
    return output;
  }
};
```

The biquad (bi-quadratic) structure is numerically stable and requires only 5 multiply-accumulate operations per sample, well within the ESP32's capabilities at 200 Hz.

### 4.3 FFT Frequency Analysis

After collecting 256 filtered samples (1.28 seconds at 200 Hz), we perform frequency analysis:

1. **Copy filtered acceleration data to FFT input arrays** (`vReal[256]`, `vImag[256]`)
2. **Apply Hanning window** to reduce spectral leakage:
   - Without windowing, the FFT assumes the signal is periodic within the window
   - Non-periodic signals "leak" energy into adjacent frequency bins
   - The Hanning window `w(n) = 0.5 * (1 - cos(2*pi*n/N))` tapers the signal to zero at window edges
3. **Compute 256-point FFT** using the `arduinoFFT` library (Cooley-Tukey algorithm)
4. **Convert to magnitudes** - each bin now contains the amplitude at that frequency

**Frequency resolution:**
```
delta_f = fs / N = 200 / 256 = 0.78125 Hz per bin
```

This means we can distinguish frequencies 0.78 Hz apart - sufficient for classifying vibration sources (earthquake vs. machinery vs. footsteps).

**Useful frequency range:** Bin 1 (0.78 Hz) to Bin 128 (100 Hz). Bin 0 is DC (filtered out by HPF).

### 4.4 PPV Computation

Peak Particle Velocity is computed by integrating filtered acceleration to velocity:

**Method:** Trapezoidal integration
```
v[n] = v[n-1] + 0.5 * (a[n-1] + a[n]) * dt * 9810
```

Where:
- `a[n]` is filtered acceleration in g
- `dt = 1/200 = 0.005 s`
- `9810` converts g to mm/s^2 (1g = 9810 mm/s^2)
- Result `v[n]` is velocity in mm/s

**Drift correction:** Integration of noisy acceleration inherently drifts. We apply an exponential decay:
```
v[n] = v[n] * 0.998
```
This acts as a high-pass filter on the velocity signal with a time constant of about 2.5 seconds, removing slow drift while preserving vibration-frequency velocity variations.

**PPV** = maximum |v[n]| across the 256-sample window (1.28 seconds)

### 4.5 Feature Extraction

From each 256-sample window, we extract:

| Feature | Formula | Unit | Physical Meaning |
|---------|---------|------|------------------|
| RMS | `sqrt(mean(a[i]^2))` | g | Average vibration energy |
| Peak | `max(abs(a[i]))` | g | Maximum instantaneous acceleration |
| PPV | `max(abs(v[i]))` | mm/s | Peak velocity (DIN 4150-3 metric) |
| Crest Factor | `Peak / RMS` | ratio | Impulsiveness (sharp transient detection) |
| Dominant Frequency | FFT peak bin * 0.78125 | Hz | Strongest vibration frequency |
| Spectral Centroid | `sum(f[i]*mag[i]) / sum(mag[i])` | Hz | Center of mass of frequency spectrum |

**Crest Factor interpretation:**
- CF ~ 1.4: Pure sine wave (continuous machinery)
- CF ~ 2-3: Normal mixed vibrations
- CF > 5: Sharp impact (falling debris, hammer blow, collapse)

**Spectral Centroid shift detection:**
If the centroid changes by more than 50% between consecutive windows, it indicates a new vibration source has appeared or replaced the previous one. This triggers a `source_change` alert.

### 4.6 Memory Usage on ESP32

| Buffer | Size | Memory |
|--------|------|--------|
| `accelSamples[256]` | 256 floats | 1,024 bytes |
| `velocitySamples[256]` | 256 floats | 1,024 bytes |
| `vReal[256]` | 256 doubles | 2,048 bytes |
| `vImag[256]` | 256 doubles | 2,048 bytes |
| BLE stack | - | ~30 KB |
| Display framebuffer | - | ~10 KB |
| **Total** | | **~45 KB** |

ESP32 has 520 KB SRAM. Our DSP pipeline uses less than 9% of available memory.

### 4.7 Multi-Rate Timing Architecture

The firmware uses a cooperative multi-rate loop (no RTOS tasks):

| Task | Rate | Interval | Duration | Priority |
|------|------|----------|----------|----------|
| IMU Sampling | 200 Hz | 5 ms | <1 ms | Highest |
| FFT + Features | ~0.78 Hz | 1280 ms | 5-10 ms | High |
| Hazard Classification | ~0.78 Hz | After FFT | <1 ms | High |
| Moisture Read | 1 Hz | 1000 ms | <2 ms | Low |
| BLE Transmit | 2 Hz | 500 ms | <5 ms | Medium |
| Display Update | 4 Hz | 250 ms | 10-20 ms | Low |

The 200 Hz sampling is implemented with `micros()` timing to avoid jitter. All other tasks are checked with `millis()` in the main loop.

---

## 5. Hazard Classification (Tier 1 - Firmware Rules)

The firmware implements a priority-ordered decision tree based on DIN 4150-3 guideline values and vibration source frequency signatures.

### Decision Tree

| Priority | Condition | Alert Level | Hazard Type | Rationale |
|----------|-----------|-------------|-------------|-----------|
| 1 | PPV > 10 mm/s | CRITICAL | `structural` | Exceeds all DIN 4150-3 limits - structural damage imminent |
| 2 | PPV > 3 mm/s AND freq 0.5-10 Hz | CRITICAL | `seismic` | Low-frequency, high-amplitude matches earthquake signature |
| 3 | PPV > 3 mm/s AND freq 10-50 Hz | WARNING | `machinery` | Mid-frequency matches heavy construction equipment |
| 4 | PPV > 8 mm/s AND freq > 50 Hz | WARNING | `hf_stress` | High-frequency structural stress per DIN 4150-3 Line 3 |
| 5 | Crest > 5 AND PPV > 1 mm/s | WARNING | `impact` | Sharp transient (high Peak/RMS) - impact or collapse |
| 6 | PPV > 2.5 mm/s (any freq) | WARNING | `continuous` | Heritage continuous vibration limit exceeded |
| 7 | Centroid shift > 50% AND PPV > 0.5 | WARNING | `source_change` | New vibration source detected |

### Classification Logic

The rules are evaluated in priority order (highest first). The first matching rule determines the alert. This ensures that the most dangerous conditions are always reported, even if multiple rules match.

**Priority 1 (Structural Damage):** Any vibration exceeding 10 mm/s PPV at any frequency is immediately classified as structural damage risk. This is the absolute upper bound from DIN 4150-3.

**Priority 2 (Seismic):** Low-frequency vibrations (0.5-10 Hz) above 3 mm/s PPV match the earthquake/seismic signature. This is CRITICAL because low-frequency vibrations are most destructive to masonry and stone structures (resonance with building natural frequencies).

**Priority 3 (Machinery):** Mid-frequency vibrations (10-50 Hz) above 3 mm/s indicate heavy machinery (excavators, compactors, trucks). This is WARNING level because the source can typically be controlled.

**Priority 5 (Impact):** A crest factor > 5 combined with significant PPV indicates a sharp, impulsive event. Normal vibrations have crest factors of 1.4-3. Values above 5 suggest falling objects, hammer blows, or partial collapse.

**Priority 7 (Source Change):** Spectral centroid shift detection catches situations where the vibration source changes (e.g., a new machine starts operating, or ambient conditions shift suddenly). The 50% shift threshold is relative to the previous spectral centroid.

### Moisture Integration

The moisture sensor also feeds into the alert system:
- Soil moisture < 30%: WARNING (dry soil is unstable, trench wall collapse risk)
- Soil moisture > 60%: CRITICAL (wet soil increases lateral pressure, collapse risk)

Moisture alerts can override vibration alerts if the moisture condition is more severe.

---

## 6. ML Anomaly Detection (Tier 2 - Flutter App)

### 6.1 Why Two Tiers?

The firmware rule-based system (Tier 1) handles known hazard patterns using fixed thresholds derived from DIN 4150-3. However:

1. **Novel patterns**: A new type of vibration that doesn't match any rule template goes undetected
2. **Subtle drift**: Gradual changes in vibration patterns that individually stay below thresholds but collectively indicate deterioration
3. **Context-specific anomalies**: What's "normal" varies between sites - a busy urban excavation has different baseline than a remote rural dig

The autoencoder (Tier 2) addresses these by learning what "normal" looks like and flagging anything different, without needing to know what the anomaly is.

### 6.2 Architecture: Autoencoder

An autoencoder is an unsupervised neural network that learns to compress and reconstruct its input. If trained only on normal data, it will poorly reconstruct anomalous inputs, producing high reconstruction error.

```
Input [4] --> Dense(4, ReLU) --> Dense(3, ReLU) --> Dense(4, ReLU) --> Dense(4, linear) --> Output [4]
              Encoder              Bottleneck         Decoder           Reconstruction
```

| Layer | Neurons | Activation | Purpose |
|-------|---------|------------|---------|
| Input | 4 | - | [rms, ppv, freq, crest] |
| Encoder | 4 | ReLU | Feature transformation |
| Bottleneck | 3 | ReLU | Compressed representation |
| Decoder | 4 | ReLU | Reconstruction |
| Output | 4 | Linear | Reconstructed features |

**Key design choices:**
- **Bottleneck = 3**: Forces compression from 4 to 3 dimensions, requiring the model to learn the essential structure of normal vibration data
- **ReLU activation**: Standard for autoencoders; prevents vanishing gradients
- **Linear output**: Allows unbounded reconstruction (features can be negative after StandardScaler normalization)
- **Total parameters**: ~60 (extremely small - fits in 3.5 KB as TFLite)

### 6.3 Training Pipeline

**Script:** `scripts/train_vibration_autoencoder.py`

**Training data (synthetic, v1.0):**
- 2,000 samples generated with `numpy.random.seed(42)` for reproducibility
- Distribution:
  - 70% ambient (1,400 samples): PPV 0.01-0.3 mm/s, freq 0.5-8 Hz
  - 20% footsteps (400 samples): PPV 0.05-0.5 mm/s, freq 1-5 Hz
  - 10% light tools (200 samples): PPV 0.1-0.8 mm/s, freq 3-20 Hz
- All samples represent safe, normal archaeological site conditions

**Preprocessing:**
- StandardScaler normalization: `x_scaled = (x - mean) / std`
- Train/validation split: 80/20 (random_state=42)

**Training configuration:**
- Optimizer: Adam (lr=0.001)
- Loss: Mean Squared Error (MSE)
- Epochs: up to 200 with EarlyStopping (patience=20)
- ReduceLROnPlateau: factor=0.5, patience=10, min_lr=1e-6
- Batch size: 32

### 6.4 Normalization (StandardScaler)

The scaler transforms raw features to zero-mean, unit-variance:

| Feature | Mean | Std Dev | Interpretation |
|---------|------|---------|----------------|
| rms | 0.00776 g | 0.00697 g | Typical ambient RMS is ~8 mg |
| ppv | 0.1562 mm/s | 0.1308 mm/s | Normal PPV well below 3 mm/s limit |
| freq | 3.411 Hz | 2.243 Hz | Dominant frequency is low-freq ambient |
| crest | 2.200 | 0.647 | Normal crest factor around 2 |

The scaler parameters are saved to `assets/ml/vibration_scaler.json` and applied in the Flutter app before inference.

### 6.5 Anomaly Thresholds

Computed from reconstruction errors on the training data:

| Metric | Value | Meaning |
|--------|-------|---------|
| Mean reconstruction error | 0.286 MSE | Average error on normal data |
| Std reconstruction error | 0.475 MSE | Variation in normal reconstruction |
| P95 (threshold_low) | 1.030 MSE | 95% of normal data below this |
| P99 (threshold_high) | 2.419 MSE | 99% of normal data below this |

### 6.6 Classification

| Level | Condition | Color | Meaning |
|-------|-----------|-------|---------|
| Normal | MSE < 1.030 | Green | Vibration pattern matches normal training data |
| Unusual | 1.030 <= MSE < 2.419 | Yellow | Pattern is uncommon but may be within normal variation |
| Anomaly | MSE >= 2.419 | Red | Pattern significantly differs from all training data |

### 6.7 Flutter Integration

The `VibrationAnomalyService` class (singleton) handles:
1. Loading the TFLite model from `assets/ml/vibration_anomaly.tflite`
2. Loading scaler parameters from `assets/ml/vibration_scaler.json`
3. Loading thresholds from `assets/ml/vibration_model_config.json`
4. Running inference on each BLE data update (every 500 ms)

**Inference flow:**
```
BLE data --> Extract {rms, ppv, freq, crest}
         --> StandardScaler normalize
         --> TFLite interpreter.run()
         --> Compute MSE(input, output)
         --> Classify: Normal / Unusual / Anomaly
         --> Update UI (ML Anomaly Indicator widget)
```

### 6.8 Model Quantization

The TFLite model uses float16 quantization:
- Original Keras model: ~1 KB weights
- TFLite float32: ~4 KB
- TFLite float16: ~3.5 KB (our deployment)
- Accuracy impact: negligible for this small model

---

## 7. BLE Protocol (v2.0)

### Design Principle: Backward Compatibility

All BLE UUIDs are unchanged from v1.0. New fields are appended to existing JSON payloads. An older app receiving v2.0 data will simply ignore unknown fields.

### Service and Characteristics

**Service UUID:** `4fafc201-1fb5-459e-8fcc-c5c9c331914b`

| Characteristic | UUID | Properties | Update Rate |
|---------------|------|------------|-------------|
| IMU | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | READ, NOTIFY | 2 Hz |
| Moisture | `beb5483e-36e1-4688-b7f5-ea07361b26a9` | READ, NOTIFY | 2 Hz |
| Alert | `beb5483e-36e1-4688-b7f5-ea07361b26aa` | READ, NOTIFY | On change |

### JSON Payload Formats

**IMU Characteristic (v2.0):**
```json
{
  "x": 0.01,      // Accel X (g) - v1.0
  "y": 0.02,      // Accel Y (g) - v1.0
  "z": 1.00,      // Accel Z (g) - v1.0
  "vib": 0.03,    // Raw magnitude (g) - v1.0 legacy
  "ppv": 0.2,     // Peak Particle Velocity (mm/s) - NEW
  "rms": 0.0012,  // RMS acceleration (g) - NEW
  "freq": 3.0,    // Dominant frequency (Hz) - NEW
  "crest": 1.8    // Crest factor (ratio) - NEW
}
```
Approximate payload size: 120-140 bytes

**Moisture Characteristic (unchanged):**
```json
{
  "percent": 45,   // Moisture percentage (0-100)
  "raw": 2500      // Raw ADC value
}
```
Approximate payload size: 25-30 bytes

**Alert Characteristic (v2.0):**
```json
{
  "level": "safe",     // Alert level: safe/warning/critical - v1.0
  "message": "",       // Human-readable message - v1.0
  "type": "none"       // Hazard type classification - NEW
}
```
Approximate payload size: 40-100 bytes

### MTU Considerations

Default BLE MTU is 23 bytes (20 bytes payload). The IMU JSON payload is ~130 bytes. **MTU negotiation is mandatory.**

The Flutter app calls `device.requestMtu(512)` on connection, and the ESP32 BLE stack supports up to 517 bytes MTU. This must happen on ALL connection paths (initial connect and reconnect-to-already-connected device).

Additional robustness measures in the app:
- Strip null bytes from received data
- Check for truncated JSON (missing closing brace)
- Wrap `requestMtu` in its own try-catch to prevent connection failure
- 500 ms delay after MTU negotiation before discovering services

---

## 8. Flutter App UI Components

### 8.1 VibrationAnalysisCard

A comprehensive dashboard card showing the primary DIN 4150-3 metrics:

- **PPV gauge bar**: Horizontal bar from 0 to 10 mm/s with 6 color-coded segments matching DIN 4150-3 zones:
  - Green (0-0.3): Safe, below human perception
  - Light green (0.3-2.5): Detectable but within limits
  - Yellow (2.5-3.0): Approaching heritage limit
  - Orange (3.0-8.0): Heritage low-frequency limit exceeded
  - Red-orange (8.0-10.0): Heritage high-frequency limit exceeded
  - Red (>10.0): Structural damage risk
- **Metrics grid**: RMS (g), Crest Factor, Dominant Frequency (Hz)
- **Frequency band indicator**: Labels the dominant frequency as "Seismic", "Machinery", "Structural", etc.

### 8.2 PPVTrendGraphCard

Real-time PPV time series with custom `CustomPainter`:

- Plots PPV values over time (rolling window)
- **DIN 4150-3 reference lines**:
  - Red dashed line at 3.0 mm/s (heritage limit)
  - Amber dashed line at 2.5 mm/s (continuous limit)
- Gradient fill below the PPV curve
- Glow effect on the data points
- Auto-scaling Y axis

### 8.3 MLAnomalyIndicator

Glassmorphic card displaying the Tier 2 ML results:

- **Score bar**: 0-100% horizontal indicator
- **Level badge**: Color-coded label (Normal/Unusual/Anomaly)
- **Raw MSE value**: For debugging and calibration

### 8.4 LiveSensorsCard (Enhanced)

The existing sensor card was enhanced with:

- **v2.0 DSP badge**: Visual indicator that v2.0 firmware is connected
- **PPV display**: Shows current PPV value with DIN-appropriate color
- **Frequency analysis row**: Dominant frequency and crest factor
- **Hazard type label**: Translated human-readable hazard type

### 8.5 Simulation Mode

For demonstration without hardware, simulation mode generates realistic v2.0 vibration profiles:

- **Seismic event**: PPV ramps to 5-8 mm/s, freq 1-5 Hz, crest 2-3
- **Machinery**: PPV 3-6 mm/s, freq 15-35 Hz, crest 1.5-2.5
- **Impact event**: PPV spikes to 8-15 mm/s, crest 5-8, freq 20-40 Hz
- **Normal ambient**: PPV 0.01-0.2 mm/s, freq 1-5 Hz, crest 1.5-2.5

---

## 9. Known Limitations & Future Work

### 9.1 Limitations Resolved in v3.0

The following v2.0 limitations have been resolved:

| # | v2.0 Limitation | v3.0 Resolution |
|---|----------------|----------------|
| 1 | Velocity drift correction is simplistic (0.998 decay) | **Resolved**: 2nd-order Butterworth HPF at 0.3 Hz on velocity signal per axis |
| 2 | No FFT noise floor threshold | **Resolved**: Adaptive noise floor (3x RMS of magnitude spectrum), frequency reported as 0 when below |
| 3 | Gravity removal assumes fixed orientation | **Resolved**: Madgwick quaternion filter fuses accel+gyro for true orientation-independent gravity removal |
| 5 | Filter warm-up transient | **Resolved**: First 2 FFT windows discarded after boot |
| 6 | Single-axis PPV | **Resolved**: Tri-axial PCPV (Peak Component Particle Velocity) per DIN 4150-3 specification |
| 9 | Only 4 ML features | **Resolved**: 7 features [rms, ppv, freq, crest, centroid, kurtosis, sta_lta] with deeper autoencoder |
| 10 | No PPV smoothing/peak-hold | **Resolved**: EMA smoothing (alpha=0.3) + 5-second peak hold display in app |

Additionally, v3.0 adds capabilities not in the original limitations list:
- **STA/LTA seismic event trigger**: Standard seismology algorithm for automatic event detection
- **Kurtosis computation**: 4th statistical moment for impact characterization
- **Hysteresis alert state machine**: Both firmware and app-side, prevents alert flickering
- **App-side alert persistence**: 3-sample confirmation to trigger, 6-sample cooldown to clear

### 9.2 Remaining Limitations

#### Firmware

4. **No adaptive baseline**: The DIN 4150-3 thresholds are fixed. At a busy urban site with constant 2 mm/s ambient vibration, the system would generate continuous warnings. An adaptive baseline using a running median or Kalman filter could dynamically adjust the "normal" level.

#### ML Model

7. **Trained on synthetic data only**: The autoencoder has never seen real sensor data. The synthetic distributions are approximations. Real site data may have different statistical properties.

8. **No online learning**: The model cannot adapt to site-specific conditions after deployment. Every new site would ideally need a calibration period to retrain the baseline.

### 9.3 Future Improvements

1. **Edge Impulse on ESP32**: Run a multi-class vibration classifier directly on the microcontroller using Edge Impulse's TinyML workflow.

2. **Adaptive baseline**: Implement a running median or Kalman filter to track the "normal" vibration level and dynamically adjust alert thresholds.

3. **Real data collection and retraining**: Deploy sensors at actual archaeological sites, collect days of labeled data, and retrain the autoencoder.

4. **Wavelet denoising**: Replace or supplement the Butterworth bandpass with wavelet denoising (e.g., Daubechies-4).

5. **Data logging to SD card**: An I2C/SPI SD module could be added to log raw data for post-incident analysis and model retraining.

---

## 10. Academic References

### International Standards

1. **DIN 4150-3:1999** - "Structural vibration - Part 3: Effects of vibration on structures"
   German Institute for Standardization (Deutsches Institut fur Normung). Updated 2016.
   The primary standard for vibration limits on heritage structures. Provides frequency-dependent PPV guideline values. Line 3 (most sensitive) covers structures of great intrinsic value under preservation orders.

2. **ISO 2631-1:1997** - "Mechanical vibration and shock - Evaluation of human exposure to whole-body vibration - Part 1: General requirements"
   International Organization for Standardization. Reviewed and confirmed 2021.
   URL: https://www.iso.org/standard/7612.html
   Defines frequency-weighted acceleration limits for human vibration exposure in the range 0.5-80 Hz (health effects) and 0.1-0.5 Hz (motion sickness).

### Heritage Vibration Monitoring

3. **Lorenzoni, F. et al.** (2024) - "Vibration monitoring of the Hera Temple at the archaeological site of Paestum"
   *ScienceDirect* - Continuous vibration monitoring of a 2,500-year-old Greek temple in Italy. Demonstrates PPV-based monitoring with DIN 4150-3 compliance for ancient structures. Part of broader conservation efforts in the Campania region using advanced sensor technology.

4. **Pau, A. & Vestroni, F.** (2019) - "Urban Seismic Networks, Structural Health and Cultural Heritage Monitoring: The National Earthquakes Observatory (INGV, Italy) Experience"
   *Frontiers in Built Environment*, 5:127
   DOI: 10.3389/fbuil.2019.00127
   URL: https://www.frontiersin.org/articles/10.3389/fbuil.2019.00127/full
   INGV's prototypal urban seismic monitoring combining EO and SHM, deployed in Catania and Acireale. Uses battery-powered triaxial MEMS accelerometers with LoRa wireless and GPS synchronization. Successfully recorded 10 earthquakes (ML 2.4-5.2) in 4 months. The OSU-CT network features 40+ stations in Catania's historic center.

5. **Masciotta, M.G. et al.** (2023) - "Structural Health Monitoring and Management of Cultural Heritage Structures: A State-of-the-Art Review"
   *Applied Sciences*, 13(11), 6450
   DOI: 10.3390/app13116450
   URL: https://www.mdpi.com/2076-3417/13/11/6450
   Comprehensive review of SHM techniques for cultural heritage, covering traditional methods, fiber optic sensors, smart-sensing materials, IoT-SHM systems, and BIM integration. Identifies unique challenges of heritage SHM due to the uniqueness of each structure.

6. **(2025)** - "Impact assessment of construction methods and support structures on vibration levels of ancient reliefs"
   *npj Heritage Science* (Nature Partner Journal)
   DOI: 10.1038/s40494-025-01845-1
   URL: https://www.nature.com/articles/s40494-025-01845-1
   Vibration monitoring of Assyrian reliefs (883-859 BCE) during construction work. Demonstrates practical protection of ancient artifacts using vibration monitoring networks.

7. **(2024)** - "Preservation and Protection of Cultural Heritage: Vibration Monitoring and Seismic Vulnerability of the Ruins of Carmo Convent (Lisbon)"
   *Sensors*, 24(18), 6095
   DOI: 10.3390/s24186095
   URL: https://www.mdpi.com/1424-8220/24/18/6095
   Practical vibration monitoring and seismic vulnerability assessment of historical ruins in Lisbon.

8. **(2020)** - "Development of an IoT Structural Monitoring System Applied to a Hypogeal Site"
   *Sensors*, 20(23), 6769
   DOI: 10.3390/s20236769
   URL: https://www.mdpi.com/1424-8220/20/23/6769
   Long-term monitoring at the Mithraeum of the Baths of Caracalla in Rome. Demonstrates IoT-based hygrothermal and structural monitoring in underground archaeological sites.

### IoT Vibration Monitoring

9. **Meng, Q. & Zhu, S.** (2020) - "Developing IoT Sensing System for Construction-Induced Vibration Monitoring and Impact Assessment"
   *Sensors*, 20(21), 6120
   DOI: 10.3390/s20216120
   URL: https://www.mdpi.com/1424-8220/20/21/6120
   Department of Civil and Environmental Engineering, The Hong Kong Polytechnic University. IoT system using Raspberry Pi and MEMS accelerometer. Validated through laboratory tests and real construction sites with 2.35% accuracy vs. reference instruments.

10. **(2026)** - "Advanced Sensing and Digital Monitoring Technologies for Structural Health Assessment of Civil Infrastructure"
    *Buildings*, 16(3), 656
    URL: https://www.mdpi.com/2075-5309/16/3/656
    Review of technological advances in sensing systems over the past five years, covering convergence of IoT, AI, and digital twin frameworks. Highlights wireless networks with MEMS accelerometers for cost reduction and minimal visual/physical impact on heritage.

### TinyML and Embedded Vibration Analysis

11. **(2025)** - "Embedded TinyML for Predictive Maintenance: Vibration Analysis on ESP32 with Real-Time Fault Detection in Industrial Equipment"
    *International Journal on Computational Modelling Applications (IJCMA)*
    URL: https://submissions.adroidjournals.com/index.php/ijcma/article/view/114
    TinyML framework on ESP32 with triaxial ADXL345 accelerometer. Optimized 1D CNN achieving >92% fault detection accuracy. Demonstrates edge-based autonomous classification without cloud dependency.

12. **(2025)** - "An edge-deployable TinyML approach enhanced by transfer learning for efficient bearing fault diagnosis"
    *Science China Technological Sciences*
    DOI: 10.1007/s11431-025-3072-9
    URL: https://link.springer.com/article/10.1007/s11431-025-3072-9
    Transfer learning on ESP32-S3. Achieves 88.28% accuracy, inference in 45 ms, consuming only 17.7 mJ per classification. Demonstrates energy-efficient edge computing for battery-powered monitoring.

13. **(2025)** - "IoT device for detecting abnormal vibrations in motors using TinyML"
    *Discover Internet of Things* (Springer Nature)
    DOI: 10.1007/s43926-025-00142-4
    URL: https://link.springer.com/article/10.1007/s43926-025-00142-4
    ESP32S3 with MPU6050 accelerometer and Edge Impulse deployment. Achieves 96.5% accuracy with 300 ms end-to-end latency.

### Autoencoder-Based Anomaly Detection

14. **Okur, F.Y., Altunisik, A.C. & Okur, E.K.** (2025) - "A Novel Approach for Anomaly Detection in Vibration-Based Structural Health Monitoring Using Autoencoders in Deep Learning"
    *Structural Control and Health Monitoring*, Wiley
    DOI: 10.1155/stc/5602604
    URL: https://onlinelibrary.wiley.com/doi/10.1155/stc/5602604
    Autoencoder (128x64x64x128 Conv1D) for anomaly detection using EFDD signal processing. Tested on Z24 Bridge dataset with noise levels 0-2%. Demonstrates reliability in challenging noise environments through comparison with Bayesian approaches and Fourier-based techniques.

15. **Li, Z. et al.** (2024) - "Mechanics-informed autoencoder enables automated detection and localization of unforeseen structural damage"
    *Nature Communications*, 15, 8955
    DOI: 10.1038/s41467-024-52501-4
    URL: https://www.nature.com/articles/s41467-024-52501-4
    "Deploy-and-forget" physics-informed autoencoder using passive measurements from inexpensive sensors. Incorporates mechanical priors for 35% improvement over standard autoencoders. Learns baseline from just 3 hours of undamaged data. Ideal for long-term archaeological site monitoring.

16. **(2023)** - "Anomaly detection for construction vibration signals using unsupervised deep learning and cloud computing"
    *Advanced Engineering Informatics* (ScienceDirect)
    DOI: 10.1016/j.jobe.2023.106256
    URL: https://www.sciencedirect.com/science/article/abs/pii/S1474034623000356
    Hong Kong Polytechnic University. Temporal convolutional network + autoencoder for unsupervised anomaly detection in construction vibration. Anomalies detected via reconstruction errors.

17. **(2024)** - "Anomaly Detection Based on Graph Convolutional Network-Variational Autoencoder Model Using Time-Series Vibration and Current Data"
    *Mathematics* (MDPI), 12(23), 3750
    DOI: 10.3390/math12233750
    URL: https://www.mdpi.com/2227-7390/12/23/3750
    GCN-VAE model for time-series vibration anomaly detection. VAEs offer superior denoising capabilities useful for noisy archaeological site environments.

### Open-Source References

18. **ShawnHymel/tinyml-example-anomaly-detection**
    GitHub reference implementation for TinyML anomaly detection using autoencoders. Pipeline architecture referenced for our training script.

19. **CWRU Bearing Dataset**
    Case Western Reserve University bearing vibration dataset. Standard benchmark for vibration-based fault detection and transfer learning.

---

## 11. File Inventory

### Firmware
| File | Description |
|------|-------------|
| `m5stick_firmware/AncientVisionSensor.ino` | Complete ESP32 firmware: 200Hz sampling, DLPF, Butterworth, FFT, PPV, DIN 4150-3 classification |
| `m5stick_firmware/README.md` | Firmware documentation, wiring diagram, calibration guide |

### Flutter App
| File | Description |
|------|-------------|
| `lib/main.dart` | Main app: BLE parsing, vibration dashboard, PPV trend graph, simulation mode |
| `lib/services/vibration_anomaly_service.dart` | TFLite autoencoder inference service (singleton) |

### ML Pipeline
| File | Description |
|------|-------------|
| `scripts/train_vibration_autoencoder.py` | Python training script: synthetic data generation, autoencoder training, TFLite export |
| `assets/ml/vibration_anomaly.tflite` | Trained autoencoder model (3.5 KB, float16 quantized) |
| `assets/ml/vibration_scaler.json` | StandardScaler mean/scale parameters for feature normalization |
| `assets/ml/vibration_model_config.json` | Model version, input dimensions, anomaly thresholds |

### Documentation
| File | Description |
|------|-------------|
| `docs/VIBRATION_RESEARCH.md` | This document |
| `docs/FEATURES.md` | App feature documentation |
| `docs/TECHNICAL.md` | Technical architecture documentation |

---

*This document was compiled from analysis of the AncientVision codebase, DIN 4150-3 standard research, and academic literature review. All code references correspond to the v2.0 implementation.*
