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
- Exponential backoff on trigger file write failure (1s, 2s, 4s, 8s, max 3 retries).
- Sample rate monitoring with warnings for zero rate (10+ min) or spike (>100/min).
- Structured JSON logging for key events.
- Trigger cooldown (300s) to prevent thrashing.
- Graceful shutdown handling with SIGTERM.
"""
import json
import logging
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    stream=sys.stdout,
)

TRIGGER_THRESHOLD = int(os.environ.get("TRIGGER_THRESHOLD", "100"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
BACKOFF_BASE = int(os.environ.get("BACKOFF_BASE", "60"))   # seconds to wait after a failure
TRIGGER_COOLDOWN_SECS = int(os.environ.get("TRIGGER_COOLDOWN_SECS", "300"))
TRIGGER_WRITE_MAX_RETRIES = 3
SAMPLE_RATE_HISTORY_SIZE = 600  # 10 minutes of 1-minute windows


def _read_int(path: Path, default: int = 0) -> int:
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _log_json(event: str, **kwargs) -> None:
    """Log an event as structured JSON."""
    payload = {"event": event, "ts": time.time(), **kwargs}
    logging.info(json.dumps(payload))


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
    last_trigger_time: float | None = None,
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
    if last_trigger_time is not None:
        payload["last_trigger_time"] = last_trigger_time
    try:
        status_path.write_text(json.dumps(payload))
    except OSError as exc:
        logging.warning(f"Could not write status file: {exc}")
        _log_json("status_write_error", error=str(exc))


# ---------------------------------------------------------------------------
# Trigger file with exponential backoff retry
# ---------------------------------------------------------------------------

def write_trigger_with_retry(trigger_file: Path, threshold: int, sample_count: int) -> bool:
    """
    Write trigger file with exponential backoff on failure.

    Returns True on success, False if all retries exhausted.
    """
    for attempt in range(1, TRIGGER_WRITE_MAX_RETRIES + 1):
        try:
            trigger_file.parent.mkdir(parents=True, exist_ok=True)
            trigger_file.touch()
            _log_json(
                "trigger_written",
                sample_count=sample_count,
                threshold=threshold,
                attempt=attempt,
            )
            return True
        except (OSError, PermissionError) as exc:
            if attempt < TRIGGER_WRITE_MAX_RETRIES:
                wait_secs = 2 ** (attempt - 1)  # 1s, 2s, 4s
                _log_json(
                    "trigger_write_retry",
                    attempt=attempt,
                    max_retries=TRIGGER_WRITE_MAX_RETRIES,
                    wait_secs=wait_secs,
                    error=str(exc),
                )
                time.sleep(wait_secs)
            else:
                _log_json(
                    "trigger_write_failed",
                    attempt=attempt,
                    max_retries=TRIGGER_WRITE_MAX_RETRIES,
                    error=str(exc),
                )
                return False
    return False


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
        logging.error(f"Trainer subprocess error: {exc}")
        _log_json("trainer_subprocess_error", error=str(exc))
        return False
    finally:
        try:
            lock_file.unlink(missing_ok=True)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Sample rate monitoring
# ---------------------------------------------------------------------------

class SampleRateMonitor:
    """Track sample arrivals per minute and warn on anomalies."""

    def __init__(self, history_size: int = 600):
        self.history: list[int] = []  # samples per minute
        self.history_size = history_size
        self.last_sample_count = 0

    def update(self, current_sample_count: int) -> None:
        """Add new sample count and track rate."""
        new_samples = max(0, current_sample_count - self.last_sample_count)
        self.history.append(new_samples)
        if len(self.history) > self.history_size:
            self.history.pop(0)
        self.last_sample_count = current_sample_count

    def check_anomalies(self) -> None:
        """Check for zero rate or spike."""
        if len(self.history) < 10:  # Need at least 10 minutes of history
            return

        recent_10_min = self.history[-10:]
        total_recent = sum(recent_10_min)

        if total_recent == 0:
            _log_json(
                "sample_rate_warning",
                reason="no_new_samples_10min",
                device_status="possibly_offline",
            )
            logging.warning("No new samples for 10 minutes — device may be offline")

        # Check for spike: if last reading >100/min
        if self.history[-1] > 100:
            _log_json(
                "sample_rate_warning",
                reason="spike",
                samples_per_min=self.history[-1],
                possible_cause="replay_or_attack",
            )
            logging.warning(f"Unusual sample rate: {self.history[-1]}/min — possible replay or attack")


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
    last_trigger_time: float = 0.0  # epoch seconds
    rate_monitor = SampleRateMonitor(SAMPLE_RATE_HISTORY_SIZE)

    # Graceful shutdown handler
    def handle_shutdown(sig, frame):
        logging.info("Shutdown signal received, flushing logs...")
        _log_json("watcher_shutdown", signal=sig)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)

    logging.info(
        f"Watching {data_dir} — trigger at {TRIGGER_THRESHOLD} new samples, "
        f"poll={POLL_INTERVAL}s, cooldown={TRIGGER_COOLDOWN_SECS}s"
    )
    _log_json(
        "watcher_started",
        data_dir=str(data_dir),
        trigger_threshold=TRIGGER_THRESHOLD,
        poll_interval=POLL_INTERVAL,
        cooldown_secs=TRIGGER_COOLDOWN_SECS,
    )

    while True:
        total = _read_int(data_dir / "field" / ".sample_count")
        delta = sample_delta(data_dir)
        need = max(0, TRIGGER_THRESHOLD - delta)

        # Update sample rate monitor
        rate_monitor.update(total)
        rate_monitor.check_anomalies()

        logging.info(
            f"[{_iso_now()}] {delta} new samples since last retrain (need {need} more)"
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
            last_trigger_time=last_trigger_time if last_trigger_time > 0 else None,
        )

        # Check whether we should trigger a retrain
        now = time.monotonic()
        if delta >= TRIGGER_THRESHOLD:
            if lock_file.exists():
                logging.info("Lock file exists — trainer already running; skipping trigger.")
                _log_json("trigger_skipped", reason="lock_file_exists")
            elif now < backoff_until:
                remaining = int(backoff_until - now)
                logging.info(
                    f"In backoff after {consecutive_failures} consecutive failure(s); "
                    f"waiting {remaining}s more."
                )
                _log_json(
                    "trigger_skipped",
                    reason="backoff_active",
                    consecutive_failures=consecutive_failures,
                    remaining_secs=remaining,
                )
            elif now - last_trigger_time < TRIGGER_COOLDOWN_SECS:
                remaining = int(TRIGGER_COOLDOWN_SECS - (now - last_trigger_time))
                logging.info(
                    f"Trigger cooldown active; waiting {remaining}s more "
                    f"(last trigger {int(now - last_trigger_time)}s ago)."
                )
                _log_json(
                    "trigger_skipped",
                    reason="cooldown_active",
                    seconds_since_last_trigger=int(now - last_trigger_time),
                    remaining_secs=remaining,
                )
            else:
                # Write trigger file with exponential backoff retry
                success = write_trigger_with_retry(trigger_file, TRIGGER_THRESHOLD, total)
                if not success:
                    logging.error("Failed to write trigger file after all retries.")
                    _log_json("trigger_launch_aborted", reason="trigger_file_write_failed")
                else:
                    logging.info("Threshold reached — launching trainer.")
                    last_trigger_time = now

                    write_status(
                        data_dir,
                        sample_count=total,
                        samples_since_last_retrain=delta,
                        consecutive_failures=consecutive_failures,
                        status="retraining",
                        last_trigger_time=last_trigger_time,
                    )

                    success = run_trainer(trainer_cmd, lock_file)

                    if success:
                        logging.info("Trainer finished successfully.")
                        _log_json("trainer_success", consecutive_failures=consecutive_failures)
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
                        logging.error(
                            f"Trainer failed (consecutive failures: {consecutive_failures}). "
                            f"Backing off {wait}s."
                        )
                        _log_json(
                            "trainer_failed",
                            consecutive_failures=consecutive_failures,
                            backoff_secs=wait,
                        )
                        write_status(
                            data_dir,
                            sample_count=total,
                            samples_since_last_retrain=delta,
                            consecutive_failures=consecutive_failures,
                            status="error",
                            last_trigger_time=last_trigger_time,
                        )

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
