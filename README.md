# AncientVision Device

Field safety system for archaeologists — detects micro-vibrations preceding soil avalanches using an M5StickC Plus 2 (ESP32), a Flutter mobile app, and on-device ML models.

---

## Quick Start

```bash
make help                  # Show all available targets
make collect               # Start data-collector Flask API (port 8765)
make train                 # Start file-watcher + trainer (runs once per stack start)
make simulate              # Send 150 synthetic samples to collector for testing
make health                # Ping all services and show status table
make deployment-check      # Verify ML assets and configs are ready for field use
```

Build targets (require Docker Desktop):

```bash
make build                 # Build firmware + Flutter APK + ML models
make firmware              # Build firmware only  →  .pio/build/.../firmware.bin
make flutter               # Build Flutter APK   →  app/build/.../app-release.apk
make ml                    # Train ML models     →  app/assets/ml/*.tflite + *.json
```

---

## System Architecture

```
  ┌──────────────┐  BLE JSON + raw accel   ┌────────────────────────────────────┐
  │  M5StickC+2  │ ───────────────────────► │         Flutter App (Android)       │
  │  (Firmware)  │  22+ fields, ~100 Hz     │                                    │
  │              │  200 Hz raw accel buffer │  ┌──────────────────────────────┐  │
  │  • 200Hz IMU │                          │  │    VibrationDspService        │  │
  │  • PPV calc  │                          │  │  FFT / DWT / Kurtosis / SNR  │  │
  │  • BLE adv   │                          │  └──────────────┬───────────────┘  │
  └──────────────┘                          │                 │                  │
                                            │  ┌──────────────▼───────────────┐  │
  ┌──────────────────────┐                  │  │    AdaptiveAnomalyService     │  │
  │   Google Firestore   │◄─────────────────│  │  Autoencoder TFLite (11 feat) │  │
  │   (Cloud Sync)       │   session data   │  └──────────────┬───────────────┘  │
  └──────────────────────┘                  │                 │                  │
                                            │  ┌──────────────▼───────────────┐  │
  ┌──────────────┐                          │  │   PrecursorClassifierService  │  │
  │   Collector  │◄─────────────────────────│  │  4-class TFLite (17 features) │  │
  │ Flask :8765  │  HTTP POST (samples)     │  │  soil_creep / crack_prop /    │  │
  └──────┬───────┘                          │  │  imminent_failure / normal    │  │
         │ CSV                              │  └──────────────┬───────────────┘  │
  ┌──────▼───────┐                          │                 │  SafetyView UI   │
  │ File Watcher │  .retrain_trigger        └─────────────────┼──────────────────┘
  └──────┬───────┘                                            │
         │                                                    ▼
  ┌──────▼───────┐  .tflite + scaler   ┌──────────────────────────────────────────┐
  │  ML Trainer  │ ──────────────────► │              app/assets/ml/              │
  │(run_pipeline)│                     │  precursor_classifier.tflite (17 feat)   │
  └──────────────┘                     │  autoencoder.tflite (11 feat)            │
                                       │  precursor_classifier_scaler.json        │
  ┌──────────────┐                     └──────────────────────────────────────────┘
  │  Prometheus  │  metrics scrape
  │  + Grafana   │◄── collector /metrics
  │  :9090/:3000 │
  └──────────────┘
```

**Data flow:**
1. **Firmware → BLE → Flutter**: M5StickC Plus 2 streams 22+ JSON fields at ~100 Hz; raw 200 Hz acceleration in 512-byte binary chunks over a separate BLE characteristic.
2. **Flutter → DSP → ML inference**: VibrationDspService runs FFT/DWT/kurtosis in an isolate. AdaptiveAnomalyService (autoencoder) and PrecursorClassifierService (4-class) run inference and feed the SafetyView UI.
3. **Flutter → HTTP → Collector**: All samples are posted to the Docker collector for field data archival and continuous learning.
4. **Collector → Watcher → Trainer**: CSV accumulates in `./data/field_samples.csv`. File watcher triggers retraining at 100+ new samples. Trainer runs 5-fold CV and exports `.tflite` + scaler.
5. **Trainer → APK → Field**: Updated models are bundled into the next APK build via Docker; hot-swap via Firestore updates.

---

## Docker Services

| Service | Compose file | Description |
|---|---|---|
| `firmware` | `docker-compose.yml` | PlatformIO build → `firmware.bin` (1 CPU, 2 GB) |
| `flutter` | `docker-compose.yml` | Flutter release APK (2 CPU, 4 GB) |
| `ml` | `docker-compose.yml` | ML model training → `.tflite` + scalers (2 CPU, 4 GB) |
| `data-collector` | `docker-compose.collect.yml` | Flask API on port 8765 with nginx reverse proxy |
| `watcher` + `trainer` | `docker-compose.train.yml` | File-watcher triggers trainer; **runs ONCE per stack start** |
| `ml-dev` / `flutter-dev` / `firmware-dev` | `docker-compose.dev.yml` | Interactive bash dev shells |
| `prometheus` + `grafana` | `docker-compose.monitoring.yml` | Metrics at :9090 (Prometheus) and :3000 (Grafana) |

To force a clean rebuild of any image: `docker compose run --rm --build <service>`.

---

## CI/CD

All workflows live in `.github/workflows/`.

| Workflow | Trigger | Purpose |
|---|---|---|
| `build.yml` | Push to master | Build firmware.bin + Flutter APK; upload as 30-day artifacts |
| `release.yml` | Push `v*.*.*` tag | Create GitHub Release + upload to Firebase App Distribution |
| `release_notes.yml` | Push `v*.*.*` tag | Extract CHANGELOG section and attach to GitHub Release |
| `pytest.yml` | Push/PR to master or docker-experiment | Full Python test suite with coverage |
| `pytest_coverage.yml` | Push to scripts/ or docker/ Python files | Detailed coverage report |
| `flutter_test.yml` | Push/PR when app/ changes | Flutter unit tests |
| `integration_test.yml` | Push to docker-experiment | Collector + watcher integration tests |
| `nightly_integration.yml` | Daily 02:00 UTC | Full integration suite |
| `lint_check.yml` | Push when scripts/ or docker/ Python changes | ruff linting |
| `dependency_audit.yml` | Push to master/docker-experiment + weekly | pip-audit on all requirements |
| `security_scan.yml` | Push to requirements files + weekly | pip-audit on Python deps |
| `docker_security_scan.yml` | Push to Dockerfiles + weekly | Trivy container security scan |
| `drift_check.yml` | Weekly Monday 06:00 UTC | Data drift detection |
| `data_quality.yml` | Daily 06:00 UTC | Training data quality gate |
| `data_quality_check.yml` | Weekly Monday 07:00 UTC | Extended data quality checks |
| `model_health.yml` | Daily 08:00 UTC + ML asset changes | TFLite model + scaler validation |
| `model_quality.yml` | Push when training scripts or ML assets change | ML quality gate |
| `model_benchmark.yml` | Push when ML assets change | TFLite inference benchmark |
| `model_regression.yml` | Push to docker-experiment when ML assets change | Detect accuracy regressions |
| `performance_benchmark.yml` | Push to docker-experiment (scripts/docker) + weekly | API + inference performance |
| `coverage_report.yml` | Push to docker-experiment + weekly Sunday | Python test coverage report |
| `deployment_check.yml` | Push to docker-experiment + weekly Sunday | Deployment readiness check |

Required secrets for release: `FIREBASE_APP_ID`, `FIREBASE_TOKEN`, `GOOGLE_SERVICES_JSON`.

---

## Scripts Reference

| Script | Description |
|---|---|
| `scripts/run_pipeline.py` | Trainer entrypoint; manages `.retrain_trigger`; deletes trigger on any failure |
| `scripts/simulate_field_data.py` | Send synthetic samples to collector (modes: normal/soil_creep/crack_propagation/imminent_failure/mixed) |
| `scripts/backup_data.sh` | Tar `./data` directory for archiving |
| `scripts/health_check.py` | Ping all services and print a status table |
| `scripts/evaluate_models.py` | Evaluate TFLite models against field CSVs: ROC curve, calibration, top-K, error analysis |
| `scripts/visualize_features.py` | ASCII feature distribution histograms from field CSVs |
| `scripts/field_report.py` | Markdown field session summary report |
| `scripts/reset_pipeline.py` | Safely reset the retrain trigger and baseline count |
| `scripts/load_test.py` | API performance testing with p95 latency measurements (500 requests default) |
| `scripts/live_dashboard.py` | Curses terminal dashboard polling the collector API (Windows: curses optional) |
| `scripts/ab_test_models.py` | A/B accuracy comparison of two TFLite model versions (`make ab-test MODEL_A= MODEL_B=`) |
| `scripts/data_augmentation_report.py` | Class imbalance analysis and augmentation recommendations |
| `scripts/model_serve.py` | Lightweight HTTP inference server for model testing (port 8766) |
| `scripts/session_report.py` | Generate Markdown session report from a field CSV (`make session-report SESSION_CSV=`) |
| `scripts/device_calibration_check.py` | Verify device calibration quality per device from field CSVs |
| `scripts/pipeline_status.py` | Comprehensive pipeline status: model versions, sample counts, drift indicators |
| `scripts/deployment_readiness.py` | Check all ML assets and configs are present and valid for field deployment |
| `scripts/compliance_report.py` | Check field data against DIN 4150-3 / BS 7385-2 / ISO 4866 vibration standards |
| `scripts/battery_life_estimator.py` | Estimate M5StickC Plus 2 battery life by operating mode |
| `scripts/data_drift_detector.py` | Detect statistical drift between collected data and training baseline |
| `scripts/retrain_advisor.py` | Evaluate whether ML model retraining is recommended |

---

## Field Deployment Checklist

### Before Leaving for Site
- [ ] Charge M5StickC Plus 2 battery (check LED: green = full)
- [ ] Verify firmware version on device screen (should show v5.x.x)
- [ ] Run `make validate-config` — confirm model files valid
- [ ] Run `make health` — all services green
- [ ] Start data collector: `make collect`
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
- [ ] CRITICAL level (red) — evacuate non-essential personnel immediately
- [ ] Log any external vibration sources (machinery, footsteps)
- [ ] Run `make calibration-check` daily to verify sensor health

### After Session
- [ ] Export session CSV from app (Tools → Export)
- [ ] Run `make backup` to archive field data
- [ ] Run `make session-report SESSION_CSV=<file>` to generate session summary
- [ ] Run `make drift` to check if retraining is needed
- [ ] Push data: `make sync BUCKET=your-firebase-bucket`

---

## Docker Build Instructions

All build targets run in isolated containers. No local toolchain required beyond Docker Desktop.

### Prerequisites
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- Repo cloned locally

### Individual Build Targets

```bash
docker compose run --rm firmware   # firmware.bin
docker compose run --rm flutter    # app-release.apk
docker compose run --rm ml         # *.tflite + *.json
```

### Build Everything

```bash
docker compose run --rm firmware && \
docker compose run --rm flutter && \
docker compose run --rm ml
```

### Output Summary

| Target   | Output path |
|----------|-------------|
| Firmware | `.pio/build/m5stick-c-plus2/firmware.bin` |
| APK      | `app/build/app/outputs/flutter-apk/app-release.apk` |
| ML       | `app/assets/ml/*.tflite`, `app/assets/ml/*.json` |

All build artefacts are written to bind-mounted host directories and persist after the container exits. First runs are slower while Docker pulls base images and populates caches.
