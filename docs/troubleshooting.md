# Troubleshooting Guide

This guide covers the most common issues encountered when developing, deploying, or
operating AncientVision in the field.

---

## 1. Docker Storage Issues — C: Drive Full

### Symptoms

- `docker compose build` fails with `no space left on device`.
- Windows shows C: drive at 100% capacity.
- Docker Desktop reports a locked VHDX file it cannot shrink.

### Cause

Docker Desktop (WSL 2 backend) stores its VHDX disk image on C: by default. This
image grows as images and containers are created and does not automatically shrink when
layers are deleted.

### Solution — Move Docker Storage to D:

1. **Reboot Windows** first. Hyper-V/WSL 2 locks the VHDX while running and Windows
   cannot compact or move it until the lock is released.

2. After reboot, run the cleanup script to reclaim space before moving:
   ```powershell
   # PowerShell (run as Administrator)
   & "$env:USERPROFILE\Desktop\cleanup_docker_c_drive.ps1"
   ```

3. Open Docker Desktop settings:
   - Resources > Advanced > Disk image location
   - Change from `C:\Users\<user>\AppData\Local\Docker\wsl` to `D:\Docker\`

4. Alternatively, edit `%APPDATA%\Docker\settings-store.json` directly:
   ```json
   {
     "CustomWslDistroDir": "D:\\Docker\\wsl",
     "DataFolder": "D:\\Docker\\data"
   }
   ```

5. Restart Docker Desktop.

6. Verify Docker is working:
   ```bash
   docker info
   docker run --rm hello-world
   ```

### Prevention

- Run `docker system prune -f` after each build session to remove dangling layers.
- Use `make clean` which calls `docker system prune -f` automatically.
- Allocate at least 40 GB to Docker's VHDX.

---

## 2. BLE Not Connecting

### Symptoms

- App shows "Scanning..." indefinitely.
- Device appears in scan results but "Connect" fails immediately.
- App connects but receives no data.

### Causes and Solutions

**A. MTU not negotiated**

The firmware requires MTU 517. If the phone does not negotiate MTU, JSON packets
larger than 20 bytes are silently truncated and the BLE parser will reject them.

Fix: Ensure `BLEDevice::setMTU(517)` is called in the firmware before creating the
GATT server. This is already present in v5.0+. If you are running an older firmware
build, flash the latest version.

**B. Device name not found during scan**

On Android, `platformName` is often empty during the initial BLE scan cycle.
The app must also check `advertisementData.advName`.

Fix: In `lib/utils/ble_parser.dart`, confirm the scan filter checks both fields:
```dart
final name = device.platformName.isNotEmpty
    ? device.platformName
    : device.advertisementData.advName;
if (name == 'AncientVision') { ... }
```

**C. Wrong service or characteristic UUID**

The FFT/raw accel characteristic UUID changed from `...26a9` to `...26ac` in the
v5.0 refactor. Old app builds point to the wrong UUID and silently receive nothing.

Fix: Check `lib/config/app_constants.dart` — the correct UUID is:
```
CHAR_FFT_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26ac"
```

**D. Android BLE scan mode**

Android's background BLE scan mode may miss advertisements. In the foreground
scanning loop, use `ScanMode.lowLatency`.

**E. RSSI too low**

Keep the phone within 3 m of the M5StickC Plus 2. Concrete, soil, and metal
significantly attenuate BLE at 2.4 GHz.

---

## 3. TFLite Inference Fails

### Symptoms

- Safety view shows "Initializing" or `AnomalyLevel.unknown` indefinitely after the
  calibration period.
- Logcat shows: `TfLiteException`, `ModelFingerprintMismatch`, or
  `Failed to apply delegate`.

### Causes and Solutions

**A. Model file not bundled in APK**

Verify `app/pubspec.yaml` includes the model assets:
```yaml
flutter:
  assets:
    - assets/ml/autoencoder.tflite
    - assets/ml/precursor_classifier.tflite
    - assets/ml/autoencoder_scaler.json
    - assets/ml/precursor_scaler.json
```

**B. Scaler dimension mismatch**

The scaler JSON must have exactly 11 entries for the autoencoder and 17 for the
precursor classifier. If you retrained with different features, regenerate the scaler
and redeploy.

Fix: Run `scripts/generate_precursor_data.py` and `scripts/train_autoencoder.py` to
regenerate both model + scaler pairs, then `make flutter` to rebuild.

**C. Model warm-up**

TFLite models take one inference cycle to warm up JIT-compiled kernels. The first
inference may be slow (100–500 ms). The anomaly service handles this by discarding the
first result after loading.

**D. NNAPI / GPU delegate not available**

Some Android devices do not support NNAPI or GPU delegates. The app falls back to the
CPU delegate automatically. If you see delegate errors, ensure the TFLite Flutter
plugin is configured to use CPU:
```dart
final options = InterpreterOptions()..useNnApiForAndroid = false;
```

**E. Inference exception caught by safety net**

`AdaptiveAnomalyService` wraps all inference calls in try-catch and falls back to the
rule-based scorer (see `docs/ml-architecture.md`). If the safety view shows any alert
level other than "Initializing", inference has fallen back to rules — check the device
log for the specific exception.

---

## 4. Firebase / Firestore Not Syncing

### Symptoms

- Data-collector log shows: `firestore_sync: disabled, reason: no_credentials`.
- Phone-uploaded samples never appear in `data/field/*.csv`.
- Firestore writes from the app time out after 10 seconds.

### Causes and Solutions

**A. Missing GOOGLE_APPLICATION_CREDENTIALS**

The data-collector Firestore background sync is disabled when this variable is not set.

Fix: Set it in your `.env` file:
```
GOOGLE_APPLICATION_CREDENTIALS=/workspace/secrets/firebase-key.json
```
Mount the key file into the container (see `docker-compose.collect.yml`).

**B. Wrong Firestore collection name**

The app writes to the collection configured in `lib/config/app_constants.dart`. The
data-collector reads from the collection set by `FIRESTORE_COLLECTION` env var
(default: `vibration_samples`). These must match.

Fix: Either change the env var or update `app_constants.dart`, then rebuild.

**C. Firestore offline writes stuck**

The Flutter Firestore SDK queues writes offline and flushes when connectivity is
restored. If writes are stuck, check:
- Device has internet access.
- Firebase project quota has not been exceeded.
- The 10-second timeout in the app is triggering a snackbar — this is a warning, not
  an error; Firestore will retry automatically.

---

## 5. Training Fails

### Symptoms

- `docker compose -f docker-compose.train.yml run --rm trainer` exits with an error.
- `scripts/generate_precursor_data.py` raises `ValueError` or `ImportError`.

### Causes and Solutions

**A. Insufficient data**

The training pipeline requires a minimum number of samples to fit a reliable scaler
and avoid degenerate models. If `data/field/*.csv` contains fewer than ~50 rows, the
trainer will warn and may produce a low-accuracy model.

Fix: Collect more data with `make simulate` (sends 150 synthetic samples to the
collector) or wait for field data to accumulate.

**B. Wrong data format**

Each CSV row must include at minimum: `device_id`, `timestamp`, `ppv`, `rms`, `freq`,
`kurtosis`. Rows missing these fields are skipped during training.

Fix: Inspect the CSV with `GET /quality` to see the `missing_required_fields` count.
Re-label or remove malformed rows using `POST /label` or `DELETE /data/old`.

**C. TensorFlow / NumPy not installed**

The ML Docker image installs all dependencies via `docker/ml/requirements.txt`.
If running scripts locally, install manually:
```bash
pip install tensorflow numpy scikit-learn
```

**D. Scaler dimension mismatch on load**

`PrecursorClassifierService.initialize()` checks that `precursor_scaler.json` has
exactly 17 features. If a stale scaler from an older model version is bundled, it will
fail with a logged error and fall back to the rule-based scorer.

Fix: Retrain from scratch with `scripts/generate_precursor_data.py` and redeploy.

---

## 6. High False Positive Rate

### Symptoms

- Safety view frequently shows WARNING or CRITICAL during normal operation.
- `evts` counter increments rapidly even when the device is stationary.

### Causes and Solutions

**A. Calibration not completed**

The noise floor is calibrated over the first 5 analysis windows (~6.4 s). During this
period `cal = false` in the BLE JSON. Alerts before calibration completes are
unreliable.

Fix: Wait for `cal = true` before trusting any alert output. You can also trigger a
fresh calibration by sending the `CALIBRATE` command over BLE.

**B. Noise floor too low**

If the device is placed on a surface with micro-vibrations (e.g., a diesel generator
nearby), the calibrated noise floor may be set too high, reducing sensitivity, or too
low, causing false positives.

Fix: Place the device on the target measurement surface during the calibration window,
away from external vibration sources. The M5StickC Plus 2 noise floor on a stable
surface should be < 0.05 mm/s PPV.

**C. STA/LTA threshold too sensitive**

The STA/LTA trigger is set at 4.0 (configurable in `src/main.cpp` as `STA_TRIGGER`).
For sites with high ambient vibration, increase this value.

**D. PPV threshold too low**

`PPV_SAFE_MAX = 0.3 mm/s` (per DIN 4150-3 background level). Archaeological sites
near roads or construction may have higher ambient PPV. Adjust this constant in
`src/main.cpp` and rebuild the firmware.

---

## 7. App Shows "Initializing" Forever

### Symptoms

- Safety view displays "Initializing" or the anomaly level remains `unknown`
  indefinitely, even after BLE connects and data is flowing.

### Causes and Solutions

**A. Calibration pending**

`AnomalyLevel.unknown` is returned until the autoencoder calibration phase completes
(5 windows, ~6.4 s). This is normal behaviour at startup.

Fix: Wait ~10 seconds after connecting BLE. If the app still shows "Initializing"
after 30 seconds, proceed to B.

**B. BLE data not flowing**

If no raw accel packets are received, `VibrationDspService` has no data to compute
features from, and calibration never completes.

Fix: Check the RSSI indicator in the app header. Ensure the device is in range.
Check logcat for BLE packet errors or MTU issues (see Issue 2 above).

**C. TFLite model failed to load**

If `initialize()` fails with an exception, `_isLoaded` is set to `false` and the
service returns `unknown` for every subsequent call.

Fix: Check logcat for `TfLiteException` or file-not-found errors. Verify the model
assets are present (see Issue 3A above).

**D. DspService not disposed from a previous session**

If `dspService.dispose()` was not called when the previous BLE session disconnected,
internal state from the old session may interfere.

Fix: Ensure `dspService.dispose()` is called in `safety_view.dart`'s `dispose()`
method. This was fixed in the 2026-02-24 audit.

---

## 8. Missed BLE Packets

### Symptoms

- `seq` counter in the BLE JSON has gaps (e.g., jumps from 100 to 102).
- Raw accel reassembler reports incomplete windows.
- Phone-side FFT results are less frequent than expected.

### Causes and Solutions

**A. BLE advertising interval too long**

In low-power mode, the firmware extends the BLE advertising interval, which can cause
the Android BLE stack to miss packets.

Fix: In `src/main.cpp`, check `g_powerSaveActive`. The device enters low-power mode
after sustained safe vibration. A `CALIBRATE` command will reset the state and
temporarily restore the normal advertising interval.

**B. Android BLE scan mode**

Android's background BLE scan mode (`ScanMode.lowPower`) misses more advertisements
than `ScanMode.lowLatency`.

Fix: Ensure the Flutter BLE plugin is configured for `lowLatency` scan mode while the
safety view is in the foreground.

**C. Phone CPU throttling**

On some Android devices, aggressive battery optimisation suspends background processes,
including the BLE receive handler.

Fix: Disable battery optimisation for the AncientVision app in Android Settings >
Battery > Battery optimisation. This is documented in the field deployment checklist
(see `docs/deployment.md`).

**D. MTU fragmentation**

If MTU negotiation fails and falls back to 23 bytes, multi-byte BLE packets (JSON,
raw accel) will be fragmented across many L2CAP PDUs, increasing the chance of
delivery failure under interference.

Fix: Confirm MTU = 517 by checking the log line `ble_mtu_negotiated: 517` in the
data-collector logs or in Flutter logcat.
