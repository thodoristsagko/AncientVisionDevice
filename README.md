# AncientVision Device

Field safety system for archaeologists — detects micro-vibrations preceding soil avalanches using an M5StickC Plus 2 (ESP32), a Flutter mobile app, and on-device ML models.

---

## Docker Build Instructions

All build targets run in isolated containers. No local toolchain installation required beyond Docker Desktop.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- The repo cloned locally

### Build Firmware

Compiles the PlatformIO firmware for the M5StickC Plus 2 (ESP32).

```bash
docker compose run --rm firmware
```

Output: `.pio/build/m5stick-c-plus2/firmware.bin`

### Build Flutter APK

Builds a release APK for Android.

```bash
docker compose run --rm flutter
```

Output: `app/build/app/outputs/flutter-apk/app-release.apk`

### Train ML Models

Runs the model training pipeline and exports TFLite models and scalers.

```bash
docker compose run --rm ml
```

Output: `assets/ml/*.tflite` and `assets/ml/*.json`

### Build Everything at Once

Run all three targets in sequence:

```bash
docker compose run --rm firmware && \
docker compose run --rm flutter && \
docker compose run --rm ml
```

Or, if a `build-all` service is defined in `docker-compose.yml`:

```bash
docker compose run --rm build-all
```

### Output Summary

| Target   | Output path                                                    |
|----------|----------------------------------------------------------------|
| Firmware | `.pio/build/m5stick-c-plus2/firmware.bin`                      |
| APK      | `app/build/app/outputs/flutter-apk/app-release.apk`           |
| ML       | `assets/ml/*.tflite`, `assets/ml/*.json`                       |

### Notes

- All build artefacts are written to bind-mounted host directories, so outputs are available after the container exits.
- First runs will be slower while Docker pulls base images and populates caches.
- To force a clean rebuild of the Docker image itself, add `--build`: `docker compose run --rm --build firmware`.
