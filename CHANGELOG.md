# Changelog

All notable changes to AncientVision are documented here.

## [Unreleased] — 2026-03-04 Sprint 2 (docker-experiment branch)

### Added — Flutter App
- **Notifications screen**: filter chips (All/Critical/Warning/Info/Success), mark-all-read, swipe-to-dismiss, smart timestamps ("Just now", "X min ago")
- **Dashboard home**: live status banner with BLE dot + anomaly level + session timer; recent alerts summary card; session stats row
- **Tools view**: last-used timestamps per tool card; quick-action chips row; status badges
- **Settings screen**: calibration section (wizard + BLE CALIBRATE command + last-calibration date); notification settings (sound/vibration/cooldown); data privacy section (export/clear); app info with licenses
- **Field journal**: date range filter with picker; entry statistics header; export to clipboard; date range cleared on X tap
- **Quick capture**: vibration risk overlay badge on camera preview; GPS accuracy color indicator; photo save SnackBar with file size
- **FindingDetailsPage**: vibration risk overlay (nearby critical events, peak PPV, risk badge); JSON export; photo count badge; tappable measurement rows
- **FindingsMapScreen**: sensor location marker (orange, tap for coords); alert history markers (red warnings, count badge); GeoJSON export; distance measurement tool (long-press to activate)
- **ManualEntryFormScreen**: auto-suggest GPS on field focus; PPV-at-discovery card; explicit Save Draft button

### Added — Services
- **CriticalEventLogService**: event clustering (merge nearby events within 30s/1km); statistics (totalEvents, criticalCount, peakPpvAllTime, lastEventTime); CSV export method
- **EmergencyShareService**: SMS-format message builder; WhatsApp deep link; EmergencyAlertData data class; lastShareTime tracking
- **SessionSyncService**: batch upload (groups of 20); offline queue with SharedPreferences persistence; onProgress callback; collector URL persistence
- **ConnectivityMonitorService**: BLE disconnect duration; reconnection counter; health score (0.0–1.0); health description string
- **VibrationDspService**: signal quality score; clip detection; SNR estimate in dB; DspResult.qualityLabel
- **VibrationAnomalyService**: PPV trend detection (rising/stable/falling); consecutive anomaly readings; prediction confidence; anomaly description; level change duration

### Added — Scripts
- `scripts/live_dashboard.py` — curses terminal dashboard polling collector API (Windows: curses optional)
- `scripts/ab_test_models.py` — A/B comparison of two TFLite model versions
- `scripts/data_augmentation_report.py` — class imbalance analysis and augmentation recommendations
- `scripts/model_serve.py` — lightweight HTTP inference server for model testing
- `scripts/session_report.py` — Markdown session report from field CSV
- `scripts/device_calibration_check.py` — verify device calibration quality per device

### Added — Docker/Infrastructure
- `docker/nginx/nginx.conf`: gzip compression; security headers; differentiated rate limits per endpoint; access log with request time; upstream keepalive
- `docker/collect/app.py`: paginated `/data` endpoint; `/archive` endpoint; `/ingest` batch endpoint; per-device `/device/<id>/summary`; `/summary` aggregate
- `docker/monitoring/prometheus/`: prometheus.yml config + class imbalance + high ingestion rate alerting rules
- 3 new GitHub Actions workflows: performance_benchmark.yml, model_regression.yml, coverage_report.yml

### Added — Firmware (src/main.cpp)
- BLE CALIBRATE command handler: processes "CALIBRATE"/"CALIBRATE_START", triggers calibrateAccelBias(), notifies phone
- Auto gain control improvements: log format shows PPV value
- `alert_ms` field in BLE JSON (duration of current alert level)
- PPV trend arrow on M5StickC display

### Added — Flutter Tests
- 47 new unit tests: VibrationDspService (10), MlAnomalyService (17), AlertEscalationService (20)

### Fixed
- Flutter analyze: `No issues found!` — connectivity_plus API v6 migration, AlertData import ambiguity, color import, GPS accuracy bracket style
- Windows compatibility: curses optional import in live_dashboard.py

---

## [Unreleased] — Sprint 1 (docker-experiment branch)

### Added
- Docker infrastructure: multi-service compose (collect, train, dev)
- Data collector service with /stats, /export, /devices, /quality endpoints
- Rate limiting (10 req/s per device), input validation, structured JSON logging
- ML training pipeline: watcher + trainer with rollback and metrics
- GitHub Actions CI: build.yml, release.yml, pytest.yml
- 5-fold cross-validation + holdout test set + confusion matrix in training
- Early stopping + LR schedule for autoencoder and precursor classifier
- Model versioning (date + git SHA in config JSON)
- scripts/evaluate_models.py — evaluate TFLite models against field CSVs
- scripts/visualize_features.py — ASCII feature distribution histograms
- scripts/field_report.py — field session summary report
- scripts/reset_pipeline.py — safely reset trigger + baseline count
- scripts/health_check.py — ping all services, print status table
- scripts/test_e2e_pipeline.py — end-to-end pipeline integration tests (P224)
- scripts/load_test.py — API performance testing, p95 latency measurements (P225)
- Makefile targets: analyze, apk, quantize, benchmark, load-test, validate-data, e2e (P228)
- Flutter: session peak tracking, all-clear timer, stale-value detection
- Flutter: inference debounce (max 2Hz), session timer, Initializing label
- Flutter: ML service retry logic, adaptive threshold tuning after calibration
- Firmware: sequence number, firmware version, reboot counter in BLE JSON
- Firmware: STA/LTA zero-division guard, event duration + count in JSON
- Security: CORS headers (configurable via CORS_ORIGIN env var)
- Security: Request size limit (10 KB max) for /ingest and /collect endpoints
- Security: Path traversal prevention in /label endpoint (device_id, timestamp validation)
- Security: Retry-After header (1s) in rate-limit 429 responses

### Changed
- Improved synthetic training data: 10,200 samples with realistic class separation
- Dead field-data named volume replaced with bind mount
- Error recovery: trigger file deleted on pipeline failure
- Firestore collection name now configurable via FIRESTORE_COLLECTION env var
- Collector API: X-Content-Type-Options and X-Frame-Options security headers on all responses

### Fixed
- Merge blocker: Flutter Dockerfile /etc/passwd was empty
- Merge blocker: docker-compose.yml not mounted in trainer container
- run_pipeline.py: permanent wedge when sys.exit() inside run()
- psdSlope missing from extractFeatures() secondary call sites
- _useRuleBased never reset after transient ML failure

## [5.0.0] — 2026-02-13

### Changed
- Major architecture change: DSP moved from firmware to phone
- Firmware now sends simplified JSON + raw accel binary
- VibrationDspService added (Flutter): FFT, DWT, kurtosis, spectral centroid
- PrecursorClassifierService added: soil_creep, crack_propagation, imminent_failure

## [4.0.0] — 2026-02-12

### Fixed
- Critical: _runDeferredProcessing() was referenced but never implemented
- Critical: firmware missing BLEDevice::setMTU(517) — JSON >20 bytes truncated
- Added circular buffers (O(1) vs O(N) removeAt(0))
- Fixed timer leak in background_service.dart
- Added rule-based anomaly fallback when TFLite model unavailable
