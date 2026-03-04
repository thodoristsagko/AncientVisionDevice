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

```ascii
┌─────────────────────────────────────────────────────────────────┐
│                    AncientVision System                          │
└─────────────────────────────────────────────────────────────────┘

  ┌──────────────┐    BLE JSON     ┌──────────────────────────────┐
  │  M5StickC+2  │ ─────────────► │      Android Phone           │
  │  (Firmware)  │  200Hz accel   │                              │
  │              │  3-axis binary  │  ┌──────────────────────┐   │
  │  ・ IMU      │                 │  │  Flutter App          │   │
  │  ・ BLE      │                 │  │                      │   │
  │  ・ Screen   │                 │  │  DSP (isolate)       │   │
  └──────────────┘                 │  │  ├─ FFT / DWT        │   │
                                   │  │  ├─ Kurtosis/Crest   │   │
  ┌──────────────┐                 │  │  └─ PSD Slope        │   │
  │  Field Data  │                 │  │                      │   │
  │  Collector   │◄────────────── │  │  ML Pipeline         │   │
  │  (Docker)    │  POST /ingest  │  │  ├─ Autoencoder      │   │
  │              │                 │  │  ├─ Precursor Class. │   │
  │  /stats      │                 │  │  └─ Rule-based Fall. │   │
  │  /export     │                 │  └──────────────────────┘   │
  │  /devices    │                 └──────────────────────────────┘
  └──────┬───────┘
         │ CSV + Firestore
         ▼
  ┌──────────────┐
  │  ML Training │
  │  Pipeline    │
  │  (Docker)    │
  │              │
  │  Watcher ────┼──► Trainer ──► .tflite ──► app/assets/ml/
  │  (100 samples│    ├─ Autoencoder
  │   threshold) │    └─ Precursor Classifier
  └──────────────┘
```

**Data Flow:**
1. Firmware → BLE → Flutter (real-time display + ML inference)
2. Flutter → HTTP → Collector (field data logging)
3. Watcher monitors CSV count → triggers trainer at 100 new samples
4. Trainer outputs .tflite models → bundled into APK via Docker build

---

## Field Deployment Checklist

### Before Deployment
- [ ] Charge M5StickC Plus 2 battery (>80%)
- [ ] Flash latest firmware: `python -m platformio run -t upload`
- [ ] Verify BLE JSON in serial monitor (fw, seq, ppv fields present)
- [ ] Install Flutter APK on Android phone
- [ ] Test BLE connection — device should appear as "AncientVision"
- [ ] Verify app shows real-time PPV readings
- [ ] Start data collector: `make collect`
- [ ] Test data ingestion: `make simulate` → check `/stats` endpoint

### At the Site
- [ ] Mount sensor on stable surface (avoid direct soil contact)
- [ ] Note sensor orientation (Z-axis vertical preferred)
- [ ] Run 5-minute baseline before beginning excavation
- [ ] Monitor app for ANOMALY alerts during work
- [ ] Record GPS coordinates for sensor placement

### After Session
- [ ] Export session data: `curl http://localhost:8765/export > session.csv`
- [ ] Back up field data: `make backup`
- [ ] If 100+ new samples: retrain → `make train`
- [ ] Check training metrics: `cat app/assets/ml/precursor_training_metrics.json`

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
