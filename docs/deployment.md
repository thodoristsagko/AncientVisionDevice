# Field Deployment Guide

This guide covers everything needed to deploy AncientVision at an archaeological
excavation site, from first-time setup to post-deployment data collection and
model retraining.

---

## 1. Prerequisites

### Hardware

| Item | Notes |
|------|-------|
| Android phone | Android 10+, BLE 5.0, minimum 3 GB RAM |
| M5StickC Plus 2 | Firmware v5.1.0 flashed (see Step 4) |
| Soil moisture sensor | Connected to GPIO 33 |
| USB-C cable | For firmware flashing and APK sideloading |
| Laptop | Windows/macOS/Linux with Docker and Git |

### Software (laptop)

| Tool | Version | Purpose |
|------|---------|---------|
| Docker Desktop | 24+ | Build and run all services |
| Git | 2.40+ | Clone repository |
| Python | 3.11+ | Run scripts locally if needed |
| ADB (Android Debug Bridge) | Latest | Install APK via USB |

Ensure Docker has at least 20 GB of free disk space. If your C: drive is full, see
`docs/troubleshooting.md` — Issue 1.

---

## 2. First-Time Setup

```bash
# 1. Clone the repository
git clone <repo-url> AncientVisionDevice
cd AncientVisionDevice

# 2. Copy the environment template
cp .env.example .env
```

Open `.env` in a text editor and configure:

```
# Firebase service account key (optional — enables Firestore sync)
GOOGLE_APPLICATION_CREDENTIALS=/workspace/secrets/firebase-key.json

# Firestore collection name (must match app_constants.dart)
FIRESTORE_COLLECTION=vibration_samples

# Data directory (mapped inside the collector container)
DATA_DIR=/workspace/data

# API key for the data collector (leave blank for development/local use)
API_KEY=

# Collector port
PORT=8765
```

If you have a Firebase service account key, place it at:
```
secrets/firebase-key.json
```
(The `secrets/` directory is gitignored.)

```bash
# 3. Build all Docker services
make build
```

This may take 5–15 minutes on first run as Docker pulls base images and compiles the
Flutter APK.

---

## 3. Start the Data Collector

The data collector is a lightweight Flask service that receives sensor samples from
the phone (when on the same Wi-Fi network) and writes them to daily CSV files.

```bash
make collect
```

You should see:

```
data-collector | {"ts": "...", "event": "startup", "data_dir": "/workspace/data"}
data-collector | * Running on http://0.0.0.0:8765
```

Verify it is healthy:

```bash
curl http://localhost:8765/health
# {"status": "ok", "samples": 0}
```

To run in the background:

```bash
docker compose -f docker-compose.collect.yml up -d
```

To view logs:

```bash
make logs
```

---

## 4. Flash the Firmware

### Option A — Build and Flash via Docker (no local toolchain)

```bash
# Build the firmware binary
make firmware

# The compiled .bin file will be at:
# .pio/build/m5stick-c-plus2/firmware.bin
```

Flash using PlatformIO (requires `esptool` installed locally):

```bash
python -m platformio run -d . --target upload
```

Or use the PlatformIO VS Code extension: open the project, select the
`m5stick-c-plus2` environment, and click "Upload".

### Option B — Build Locally

```bash
# Requires PlatformIO Core installed
python -m platformio run -d . --target upload
```

### Verifying the Flash

After flashing, the M5StickC Plus 2 display should show:

```
AncientVision v5.1.0
PPV: 0.00 mm/s
BLE: Advertising
```

The device advertises as `AncientVision` over BLE immediately after boot.

---

## 5. Build and Install the App

### Build the Flutter APK

```bash
make flutter
```

This runs the Flutter build inside Docker and places the APK at:

```
app/build/app/outputs/flutter-apk/app-release.apk
```

### Install on Android

```bash
# Enable USB debugging on the phone first (Settings > Developer Options)
adb devices           # Confirm phone is listed
adb install app/build/app/outputs/flutter-apk/app-release.apk
```

Or copy the APK to the phone over USB and install manually.

### Android Setup (one-time)

1. Disable battery optimisation for AncientVision:
   - Android Settings > Battery > Battery optimisation > AncientVision > Don't optimise

2. Grant Bluetooth and Location permissions when prompted on first launch.

3. If on Android 12+, grant "Nearby devices" permission.

---

## 6. Field Operation

### Start of Day

1. Power on the M5StickC Plus 2. Allow 10 seconds for boot and initial calibration
   (`cal = false` until calibration completes).

2. Open the AncientVision app on the phone.

3. Tap "Scan" — the device should appear as `AncientVision` within a few seconds.

4. Tap the device to connect. The app will subscribe to all BLE characteristics
   automatically.

5. Wait for the safety view to show a green status (typically 10–15 seconds after
   connecting).

### Running Calibration

Before relying on alert levels, run a manual calibration to establish the noise floor
on the specific surface where the device is placed:

1. Place the M5StickC Plus 2 on the target measurement surface (e.g., trench wall,
   soil edge).

2. In the app, tap the "Calibrate" button (or send `CALIBRATE` via the CMD BLE
   characteristic).

3. Wait ~10 seconds. The `cal` indicator in the JSON will return to `true` and the
   safety view will update with the new noise baseline.

4. Do not disturb the device during calibration.

### Monitoring the Safety View

The safety view shows real-time:

- **PPV** (mm/s) with DIN 4150-3 colour coding: green < 0.3, amber 0.3–10, red > 10
- **Anomaly level**: SAFE / ANOMALY / CRITICAL
- **Precursor class**: normal / soil_creep / crack_propagation / imminent_failure
- **RSSI indicator**: confirms BLE signal quality
- **Battery level**: from the device BLE JSON

### Alert Response

| Level | Action |
|-------|--------|
| SAFE (green) | Normal operation |
| ANOMALY (amber) | Heightened awareness — note time and site conditions |
| CRITICAL (red) | Evacuate excavation personnel immediately; do not re-enter until level returns to SAFE for > 5 minutes |

---

## 7. After Deployment

After a field session, back up all collected data:

```bash
make backup
```

This runs `scripts/backup_data.sh`, which copies `data/field/*.csv` to a timestamped
archive directory.

To download a single combined CSV of all collected data:

```bash
curl http://localhost:8765/export -o field_data_$(date +%Y-%m-%d).csv
```

To trigger model retraining with the new field data:

```bash
make train
```

The watcher (`docker/watcher/watch.py`) and trainer will start automatically.
The watcher monitors `data/field/.sample_count` and triggers training when 100 new
samples have been collected since the last training run.

---

## 8. Retraining

### Automatic Retraining (via watcher)

When the watcher detects the trigger threshold has been reached, it creates
`data/.retrain_trigger`. The trainer container picks this up and starts a full
training run automatically.

```bash
# Start the watcher + trainer stack
make train
```

To adjust the trigger threshold (default: 100 new samples):

```bash
curl -X POST http://localhost:8765/config \
  -H "Content-Type: application/json" \
  -d '{"trigger_threshold": 200}'
```

### Manual Retraining

To retrain immediately regardless of sample count:

```bash
docker compose -f docker-compose.train.yml run --rm trainer
```

### Retraining Pipeline

1. The trainer reads all CSV files in `data/field/`.
2. New real samples are merged with synthetic baseline data.
3. A new autoencoder and precursor classifier are trained (see `docs/ml-architecture.md`).
4. The new models are evaluated against the holdout test set.
5. If the new model accuracy exceeds the stored baseline, the TFLite files in
   `app/assets/ml/` are updated.
6. If accuracy is lower, the previous models are kept (automatic rollback).

### Deploying Retrained Models

After a successful retrain:

```bash
# Rebuild the Flutter APK with the updated TFLite files
make flutter

# Reinstall on the phone
adb install app/build/app/outputs/flutter-apk/app-release.apk
```

---

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `DATA_DIR` | `/workspace/data` | Directory where CSV files are written |
| `PORT` | `8765` | Data-collector HTTP port |
| `GOOGLE_APPLICATION_CREDENTIALS` | — | Path to Firebase service account JSON |
| `FIRESTORE_COLLECTION` | `vibration_samples` | Firestore collection for phone-uploaded samples |
| `API_KEY` | — | If set, all collector endpoints (except `/health`, `/metrics`) require `X-API-Key` header |
| `TRIGGER_THRESHOLD` | `100` | New samples required to trigger retraining |
| `POLL_INTERVAL` | `60` | Watcher poll interval in seconds |

---

## Useful Commands

```bash
# View collector status
curl http://localhost:8765/health
curl http://localhost:8765/stats

# View data quality
curl http://localhost:8765/quality

# List devices that have sent data
curl http://localhost:8765/devices

# Send 150 synthetic samples (for testing)
make simulate

# Open interactive shell in ML container
make dev-ml

# Open interactive shell in Flutter container
make dev-flutter

# Stop all services and prune Docker
make clean
```
