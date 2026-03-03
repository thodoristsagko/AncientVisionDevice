# M5StickC Plus 2 - AncientVision Trench Safety Sensor v4.0

## What's New in v4.0

### Major Upgrades from v3.0

- **Recursive STA/LTA with EMA** - saves 8KB RAM by eliminating circular buffers, uses exponential moving averages
- **3-level Haar DWT** - on-device Discrete Wavelet Transform decomposes vibration into 3 frequency bands (D1: 50-100Hz, D2: 25-50Hz, D3: 12-25Hz)
- **Arias Intensity** - cumulative seismic energy metric (π/2g·∫a²dt), auto-resets every 60 seconds, used in building codes worldwide
- **CAV (Cumulative Absolute Velocity)** - industry standard (EPRI threshold: 0.16 g·s for structural damage)
- **IMU Temperature** - MPU6886 die temperature reading with thermal bias compensation (0.0005g/°C applied to acceleration)
- **Expanded BLE JSON** - 17 fields (was 11 in v3.0): +arias, +cav, +temp, +dwt1, +dwt2, +dwt3
- **All v3.0 features retained**: Madgwick gravity removal, tri-axial PCPV, Butterworth bandpass, FFT, kurtosis, spectral centroid, hysteresis

### v3.0 Features (Still Included)

- **Madgwick quaternion gravity removal** - accurate at any sensor orientation
- **Tri-axial PCPV** - proper DIN 4150-3 Peak Component Particle Velocity
- **2nd-order Butterworth HPF on velocity** - clean drift removal
- **Adaptive FFT noise floor** - 3x RMS threshold
- **Kurtosis computation** - 4th moment for impact detection
- **Hysteresis alert state machine** - 2 windows to trigger, 4 to clear
- **Filter warm-up discard** - first 2 FFT windows ignored after boot

## Hardware Required
- M5StickC Plus 2
- Capacitive Soil Moisture Sensor (analog output)
- Jumper wires

## Wiring Diagram

```
M5StickC Plus 2          Soil Moisture Sensor
----------------         -------------------
3.3V (or 5V)     ----→   VCC
GND              ----→   GND
GPIO 33          ----→   Signal (Analog Out)
```

**Note:** GPIO 33 is available on the Grove port of the M5StickC Plus 2.

## Software Setup

### 1. Install Arduino IDE
Download from: https://www.arduino.cc/en/software

### 2. Install M5StickC Plus 2 Board Support
1. Open Arduino IDE
2. Go to **File → Preferences**
3. Add this URL to "Additional Board Manager URLs":
   ```
   https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/arduino/package_m5stack_index.json
   ```
4. Go to **Tools → Board → Boards Manager**
5. Search for "M5Stack" and install **M5Stack by M5Stack**
6. Select **Tools → Board → M5Stack → M5StickCPlus2**

### 3. Install Required Libraries
Go to **Sketch → Include Library → Manage Libraries** and install:
- **M5StickCPlus2** (by M5Stack)
- **arduinoFFT** (by Enrique Condes) - for frequency analysis
- **MadgwickAHRS** (by Arduino) - for quaternion-based gravity removal

The ESP32 BLE library is included with the board support.

### 4. Upload the Firmware
1. Connect M5StickC Plus 2 via USB-C
2. Select the correct port: **Tools → Port → COMx** (or /dev/ttyUSBx on Linux)
3. Open `AncientVisionSensor.ino`
4. Click **Upload** (→ arrow button)

## Signal Processing Pipeline v4.0

```
Raw IMU (200Hz) → DLPF (99Hz HW) → Madgwick Gravity Removal (quaternion)
                                      ↓
                          Per-axis linear acceleration (X, Y, Z)
                                      ↓
                      HPF 0.5Hz → LPF 100Hz (per axis, Butterworth)
                                      ↓
         ┌────────────────────────────┼────────────────────────────┐
         ↓                            ↓                            ↓
   Tri-axial PPV              FFT (256-pt)              NEW: 3-Level Haar DWT
   (velocity HPF              Noise floor              D1(50-100Hz), D2(25-50Hz),
    @ 0.3 Hz)                 + Frequency              D3(12-25Hz) decomposition
         ↓                            ↓                            ↓
   PCPV = max(X,Y,Z)      Centroid + Kurtosis           DWT Band Amplitudes
         ↓                            ↓                            ↓
         └────────────────────────────┼────────────────────────────┘
                                      ↓
                      NEW: Recursive STA/LTA (EMA-based, -8KB RAM)
                                      ↓
                      NEW: Arias Intensity (cumulative ∫a²dt)
                      NEW: CAV (cumulative |velocity|)
                      NEW: IMU Temperature + Compensation
                                      ↓
                      DIN 4150-3 Classification (Hysteresis)
                                      ↓
                      BLE JSON (17 fields: v3.0 + 6 new)
```

1. **IMU sampling at 200 Hz** - captures vibrations up to 100 Hz (Nyquist)
2. **DLPF at 99 Hz** - hardware anti-aliasing on the MPU6886 chip
3. **Madgwick filter** - fuses accelerometer + gyroscope to track orientation, removes gravity
4. **Butterworth bandpass (0.5-100 Hz) per axis** - isolates structural vibrations from noise
5. **Tri-axial velocity integration** - trapezoidal rule with 0.3 Hz HPF drift removal
6. **256-point FFT with Hanning window** - identifies dominant vibration frequency
7. **Adaptive noise floor** - 3x RMS threshold prevents false frequency readings
8. **3-level Haar DWT** - on-device wavelet decomposition into frequency bands
9. **Recursive STA/LTA** - EMA-based seismic trigger (saves 8KB RAM vs circular buffers)
10. **Arias Intensity & CAV** - cumulative seismic energy and velocity metrics
11. **IMU Temperature** - die temperature reading with 0.0005g/°C bias compensation
12. **Feature extraction** - 17 metrics: PCPV, RMS, crest, centroid, kurtosis, STA/LTA, Arias, CAV, temp, DWT bands
13. **DIN 4150-3 classification** - hysteresis state machine with 2-window trigger, 4-window clear

## Calibration

### Soil Moisture Sensor Calibration
Edit these values in the code based on your sensor:

```cpp
const int MOISTURE_AIR = 3500;    // Value when sensor is in air (dry)
const int MOISTURE_WATER = 1500;  // Value when sensor is in water (wet)
```

### DIN 4150-3 Vibration Thresholds
These are based on international standards for heritage structures:

```cpp
const float PPV_SAFE_MAX = 0.3;           // Below human perception (mm/s)
const float PPV_HERITAGE_LOW = 3.0;       // Heritage limit 1-10 Hz (mm/s)
const float PPV_HERITAGE_HIGH = 8.0;      // Heritage limit 50-100 Hz (mm/s)
const float PPV_STRUCTURAL_DAMAGE = 10.0; // Structural damage risk (mm/s)
const float PPV_CONTINUOUS_LIMIT = 2.5;   // Continuous vibration limit (mm/s)
const float CREST_IMPACT_THRESHOLD = 5.0; // Impact detection (Peak/RMS ratio)
```

### STA/LTA Configuration v4.0
Recursive EMA-based seismic event trigger (saves 8KB RAM):

```cpp
const float STA_ALPHA = 0.05;     // EMA alpha for short-term average
const float LTA_ALPHA = 0.0005;   // EMA alpha for long-term average
const float STA_TRIGGER = 4.0;    // Trigger when ratio > 4.0
const float STA_DETRIGGER = 1.5;  // De-trigger when ratio < 1.5
```

**Memory savings:** v3.0 used circular buffers (40 + 2000 floats = 8160 bytes), v4.0 uses 2 floats (8 bytes)

## Using with the App

1. Power on the M5StickC Plus 2
2. The display shows "AncientVision" and firmware version indicator
3. Open the AncientVision app on your phone
4. Go to the **Safety** tab
5. The app automatically scans for and connects to "AncientVision-Sensor"
6. **With v4.0 firmware:** You'll see PPV, frequency, crest, kurtosis, STA/LTA, Arias Intensity, CAV, temperature, and 3 DWT frequency bands
7. **With v3.0/v2.0 firmware:** Legacy metrics only (app is backward compatible)

## Display Layout v4.0

```
┌─────────────────────────────────┐
│ AncientVision v4.0   BT  85%   │  ← Title + Version + BLE + Battery
│ PPV:0.2mm/s T:24°C            │  ← PPV + NEW: Temperature
│ 3Hz S/L:1.2 AI:0.05           │  ← Freq + STA/LTA + NEW: Arias
│ Safe - DIN 4150-3              │  ← Hazard status
│ CAV:0.02 D1:█ D2:▄ D3:▂       │  ← NEW: CAV + DWT bands
│ Mst:45% OK                     │  ← Moisture
│ RMS:0.0012 CF:1.8 K:0.3       │  ← RMS, Crest, Kurtosis
└─────────────────────────────────┘
```

**NEW in v4.0:**
- Temperature display (IMU die temp)
- Arias Intensity (AI)
- CAV metric
- DWT frequency band bars (D1/D2/D3 with amplitude visualization)

### Background Colors

| Color | Meaning |
|-------|---------|
| Green | All safe - DIN 4150-3 compliant |
| Orange | Warning - hazard detected |
| Red | Critical - evacuate area! |

## Button Functions

- **Button A** (front): Test alert (sends test notification to app)

## BLE Data Format v4.0

The sensor sends JSON data over BLE characteristics:

| Characteristic | UUID suffix | Data Format |
|---------------|-------------|-------------|
| IMU v4.0 | `...26a8` | `{"x":0.01,"y":0.02,"z":1.00,"vib":0.03,"ppv":0.2,"rms":0.0012,"freq":3.0,"crest":1.8,"cent":5.2,"kurt":0.3,"stalta":1.1,"arias":0.05,"cav":0.02,"temp":24.5,"dwt1":0.003,"dwt2":0.002,"dwt3":0.001}` |
| Moisture | `...26a9` | `{"percent":45,"raw":2500}` |
| Alert | `...26aa` | `{"level":"safe","message":"","type":"none"}` |

### v4.0 Fields (backward compatible with v2.0/v3.0)

| Field | Unit | Description | Version |
|-------|------|-------------|---------|
| `ppv` | mm/s | Peak Component Particle Velocity (tri-axial PCPV) | v2.0+ |
| `rms` | g | RMS acceleration (vibration energy) | v2.0+ |
| `freq` | Hz | Dominant vibration frequency from FFT (0 if below noise floor) | v2.0+ |
| `crest` | ratio | Crest factor (Peak/RMS - detects impacts) | v3.0+ |
| `cent` | Hz | Spectral centroid (frequency center of mass) | v3.0+ |
| `kurt` | ratio | Excess kurtosis (>3 = impulsive events) | v3.0+ |
| `stalta` | ratio | STA/LTA ratio (>4 = seismic event trigger) | v3.0+ |
| **`arias`** | **m/s** | **Arias Intensity (cumulative seismic energy)** | **v4.0** |
| **`cav`** | **g·s** | **Cumulative Absolute Velocity (EPRI: 0.16 g·s threshold)** | **v4.0** |
| **`temp`** | **°C** | **IMU die temperature (thermal compensation applied)** | **v4.0** |
| **`dwt1`** | **g** | **DWT band D1 amplitude (50-100 Hz machinery)** | **v4.0** |
| **`dwt2`** | **g** | **DWT band D2 amplitude (25-50 Hz structural)** | **v4.0** |
| **`dwt3`** | **g** | **DWT band D3 amplitude (12-25 Hz seismic)** | **v4.0** |
| `type` | string | Hazard classification (seismic/machinery/impact/etc) | v3.0+ |

### Hazard Types

| Type | Meaning | Trigger |
|------|---------|---------|
| `none` | Safe conditions | PPV < 0.3 mm/s |
| `seismic` | Seismic activity | PPV > 3 mm/s, freq 0.5-10 Hz, or STA/LTA > 4 |
| `machinery` | Heavy machinery | PPV > 3 mm/s, freq 10-50 Hz |
| `structural` | Structural damage risk | PPV > 10 mm/s |
| `hf_stress` | High-frequency stress | PPV > 8 mm/s, freq > 50 Hz |
| `impact` | Impact/collapse | Crest factor > 5, PPV > 1 mm/s |
| `continuous` | Sustained vibration | PPV > 2.5 mm/s |
| `source_change` | Vibration source changed | Spectral centroid shift > 50% |

**Note:** The app automatically negotiates a 512-byte BLE MTU to prevent JSON truncation. v4.0 JSON payload is ~320 bytes, well under MTU limit.

## DIN 4150-3 Reference

The international standard for vibration effects on heritage structures:

| Frequency | Heritage/Archaeological Limit (PPV) |
|-----------|-------------------------------------|
| 1-10 Hz | 3 mm/s |
| 10-50 Hz | 3-8 mm/s |
| 50-100 Hz | 8-10 mm/s |
| Continuous | 2.5 mm/s (any frequency) |

Human perception threshold: 0.14-0.3 mm/s PPV

## Troubleshooting

### App can't find the sensor
- Make sure Bluetooth is enabled on your phone
- Ensure the M5StickC Plus 2 is powered on and showing "BT" on screen
- Try restarting both devices

### Sensor values show 0 in the app
- This is usually caused by BLE MTU being too small (JSON gets truncated)
- The latest app version negotiates MTU automatically
- Try disconnecting and reconnecting the sensor

### Incorrect moisture readings
- Recalibrate the sensor (see Calibration section)
- Check wiring connections

### PPV readings seem too high/low
- Ensure the M5StickC is firmly mounted (not loose/dangling)
- The first 2 FFT windows (~2.5s) are discarded for filter warm-up
- Check Serial Monitor at 115200 baud for DSP debug output
- Tilt test: v3.0 with Madgwick should show near-zero PPV when tilted (v2.0 showed ~0.13g error)

### STA/LTA ratio stays high
- After a strong vibration event, the LTA needs ~10 seconds to settle
- This is normal behavior - the algorithm adapts its baseline
- v4.0 recursive EMA version recovers faster than v3.0 circular buffers

### New v4.0 metrics not showing in app
- Ensure you're running v4.0 firmware (check M5StickC display for version)
- App automatically detects firmware version and shows appropriate UI
- If v4.0 firmware but no new metrics: reconnect BLE device

## ML Anomaly Detection v4.0 (Tier 2)

The Flutter app includes a TensorFlow Lite Variational Autoencoder (VAE) trained on normal vibration data:
- **v4.0 VAE architecture:** 10→8→6→latent(4)→6→8→10 (upgraded from v3.0 autoencoder)
- **10 input features** (was 7 in v3.0): [rms, ppv, freq, crest, cent, kurt, stalta, arias, cav, temp]
- **Combined anomaly score:** reconstruction_mse + beta * kl_divergence
- Model: `assets/ml/vibration_anomaly.tflite` (~8 KB, float16 quantized)
- Scaler: `assets/ml/vibration_scaler.json` (StandardScaler mean/scale for 10 features)
- Config: `assets/ml/vibration_model_config.json` (thresholds, model_version: 4.0)
- Service: `lib/services/vibration_anomaly_service.dart` (auto-adapts to 7 or 10 features)
- Training: `python scripts/train_vibration_autoencoder.py --synthetic` (generates v4.0 model)

**Backward Compatibility:** Service gracefully handles v2.0 (4 features), v3.0 (7 features), or v4.0 (10 features) firmware
