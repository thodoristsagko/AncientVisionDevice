# AncientVision Device

Field safety system for archaeologists — detects micro-vibrations preceding soil avalanches using an M5StickC Plus 2 (ESP32), a Flutter mobile app, and on-device ML models.

---

## Docker Build Instructions

All build targets run in isolated containers. No local toolchain installation required beyond Docker Desktop.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- The repo cloned locally

### Build Firmware

Compiles the PlatformIO firmware for the M5StickC Plus 2 (ESP32).

```bash
docker compose run --rm firmware
```

Output: `.pio/build/m5stick-c-plus2/firmware.bin`

### Build Flutter APK

Builds a release APK for Android.

```bash
docker compose run --rm flutter
```

Output: `app/build/app/outputs/flutter-apk/app-release.apk`

### Train ML Models

Runs the model training pipeline and exports TFLite models and scalers.

```bash
docker compose run --rm ml
```

Output: `assets/ml/*.tflite` and `assets/ml/*.json`

### Build Everything at Once

Run all three targets in sequence:

```bash
docker compose run --rm firmware && \
docker compose run --rm flutter && \
docker compose run --rm ml
```

### Output Summary

| Target   | Output path                                                    |
|----------|----------------------------------------------------------------|
| Firmware | `.pio/build/m5stick-c-plus2/firmware.bin`                      |
| APK      | `app/build/app/outputs/flutter-apk/app-release.apk`           |
| ML       | `assets/ml/*.tflite`, `assets/ml/*.json`                       |

### Notes

- All build artefacts are written to bind-mounted host directories, so outputs are available after the container exits.
- First runs will be slower while Docker pulls base images and populates caches.
- To force a clean rebuild of the Docker image itself, add `--build`: `docker compose run --rm --build firmware`.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    AncientVision System                          │
└─────────────────────────────────────────────────────────────────┘

  ┌──────────────┐   BLE JSON    ┌──────────────────────────────┐
  │  M5StickC+2  │ ────────────► │       Flutter App (Android)   │
  │  (Firmware)  │  22+ fields   │                              │
  │              │               │  ┌─────────────────────────┐ │
  │  • 200Hz IMU │               │  │ VibrationDspService     │ │
  │  • FFT basic │               │  │ • FFT / DWT / Kurtosis  │ │
  │  • BLE adv   │               │  │ • Signal quality        │ │
  │  • PPV calc  │               │  └──────────┬──────────────┘ │
  └──────────────┘               │             │                 │
                                 │  ┌──────────▼──────────────┐ │
  ┌──────────────┐               │  │ AdaptiveAnomalyService  │ │
  │  Field Data  │               │  │ • Autoencoder TFLite    │ │
  │  Collector   │◄──────────────│  │ • Calibration          │ │
  │  (Flask:8765)│  HTTP POST    │  └──────────┬──────────────┘ │
  └──────┬───────┘               │             │                 │
         │ CSV                   │  ┌──────────▼──────────────┐ │
  ┌──────▼───────┐               │  │ PrecursorClassifier     │ │
  │ File Watcher │               │  │ • 4-class TFLite        │ │
  │ (Retrain     │               │  │ • soil_creep etc.       │ │
  │  trigger)    │               │  └──────────┬──────────────┘ │
  └──────┬───────┘               │             │ SafetyView UI   │
         │ .retrain_trigger      └─────────────┼────────────────┘
  ┌──────▼───────┐                             │
  │  ML Trainer  │        Firestore            ▼
  │ (run_pipeline│◄──────────────────   Cloud Sync
  │  .py)        │
  └──────┬───────┘
         │ .tflite + scaler
  ┌──────▼───────────────────────────────────────┐
  │              app/assets/ml/                  │
  │  precursor_classifier.tflite (17 features)   │
  │  autoencoder.tflite (11 features)            │
  │  precursor_classifier_scaler.json            │
  └──────────────────────────────────────────────┘
```

**Data Flow:**
1. **Firmware → BLE → Flutter** (real-time display + ML inference)
   - M5StickC Plus 2 sends 22+ JSON fields at ~100 Hz over BLE
   - 200 Hz raw acceleration logged in circular buffer
2. **Flutter → HTTP → Collector** (field data logging)
   - VibrationDspService runs FFT/DWT/kurtosis in isolate (non-blocking)
   - AdaptiveAnomalyService runs autoencoder inference on 11-sample windows
   - PrecursorClassifier runs 4-class inference on 17 features
   - All samples posted to collector (Flask at 8765)
3. **Collector → Watcher → Trainer** (continuous learning)
   - CSV accumulates in `./data/field_samples.csv`
   - Watcher monitors new samples; at 100+ threshold, triggers trainer
   - Trainer runs 5-fold CV, exports .tflite + scaler.json
4. **Trainer → APK → Field** (deployment)
   - Models bundled into next APK build via Docker
   - App loads models at startup; hot-swap via Firestore updates

---

## Field Deployment Checklist

### Before Leaving for Site
- [ ] Charge M5StickC Plus 2 battery (check LED: green = full)
- [ ] Verify firmware version on device screen (should show v5.x.x)
- [ ] Run `make validate-config` — confirm model files valid
- [ ] Run `make health` — all services green
- [ ] Start data collector: `make collect` (or Docker service)
- [ ] Test BLE connection with Android phone (AncientVision app)
- [ ] Run `make simulate` — confirm samples appear in collector

### On Site Setup
- [ ] Place device on stable, undisturbed soil (not on loose fill)
- [ ] Allow 60-second calibration period before recording
- [ ] Note GPS coordinates (app auto-captures if location enabled)
- [ ] Set site name in app Settings for report labeling
- [ ] Verify signal quality indicator shows "Good" or better

### During Monitoring
- [ ] Watch for ANOMALY level (amber) — investigate source
- [ ] CRITICAL level (red) — evacuate non-essential personnel
- [ ] Log any external vibration sources (machinery, footsteps)
- [ ] Run `make calibration-check` daily to verify sensor health

### After Session
- [ ] Export session CSV from app (Tools → Export)
- [ ] Run `make backup` to archive field data
- [ ] Run `make report` to generate session summary
- [ ] Run `make drift` to check if retraining needed
- [ ] Push data: `make sync BUCKET=your-firebase-bucket`

---

## Analysis Scripts

| Script | Description |
|---|---|
| `scripts/simulate_field_data.py` | Sends synthetic samples to collector (normal/soil_creep/crack_propagation/imminent_failure/mixed modes) |
| `scripts/evaluate_models.py` | Evaluate TFLite models against field CSVs; ROC curve, calibration, top-K, error analysis |
| `scripts/visualize_features.py` | ASCII feature distribution histograms |
| `scripts/field_report.py` | Field session summary report |
| `scripts/health_check.py` | Ping all services and print status table |
| `scripts/load_test.py` | API performance testing with p95 latency measurements |
| `scripts/live_dashboard.py` | Curses terminal dashboard polling the collector API |
| `scripts/ab_test_models.py` | A/B comparison of two TFLite model versions |
| `scripts/data_augmentation_report.py` | Class imbalance analysis and augmentation recommendations |
| `scripts/model_serve.py` | Lightweight HTTP inference server for model testing |
| `scripts/session_report.py` | Generate Markdown session report from a field CSV |
| `scripts/device_calibration_check.py` | Verify device calibration quality per device |
| `scripts/reset_pipeline.py` | Safely reset the retrain trigger and baseline count |
| `scripts/pipeline_status.py` | Comprehensive pipeline status report |

## Docker Services

| Service | Compose file | Description |
|---|---|---|
| `firmware` | `docker-compose.yml` | PlatformIO build → `firmware.bin` |
| `flutter` | `docker-compose.yml` | Flutter release APK |
| `ml` | `docker-compose.yml` | ML model training → `.tflite` |
| `collect` | `docker-compose.collect.yml` | Flask data collector API (port 8765) |
| `watcher` + `trainer` | `docker-compose.train.yml` | File-watcher triggers trainer; runs ONCE per stack start |
| `ml-dev` / `flutter-dev` / `firmware-dev` | `docker-compose.dev.yml` | Interactive dev shells |
| `prometheus` | `docker/monitoring/` | Metrics collection with alerting rules |
