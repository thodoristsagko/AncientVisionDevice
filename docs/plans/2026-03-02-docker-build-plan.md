# Docker Build System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Containerize all three build targets (firmware, Flutter APK, ML training) so the entire project builds with Docker, no local toolchain needed.

**Architecture:** Three separate Dockerfiles under `docker/`, one per build target, orchestrated by a single `docker-compose.yml` at the repo root. The Flutter app is copied into `app/` inside this repo so everything is self-contained on the `docker-experiment` branch.

**Tech Stack:** Docker, docker-compose, PlatformIO Core (ESP32 firmware), Flutter stable + Android SDK (APK), Python 3.11 + TensorFlow CPU + scikit-learn (ML training)

---

### Task 1: Copy Flutter app into repo

**Files:**
- Create: `app/` (copy of Flutter app)

**Step 1: Copy the Flutter app**

Run from repo root (worktree):
```bash
cp -r "/c/Users/thodo/Desktop/FLL_Thodoris/AncientVisionFLL/AncientVision/." app/
```

**Step 2: Verify key files exist**

```bash
ls app/pubspec.yaml app/lib app/android
```
Expected: all three paths exist without error.

**Step 3: Remove build artifacts from the copy**

```bash
rm -rf app/build app/.dart_tool app/.flutter-plugins app/.flutter-plugins-dependencies app/nul
```

**Step 4: Commit**

```bash
git add app/
git commit -m "feat: copy Flutter app into repo for Docker build"
```

---

### Task 2: Create `.dockerignore`

**Files:**
- Create: `.dockerignore`

**Step 1: Write `.dockerignore`**

```
.git
.pio
app/build
app/.dart_tool
app/.flutter-plugins
app/.flutter-plugins-dependencies
*.log
*.bak
*.backup
```

**Step 2: Verify it exists**

```bash
cat .dockerignore
```

**Step 3: Commit**

```bash
git add .dockerignore
git commit -m "chore: add .dockerignore"
```

---

### Task 3: Firmware Dockerfile

**Files:**
- Create: `docker/firmware/Dockerfile`

**Step 1: Create directory**

```bash
mkdir -p docker/firmware
```

**Step 2: Write `docker/firmware/Dockerfile`**

```dockerfile
FROM ghcr.io/platformio/platformio-core:latest

WORKDIR /workspace

# Copy firmware project files only (not app/ or docs/)
COPY platformio.ini ./
COPY src/ ./src/
COPY lib/ ./lib/
COPY include/ ./include/

# Pre-install platform + board packages so builds are fast
RUN pio pkg install

# Default command: build firmware
CMD ["pio", "run"]
```

**Step 3: Verify the file**

```bash
cat docker/firmware/Dockerfile
```

**Step 4: Build the firmware image (smoke test)**

```bash
docker build -f docker/firmware/Dockerfile -t ancientvision-firmware .
```
Expected: image builds successfully. PlatformIO downloads ESP32 toolchain on first run (~2 min).

**Step 5: Run a firmware build**

```bash
docker run --rm -v "$(pwd)/.pio:/workspace/.pio" ancientvision-firmware
```
Expected: `.pio/build/m5stick-c-plus2/firmware.bin` appears on your host.

**Step 6: Commit**

```bash
git add docker/firmware/Dockerfile
git commit -m "feat: add firmware Docker build"
```

---

### Task 4: Flutter Dockerfile

**Files:**
- Create: `docker/flutter/Dockerfile`

**Step 1: Create directory**

```bash
mkdir -p docker/flutter
```

**Step 2: Write `docker/flutter/Dockerfile`**

```dockerfile
FROM ghcr.io/cirruslabs/flutter:stable

WORKDIR /app

# Accept Android SDK licenses non-interactively
RUN yes | sdkmanager --licenses || true

# Copy Flutter app
COPY app/ .

# Fetch dependencies
RUN flutter pub get

# Default command: build release APK
CMD ["flutter", "build", "apk", "--release"]
```

**Step 3: Verify the file**

```bash
cat docker/flutter/Dockerfile
```

**Step 4: Build the Flutter image (smoke test)**

```bash
docker build -f docker/flutter/Dockerfile -t ancientvision-flutter .
```
Expected: image builds successfully. Flutter downloads pub packages during build (~3-5 min first time).

**Step 5: Run a Flutter APK build**

```bash
docker run --rm -v "$(pwd)/app/build:/app/build" ancientvision-flutter
```
Expected: `app/build/app/outputs/flutter-apk/app-release.apk` appears on your host.

**Step 6: Commit**

```bash
git add docker/flutter/Dockerfile
git commit -m "feat: add Flutter APK Docker build"
```

---

### Task 5: ML Training Dockerfile

**Files:**
- Create: `docker/ml/Dockerfile`

**Step 1: Create directory**

```bash
mkdir -p docker/ml
```

**Step 2: Write `docker/ml/Dockerfile`**

```dockerfile
FROM python:3.11-slim

WORKDIR /workspace

# Install Python dependencies
RUN pip install --no-cache-dir \
    numpy \
    scikit-learn \
    tensorflow-cpu \
    flatbuffers

# Copy scripts and output dir
COPY scripts/ ./scripts/
COPY assets/ml/ ./assets/ml/

# Default command: run both training scripts
CMD ["bash", "-c", "python scripts/train_autoencoder.py && python scripts/generate_precursor_data.py"]
```

**Step 3: Verify the file**

```bash
cat docker/ml/Dockerfile
```

**Step 4: Build the ML image (smoke test)**

```bash
docker build -f docker/ml/Dockerfile -t ancientvision-ml .
```
Expected: image builds and pip installs all packages successfully (~1-2 min).

**Step 5: Run ML training**

```bash
docker run --rm \
  -v "$(pwd)/assets/ml:/workspace/assets/ml" \
  ancientvision-ml
```
Expected: `assets/ml/` updated with fresh `.tflite` models and `.json` scalers.

**Step 6: Commit**

```bash
git add docker/ml/Dockerfile
git commit -m "feat: add ML training Docker build"
```

---

### Task 6: docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

**Step 1: Write `docker-compose.yml`**

```yaml
services:

  firmware:
    build:
      context: .
      dockerfile: docker/firmware/Dockerfile
    volumes:
      - ./.pio:/workspace/.pio
    # Output: .pio/build/m5stick-c-plus2/firmware.bin

  flutter:
    build:
      context: .
      dockerfile: docker/flutter/Dockerfile
    volumes:
      - ./app/build:/app/build
    # Output: app/build/app/outputs/flutter-apk/app-release.apk

  ml:
    build:
      context: .
      dockerfile: docker/ml/Dockerfile
    volumes:
      - ./assets/ml:/workspace/assets/ml
    # Output: assets/ml/*.tflite + *.json
```

**Step 2: Verify each service builds via compose**

```bash
docker compose build
```
Expected: all three images build without error.

**Step 3: Run each service once to verify end-to-end**

```bash
docker compose run --rm firmware
docker compose run --rm ml
docker compose run --rm flutter
```
Expected: `firmware.bin`, updated `assets/ml/`, and `app-release.apk` all produced.

**Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose orchestration for all build targets"
```

---

### Task 7: Add README section for Docker builds

**Files:**
- Modify: `README.md` (or create if absent) — add Docker usage section

**Step 1: Add Docker section to README**

Append to the top of README.md (or create it):

```markdown
## Docker Builds (docker-experiment branch)

Build everything without installing any local toolchain.

### Prerequisites
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running

### Build firmware (.bin)
```bash
docker compose run --rm firmware
# Output: .pio/build/m5stick-c-plus2/firmware.bin
```

### Build Flutter APK
```bash
docker compose run --rm flutter
# Output: app/build/app/outputs/flutter-apk/app-release.apk
```

### Train ML models
```bash
docker compose run --rm ml
# Output: assets/ml/*.tflite + *.json
```

### Build everything
```bash
docker compose run --rm firmware && docker compose run --rm ml && docker compose run --rm flutter
```
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add Docker build instructions to README"
```

---

### Task 8: Push docker-experiment branch

**Step 1: Push branch to remote**

```bash
git push -u origin docker-experiment
```

**Step 2: Verify on GitHub/remote**

Check that `docker-experiment` branch appears and `master` is untouched.
