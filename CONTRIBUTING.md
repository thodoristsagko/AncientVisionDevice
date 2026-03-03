# Contributing to AncientVision

AncientVision is a life-safety system for detecting soil avalanche precursors at
archaeological excavation sites. Every change you make may affect archaeologists in
the field. Read this guide carefully before contributing.

---

## Table of Contents

1. [Development Setup](#development-setup)
2. [Branching Strategy](#branching-strategy)
3. [Running Tests](#running-tests)
4. [Adding a New Feature](#adding-a-new-feature)
5. [Code Style Guidelines](#code-style-guidelines)
6. [How to Add a New Data Collector Endpoint](#how-to-add-a-new-data-collector-endpoint)
7. [How to Retrain the ML Model](#how-to-retrain-the-ml-model)
8. [Pull Request Checklist](#pull-request-checklist)

---

## Development Setup

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | 24+ | https://docs.docker.com/get-docker/ |
| Flutter SDK | 3.22+ | https://docs.flutter.dev/get-started/install |
| PlatformIO Core | latest | `pip install platformio` |
| Python | 3.11+ | https://python.org |
| Git | 2.40+ | https://git-scm.com |

### First-time Setup

```bash
# 1. Clone the repository
git clone <repo-url>
cd AncientVisionDevice

# 2. Copy environment template
cp .env.example .env
# Edit .env — set GOOGLE_APPLICATION_CREDENTIALS if you have Firebase access

# 3. Install Python test dependencies
pip install pytest flask requests

# 4. Verify Docker is running
docker info

# 5. Build all services
make build

# 6. Run all tests to confirm a clean baseline
make test
```

### Flutter App Setup

```bash
cd app
flutter pub get
flutter analyze      # Must show "No issues found!"
flutter test
```

### Firmware Setup

```bash
# Build firmware in Docker (no local toolchain needed)
make firmware

# Or build locally with PlatformIO
python -m platformio run -d .
```

---

## Branching Strategy

| Branch | Purpose |
|--------|---------|
| `master` | Stable, field-tested code. Merges only via PR with passing tests. |
| `feature/<ticket>-short-description` | All new features and bugfixes. Branched from `master`. |
| `docker-experiment` | Docker infrastructure work. Long-running branch for containerisation experiments. |

### Rules

- Never push directly to `master`.
- Feature branches must be up to date with `master` before merging.
- Branch names must include the ticket number where one exists, e.g.
  `feature/P150-add-webhook-alerts`.
- Delete branches after merging.

### Typical Workflow

```bash
git checkout master
git pull
git checkout -b feature/P999-my-feature
# ... make changes ...
make test
git push -u origin feature/P999-my-feature
# Open PR on GitHub
```

---

## Running Tests

```bash
# Run the full suite
make test

# Run only the data-collector tests
python -m pytest docker/collect/test_app.py -v

# Run only the watcher tests
python -m pytest docker/watcher/test_watch.py -v

# Run only the script tests
python -m pytest scripts/test_run_pipeline.py scripts/test_simulate.py -v

# Run Flutter tests
cd app && flutter test
```

The `make test` target runs all pytest suites in one command:

```
docker/collect/test_app.py
docker/watcher/test_watch.py
scripts/test_run_pipeline.py
scripts/test_simulate.py
scripts/test_integration.py
scripts/test_field_report.py
scripts/test_reset_pipeline.py
scripts/test_evaluate_models.py
scripts/test_visualize.py
scripts/test_training_quality.py
```

A passing test run looks like:

```
============= N passed in X.XXs =============
```

Any failure blocks merging to `master`.

---

## Adding a New Feature

Follow test-driven development (TDD):

1. **Write a failing test first.** Add it to the relevant test file or create a new
   `test_<module>.py` in `scripts/` or `docker/<service>/`.

2. **Run the test to confirm it fails:**
   ```bash
   python -m pytest path/to/test_new_feature.py -v
   ```

3. **Implement the feature** in the smallest possible change.

4. **Run all tests to confirm nothing is broken:**
   ```bash
   make test
   ```

5. **Run static analysis:**
   ```bash
   # Dart / Flutter
   cd app && flutter analyze

   # Python
   python -m flake8 docker/ scripts/ --max-line-length=100

   # C++ (firmware)
   # Review against Arduino style guide — no automated linter enforced
   ```

6. **Update documentation** (API reference, firmware protocol, ML architecture as
   appropriate — see `docs/`).

7. **Open a PR** and fill in the checklist (see below).

---

## Code Style Guidelines

### Dart / Flutter

- Follow the official [Dart style guide](https://dart.dev/guides/language/effective-dart/style).
- Run `flutter analyze` before every commit. The project must show `No issues found!`.
- Use `const` constructors wherever possible.
- Avoid `dynamic` — use typed alternatives.
- Dispose all controllers, streams, and services in `dispose()`.
- Use `mounted` guards before any `setState` after `await`.

### Python

- Follow [PEP 8](https://peps.python.org/pep-0008/).
- Max line length: 100 characters.
- Use type hints for all function signatures.
- Use `pathlib.Path` instead of raw string paths.
- Never use `print()` in production code — use `logging` or the `jlog()` helper in
  `docker/collect/app.py`.
- Avoid mutable default arguments.

### C++ (Firmware)

- Follow the [Arduino style guide](https://docs.arduino.cc/learn/contributions/arduino-library-style-guide/).
- All `#define` constants go in the `// CONFIGURATION` section at the top.
- Global variables are prefixed with `g_` (e.g., `g_bootCount`).
- Struct members use camelCase.
- Every function has a single-line comment describing its purpose.
- Never use `delay()` in the main loop — use non-blocking timing with `millis()`.
- Enable watchdog (`esp_task_wdt_init`) for any blocking operation.

---

## How to Add a New Data Collector Endpoint

The data collector is a Flask application in `docker/collect/app.py`.

### Step-by-step

1. **Write a test first** in `docker/collect/test_app.py`:
   ```python
   def test_my_endpoint(client):
       resp = client.get("/my-endpoint")
       assert resp.status_code == 200
       data = resp.get_json()
       assert "expected_key" in data
   ```

2. **Add the route** inside the `create_app()` function in `docker/collect/app.py`:
   ```python
   @app.route("/my-endpoint")
   def my_endpoint():
       return jsonify({"expected_key": "value"})
   ```

3. **Add input validation** for any POST endpoints:
   - Check required fields.
   - Validate numeric ranges using `FIELD_RANGES`.
   - Return `400` with a descriptive `{"error": "..."}` body on bad input.

4. **Add rate-limiting** if the endpoint writes data (follow the pattern in `/ingest`).

5. **Document the endpoint** in `docs/api-reference.md`:
   - Method, path, description.
   - Request/response JSON example.

6. **Run the tests:**
   ```bash
   python -m pytest docker/collect/test_app.py -v
   ```

7. **Rebuild the Docker image** and verify the endpoint is reachable:
   ```bash
   make collect
   curl http://localhost:8765/my-endpoint
   ```

---

## How to Retrain the ML Model

There are two models: an autoencoder (anomaly detection) and a precursor classifier.

### Quick Retrain via Docker

```bash
# Start the watcher and trainer stack
make train

# Or trigger training manually
docker compose -f docker-compose.train.yml run --rm trainer
```

The watcher (`docker/watcher/watch.py`) polls `data/field/.sample_count` every 60
seconds and writes `data/.retrain_trigger` when 100 new samples have arrived since
the last training run.

### Manual Retrain (Development)

```bash
# 1. Make sure you have field data in data/field/*.csv

# 2. Train the autoencoder
python scripts/train_autoencoder.py

# 3. Train the precursor classifier
python scripts/generate_precursor_data.py

# 4. Evaluate the new models
python scripts/evaluate_models.py

# 5. Run quality checks
python scripts/test_training_quality.py
```

### Deploying Updated Models

After training, TFLite models are exported to `app/assets/ml/`:
- `autoencoder.tflite` — anomaly detection
- `precursor_classifier.tflite` — 4-class soil hazard classifier
- `autoencoder_scaler.json` — StandardScaler parameters
- `precursor_scaler.json` — StandardScaler parameters

To deploy:
```bash
# Rebuild the Flutter APK with updated models
make flutter

# Install on device
adb install app/build/app/outputs/flutter-apk/app-release.apk
```

### Rollback

If new model performance is worse than the baseline (checked by `evaluate_models.py`),
the pipeline will keep the previous model. The evaluation script exits with code 1 if
the new model's accuracy is lower than the stored baseline, preventing automatic
deployment.

---

## Pull Request Checklist

Before opening a PR, confirm all of the following:

- [ ] `make test` passes — all pytest suites green.
- [ ] `cd app && flutter analyze` shows `No issues found!`.
- [ ] New endpoints are documented in `docs/api-reference.md`.
- [ ] Protocol changes are documented in `docs/firmware-protocol.md`.
- [ ] ML changes are documented in `docs/ml-architecture.md`.
- [ ] No secrets (API keys, credentials) committed — use `.env` and `.gitignore`.
- [ ] No new `TODO`/`FIXME` left in production code without a tracking ticket.
- [ ] Dispose methods added for any new Flutter services.
- [ ] `mounted` guard added before any `setState` after `await`.
- [ ] New firmware features do not exceed 97.5% flash or 17% RAM.
- [ ] Branch is up to date with `master` (`git rebase master`).

Safety-critical changes (thresholds, DSP constants, BLE protocol) require review by
at least two contributors before merge.
