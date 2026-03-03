# Full 4-Hour Sprint Plan — AncientVision System-Wide Improvements
**Date:** 2026-03-03  **Branch:** docker-experiment  **Status:** IN PROGRESS

---

## Data Collector Service (docker/collect/)
- [x] P01 Fix dead field-data named volume
- [x] P02 Configurable Firestore collection name
- [x] P03 Docker healthcheck on /health
- [x] P04 Add /stats endpoint — samples per day, per class, per device
- [x] P05 Add /export endpoint — return all collected data as CSV download
- [x] P06 Add /devices endpoint — list unique device_ids seen
- [x] P07 Add input range validation — reject physically impossible values
- [x] P08 Add structured JSON logging (replace print with json log lines)
- [x] P09 Add sliding-window rate limiting per device_id (max 10 req/s)
- [x] P10 Add data integrity check on startup

## Training Pipeline (scripts/)
- [x] P11 Fix ML output paths
- [x] P12 Improved synthetic training data (10200 samples)
- [x] P13 Add 5-fold cross-validation with per-fold accuracy
- [x] P14 Add confusion matrix + precision/recall/F1 per class
- [x] P15 Add early stopping (patience=10) to neural network
- [x] P16 Add L2 regularization to precursor neural network
- [x] P17 Add holdout test set (20% stratified split)
- [x] P18 Add model versioning — date + git SHA in config JSON
- [x] P19 Create scripts/evaluate_models.py
- [x] P20 Create scripts/visualize_features.py — ASCII feature distribution
- [x] P21 Add class weight balancing to neural network
- [x] P22 Add training metrics JSON output (loss, accuracy, training time)
- [x] P23 Add early stopping + LR schedule to autoencoder
- [ ] P24 Add data augmentation — Gaussian noise for minority classes
- [ ] P25 Add tests for training output quality

## Run Pipeline (scripts/run_pipeline.py)
- [x] P26 Error recovery — delete trigger on failure
- [x] P27 Add model deployment verification (dummy inference before archiving)
- [x] P28 Add rollback mechanism (keep previous .tflite if new fails)
- [x] P29 Add pipeline metrics JSON output
- [x] P30 Add pre-training data validation

## Docker Infrastructure
- [x] P31 Makefile with 14 targets
- [x] P32 .env.example + healthcheck
- [ ] P34 Add resource limits to compose services
- [ ] P35 Add Docker healthcheck to trainer service
- [ ] P36 Add scripts/health_check.py — ping all services

## GitHub Actions / CI
- [x] P37 build.yml — firmware + APK on push
- [x] P38 release.yml — GitHub Release + Firebase on tag
- [x] P39 Add pytest.yml — run 39 tests on every push
- [ ] P40 Add security scan (pip-audit) to CI

## Flutter App — Safety View
- [x] P42 psdSlope + validation logging
- [ ] P45 Fix AnomalyLevel.unknown label — show "Initializing"
- [ ] P46 Add session peak values tracking
- [ ] P47 Add all-clear timer (30s normal before showing green)
- [ ] P48 Add inference timing display
- [ ] P49 Add model warm-up in initialize()
- [ ] P50 Add haptic feedback on level UP transitions
- [ ] P51 Add session data export (CSV) via share_plus
- [ ] P52 Add calibration progress display
- [ ] P53 Improve precursor pattern description text
- [ ] P54 Add BLE scan filter by device name prefix
- [ ] P55 Add missed-packet detection
- [ ] P56 Add automatic device memory (SharedPreferences)
- [ ] P57 Fix inference debounce — max 2Hz
- [ ] P58 Add confidence display alongside anomaly score
- [ ] P59 Add alert escalation (ANOMALY >15s → CRITICAL)
- [ ] P60 Fix: show dashes after 5s no data (stale values)
- [ ] P61 Add session timer display
- [ ] P62 Add data packet timestamp to UI

## Flutter App — ML Services
- [ ] P67 Add adaptive_anomaly_service reset on BLE reconnect
- [ ] P68 Fix: _useRuleBased never reset — add retry logic
- [ ] P69 Add running average inference time
- [ ] P70 Add model fingerprint check on load
- [ ] P71 Add adaptive threshold tuning after calibration

## Firmware (src/main.cpp)
- [ ] P72 Add firmware version "5.1.0" to BLE JSON (key: fw)
- [ ] P73 Add packet sequence number (key: seq)
- [ ] P74 Add event duration (key: evtMs)
- [ ] P75 Add reboot counter in RTC memory (key: boots)
- [ ] P76 Add session event count (key: evts)
- [ ] P77 Improve M5StickC screen — PPV trend arrow, event count, firmware version
- [ ] P78 Add self-test on boot — verify IMU, show PASS/FAIL 2s
- [ ] P79 Add BLE CALIBRATE command processing
- [ ] P80 Add automatic gain control (switch to ±16g when PPV > 2.0)
- [ ] P81 Add serial diagnostic output on boot
- [ ] P82 Add power-save: increase BLE adv interval when SAFE for >30s
- [ ] P83 Fix: ensure STA/LTA denominator never divides by zero

## Testing and Tooling
- [x] P86 Add pytest.ini with testpaths
- [x] P87 Add integration test: simulator → watcher trigger
- [x] P88 Add concurrent write stress test
- [ ] P89 Add test for /stats, /export, /devices endpoints
- [ ] P90 Add test that model probabilities sum to ~1.0
- [x] P91 Add scripts/field_report.py — summary from collected CSVs
- [x] P92 Add scripts/reset_pipeline.py — safely reset trigger + baseline

## Documentation
- [ ] P96 Add ASCII architecture diagram to README
- [ ] P97 Add field deployment checklist
- [ ] P98 Add CHANGELOG.md
- [ ] P99 Add scripts/health_check.py — ping all services, print status table
- [ ] P100 Add contributing guide
