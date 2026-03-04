# Changelog

All notable changes to AncientVision are documented here.

## [Unreleased] — 2026-03-04 Sprint 2 (docker-experiment branch)

### Added

#### Flutter App — Screens
- **Notifications screen**: filter chips (All/Critical/Warning/Info/Success), mark-all-read, swipe-to-dismiss, smart timestamps ("Just now", "X min ago")
- **Dashboard home**: live status banner with BLE dot + anomaly level + session timer; recent alerts summary card; session stats row
- **Tools view**: last-used timestamps per tool card; quick-action chips row; status badges
- **Settings screen**: calibration section (wizard + BLE CALIBRATE command + last-calibration date); notification settings (sound/vibration/cooldown); data privacy section (export/clear); app info with licenses
- **Field journal**: date range filter with picker; entry statistics header; export to clipboard; date range cleared on X tap
- **Quick capture**: vibration risk overlay badge on camera preview; GPS accuracy color indicator; photo save SnackBar with file size
- **FindingDetailsPage**: vibration risk overlay (nearby critical events, peak PPV, risk badge); JSON export; photo count badge; tappable measurement rows
- **FindingsMapScreen**: sensor location marker (orange, tap for coords); alert history markers (red warnings, count badge); GeoJSON export; distance measurement tool (long-press to activate)
- **ManualEntryFormScreen**: auto-suggest GPS on field focus; PPV-at-discovery card; explicit Save Draft button

#### Flutter App — Services
- **CriticalEventLogService**: event clustering (merge nearby events within 30s/1km); statistics (totalEvents, criticalCount, peakPpvAllTime, lastEventTime); CSV export method
- **EmergencyShareService**: SMS-format message builder; WhatsApp deep link; EmergencyAlertData data class; lastShareTime tracking
- **SessionSyncService**: batch upload (groups of 20); offline queue with SharedPreferences persistence; onProgress callback; collector URL persistence
- **ConnectivityMonitorService**: BLE disconnect duration; reconnection counter; health score (0.0–1.0); health description string
- **VibrationDspService**: signal quality score; clip detection; SNR estimate in dB; DspResult.qualityLabel
- **VibrationAnomalyService**: PPV trend detection (rising/stable/falling); consecutive anomaly readings; prediction confidence; anomaly description; level change duration

#### Flutter App — Safety UI (sprint sprint 2026-03-03)
- Session peak tracking, all-clear timer (30s), debounce (2Hz), stale detection (5s)
- Session timer, Initializing label, haptic escalation, precursor descriptions, confidence display
- ANOMALY→CRITICAL auto-escalation after 15s sustained anomaly
- Packet timestamp display in safety view

#### Flutter App — BLE
- Sequence number tracking in ImuData (`seq` field)
- BlePacketTracker: packet loss rate and gap detection
- `isAncientVisionDevice()` helper for reliable BLE scan matching
- DeviceMemoryService: remembers last-connected device via SharedPreferences

#### Flutter App — Tests
- 47 new unit tests: VibrationDspService (10), MlAnomalyService (17), AlertEscalationService (20)

#### Scripts
- `scripts/live_dashboard.py` — curses terminal dashboard polling collector API (Windows: curses optional)
- `scripts/ab_test_models.py` — A/B comparison of two TFLite model versions
- `scripts/data_augmentation_report.py` — class imbalance analysis and augmentation recommendations
- `scripts/model_serve.py` — lightweight HTTP inference server for model testing (port 8766)
- `scripts/session_report.py` — Markdown session report from field CSV
- `scripts/device_calibration_check.py` — verify device calibration quality per device

#### Docker/Infrastructure
- `docker/nginx/nginx.conf`: gzip compression; security headers; differentiated rate limits per endpoint; access log with request time; upstream keepalive
- `docker-compose.monitoring.yml`: Prometheus + Grafana monitoring stack (`make monitor`)
- `docker/monitoring/prometheus/`: prometheus.yml config + class imbalance + high ingestion rate alerting rules

#### Collector API (`docker/collect/app.py`)
- Paginated `/data` endpoint
- `/archive` endpoint for historical data access
- `/ingest` batch endpoint for bulk sample upload
- Per-device `/device/<id>/summary` endpoint
- `/summary` aggregate statistics endpoint

#### GitHub Actions Workflows (Sprint 2 additions)
- `performance_benchmark.yml` — inference and API benchmark on push to docker-experiment
- `model_regression.yml` — detect accuracy regressions when ML assets change
- `coverage_report.yml` — Python test coverage report, weekly on Sundays

#### Makefile Targets (Sprint 2 additions)
- `monitor` — start Prometheus + Grafana monitoring stack
- `live-dashboard` — live curses terminal dashboard
- `ab-test` — A/B model comparison (MODEL_A= MODEL_B= variables)
- `augmentation-report` — class distribution + augmentation recommendations
- `serve-model` — start lightweight HTTP model inference server on port 8766
- `session-report` — Markdown report from a session CSV (SESSION_CSV= variable)
- `calibration-check` — verify device calibration quality from field CSVs
- `confidence-analysis` — model confidence distribution and calibration (ECE)
- `monitor-model` — check deployed model accuracy against labeled field data
- `deployment-check` — verify all ML assets and configs are ready for field deployment
- `compliance` — check field data against DIN 4150-3 / BS 7385-2 / ISO 4866 standards
- `battery-estimate` — estimate M5StickC Plus 2 battery life by operating mode
- `sync-app` — echo instructions to sync app/lib to standalone AncientVision repo
- `clean-docker` — full teardown including volumes and orphan containers

#### Firmware (src/main.cpp)
- BLE CALIBRATE command handler: processes "CALIBRATE"/"CALIBRATE_START", triggers calibrateAccelBias(), notifies phone
- `alert_ms` field in BLE JSON (duration of current alert level)
- PPV trend arrow on M5StickC display

### Changed
- Collector API: nginx reverse proxy with rate limiting now fronts the Flask app
- ML inference: `_useRuleBased` retry capped at max 3 attempts to prevent permanent fallback
- Adaptive anomaly service: thresholds tuned post-calibration using running field statistics
- Flutter ML services: running average inference time tracked for latency display

### Fixed
- Flutter analyze: `No issues found!` — connectivity_plus API v6 migration, AlertData import ambiguity, color import, GPS accuracy bracket style
- Windows compatibility: curses optional import in `scripts/live_dashboard.py`

---

## [Unreleased] — Sprint 1 (docker-experiment branch)

### Added

#### Docker Infrastructure
- Multi-service Docker Compose setup: `docker-compose.yml` (build), `docker-compose.collect.yml` (collector), `docker-compose.train.yml` (watcher + trainer), `docker-compose.dev.yml` (dev shells)
- Data collector service (`docker/collect/app.py`) with `/stats`, `/export`, `/devices`, `/quality` endpoints
- Rate limiting (10 req/s per device), input validation, structured JSON logging
- ML training pipeline: file watcher + trainer with rollback on failure and pipeline metrics JSON
- Resource limits on all compose services (CPU + memory)

#### ML Training
- 5-fold cross-validation + holdout test set + confusion matrix
- Early stopping + LR schedule for autoencoder and precursor classifier
- Class weights for imbalanced training data
- Model versioning: date + git SHA embedded in config JSON
- Pre-training validation gates (data integrity checks before any training run)
- Training metrics JSON written alongside model files

#### Scripts
- `scripts/run_pipeline.py` — trainer entrypoint; deletes `.retrain_trigger` on ANY failure (permanent-wedge bug fixed)
- `scripts/evaluate_models.py` — evaluate TFLite models against field CSVs; ROC, calibration, top-K, error analysis
- `scripts/visualize_features.py` — ASCII feature distribution histograms
- `scripts/field_report.py` — field session summary report
- `scripts/reset_pipeline.py` — safely reset retrain trigger and baseline count
- `scripts/health_check.py` — ping all services and print status table
- `scripts/simulate_field_data.py` — send synthetic samples to collector (normal/soil_creep/crack_propagation/imminent_failure/mixed modes)
- `scripts/backup_data.sh` — tar `./data` directory for archiving
- `scripts/test_e2e_pipeline.py` — end-to-end pipeline integration tests
- `scripts/load_test.py` — API performance testing with p95 latency measurements

#### GitHub Actions Workflows
- `build.yml` — push to master → builds firmware.bin + Flutter APK artifacts (30-day retention)
- `release.yml` — on `v*.*.*` tags → creates GitHub Release + Firebase App Distribution upload
- `pytest.yml` — Python test suite with coverage on all pushes to master/docker-experiment
- `pytest_coverage.yml` — detailed coverage report for scripts/ and docker/ Python files
- `flutter_test.yml` — Flutter unit tests when app/ changes
- `integration_test.yml` — collector + watcher integration tests
- `nightly_integration.yml` — full integration suite at 02:00 UTC daily
- `lint_check.yml` — ruff linting on Python files (scripts/, docker/)
- `dependency_audit.yml` — pip-audit security scan weekly + on push
- `security_scan.yml` — pip-audit on requirements files + Dockerfile changes
- `docker_security_scan.yml` — Trivy container security scan weekly
- `drift_check.yml` — data drift detector weekly
- `data_quality.yml` / `data_quality_check.yml` — daily/weekly training data quality gates
- `model_health.yml` — daily TFLite model + scaler validation
- `model_quality.yml` — ML quality gate on training script changes
- `model_benchmark.yml` — inference benchmark on ML asset changes
- `deployment_check.yml` — deployment readiness check on push to docker-experiment
- `release_notes.yml` — auto-extract CHANGELOG section and attach to GitHub Release

#### Makefile Targets
- `build`, `firmware`, `flutter`, `ml` — Docker build targets
- `collect`, `train` — runtime stack management
- `dev-ml`, `dev-flutter`, `dev-firmware` — interactive dev shells
- `test`, `e2e`, `load-test`, `validate-data`, `dry-run` — testing and validation
- `simulate`, `backup`, `logs`, `clean`, `report`, `drift` — field data tools
- `analyze`, `apk`, `quantize`, `benchmark` — build and analysis
- `status`, `health`, `augment`, `online-learn`, `tune`, `onnx` — pipeline management
- `label`, `annotate`, `replay`, `schedule`, `sync` — data labeling and sync

#### Security
- CORS headers configurable via `CORS_ORIGIN` environment variable
- Request size limit (10 KB max) for `/ingest` and `/collect` endpoints
- Path traversal prevention in `/label` endpoint (device_id, timestamp validation)
- Retry-After header (1s) in rate-limit 429 responses
- `X-Content-Type-Options` and `X-Frame-Options` security headers on all API responses

#### Flutter (sprint 2026-03-03 initial items)
- Session peak tracking, all-clear timer (30s), stale-value detection (5s)
- Inference debounce at max 2 Hz, session timer, Initializing label
- ML service retry logic with max 3 attempts, adaptive threshold tuning post-calibration
- BlePacketTracker for sequence-number-based packet loss detection

#### Firmware (sprint 2026-03-03 additions)
- `fw`, `seq`, `evtMs`, `boots`, `evts` fields added to BLE JSON
- STA/LTA zero-division guard
- Event duration and count in JSON output
- Boot self-test; serial diagnostic output on startup
- Power-save tracking (cumulative ms in low-power mode)
- Buffer size increased 192→256 bytes

### Changed
- Synthetic training data improved: 10,200 samples with correlated trends and realistic class separation
- Dead field-data named volume replaced with bind mount in docker-compose.train.yml
- Error recovery: `.retrain_trigger` deleted on pipeline failure (prevents permanent wedge)
- Firestore collection name now configurable via `FIRESTORE_COLLECTION` env var

### Fixed
- Docker merge blocker: Flutter Dockerfile `/etc/passwd` was empty (cirruslabs image issue); fixed with `USER 0` + populated `/etc/passwd`/`/etc/group`
- Docker merge blocker: `docker-compose.yml` was not mounted in trainer container
- `run_pipeline.py`: `sys.exit()` inside `run()` caused permanent wedge on failure
- `psdSlope` missing from `extractFeatures()` secondary call sites
- `_useRuleBased` flag never reset after transient ML inference failure
- MSYS path mangling on Windows Git Bash: resolved with `MSYS_NO_PATHCONV=1`

---

## [5.0.0] — 2026-02-13

### Changed
- Major architecture change: DSP moved from firmware to phone
- Firmware now sends simplified JSON + raw accel binary (3 packets of 512 bytes on FFT characteristic)
- VibrationDspService added (Flutter): FFT, DWT, kurtosis, spectral centroid, Arias intensity, CAV
- PrecursorClassifierService added: soil_creep, crack_propagation, imminent_failure patterns
- AdaptiveAnomalyService added: autoencoder-based anomaly detection with calibration window
- BLE parser: RawAccelReassembler for multi-packet binary; ImuData.peak field added

---

## [4.0.0] — 2026-02-12

### Fixed
- Critical: `_runDeferredProcessing()` was referenced in comments but never implemented — all advanced visualization was dead (wavelet, spectrogram, ML, multi-standard classification)
- Critical: firmware missing `BLEDevice::setMTU(517)` — ALL JSON > 20 bytes was silently truncated
- Added circular buffers (O(1) vs O(N) `removeAt(0)`) in safety_view and spectrogram
- Fixed timer leak in `background_service.dart` (heartbeatTimer not cancelled on stop)
- Added rule-based anomaly fallback (PPV/STA-LTA/CAV/kurtosis/RMS/seismic) when TFLite model unavailable

### Added
- DSP correctness fixes: Parseval scaling 4/N²→2/N², periodic Hanning, PSD ENBW normalization, crest factor floor 1.414→3.0
- Firmware: ESP32 watchdog (5s), double-buffered accel arrays, BLE delays 450→130ms, LiPo lookup table
- Firmware: 1-window warm-up before alerts fire; hourly noise recalibration; moisture sensor skip fix
- App: Firestore 10s timeouts; FFT UUID corrected (26a9→26ac); mounted checks throughout; dspService.dispose()
- Precursor classifier: scaler export added to generate_precursor_data.py; PrecursorClassifierService loads and applies normalization
- ML anomaly: scaler dimension check in `initialize()`; sample dimension check in `finishCalibration()`; `_isLoaded=false` in catch block
