# Docker Expansion Design

**Date:** 2026-03-03
**Branch:** docker-experiment
**Status:** Approved

## Goal

Expand the existing three-image Docker setup into a full development and field pipeline:
end-to-end ML retraining, field data collection, and CI/CD with auto-deploy.

## Approach: Separate Compose Files by Concern

Three compose files, each owning one concern:

| File | Purpose | When run |
|------|---------|----------|
| `docker-compose.yml` | Build services (firmware, flutter, ml) | CI/CD + manual builds |
| `docker-compose.collect.yml` | Field data collection | On field laptop |
| `docker-compose.train.yml` | ML retraining pipeline | Automatically, data-triggered |

## Artifact Flow

```
M5StickC (WiFi) ──────────────────────────────────────────┐
                                                           ▼
Flutter app (BLE) → Firestore ──→ [data-collector] → ./data/field/*.csv
                                                           │
                              [file-watcher] watches ──────┘
                              100 new samples? → [trainer]
                                                      │
                              train → export .tflite ─┘
                                           │
                              app/assets/models/*.tflite
                                           │
                              [flutter build apk] → app-release.apk

GitHub push → Actions → build all 3 → GitHub Release + Firebase App Distribution
```

## Data Collection Service (`docker-compose.collect.yml`)

**Service:** `data-collector` — lightweight Flask API.

**M5StickC WiFi path:** device POSTs vibration JSON to `http://<laptop-ip>:8765/ingest`.
Collector validates, appends to `./data/field/YYYY-MM-DD.csv`, syncs to Firestore when online.

**Firestore pull path:** background thread polls Firestore every 5 minutes for new phone-uploaded
samples, deduplicates by timestamp+device_id, writes to the same CSV files.

**Volume layout:**
```
./data/
  field/       ← raw samples (CSV, one file per day)
  processed/   ← post-training archive
```

**Credentials:** `GOOGLE_APPLICATION_CREDENTIALS` env var pointing to a service account JSON
mounted as a secret volume — never baked into the image.

**Sample tracking:** collector writes `./data/field/.sample_count` after each write.
The file watcher reads this to know when to trigger training.

## Training Pipeline (`docker-compose.train.yml`)

**Services:** `file-watcher` + `trainer`.

**file-watcher:** polls `./data/field/.sample_count` every 60 seconds. When new samples since
last training run exceed 100, writes `./data/.retrain_trigger` and exits. Docker restart policy
brings it back automatically.

**trainer** entrypoint sequence:
1. Detect `./data/.retrain_trigger`
2. Run `train_autoencoder.py` → `autoencoder.tflite`
3. Run `train_precursor_classifier.py` → `precursor_classifier.tflite` + `scaler.json`
4. Copy outputs → `app/assets/models/`
5. Trigger `docker compose run flutter flutter build apk --release`
6. Archive processed samples → `./data/processed/YYYY-MM-DD/`
7. Reset `.sample_count` to 0, delete `.retrain_trigger`

**Shared volumes across compose files:**
```
./data/               ← collect + train
app/assets/models/    ← trainer writes, flutter reads
app/build/            ← APK output
.pio/                 ← firmware build cache
```

## CI/CD (GitHub Actions)

**`build.yml`** — triggers on every push to `master`:
1. Checkout repo
2. `docker compose run firmware` → `firmware.bin`
3. `docker compose run flutter` → `app-release.apk`
4. Upload both as GitHub Actions artifacts (30-day retention)

**`release.yml`** — triggers on `v*.*.*` tags:
1. Same builds as above
2. Create GitHub Release, attach `firmware.bin` + `app-release.apk`
3. Upload APK to Firebase App Distribution

**Required GitHub secrets:**
```
FIREBASE_APP_ID           ← from Firebase console
FIREBASE_TOKEN            ← from firebase login:ci
GOOGLE_SERVICES_JSON      ← base64-encoded google-services.json
```

No self-hosted runner needed. Runs on GitHub's standard Ubuntu runners.
Firmware + flutter images cached between runs using GitHub Actions cache.
