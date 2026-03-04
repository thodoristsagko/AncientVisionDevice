# Changelog

All notable changes to AncientVision are documented here.

## [Unreleased] — docker-experiment branch

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
