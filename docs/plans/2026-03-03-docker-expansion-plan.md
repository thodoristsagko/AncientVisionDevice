# Docker Expansion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expand the three-image Docker setup into a full pipeline: field data collection, data-triggered ML retraining, and CI/CD auto-deploy to GitHub Releases + Firebase App Distribution.

**Architecture:** Three separate compose files own three concerns — `docker-compose.yml` (builds, CI/CD), `docker-compose.collect.yml` (field data ingestion), `docker-compose.train.yml` (retraining pipeline). Shared Docker volumes pass artifacts between services. GitHub Actions runs on standard Ubuntu runners using the existing images.

**Tech Stack:** Python/Flask (data collector), Python watchdog-style polling (file watcher), TensorFlow/TFLite (model export), Docker Compose volumes (artifact passing), GitHub Actions (CI/CD), Firebase App Distribution (APK delivery).

---

### Task 1: Fix ML output paths and shared volume mounts

The existing `train_autoencoder.py` writes to `assets/ml/` (repo root) and has a hardcoded
Windows path. In Docker, models must land in `app/assets/ml/` so Flutter can read them.

**Files:**
- Modify: `scripts/train_autoencoder.py`
- Modify: `scripts/generate_precursor_data.py`
- Modify: `docker-compose.yml`

**Step 1: Update output path in train_autoencoder.py**

Replace the output section at the bottom of `scripts/train_autoencoder.py`.
Find the lines:
```python
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL_ML = os.path.join(REPO, "assets", "ml")
FLUTTER_ML = r"C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision\assets\ml"
```
Replace with:
```python
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# In Docker: /workspace/app/assets/ml  (mounted from ./app/assets/ml)
# On Windows host: <repo>/app/assets/ml
LOCAL_ML = os.path.join(REPO, "app", "assets", "ml")
```
Also remove the `FLUTTER_ML` copy block at the bottom (the `if os.path.isdir(FLUTTER_ML)` branch).

**Step 2: Run autoencoder script to verify it still works**

```bash
cd .claude/worktrees/docker-experiment
docker compose run --rm ml python scripts/train_autoencoder.py
```
Expected: prints "Done." and `app/assets/ml/vibration_anomaly.tflite` exists on host.

**Step 3: Update generate_precursor_data.py similarly**

Open `scripts/generate_precursor_data.py`, find any hardcoded Windows paths or
`assets/ml` references, apply the same fix: output to `app/assets/ml/`.

**Step 4: Update docker-compose.yml ml volume mount**

In `docker-compose.yml`, change:
```yaml
  ml:
    volumes:
      - ./assets/ml:/workspace/assets/ml
```
to:
```yaml
  ml:
    volumes:
      - ./app/assets/ml:/workspace/app/assets/ml
      - ./data:/workspace/data
```
The `./data` mount is shared with collect + train services (created in later tasks).

**Step 5: Verify build still works**

```bash
docker compose build ml
docker compose run --rm ml python scripts/train_autoencoder.py
ls app/assets/ml/
```
Expected: `vibration_anomaly.tflite`, `vibration_scaler.json`, `vibration_model_config.json`

**Step 6: Commit**

```bash
git add scripts/train_autoencoder.py scripts/generate_precursor_data.py docker-compose.yml
git commit -m "fix: ML output paths point to app/assets/ml, add shared data volume"
```

---

### Task 2: Data collector Flask API

Create a Flask service that receives vibration JSON from the M5StickC over WiFi and
from Firestore (phone path), writing everything to `./data/field/YYYY-MM-DD.csv`.

**Files:**
- Create: `docker/collect/requirements.txt`
- Create: `docker/collect/Dockerfile`
- Create: `docker/collect/app.py`
- Create: `docker/collect/test_app.py`

**Step 1: Write the failing tests**

Create `docker/collect/test_app.py`:
```python
import csv
import json
import os
import tempfile
import pytest
from app import create_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c, tmp_path


def test_ingest_writes_csv(client):
    c, data_dir = client
    payload = {
        "device_id": "m5stick-01",
        "timestamp": "2026-03-03T10:00:00Z",
        "rms": 0.01,
        "ppv": 0.05,
        "freq": 15.0,
        "crest": 3.0,
        "centroid": 20.0,
        "kurtosis": 1.5,
        "stalta": 1.0,
        "arias": 0.0001,
        "cav": 0.002,
        "label": "normal"
    }
    r = c.post("/ingest", json=payload)
    assert r.status_code == 200
    csvs = list(data_dir.glob("field/*.csv"))
    assert len(csvs) == 1
    with open(csvs[0]) as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 1
    assert rows[0]["device_id"] == "m5stick-01"


def test_ingest_increments_sample_count(client):
    c, data_dir = client
    payload = {
        "device_id": "m5stick-01", "timestamp": "2026-03-03T10:00:00Z",
        "rms": 0.01, "ppv": 0.05, "freq": 15.0, "crest": 3.0,
        "centroid": 20.0, "kurtosis": 1.5, "stalta": 1.0,
        "arias": 0.0001, "cav": 0.002, "label": "normal"
    }
    c.post("/ingest", json=payload)
    c.post("/ingest", json=payload)
    count_file = data_dir / "field" / ".sample_count"
    assert count_file.read_text().strip() == "2"


def test_ingest_rejects_missing_fields(client):
    c, _ = client
    r = c.post("/ingest", json={"device_id": "x"})
    assert r.status_code == 400


def test_health(client):
    c, _ = client
    r = c.get("/health")
    assert r.status_code == 200
```

**Step 2: Run tests to verify they fail**

```bash
cd docker/collect
pip install flask pytest  # local, just for running tests
python -m pytest test_app.py -v
```
Expected: `ModuleNotFoundError: No module named 'app'`

**Step 3: Implement app.py**

Create `docker/collect/app.py`:
```python
"""
Data collection Flask API.
Receives vibration JSON from M5StickC (WiFi) and writes to CSV.
Firestore sync runs as a background thread (see firestore_sync.py).
"""
import csv
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, request

REQUIRED_FIELDS = [
    "device_id", "timestamp", "rms", "ppv", "freq", "crest",
    "centroid", "kurtosis", "stalta", "arias", "cav", "label"
]

CSV_HEADER = REQUIRED_FIELDS


def create_app():
    app = Flask(__name__)
    data_dir = Path(os.environ.get("DATA_DIR", "/workspace/data"))
    field_dir = data_dir / "field"
    field_dir.mkdir(parents=True, exist_ok=True)

    count_file = field_dir / ".sample_count"

    def _read_count():
        try:
            return int(count_file.read_text().strip())
        except Exception:
            return 0

    def _write_count(n):
        count_file.write_text(str(n))

    @app.route("/health")
    def health():
        return jsonify({"status": "ok", "samples": _read_count()})

    @app.route("/ingest", methods=["POST"])
    def ingest():
        data = request.get_json(silent=True) or {}
        missing = [f for f in REQUIRED_FIELDS if f not in data]
        if missing:
            return jsonify({"error": f"missing fields: {missing}"}), 400

        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        csv_path = field_dir / f"{date_str}.csv"
        write_header = not csv_path.exists()

        with open(csv_path, "a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_HEADER)
            if write_header:
                writer.writeheader()
            writer.writerow({k: data[k] for k in CSV_HEADER})

        _write_count(_read_count() + 1)
        return jsonify({"status": "ok"})

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8765)))
```

**Step 4: Run tests to verify they pass**

```bash
python -m pytest test_app.py -v
```
Expected: 4 tests pass.

**Step 5: Create requirements.txt**

Create `docker/collect/requirements.txt`:
```
flask==3.0.3
google-cloud-firestore==2.16.0
```

**Step 6: Create Dockerfile**

Create `docker/collect/Dockerfile`:
```dockerfile
FROM python:3.11-slim

WORKDIR /workspace

COPY docker/collect/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY docker/collect/app.py ./app.py

EXPOSE 8765

CMD ["python", "app.py"]
```

**Step 7: Commit**

```bash
git add docker/collect/
git commit -m "feat: add data collector Flask API with CSV + sample count tracking"
```

---

### Task 3: Firestore sync background thread

Add a background thread to `app.py` that polls Firestore every 5 minutes for new
phone-uploaded samples and deduplicates them by `timestamp+device_id`.

**Files:**
- Modify: `docker/collect/app.py`
- Modify: `docker/collect/test_app.py`

**Step 1: Write the failing dedup test**

Add to `docker/collect/test_app.py`:
```python
def test_dedup_same_timestamp(client):
    """Ingesting the same timestamp+device_id twice must not create duplicate rows."""
    c, data_dir = client
    payload = {
        "device_id": "m5stick-01", "timestamp": "2026-03-03T10:00:00Z",
        "rms": 0.01, "ppv": 0.05, "freq": 15.0, "crest": 3.0,
        "centroid": 20.0, "kurtosis": 1.5, "stalta": 1.0,
        "arias": 0.0001, "cav": 0.002, "label": "normal"
    }
    c.post("/ingest", json=payload)
    r = c.post("/ingest", json=payload)
    assert r.status_code == 200
    assert r.get_json()["status"] == "duplicate"
    csvs = list(data_dir.glob("field/*.csv"))
    with open(csvs[0]) as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 1  # only one row despite two POSTs
```

**Step 2: Run to verify it fails**

```bash
python -m pytest test_app.py::test_dedup_same_timestamp -v
```
Expected: FAIL — second POST returns `{"status": "ok"}` not `"duplicate"`.

**Step 3: Add dedup to app.py**

In `create_app()`, add a seen-keys set and update `/ingest`:
```python
    seen_keys: set = set()  # in-memory dedup (timestamp+device_id)

    @app.route("/ingest", methods=["POST"])
    def ingest():
        data = request.get_json(silent=True) or {}
        missing = [f for f in REQUIRED_FIELDS if f not in data]
        if missing:
            return jsonify({"error": f"missing fields: {missing}"}), 400

        key = f"{data['device_id']}|{data['timestamp']}"
        if key in seen_keys:
            return jsonify({"status": "duplicate"})
        seen_keys.add(key)

        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        csv_path = field_dir / f"{date_str}.csv"
        write_header = not csv_path.exists()
        with open(csv_path, "a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_HEADER)
            if write_header:
                writer.writeheader()
            writer.writerow({k: data[k] for k in CSV_HEADER})

        _write_count(_read_count() + 1)
        return jsonify({"status": "ok"})
```

**Step 4: Add Firestore sync function (no-op when credentials absent)**

Add at the bottom of `app.py`, before `if __name__ == "__main__"`:
```python
def _start_firestore_sync(app, field_dir, seen_keys):
    """
    Background thread: polls Firestore for new vibration samples every 5 min.
    Silently skips if GOOGLE_APPLICATION_CREDENTIALS is not set.
    """
    import threading, time

    creds = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not creds:
        app.logger.info("Firestore sync disabled (no credentials)")
        return

    def _sync_loop():
        from google.cloud import firestore
        db = firestore.Client()
        while True:
            try:
                docs = db.collection("vibration_samples").stream()
                for doc in docs:
                    data = doc.to_dict()
                    data.setdefault("label", "unknown")
                    missing = [f for f in REQUIRED_FIELDS if f not in data]
                    if missing:
                        continue
                    key = f"{data['device_id']}|{data['timestamp']}"
                    if key in seen_keys:
                        continue
                    # Reuse ingest logic via internal call
                    with app.test_request_context(
                        "/ingest", method="POST",
                        json={k: data[k] for k in REQUIRED_FIELDS}
                    ):
                        ingest()
            except Exception as e:
                app.logger.warning(f"Firestore sync error: {e}")
            time.sleep(300)

    t = threading.Thread(target=_sync_loop, daemon=True)
    t.start()
```

Call it after `field_dir.mkdir(...)`:
```python
    import threading as _threading
    # Start Firestore sync after app is fully created
    @app.before_request
    def _lazy_start_sync():
        if not hasattr(app, "_sync_started"):
            app._sync_started = True
            _start_firestore_sync(app, field_dir, seen_keys)
```

**Step 5: Run all tests**

```bash
python -m pytest test_app.py -v
```
Expected: 5 tests pass.

**Step 6: Commit**

```bash
git add docker/collect/app.py docker/collect/test_app.py
git commit -m "feat: add dedup by timestamp+device_id and Firestore sync thread"
```

---

### Task 4: docker-compose.collect.yml

Wire the collector service into a compose file.

**Files:**
- Create: `docker-compose.collect.yml`

**Step 1: Create the file**

```yaml
# docker-compose.collect.yml
# Run on field laptop to collect vibration data.
# Usage: docker compose -f docker-compose.collect.yml up
#
# Optional: set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON
# for Firestore sync.  If not set, only WiFi ingestion works.

services:

  data-collector:
    build:
      context: .
      dockerfile: docker/collect/Dockerfile
    ports:
      - "8765:8765"
    volumes:
      - ./data:/workspace/data
    environment:
      - DATA_DIR=/workspace/data
      - GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS:-}
    secrets:
      - source: gcp_credentials
        target: /secrets/gcp_credentials.json
    restart: unless-stopped

secrets:
  gcp_credentials:
    file: ${GOOGLE_APPLICATION_CREDENTIALS:-/dev/null}
```

**Step 2: Build and verify**

```bash
docker compose -f docker-compose.collect.yml build
docker compose -f docker-compose.collect.yml up -d
curl http://localhost:8765/health
```
Expected: `{"samples": 0, "status": "ok"}`

**Step 3: Test ingest end-to-end**

```bash
curl -X POST http://localhost:8765/ingest \
  -H "Content-Type: application/json" \
  -d '{"device_id":"test","timestamp":"2026-03-03T12:00:00Z","rms":0.01,"ppv":0.05,"freq":15.0,"crest":3.0,"centroid":20.0,"kurtosis":1.5,"stalta":1.0,"arias":0.0001,"cav":0.002,"label":"normal"}'
```
Expected: `{"status": "ok"}`

```bash
cat data/field/*.csv
```
Expected: CSV row with the posted values.

**Step 4: Stop and commit**

```bash
docker compose -f docker-compose.collect.yml down
git add docker-compose.collect.yml
git commit -m "feat: add docker-compose.collect.yml for field data collection"
```

---

### Task 5: File watcher + trainer pipeline

Create the two services that watch for accumulated samples and trigger retraining.

**Files:**
- Create: `docker/watcher/Dockerfile`
- Create: `docker/watcher/watch.py`
- Create: `docker/watcher/test_watch.py`
- Create: `scripts/run_pipeline.py`
- Create: `docker-compose.train.yml`

**Step 1: Write the failing watcher test**

Create `docker/watcher/test_watch.py`:
```python
import os
import tempfile
from pathlib import Path
from watch import should_trigger, reset_baseline, TRIGGER_THRESHOLD


def test_no_trigger_below_threshold(tmp_path):
    count_file = tmp_path / "field" / ".sample_count"
    count_file.parent.mkdir()
    count_file.write_text("50")
    baseline_file = tmp_path / ".baseline_count"
    baseline_file.write_text("0")
    assert should_trigger(tmp_path) is False


def test_triggers_at_threshold(tmp_path):
    count_file = tmp_path / "field" / ".sample_count"
    count_file.parent.mkdir()
    count_file.write_text("100")
    baseline_file = tmp_path / ".baseline_count"
    baseline_file.write_text("0")
    assert should_trigger(tmp_path) is True


def test_no_trigger_when_already_triggered(tmp_path):
    count_file = tmp_path / "field" / ".sample_count"
    count_file.parent.mkdir()
    count_file.write_text("200")
    baseline_file = tmp_path / ".baseline_count"
    baseline_file.write_text("150")  # baseline updated after last trigger
    assert should_trigger(tmp_path) is False  # only 50 new, below threshold


def test_reset_baseline(tmp_path):
    count_file = tmp_path / "field" / ".sample_count"
    count_file.parent.mkdir()
    count_file.write_text("250")
    reset_baseline(tmp_path)
    baseline = int((tmp_path / ".baseline_count").read_text())
    assert baseline == 250
```

**Step 2: Run to verify they fail**

```bash
cd docker/watcher
pip install pytest
python -m pytest test_watch.py -v
```
Expected: `ModuleNotFoundError: No module named 'watch'`

**Step 3: Implement watch.py**

Create `docker/watcher/watch.py`:
```python
"""
File watcher: polls .sample_count every 60 seconds.
Writes .retrain_trigger when new samples since last training >= TRIGGER_THRESHOLD.
"""
import os
import time
from pathlib import Path

TRIGGER_THRESHOLD = int(os.environ.get("TRIGGER_THRESHOLD", "100"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))


def _read_int(path: Path, default: int = 0) -> int:
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def should_trigger(data_dir: Path) -> bool:
    total = _read_int(data_dir / "field" / ".sample_count")
    baseline = _read_int(data_dir / ".baseline_count")
    return (total - baseline) >= TRIGGER_THRESHOLD


def reset_baseline(data_dir: Path):
    total = _read_int(data_dir / "field" / ".sample_count")
    (data_dir / ".baseline_count").write_text(str(total))


def main():
    data_dir = Path(os.environ.get("DATA_DIR", "/workspace/data"))
    trigger_file = data_dir / ".retrain_trigger"

    print(f"Watching {data_dir} — trigger at {TRIGGER_THRESHOLD} new samples")
    while True:
        if not trigger_file.exists() and should_trigger(data_dir):
            print("Threshold reached — writing .retrain_trigger")
            trigger_file.touch()
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
```

**Step 4: Run tests to verify they pass**

```bash
python -m pytest test_watch.py -v
```
Expected: 4 tests pass.

**Step 5: Create watcher Dockerfile**

Create `docker/watcher/Dockerfile`:
```dockerfile
FROM python:3.11-slim
WORKDIR /workspace
COPY docker/watcher/watch.py ./watch.py
CMD ["python", "watch.py"]
```

**Step 6: Implement run_pipeline.py**

Create `scripts/run_pipeline.py`:
```python
"""
Training pipeline entrypoint.
Triggered when /workspace/data/.retrain_trigger exists.
Runs: train → export → copy to app/assets/ml → flutter build apk → archive data.
"""
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DATA_DIR = Path(os.environ.get("DATA_DIR", "/workspace/data"))
TRIGGER_FILE = DATA_DIR / ".retrain_trigger"
ASSETS_DIR = Path("/workspace/app/assets/ml")
REPO = Path("/workspace")


def run(cmd, **kwargs):
    print(f"+ {' '.join(cmd)}")
    result = subprocess.run(cmd, **kwargs)
    if result.returncode != 0:
        print(f"FAILED: {cmd}")
        sys.exit(result.returncode)


def main():
    if not TRIGGER_FILE.exists():
        print("No .retrain_trigger found — nothing to do.")
        return

    print("=== Retrain triggered ===")

    # 1. Train autoencoder
    run(["python", "scripts/train_autoencoder.py"])

    # 2. Train precursor classifier
    run(["python", "scripts/generate_precursor_data.py"])

    # 3. Verify outputs exist
    for fname in ["vibration_anomaly.tflite", "vibration_scaler.json", "vibration_model_config.json"]:
        p = ASSETS_DIR / fname
        if not p.exists():
            print(f"ERROR: expected output missing: {p}")
            sys.exit(1)
        print(f"  {p} ({p.stat().st_size} bytes)")

    # 4. Build APK (docker-in-docker via host socket, or skip if not available)
    docker_sock = Path("/var/run/docker.sock")
    if docker_sock.exists():
        run(["docker", "compose", "run", "--rm", "flutter"])
    else:
        print("Docker socket not available — skipping APK build.")

    # 5. Archive processed data
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
    archive_dir = DATA_DIR / "processed" / ts
    archive_dir.mkdir(parents=True, exist_ok=True)
    field_dir = DATA_DIR / "field"
    for csv_file in field_dir.glob("*.csv"):
        shutil.move(str(csv_file), archive_dir / csv_file.name)
    print(f"Archived data to {archive_dir}")

    # 6. Reset trigger and baseline
    TRIGGER_FILE.unlink(missing_ok=True)
    baseline_file = DATA_DIR / ".baseline_count"
    count_file = field_dir / ".sample_count"
    try:
        count = int(count_file.read_text().strip())
        baseline_file.write_text(str(count))
    except Exception:
        baseline_file.write_text("0")

    print("=== Pipeline complete ===")


if __name__ == "__main__":
    main()
```

**Step 7: Create docker-compose.train.yml**

```yaml
# docker-compose.train.yml
# Run on laptop alongside docker-compose.collect.yml.
# Usage: docker compose -f docker-compose.train.yml up
#
# Requires ./data/ volume populated by data-collector.
# Trainer uses Docker-in-Docker to trigger flutter build; mount host socket.

services:

  file-watcher:
    build:
      context: .
      dockerfile: docker/watcher/Dockerfile
    volumes:
      - ./data:/workspace/data
    environment:
      - DATA_DIR=/workspace/data
      - TRIGGER_THRESHOLD=100
      - POLL_INTERVAL=60
    restart: unless-stopped

  trainer:
    build:
      context: .
      dockerfile: docker/ml/Dockerfile
    volumes:
      - ./data:/workspace/data
      - ./app/assets/ml:/workspace/app/assets/ml
      - ./app/build:/workspace/app/build
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - DATA_DIR=/workspace/data
    entrypoint: ["python", "scripts/run_pipeline.py"]
    restart: "no"
```

**Step 8: Build and smoke test the watcher**

```bash
mkdir -p data/field
echo "0" > data/field/.sample_count
docker compose -f docker-compose.train.yml build
docker compose -f docker-compose.train.yml run --rm file-watcher python -c "
from watch import should_trigger; from pathlib import Path
import os; os.environ['DATA_DIR']='/workspace/data'
# Can't test volume here, just verify import works
print('watcher import OK')
"
```
Expected: `watcher import OK`

**Step 9: Commit**

```bash
git add docker/watcher/ scripts/run_pipeline.py docker-compose.train.yml
git commit -m "feat: add file-watcher, trainer pipeline, docker-compose.train.yml"
```

---

### Task 6: GitHub Actions — build.yml

Auto-build firmware + APK on every push to master.

**Files:**
- Create: `.github/workflows/build.yml`

**Step 1: Create the workflow**

Create `.github/workflows/build.yml`:
```yaml
name: Build

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Cache Docker layers
        uses: actions/cache@v4
        with:
          path: /tmp/.buildx-cache
          key: ${{ runner.os }}-buildx-${{ github.sha }}
          restore-keys: |
            ${{ runner.os }}-buildx-

      - name: Build images
        run: docker compose build

      - name: Build firmware
        run: |
          docker compose run --rm firmware
          ls -lh .pio/build/m5stick-c-plus2/firmware.bin

      - name: Decode google-services.json
        env:
          GOOGLE_SERVICES_JSON: ${{ secrets.GOOGLE_SERVICES_JSON }}
        run: |
          echo "$GOOGLE_SERVICES_JSON" | base64 -d > app/android/app/google-services.json

      - name: Build APK
        run: |
          docker compose run --rm flutter
          ls -lh app/build/app/outputs/flutter-apk/app-release.apk

      - name: Upload firmware artifact
        uses: actions/upload-artifact@v4
        with:
          name: firmware-${{ github.sha }}
          path: .pio/build/m5stick-c-plus2/firmware.bin
          retention-days: 30

      - name: Upload APK artifact
        uses: actions/upload-artifact@v4
        with:
          name: apk-${{ github.sha }}
          path: app/build/app/outputs/flutter-apk/app-release.apk
          retention-days: 30
```

**Step 2: Commit**

```bash
mkdir -p .github/workflows
git add .github/workflows/build.yml
git commit -m "ci: add build workflow — firmware + APK on every push to master"
```

---

### Task 7: GitHub Actions — release.yml

On version tags, create a GitHub Release and push APK to Firebase App Distribution.

**Files:**
- Create: `.github/workflows/release.yml`

**Step 1: Create the workflow**

Create `.github/workflows/release.yml`:
```yaml
name: Release

on:
  push:
    tags:
      - "v*.*.*"

jobs:
  release:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Cache Docker layers
        uses: actions/cache@v4
        with:
          path: /tmp/.buildx-cache
          key: ${{ runner.os }}-buildx-${{ github.sha }}
          restore-keys: |
            ${{ runner.os }}-buildx-

      - name: Build images
        run: docker compose build

      - name: Build firmware
        run: docker compose run --rm firmware

      - name: Decode google-services.json
        env:
          GOOGLE_SERVICES_JSON: ${{ secrets.GOOGLE_SERVICES_JSON }}
        run: echo "$GOOGLE_SERVICES_JSON" | base64 -d > app/android/app/google-services.json

      - name: Build APK
        run: docker compose run --rm flutter

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            .pio/build/m5stick-c-plus2/firmware.bin
            app/build/app/outputs/flutter-apk/app-release.apk
          generate_release_notes: true

      - name: Upload APK to Firebase App Distribution
        uses: wzieba/Firebase-Distribution-Github-Action@v1
        with:
          appId: ${{ secrets.FIREBASE_APP_ID }}
          token: ${{ secrets.FIREBASE_TOKEN }}
          groups: testers
          file: app/build/app/outputs/flutter-apk/app-release.apk
          releaseNotes: "Release ${{ github.ref_name }}"
```

**Step 2: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow — GitHub Release + Firebase App Distribution on tags"
```

---

### Task 8: Document required secrets and test CI

Set up the GitHub secrets and verify the build workflow runs green.

**Files:**
- Modify: `docs/plans/2026-03-03-docker-expansion-design.md` (add secrets setup section)

**Step 1: Get Firebase token**

On your local machine (not in Docker):
```bash
npm install -g firebase-tools
firebase login:ci
```
Copy the printed token — this is `FIREBASE_TOKEN`.

**Step 2: Get FIREBASE_APP_ID**

In Firebase console → Project Settings → Your Apps → Android app → App ID.
Format: `1:123456789:android:abcdef123456`

**Step 3: Encode google-services.json**

```bash
base64 -w 0 app/android/app/google-services.json
```
Copy the output — this is `GOOGLE_SERVICES_JSON`.

**Step 4: Add secrets to GitHub**

Go to: `github.com/<your-repo>/settings/secrets/actions/new`

Add three secrets:
- `FIREBASE_APP_ID`
- `FIREBASE_TOKEN`
- `GOOGLE_SERVICES_JSON`

**Step 5: Push to master and verify**

```bash
git push origin docker-experiment:master
```
Go to GitHub → Actions → Build workflow → verify green.

**Step 6: Tag a release and verify**

```bash
git tag v0.1.0
git push origin v0.1.0
```
Expected: GitHub Release created with `firmware.bin` + `app-release.apk` attached,
APK appears in Firebase App Distribution for the `testers` group.
