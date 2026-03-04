#!/usr/bin/env python3
"""
training_scheduler.py — Automated retraining scheduler for AncientVision.

Monitors a data directory for new samples and writes a trigger file when
enough new samples have accumulated to justify retraining.

Features:
  - Adaptive threshold: grows with dataset size (max(100, 0.1 * total_samples))
  - Time-based trigger: retrains if >7 days since last training
  - Model degradation check: triggers if last accuracy < 0.75
  - Email notification stub: --notify EMAIL flag
  - Dry-run mode: --dry-run flag shows what would happen

Usage:
    python scripts/training_scheduler.py [--data-dir ./data/field] \
        [--threshold 100] [--check-interval 300] \
        [--trigger-file .retrain_trigger] [--once] \
        [--notify EMAIL@example.com] [--dry-run]
"""

import argparse
import json
import os
import signal
import sys
import time
from datetime import datetime, timedelta


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


def _write_trigger(trigger_file: str, dry_run: bool = False) -> None:
    """Write the retrain trigger file with an ISO timestamp inside."""
    if dry_run:
        _log(f"[DRY-RUN] Would write trigger → {trigger_file}")
    else:
        with open(trigger_file, "w") as fh:
            fh.write(_timestamp())
        _log(f"Trigger written → {trigger_file}")


def _load_pipeline_metrics(repo_dir: str) -> dict:
    """Load pipeline_metrics.json if it exists; return empty dict otherwise."""
    metrics_path = os.path.join(repo_dir, "pipeline_metrics.json")
    if not os.path.isfile(metrics_path):
        return {}
    try:
        with open(metrics_path, "r") as fh:
            return json.load(fh)
    except (json.JSONDecodeError, IOError):
        return {}


def _parse_iso_timestamp(ts_str: str) -> datetime:
    """Parse ISO timestamp (2026-03-04T12:34:56 or similar)."""
    try:
        # Try common ISO formats
        for fmt in ["%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"]:
            try:
                return datetime.strptime(ts_str, fmt)
            except ValueError:
                continue
        return datetime.now()
    except Exception:
        return datetime.now()


def _compute_adaptive_threshold(total_samples: int, default_threshold: int) -> int:
    """Compute adaptive threshold: max(default, 0.1 * total_samples)."""
    return max(default_threshold, int(0.1 * total_samples))


def _check_time_based_trigger(repo_dir: str, days_threshold: int = 7) -> bool:
    """Check if >days_threshold days have passed since last training."""
    metrics = _load_pipeline_metrics(repo_dir)
    if not metrics or "last_training_timestamp" not in metrics:
        return False
    try:
        last_train_str = metrics["last_training_timestamp"]
        last_train = _parse_iso_timestamp(last_train_str)
        age = datetime.now() - last_train
        if age > timedelta(days=days_threshold):
            _log(
                f"Time-based trigger: {age.days}d since last training (threshold={days_threshold}d)"
            )
            return True
    except Exception as exc:
        _log(f"Error checking time-based trigger: {exc}")
    return False


def _check_model_degradation(repo_dir: str, accuracy_threshold: float = 0.75) -> bool:
    """Check if last training accuracy was below threshold."""
    metrics = _load_pipeline_metrics(repo_dir)
    if not metrics or "last_training_accuracy" not in metrics:
        return False
    try:
        last_acc = float(metrics["last_training_accuracy"])
        if last_acc < accuracy_threshold:
            _log(
                f"Model degradation trigger: last accuracy {last_acc:.4f} "
                f"< threshold {accuracy_threshold:.4f}"
            )
            return True
    except (ValueError, TypeError):
        pass
    return False


def _send_email_stub(email: str, reason: str, dry_run: bool = False) -> None:
    """Email notification stub. In production, integrate with sendgrid/ses/etc."""
    if dry_run:
        _log(f"[DRY-RUN] Would send email to: {email}")
        _log(f"[DRY-RUN] Reason: {reason}")
    else:
        _log(f"[EMAIL] To: {email}")
        _log(f"[EMAIL] Subject: AncientVision Retraining Triggered")
        _log(f"[EMAIL] Body: {reason}")


def _check_once(
    data_dir: str,
    threshold: int,
    trigger_file: str,
    repo_dir: str,
    notify_email: str = None,
    dry_run: bool = False,
) -> bool:
    """
    Perform a single scheduler check with multiple triggers.

    Returns True if any trigger was fired, False otherwise.
    """
    total = _count_samples(data_dir)
    last = _read_last_count(data_dir)
    new_samples = max(0, total - last)

    # Compute adaptive threshold
    adaptive_threshold = _compute_adaptive_threshold(total, threshold)

    triggers = []
    reasons = []

    # Trigger 1: Sample count
    if new_samples >= adaptive_threshold:
        triggers.append(True)
        reasons.append(f"{new_samples} new samples >= adaptive threshold {adaptive_threshold}")

    # Trigger 2: Time-based
    if _check_time_based_trigger(repo_dir):
        triggers.append(True)
        reasons.append("7+ days since last training")

    # Trigger 3: Model degradation
    if _check_model_degradation(repo_dir):
        triggers.append(True)
        reasons.append("last training accuracy < 0.75")

    if triggers:
        reason_str = " AND ".join(reasons)
        _log(
            f"Scheduler check: Retrain triggered — {reason_str}"
        )
        _write_trigger(trigger_file, dry_run=dry_run)
        if not dry_run:
            _write_last_count(data_dir, total)
        if notify_email:
            _send_email_stub(notify_email, reason_str, dry_run=dry_run)
        return True
    else:
        need = adaptive_threshold - new_samples
        _log(
            f"Scheduler check: {new_samples}/{total} total samples "
            f"(need {need} more for adaptive threshold {adaptive_threshold})"
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
        help="Base number of new samples for trigger (default: 100); "
             "actual threshold adapts as: max(threshold, 0.1 * total_samples)",
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
    parser.add_argument(
        "--notify",
        metavar="EMAIL",
        default=None,
        help="Email address to notify when retraining is triggered (stub implementation)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would happen without writing trigger file or sending emails",
    )
    args = parser.parse_args()

    # Normalise paths; find repo root (parent of data dir)
    data_dir = os.path.abspath(args.data_dir)
    trigger_file = os.path.abspath(args.trigger_file)
    repo_dir = os.path.dirname(data_dir) if os.path.basename(data_dir) == "field" else os.path.dirname(os.path.dirname(data_dir))

    if args.dry_run:
        _log("[DRY-RUN MODE] No trigger files or emails will be written.")

    # Graceful SIGINT handler
    running = [True]

    def _handle_sigint(signum, frame):  # noqa: ANN001
        running[0] = False
        _log("Scheduler stopped")
        sys.exit(0)

    signal.signal(signal.SIGINT, _handle_sigint)

    if args.once:
        _check_once(
            data_dir,
            args.threshold,
            trigger_file,
            repo_dir,
            notify_email=args.notify,
            dry_run=args.dry_run,
        )
        return

    _log(
        f"Scheduler started — data_dir={data_dir}, threshold={args.threshold}, "
        f"interval={args.check_interval}s, trigger={trigger_file}"
    )
    if args.notify:
        _log(f"  Email notifications enabled: {args.notify}")
    if args.dry_run:
        _log(f"  DRY-RUN MODE")

    while running[0]:
        _check_once(
            data_dir,
            args.threshold,
            trigger_file,
            repo_dir,
            notify_email=args.notify,
            dry_run=args.dry_run,
        )
        # Sleep in 1-second increments so SIGINT is handled promptly
        for _ in range(args.check_interval):
            if not running[0]:
                break
            time.sleep(1)


if __name__ == "__main__":
    main()
