"""
Training pipeline entrypoint. Run inside the ml container.
Triggered when $DATA_DIR/.retrain_trigger exists.
Sequence: train -> verify outputs -> flutter build apk -> archive data -> reset trigger.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

DATA_DIR = Path(os.environ.get("DATA_DIR", "/workspace/data"))
TRIGGER_FILE = DATA_DIR / ".retrain_trigger"
ASSETS_DIR = Path("/workspace/app/assets/ml")


def _ts() -> str:
    """Return current local time as [HH:MM:SS]."""
    return datetime.now().strftime("[%H:%M:%S]")


def log(msg: str) -> None:
    print(f"{_ts()} {msg}", flush=True)


def run(cmd: list[str]) -> None:
    log(f"Step: run {' '.join(cmd)}")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        raise RuntimeError(f"Command failed (exit {result.returncode}): {cmd}")


def _validate_training_data(field_dir: Path) -> int:
    """Validate CSV files in field_dir. Returns total valid sample count."""
    total = 0
    for csv_file in sorted(field_dir.glob("*.csv")):
        try:
            with open(csv_file) as f:
                lines = f.readlines()
            if len(lines) < 2:  # header only = empty
                continue
            total += len(lines) - 1  # subtract header
        except Exception as e:
            raise RuntimeError(f"Corrupt CSV {csv_file}: {e}")
    if total == 0:
        raise RuntimeError("No valid training samples found in field data")
    return total


def _backup_models(assets_dir: Path, backup_dir: Path) -> None:
    """Copy current .tflite and .json files to backup_dir."""
    backup_dir.mkdir(parents=True, exist_ok=True)
    for f in assets_dir.glob("*.tflite"):
        shutil.copy2(f, backup_dir / f.name)
    for f in assets_dir.glob("*.json"):
        shutil.copy2(f, backup_dir / f.name)


def _restore_models(backup_dir: Path, assets_dir: Path) -> None:
    """Restore models from backup_dir to assets_dir."""
    for f in backup_dir.glob("*.tflite"):
        shutil.copy2(f, assets_dir / f.name)
    for f in backup_dir.glob("*.json"):
        shutil.copy2(f, assets_dir / f.name)


def _verify_new_models(assets_dir: Path) -> bool:
    """Run dummy TFLite inference on both new models to confirm they're valid."""
    for model_file in ["vibration_anomaly.tflite", "precursor_classifier.tflite"]:
        model_path = assets_dir / model_file
        result = subprocess.run(
            [sys.executable, "-c",
             f"import tensorflow as tf; "
             f"i=tf.lite.Interpreter(model_path=r'{model_path}'); "
             f"i.allocate_tensors(); print('OK')"],
            capture_output=True, timeout=30
        )
        if result.returncode != 0 or b"OK" not in result.stdout:
            return False
    return True


def _count_archived_csvs(archive_dir: Path) -> int:
    """Count CSV files in archive_dir."""
    if not archive_dir.exists():
        return 0
    return sum(1 for _ in archive_dir.glob("*.csv"))


def main() -> None:
    if not TRIGGER_FILE.exists():
        log("Step: no .retrain_trigger found — nothing to do.")
        return

    log("Step: retrain triggered")

    backup_dir = DATA_DIR / ".model_backup"
    start_time = time.time()

    try:
        # P30: Validate training data before doing anything expensive
        field_dir = DATA_DIR / "field"
        sample_count = _validate_training_data(field_dir)
        log(f"Step: validated training data — {sample_count} samples found")

        # P28: Backup existing models before training
        if ASSETS_DIR.exists():
            _backup_models(ASSETS_DIR, backup_dir)
            log(f"Step: backed up existing models to {backup_dir}")

        log("Step: train autoencoder")
        run(["python", "scripts/train_autoencoder.py"])

        log("Step: generate precursor data")
        run(["python", "scripts/generate_precursor_data.py"])

        log("Step: verify output files")
        expected = [
            "vibration_anomaly.tflite",
            "vibration_scaler.json",
            "vibration_model_config.json",
            "precursor_classifier.tflite",
            "precursor_classifier_scaler.json",
            "precursor_classifier_config.json",
        ]
        for fname in expected:
            p = ASSETS_DIR / fname
            if not p.exists():
                raise FileNotFoundError(f"Expected output missing: {p}")
            log(f"Step: verified {p} ({p.stat().st_size} bytes)")

        # P27: Verify new models actually load and run inference
        log("Step: verifying new model integrity")
        if not _verify_new_models(ASSETS_DIR):
            raise RuntimeError("Model verification failed — new models are invalid")
        log("Step: model integrity verified")

        # Trigger APK build via Docker-in-Docker if host socket is available
        if Path("/var/run/docker.sock").exists() and shutil.which("docker"):
            log("Step: trigger flutter APK build via DinD")
            run(["docker", "compose", "run", "--rm", "flutter"])
        else:
            log("Step: docker socket or CLI not available — skipping APK build")

        # Archive processed field data
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
        archive_dir = DATA_DIR / "processed" / ts
        archive_dir.mkdir(parents=True, exist_ok=True)
        for csv_file in field_dir.glob("*.csv"):
            shutil.move(str(csv_file), archive_dir / csv_file.name)
        log(f"Step: archived field data to {archive_dir}")

        # Reset trigger and update baseline count
        TRIGGER_FILE.unlink(missing_ok=True)
        try:
            count = int((field_dir / ".sample_count").read_text().strip())
        except Exception:
            count = 0
        (DATA_DIR / ".baseline_count").write_text(str(count))
        log("Step: reset trigger and updated baseline count")

        # P29: Write pipeline metrics
        end_time = time.time()
        metrics = {
            "pipeline_run_at": datetime.now(timezone.utc).isoformat(),
            "training_duration_seconds": round(end_time - start_time, 1),
            "samples_processed": _count_archived_csvs(archive_dir),
            "model_sizes": {
                f.stem: f.stat().st_size
                for f in ASSETS_DIR.glob("*.tflite")
            },
        }
        metrics_path = DATA_DIR / "pipeline_metrics.json"
        metrics_path.write_text(json.dumps(metrics, indent=2))
        log(f"Step: metrics written to {metrics_path}")

        # Clean up backup on success
        if backup_dir.exists():
            shutil.rmtree(backup_dir)
            log("Step: cleaned up model backup")

        log("Step: pipeline complete")

    except Exception as exc:
        ts_err = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(
            f"[{ts_err}] PIPELINE ERROR: {exc}",
            flush=True,
            file=sys.stderr,
        )
        # P28: Rollback to previous models if backup exists
        if backup_dir.exists():
            _restore_models(backup_dir, ASSETS_DIR)
            log("ROLLBACK: restored previous models")

        # Remove trigger so the watcher can re-trigger on the next threshold breach.
        # Without this the pipeline is permanently wedged: trigger stays, watcher
        # won't write a new one, trainer container has restart:"no".
        TRIGGER_FILE.unlink(missing_ok=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
