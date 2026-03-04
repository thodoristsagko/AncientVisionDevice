"""
Training pipeline entrypoint. Run inside the ml container.
Triggered when $DATA_DIR/.retrain_trigger exists.
Sequence: train -> verify outputs -> flutter build apk -> archive data -> reset trigger.

Flags:
  --dry-run   Validate all prerequisites without training.
  --status    Print last training time, model version, sample count, pipeline health.
"""
import argparse
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

# Path for structured JSON log (relative to DATA_DIR so it moves with data)
_PIPELINE_LOG: Path | None = None  # set lazily on first structured log write


def _pipeline_log_path() -> Path:
    return DATA_DIR / "pipeline.log"


def _ts() -> str:
    """Return current local time as [HH:MM:SS]."""
    return datetime.now().strftime("[%H:%M:%S]")


def log(msg: str, *, level: str = "INFO", step: str | None = None, extra: dict | None = None) -> None:
    """Print a human-readable line AND append a JSON entry to pipeline.log."""
    print(f"{_ts()} {msg}", flush=True)
    record: dict = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "msg": msg,
    }
    if step:
        record["step"] = step
    if extra:
        record.update(extra)
    try:
        with open(_pipeline_log_path(), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
    except OSError:
        pass  # Never let logging break the pipeline


def run(cmd: list[str]) -> None:
    log(f"Step: run {' '.join(cmd)}", step="subprocess")
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


def _check_assets_writable(assets_dir: Path) -> list[str]:
    """Return list of error strings for asset-directory write checks."""
    errors = []
    if not assets_dir.exists():
        # Directory will be created by training scripts; check parent is writable.
        parent = assets_dir.parent
        if not parent.exists():
            errors.append(f"Assets parent dir does not exist: {parent}")
        elif not os.access(parent, os.W_OK):
            errors.append(f"Assets parent dir is not writable: {parent}")
    else:
        if not os.access(assets_dir, os.W_OK):
            errors.append(f"Assets dir is not writable: {assets_dir}")
        for fname in [
            "vibration_anomaly.tflite",
            "precursor_classifier.tflite",
        ]:
            p = assets_dir / fname
            if p.exists() and not os.access(p, os.W_OK):
                errors.append(f"Model file is not writable: {p}")
    return errors


def dry_run() -> int:
    """Validate all prerequisites without running any training.

    Returns 0 if all checks pass, 1 if any check fails.
    """
    print(f"{_ts()} [DRY-RUN] Validating pipeline prerequisites …")
    errors: list[str] = []

    # 1. Check trigger file presence
    if not TRIGGER_FILE.exists():
        errors.append(f"Trigger file not found: {TRIGGER_FILE} (pipeline would be a no-op)")

    # 2. Validate training data
    field_dir = DATA_DIR / "field"
    if not field_dir.exists():
        errors.append(f"Field data directory missing: {field_dir}")
    else:
        try:
            count = _validate_training_data(field_dir)
            print(f"{_ts()} [DRY-RUN] Training data OK — {count} samples")
            log("[DRY-RUN] Training data validated", step="dry_run", extra={"sample_count": count})
        except RuntimeError as exc:
            errors.append(f"Training data invalid: {exc}")

    # 3. Check assets-dir writeability
    asset_errors = _check_assets_writable(ASSETS_DIR)
    errors.extend(asset_errors)
    if not asset_errors:
        print(f"{_ts()} [DRY-RUN] Assets directory writable OK: {ASSETS_DIR}")

    # 4. Check Python executable
    py = sys.executable or "python"
    if not Path(py).exists():
        errors.append(f"Python executable not found: {py}")
    else:
        print(f"{_ts()} [DRY-RUN] Python executable OK: {py}")

    # 5. Check training scripts exist
    script_dir = Path(__file__).parent
    for script in ["train_autoencoder.py", "generate_precursor_data.py"]:
        # Scripts are called as `python scripts/<name>` from project root
        candidates = [script_dir / script, Path("scripts") / script, Path(script)]
        found = any(c.exists() for c in candidates)
        if not found:
            errors.append(f"Training script not found: {script}")
        else:
            print(f"{_ts()} [DRY-RUN] Script OK: {script}")

    # Summary
    if errors:
        print(f"\n{_ts()} [DRY-RUN] FAILED — {len(errors)} issue(s) found:")
        for e in errors:
            print(f"  - {e}")
        log("[DRY-RUN] Prerequisites check FAILED", level="ERROR", step="dry_run",
            extra={"errors": errors})
        return 1
    else:
        print(f"\n{_ts()} [DRY-RUN] All prerequisites OK — pipeline would proceed.")
        log("[DRY-RUN] Prerequisites check PASSED", step="dry_run")
        return 0


def status() -> int:
    """Print pipeline status: last training time, model version, sample count, health.

    Returns 0.
    """
    print(f"\n{'='*60}")
    print("  AncientVision Pipeline Status")
    print(f"{'='*60}")

    # --- Last training run from pipeline_metrics.json ---
    metrics_path = DATA_DIR / "pipeline_metrics.json"
    print("\n[Last Training Run]")
    if metrics_path.exists():
        try:
            metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
            ran_at = metrics.get("pipeline_run_at", "unknown")
            duration = metrics.get("training_duration_seconds", "?")
            samples = metrics.get("samples_processed", "?")
            print(f"  Trained at      : {ran_at}")
            print(f"  Duration        : {duration}s")
            print(f"  Samples used    : {samples}")
            model_sizes = metrics.get("model_sizes", {})
            for name, size in model_sizes.items():
                print(f"  Model {name:22s}: {size} bytes")
        except (json.JSONDecodeError, OSError) as exc:
            print(f"  [ERROR] Cannot read pipeline_metrics.json: {exc}")
    else:
        print("  (no pipeline_metrics.json found — pipeline has not run yet)")

    # --- Model versions from config JSONs ---
    print("\n[Model Versions]")
    for cfg_name in ["precursor_classifier_config.json", "vibration_model_config.json"]:
        cfg_path = ASSETS_DIR / cfg_name
        if cfg_path.exists():
            try:
                cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
                version = cfg.get("model_version", "?")
                trained_at = cfg.get("trained_at", "?")
                print(f"  {cfg_name:<42}: v{version} (trained {trained_at})")
            except (json.JSONDecodeError, OSError) as exc:
                print(f"  {cfg_name:<42}: [ERROR] {exc}")
        else:
            print(f"  {cfg_name:<42}: [MISSING]")

    # --- Sample count in field data ---
    print("\n[Field Data]")
    field_dir = DATA_DIR / "field"
    if field_dir.exists():
        csv_files = list(field_dir.glob("*.csv"))
        total_samples = 0
        for csv_file in csv_files:
            try:
                lines = csv_file.read_text(encoding="utf-8").splitlines()
                total_samples += max(0, len(lines) - 1)  # subtract header
            except OSError:
                pass
        print(f"  CSV files       : {len(csv_files)}")
        print(f"  Total samples   : {total_samples}")
        sample_count_file = field_dir / ".sample_count"
        if sample_count_file.exists():
            print(f"  .sample_count   : {sample_count_file.read_text().strip()}")
    else:
        print("  Field dir not found — no data collected yet")

    baseline_file = DATA_DIR / ".baseline_count"
    if baseline_file.exists():
        print(f"  .baseline_count : {baseline_file.read_text().strip()}")

    # --- Pipeline health ---
    print("\n[Pipeline Health]")
    trigger_present = TRIGGER_FILE.exists()
    print(f"  Retrain trigger : {'PENDING' if trigger_present else 'clear'}")

    # Expected model files
    all_present = True
    for fname in ["vibration_anomaly.tflite", "precursor_classifier.tflite"]:
        p = ASSETS_DIR / fname
        if p.exists():
            print(f"  {fname:<42}: OK ({p.stat().st_size} bytes)")
        else:
            print(f"  {fname:<42}: MISSING")
            all_present = False

    overall = "HEALTHY" if all_present and not trigger_present else "NEEDS ATTENTION"
    print(f"\n  Overall status  : {overall}")
    print(f"{'='*60}\n")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="AncientVision training pipeline entrypoint.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate all prerequisites (data, scripts, write-access) without training.",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Print pipeline status (last training time, model versions, sample count).",
    )
    args, _ = parser.parse_known_args()

    if args.dry_run:
        sys.exit(dry_run())

    if args.status:
        sys.exit(status())

    _run_pipeline()


def _run_pipeline() -> None:
    if not TRIGGER_FILE.exists():
        log("Step: no .retrain_trigger found — nothing to do.")
        return

    log("Step: retrain triggered", step="start")

    backup_dir = DATA_DIR / ".model_backup"
    start_time = time.time()

    try:
        # P30: Validate training data before doing anything expensive
        field_dir = DATA_DIR / "field"
        sample_count = _validate_training_data(field_dir)
        log(f"Step: validated training data — {sample_count} samples found",
            step="validate_data", extra={"sample_count": sample_count})

        # P28: Backup existing models before training
        if ASSETS_DIR.exists():
            _backup_models(ASSETS_DIR, backup_dir)
            log(f"Step: backed up existing models to {backup_dir}", step="backup_models")

        log("Step: train autoencoder", step="train_autoencoder")
        run(["python", "scripts/train_autoencoder.py"])

        log("Step: generate precursor data", step="generate_precursor")
        run(["python", "scripts/generate_precursor_data.py"])

        log("Step: verify output files", step="verify_outputs")
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
            log(f"Step: verified {p} ({p.stat().st_size} bytes)",
                step="verify_outputs", extra={"file": fname, "size": p.stat().st_size})

        # P27: Verify new models actually load and run inference
        log("Step: verifying new model integrity", step="verify_models")
        if not _verify_new_models(ASSETS_DIR):
            raise RuntimeError("Model verification failed — new models are invalid")
        log("Step: model integrity verified", step="verify_models")

        # Trigger APK build via Docker-in-Docker if host socket is available
        if Path("/var/run/docker.sock").exists() and shutil.which("docker"):
            log("Step: trigger flutter APK build via DinD", step="apk_build")
            run(["docker", "compose", "run", "--rm", "flutter"])
        else:
            log("Step: docker socket or CLI not available — skipping APK build", step="apk_build")

        # Archive processed field data
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
        archive_dir = DATA_DIR / "processed" / ts
        archive_dir.mkdir(parents=True, exist_ok=True)
        for csv_file in field_dir.glob("*.csv"):
            shutil.move(str(csv_file), archive_dir / csv_file.name)
        log(f"Step: archived field data to {archive_dir}", step="archive_data",
            extra={"archive_dir": str(archive_dir)})

        # Reset trigger and update baseline count
        TRIGGER_FILE.unlink(missing_ok=True)
        try:
            count = int((field_dir / ".sample_count").read_text().strip())
        except Exception:
            count = 0
        (DATA_DIR / ".baseline_count").write_text(str(count))
        log("Step: reset trigger and updated baseline count", step="reset_trigger")

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
        log(f"Step: metrics written to {metrics_path}", step="write_metrics",
            extra={"duration_s": metrics["training_duration_seconds"],
                   "samples_processed": metrics["samples_processed"]})

        # Clean up backup on success
        if backup_dir.exists():
            shutil.rmtree(backup_dir)
            log("Step: cleaned up model backup", step="cleanup")

        log("Step: pipeline complete", step="complete",
            extra={"duration_s": round(time.time() - start_time, 1)})

    except Exception as exc:
        ts_err = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(
            f"[{ts_err}] PIPELINE ERROR: {exc}",
            flush=True,
            file=sys.stderr,
        )
        log(f"PIPELINE ERROR: {exc}", level="ERROR", step="error", extra={"error": str(exc)})
        # P28: Rollback to previous models if backup exists
        if backup_dir.exists():
            _restore_models(backup_dir, ASSETS_DIR)
            log("ROLLBACK: restored previous models", level="WARN", step="rollback")

        # Remove trigger so the watcher can re-trigger on the next threshold breach.
        # Without this the pipeline is permanently wedged: trigger stays, watcher
        # won't write a new one, trainer container has restart:"no".
        TRIGGER_FILE.unlink(missing_ok=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
