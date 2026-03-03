"""
File watcher: polls ./data/field/.sample_count every POLL_INTERVAL seconds.
Launches the trainer subprocess when new samples since last retrain >= TRIGGER_THRESHOLD.

Improvements
------------
- Exponential backoff on trainer failure (60 s base, doubles per consecutive failure).
- Delta tracking: logs "N new samples since last retrain (need M more)".
- Lock file prevents concurrent trainer runs (.retrain_in_progress by default).
- Status file (.watcher_status.json) written every poll cycle.
- TRIGGER_FILE and LOCK_FILE are configurable via environment variables.
"""
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

TRIGGER_THRESHOLD = int(os.environ.get("TRIGGER_THRESHOLD", "100"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
BACKOFF_BASE = int(os.environ.get("BACKOFF_BASE", "60"))   # seconds to wait after a failure


def _read_int(path: Path, default: int = 0) -> int:
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Core checks
# ---------------------------------------------------------------------------

def sample_delta(data_dir: Path) -> int:
    """Return the number of new samples since the last retrain baseline."""
    total = _read_int(data_dir / "field" / ".sample_count")
    baseline = _read_int(data_dir / ".baseline_count")
    return max(0, total - baseline)


def should_trigger(data_dir: Path) -> bool:
    return sample_delta(data_dir) >= TRIGGER_THRESHOLD


def reset_baseline(data_dir: Path) -> None:
    total = _read_int(data_dir / "field" / ".sample_count")
    (data_dir / ".baseline_count").write_text(str(total))


# ---------------------------------------------------------------------------
# Status file
# ---------------------------------------------------------------------------

def write_status(
    data_dir: Path,
    sample_count: int,
    samples_since_last_retrain: int,
    consecutive_failures: int,
    status: str,
) -> None:
    """Write .watcher_status.json to data_dir."""
    status_path = data_dir / ".watcher_status.json"
    payload = {
        "last_check": _iso_now(),
        "sample_count": sample_count,
        "samples_since_last_retrain": samples_since_last_retrain,
        "consecutive_failures": consecutive_failures,
        "status": status,
    }
    try:
        status_path.write_text(json.dumps(payload))
    except OSError as exc:
        print(f"  Warning: could not write status file: {exc}", flush=True)


# ---------------------------------------------------------------------------
# Trainer subprocess
# ---------------------------------------------------------------------------

def run_trainer(trainer_cmd: list[str], lock_file: Path) -> bool:
    """
    Create lock file, run trainer subprocess, remove lock file.

    Returns True if the trainer exited with code 0, False otherwise.
    """
    lock_file.touch()
    try:
        result = subprocess.run(trainer_cmd, check=False)
        return result.returncode == 0
    except Exception as exc:
        print(f"  Trainer subprocess error: {exc}", flush=True)
        return False
    finally:
        try:
            lock_file.unlink(missing_ok=True)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main() -> None:
    data_dir = Path(os.environ.get("DATA_DIR", "/workspace/data"))
    trainer_cmd = os.environ.get("TRAINER_CMD", "python /workspace/train.py").split()
    trigger_file_name = os.environ.get("TRIGGER_FILE", ".retrain_trigger")
    lock_file_name = os.environ.get("LOCK_FILE", ".retrain_in_progress")

    trigger_file = data_dir / trigger_file_name
    lock_file = data_dir / lock_file_name

    consecutive_failures = 0
    backoff_until: float = 0.0   # epoch seconds; 0 means no backoff active

    print(
        f"Watching {data_dir} — trigger at {TRIGGER_THRESHOLD} new samples"
        f"  poll={POLL_INTERVAL}s",
        flush=True,
    )

    while True:
        total = _read_int(data_dir / "field" / ".sample_count")
        delta = sample_delta(data_dir)
        need = max(0, TRIGGER_THRESHOLD - delta)

        print(
            f"[{_iso_now()}] {delta} new samples since last retrain "
            f"(need {need} more)",
            flush=True,
        )

        # Determine current status for the status file
        if lock_file.exists():
            current_status = "retraining"
        elif consecutive_failures > 0 and time.monotonic() < backoff_until:
            current_status = "error"
        else:
            current_status = "waiting"

        write_status(
            data_dir,
            sample_count=total,
            samples_since_last_retrain=delta,
            consecutive_failures=consecutive_failures,
            status=current_status,
        )

        # Check whether we should trigger a retrain
        now = time.monotonic()
        if delta >= TRIGGER_THRESHOLD:
            if lock_file.exists():
                print(
                    "  Lock file exists — trainer already running; skipping trigger.",
                    flush=True,
                )
            elif now < backoff_until:
                remaining = int(backoff_until - now)
                print(
                    f"  In backoff after {consecutive_failures} consecutive failure(s); "
                    f"waiting {remaining}s more.",
                    flush=True,
                )
            else:
                # Legacy trigger file kept for backwards compatibility
                trigger_file.touch()
                print("  Threshold reached — launching trainer.", flush=True)

                write_status(
                    data_dir,
                    sample_count=total,
                    samples_since_last_retrain=delta,
                    consecutive_failures=consecutive_failures,
                    status="retraining",
                )

                success = run_trainer(trainer_cmd, lock_file)

                if success:
                    print("  Trainer finished successfully.", flush=True)
                    consecutive_failures = 0
                    backoff_until = 0.0
                    reset_baseline(data_dir)
                    try:
                        trigger_file.unlink(missing_ok=True)
                    except OSError:
                        pass
                else:
                    consecutive_failures += 1
                    wait = BACKOFF_BASE * (2 ** (consecutive_failures - 1))
                    backoff_until = time.monotonic() + wait
                    print(
                        f"  Trainer failed (consecutive failures: {consecutive_failures}). "
                        f"Backing off {wait}s.",
                        flush=True,
                    )
                    write_status(
                        data_dir,
                        sample_count=total,
                        samples_since_last_retrain=delta,
                        consecutive_failures=consecutive_failures,
                        status="error",
                    )

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
