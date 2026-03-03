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


def run(cmd: list[str]) -> None:
    print(f"+ {' '.join(cmd)}", flush=True)
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"FAILED (exit {result.returncode}): {cmd}", flush=True)
        sys.exit(result.returncode)


def main() -> None:
    if not TRIGGER_FILE.exists():
        print("No .retrain_trigger found — nothing to do.")
        return

    print("=== Retrain triggered ===", flush=True)

    run(["python", "scripts/train_autoencoder.py"])
    run(["python", "scripts/generate_precursor_data.py"])

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
            print(f"ERROR: expected output missing: {p}", flush=True)
            sys.exit(1)
        print(f"  {p} ({p.stat().st_size} bytes)", flush=True)

    # Trigger APK build via Docker-in-Docker if host socket is available
    if Path("/var/run/docker.sock").exists():
        run(["docker", "compose", "run", "--rm", "flutter"])
    else:
        print("Docker socket not available — skipping APK build.", flush=True)

    # Archive processed field data
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
    archive_dir = DATA_DIR / "processed" / ts
    archive_dir.mkdir(parents=True, exist_ok=True)
    field_dir = DATA_DIR / "field"
    for csv_file in field_dir.glob("*.csv"):
        shutil.move(str(csv_file), archive_dir / csv_file.name)
    print(f"Archived data to {archive_dir}", flush=True)

    # Reset trigger and baseline
    TRIGGER_FILE.unlink(missing_ok=True)
    try:
        count = int((field_dir / ".sample_count").read_text().strip())
    except Exception:
        count = 0
    (DATA_DIR / ".baseline_count").write_text(str(count))

    print("=== Pipeline complete ===", flush=True)


if __name__ == "__main__":
    main()
