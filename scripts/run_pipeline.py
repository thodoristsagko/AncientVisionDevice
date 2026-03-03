"""
Training pipeline entrypoint. Run inside the ml container.
Triggered when $DATA_DIR/.retrain_trigger exists.
Sequence: train -> verify outputs -> flutter build apk -> archive data -> reset trigger.
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


def main() -> None:
    if not TRIGGER_FILE.exists():
        log("Step: no .retrain_trigger found — nothing to do.")
        return

    log("Step: retrain triggered")

    try:
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
        field_dir = DATA_DIR / "field"
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

        log("Step: pipeline complete")

    except Exception as exc:
        ts_err = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(
            f"[{ts_err}] PIPELINE ERROR: {exc}",
            flush=True,
            file=sys.stderr,
        )
        # Remove trigger so the watcher can re-trigger on the next threshold breach.
        # Without this the pipeline is permanently wedged: trigger stays, watcher
        # won't write a new one, trainer container has restart:"no".
        TRIGGER_FILE.unlink(missing_ok=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
