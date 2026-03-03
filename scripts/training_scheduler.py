#!/usr/bin/env python3
"""
training_scheduler.py — Automated retraining scheduler for AncientVision.

Monitors a data directory for new samples and writes a trigger file when
enough new samples have accumulated to justify retraining.

Usage:
    python scripts/training_scheduler.py [--data-dir ./data/field] \
        [--threshold 100] [--check-interval 300] \
        [--trigger-file .retrain_trigger] [--once]
"""

import argparse
import os
import signal
import sys
import time
from datetime import datetime


def _timestamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _log(msg: str) -> None:
    print(f"[{_timestamp()}] {msg}", flush=True)


def _count_samples(data_dir: str) -> int:
    """Count CSV sample files in data_dir (non-recursive)."""
    if not os.path.isdir(data_dir):
        return 0
    return sum(
        1
        for f in os.listdir(data_dir)
        if f.endswith(".csv") and os.path.isfile(os.path.join(data_dir, f))
    )


def _read_last_count(data_dir: str) -> int:
    """Read the previously recorded sample count from .last_retrain_count."""
    marker = os.path.join(data_dir, ".last_retrain_count")
    try:
        with open(marker, "r") as fh:
            return int(fh.read().strip())
    except (FileNotFoundError, ValueError):
        return 0


def _write_last_count(data_dir: str, count: int) -> None:
    """Persist the current sample count so we can compute deltas later."""
    marker = os.path.join(data_dir, ".last_retrain_count")
    with open(marker, "w") as fh:
        fh.write(str(count))


def _write_trigger(trigger_file: str) -> None:
    """Write the retrain trigger file with an ISO timestamp inside."""
    with open(trigger_file, "w") as fh:
        fh.write(_timestamp())
    _log(f"Trigger written → {trigger_file}")


def _check_once(data_dir: str, threshold: int, trigger_file: str) -> bool:
    """
    Perform a single scheduler check.

    Returns True if the trigger was fired, False otherwise.
    """
    total = _count_samples(data_dir)
    last = _read_last_count(data_dir)
    new_samples = max(0, total - last)

    if new_samples >= threshold:
        _log(
            f"Scheduler check: {new_samples} new samples — threshold reached "
            f"({threshold}). Firing retrain trigger."
        )
        _write_trigger(trigger_file)
        _write_last_count(data_dir, total)
        return True
    else:
        need = threshold - new_samples
        _log(
            f"Scheduler check: {new_samples} new samples "
            f"(need {need} more to trigger)"
        )
        return False


def main() -> None:
    parser = argparse.ArgumentParser(
        description="AncientVision automated retraining scheduler."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        help="Directory containing collected CSV sample files (default: ./data/field)",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=100,
        help="Number of new samples required to trigger retraining (default: 100)",
    )
    parser.add_argument(
        "--check-interval",
        type=int,
        default=300,
        help="Seconds between checks when running as daemon (default: 300)",
    )
    parser.add_argument(
        "--trigger-file",
        default=".retrain_trigger",
        help="Path to the trigger file to write (default: .retrain_trigger)",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Check once and exit (useful for cron jobs)",
    )
    args = parser.parse_args()

    # Normalise paths
    data_dir = os.path.abspath(args.data_dir)
    trigger_file = os.path.abspath(args.trigger_file)

    # Graceful SIGINT handler
    running = [True]

    def _handle_sigint(signum, frame):  # noqa: ANN001
        running[0] = False
        _log("Scheduler stopped")
        sys.exit(0)

    signal.signal(signal.SIGINT, _handle_sigint)

    if args.once:
        _check_once(data_dir, args.threshold, trigger_file)
        return

    _log(
        f"Scheduler started — data_dir={data_dir}, threshold={args.threshold}, "
        f"interval={args.check_interval}s, trigger={trigger_file}"
    )

    while running[0]:
        _check_once(data_dir, args.threshold, trigger_file)
        # Sleep in 1-second increments so SIGINT is handled promptly
        for _ in range(args.check_interval):
            if not running[0]:
                break
            time.sleep(1)


if __name__ == "__main__":
    main()
