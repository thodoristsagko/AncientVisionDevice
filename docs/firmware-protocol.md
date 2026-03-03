# Firmware BLE Protocol Reference

## Overview

The M5StickC Plus 2 firmware (v5.1.0) exposes a single BLE GATT service with five
notify characteristics and one writable command characteristic. The phone acts as a
central; the device acts as a peripheral.

DSP-heavy calculations (FFT, DWT, kurtosis, Arias intensity, CAV) were moved to the
phone in v5.0. The firmware now sends simplified JSON metrics at ~1 Hz and raw
accelerometer binary data at ~1.28-second windows for phone-side processing.

---

## BLE Service

| Property | Value |
|----------|-------|
| Service UUID | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` |
| Device name advertised | `AncientVision` |
| Peripheral role | GATT Server |
| MTU negotiated | 517 bytes (set via `BLEDevice::setMTU(517)`) |

---

## Characteristics

| Name | UUID | Properties | Description |
|------|------|------------|-------------|
| IMU JSON | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | Notify | Vibration metrics as JSON, updated ~1 Hz |
| Moisture | `beb5483e-36e1-4688-b7f5-ea07361b26a9` | Notify | Soil moisture percentage as JSON |
| Alert | `beb5483e-36e1-4688-b7f5-ea07361b26aa` | Notify | Alert state as JSON |
| Battery | `beb5483e-36e1-4688-b7f5-ea07361b26ab` | Notify | Battery level as JSON |
| Raw Accel (FFT char) | `beb5483e-36e1-4688-b7f5-ea07361b26ac` | Notify | Raw binary accelerometer packets |
| CMD | `beb5483e-36e1-4688-b7f5-ea07361b26ad` | Write | Writable command characteristic |

---

## IMU JSON Characteristic

UUID: `beb5483e-36e1-4688-b7f5-ea07361b26a8`

The firmware sends a JSON-encoded object approximately once per second. The object
fits within one MTU (517 bytes) after the v5.0 size reduction (~120 bytes typical).

### Example Payload

```json
{
  "ppv":   0.18,
  "rms":   0.042,
  "freq":  22.5,
  "crest": 2.81,
  "sta":   1.12,
  "temp":  27.3,
  "bat":   82,
  "chg":   false,
  "fw":    "5.1.0",
  "seq":   1034,
  "evtMs": 0,
  "boots": 3,
  "evts":  7,
  "gain":  0,
  "cal":   true,
  "peak":  0.21
}
```

### JSON Field Reference

| Field | Type | Unit | Description |
|-------|------|------|-------------|
| `ppv` | float | mm/s | Peak Component Particle Velocity (tri-axial, DIN 4150-3). Computed from velocity-integrated acceleration per axis; highest of the three axes is reported. |
| `rms` | float | g | RMS acceleration over the last 256-sample window (~1.28 s). Computed on gravity-removed linear acceleration. |
| `freq` | float | Hz | Dominant vibration frequency. Determined from the STA/LTA trigger band or zero-crossing estimate. Populated by phone-side FFT when raw binary packets are available. |
| `crest` | float | — | Crest factor: `peak / rms`. Typical ambient is 1.5–3.5; values above 6 indicate impulsive events. |
| `sta` | float | — | Recursive STA/LTA ratio. Window sizes: STA = 40 samples (0.2 s), LTA = 2000 samples (10 s). Trigger threshold = 4.0, detrigger = 1.5. |
| `temp` | float | °C | MPU-6886 die temperature. Used for temperature-bias compensation of accelerometer readings. |
| `bat` | integer | % | Battery charge percentage (0–100), derived from LiPo voltage lookup table. |
| `chg` | boolean | — | `true` when the device is charging via USB. |
| `fw` | string | — | Firmware version string (semver), e.g. `"5.1.0"`. |
| `seq` | integer | — | BLE packet sequence number. Increments by 1 each send (wraps at 2^32). Use to detect missed packets. |
| `evtMs` | integer | ms | Duration of the current STA/LTA event in milliseconds. `0` when no event is active. |
| `boots` | integer | — | Persistent boot counter stored in RTC memory. Survives deep sleep; resets only on full power cycle. |
| `evts` | integer | — | STA/LTA event count for the current session (resets on power cycle). |
| `gain` | integer | — | IMU gain mode: `0` = ±8 g (normal), `1` = ±16 g (high-gain, activated automatically when sustained high acceleration is detected). |
| `cal` | boolean | — | `true` once the noise-floor calibration has completed (after 5 analysis windows, ~6.4 s from boot). Results are unreliable until `cal` is `true`. |
| `peak` | float | g | Peak instantaneous acceleration (magnitude) in the last window. Used by phone-side adaptive anomaly service. |

---

## Raw Accelerometer Binary Characteristic (FFT Char)

UUID: `beb5483e-36e1-4688-b7f5-ea07361b26ac`

After each 256-sample window, the firmware sends raw tri-axial accelerometer data as
three consecutive BLE notify packets.

### Packet Format

Each of the three packets is exactly 512 bytes.

| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0 | 4 | uint32 LE | Packet index (0, 1, 2) |
| 4 | 508 | — | Payload (see below) |

### Payload Layout

Each payload contains interleaved `float32` samples in little-endian byte order:

```
[ax0, ay0, az0, ax1, ay1, az1, ..., axN, ayN, azN]
```

- Each float is 4 bytes.
- Packet 0 carries samples 0–41 (42 complete XYZ triplets = 504 bytes payload used,
  4 bytes index).
- Packets 1 and 2 carry the remaining samples.
- Total: 256 XYZ triplets across 3 packets (3072 bytes of float data + 12 bytes
  indices).

Values are in units of **g** (gravity), after gravity removal by the Madgwick filter.

### Reassembly on Phone

The Flutter `RawAccelReassembler` class in `lib/utils/ble_parser.dart` accumulates all
three packets and assembles the full 256-sample buffer before passing to
`VibrationDspService` for FFT, DWT, and kurtosis computation.

---

## CMD Characteristic

UUID: `beb5483e-36e1-4688-b7f5-ea07361b26ad`

Properties: **Write** (no response required).

The CMD characteristic accepts UTF-8 encoded command strings.

### Commands

| Command string | Description |
|----------------|-------------|
| `CALIBRATE` | Starts a 5-window noise-floor calibration sequence. During calibration, `cal` in the JSON is set to `false`. After 5 windows (~6.4 s), the noise baseline is updated and `cal` returns to `true`. |

Send by writing the UTF-8 bytes of the command string to the characteristic.

---

## Connection Sequence

```
Phone                             M5StickC Plus 2
  |                                     |
  |  scan for "AncientVision"           |
  |------------------------------------>|
  |  connect (GATT)                     |
  |<------------------------------------|
  |  negotiate MTU = 517                |
  |<----------------------------------->|
  |  discover services                  |
  |------------------------------------>|
  |  subscribe to IMU JSON notify       |
  |------------------------------------>|
  |  subscribe to Raw Accel notify      |
  |------------------------------------>|
  |  subscribe to Alert notify          |
  |------------------------------------>|
  |  subscribe to Battery notify        |
  |------------------------------------>|
  |                                     |
  |  <-- IMU JSON (every ~500 ms)       |
  |  <-- Raw Accel packet 0             |
  |  <-- Raw Accel packet 1             |
  |  <-- Raw Accel packet 2             |
  |  (repeat every ~1.28 s)             |
```

Notes:
- The firmware reconnects automatically after disconnection without requiring a reboot.
- On Android, check both `advertisementData.advName` and `platformName` when scanning
  — `platformName` is often empty during initial scan.
- MTU negotiation must succeed before subscribing. If MTU < 517, JSON packets larger
  than 20 bytes will be silently truncated.

---

## Packet Rate

| Source | Rate | Period |
|--------|------|--------|
| IMU sampling | 200 Hz | 5 ms |
| Analysis window | ~0.78 Hz | 1.28 s (256 samples) |
| BLE JSON update | ~2 Hz | 500 ms (`BLE_INTERVAL`) |
| Raw accel send | ~0.78 Hz | Immediately after window completes |

The JSON update rate (500 ms) is independent of the analysis window rate (1.28 s).
The most recent computed metrics are sent on each BLE interval.

---

## Moisture Characteristic

UUID: `beb5483e-36e1-4688-b7f5-ea07361b26a9`

```json
{"moisture": 45, "raw": 2200}
```

| Field | Type | Unit | Description |
|-------|------|------|-------------|
| `moisture` | integer | % | Soil moisture percentage (0–100), interpolated from `MOISTURE_AIR=3500` (dry) to `MOISTURE_WATER=1500` (saturated). Safe range: 30–60%. |
| `raw` | integer | ADC counts | Raw ADC reading from GPIO pin 33. |

---

## Alert Characteristic

UUID: `beb5483e-36e1-4688-b7f5-ea07361b26aa`

```json
{"alert": "WARNING", "msg": "PPV 0.35 mm/s exceeds safe threshold", "hazard": "vibration"}
```

| Field | Type | Description |
|-------|------|-------------|
| `alert` | string | One of `"SAFE"`, `"WARNING"`, `"CRITICAL"` |
| `msg` | string | Human-readable alert description |
| `hazard` | string | Hazard type identifier (e.g. `"vibration"`, `"moisture"`, `"none"`) |

Alert state transitions use hysteresis:
- Requires 2 consecutive windows above threshold to enter WARNING/CRITICAL.
- Requires 4 consecutive windows below threshold to return to SAFE.
- 8-window cooldown before re-alerting after a clear.
