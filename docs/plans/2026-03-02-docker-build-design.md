# Docker Build System Design

**Date**: 2026-03-02
**Branch**: docker-experiment
**Status**: Approved

## Goal

Containerize all three build targets — firmware, Flutter app, and ML training — so that:
- Anyone can build without installing PlatformIO, Flutter SDK, or Python locally
- Builds are reproducible across machines
- The setup is CI/CD-ready (GitHub Actions or similar)

## Approach

One Dockerfile per build target, orchestrated by a single `docker-compose.yml`. Separate images keep each target lean and independently cacheable.

## Repository Layout

```
AncientVisionDevice/          ← firmware repo (docker-experiment branch)
├── src/                      ← firmware source
├── scripts/                  ← ML training scripts
├── assets/ml/                ← TFLite models
├── app/                      ← Flutter app (full copy from Desktop)
│   ├── lib/
│   ├── android/
│   ├── pubspec.yaml
│   └── ...
├── docker/
│   ├── firmware/
│   │   └── Dockerfile
│   ├── flutter/
│   │   └── Dockerfile
│   └── ml/
│       └── Dockerfile
├── docker-compose.yml
└── .dockerignore
```

## Dockerfiles

### firmware
- Base: `ghcr.io/platformio/platformio-core:latest`
- Copies `src/`, `lib/`, `include/`, `platformio.ini`
- Runs `pio run`
- Output: `.pio/build/m5stick-c-plus2/firmware.bin`

### flutter
- Base: `ghcr.io/cirruslabs/flutter:stable` (includes Android SDK + Java)
- Working directory: `/app` (mounted from `./app`)
- Runs `flutter pub get && flutter build apk --release`
- Output: `app/build/app/outputs/flutter-apk/app-release.apk`

### ml
- Base: `python:3.11-slim`
- Installs numpy, scikit-learn, tensorflow (CPU), flatbuffers
- Copies `scripts/` and `assets/ml/`
- Runs both training scripts
- Output: `assets/ml/` (TFLite models + JSON scalers)

## docker-compose.yml

```yaml
services:
  firmware:
    build: docker/firmware
    volumes:
      - .:/workspace
    working_dir: /workspace

  flutter:
    build: docker/flutter
    volumes:
      - ./app:/app
    working_dir: /app

  ml:
    build: docker/ml
    volumes:
      - ./scripts:/workspace/scripts
      - ./assets/ml:/workspace/assets/ml
    working_dir: /workspace
```

## Usage

```bash
docker compose run firmware      # builds firmware.bin
docker compose run flutter       # builds app-release.apk
docker compose run ml            # trains + exports TFLite models
```

## Branch Strategy

- `master` — original codebase, unmodified, builds via PlatformIO + Flutter CLI as before
- `docker-experiment` — this branch, self-contained with Flutter app copy + Docker setup
