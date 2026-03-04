#!/usr/bin/env python3
"""
training_history.py — Display ML training run history and trends.

Usage:
    python scripts/training_history.py [--model-dir DIR] [--limit N]

Reads training_metrics.json files from model directory and any archived runs.
Shows per-run: date, accuracy, loss, training_time, epochs, git_sha.
Highlights improvements and regressions between runs.
"""
import argparse
import glob
import json
import os
import sys
from pathlib import Path

# Force UTF-8 output on Windows so arrow/box characters render correctly.
if sys.platform == "win32":
    try:
        import io as _io
        sys.stdout = _io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    except Exception:
        pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_MODEL_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")


def find_metrics_files(model_dir: str) -> list:
    """Find all metrics JSON files, sorted by modification time (oldest first)."""
    found = []

    # Current metrics file
    current = os.path.join(model_dir, "precursor_training_metrics.json")
    if os.path.isfile(current):
        found.append(current)

    # Archived runs
    archive_pattern = os.path.join(
        model_dir, "archive", "**", "precursor_training_metrics.json"
    )
    for f in glob.glob(archive_pattern, recursive=True):
        if f not in found:
            found.append(f)

    # Any other *_metrics.json files in model_dir (not already found)
    for f in glob.glob(os.path.join(model_dir, "*_metrics.json")):
        if f not in found:
            found.append(f)

    # Sort by file modification time (oldest first)
    found.sort(key=lambda p: os.path.getmtime(p))
    return found


def parse_metrics(path: str) -> dict:
    """Parse a metrics JSON file, returning a dict with normalised keys."""
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return {}

    mtime = os.path.getmtime(path)

    # Normalise accuracy field (various naming conventions used across runs)
    accuracy = data.get("accuracy")
    if accuracy is None:
        accuracy = data.get("holdout_accuracy")
    if accuracy is None:
        accuracy = data.get("cv_accuracy_mean")
    if accuracy is None:
        accuracy = data.get("cv_mean_accuracy")

    return {
        "path": path,
        "mtime": mtime,
        "trained_at": data.get("trained_at", ""),
        "accuracy": accuracy,
        "loss": data.get("loss"),
        "training_time_s": data.get("training_time_s"),
        "epochs_run": data.get("epochs_run"),
        "git_sha": data.get("git_sha", ""),
    }


def format_date(trained_at: str, mtime: float) -> str:
    """Return a short date string from trained_at ISO string or file mtime."""
    if trained_at:
        # Trim to first 19 chars: 2026-03-03T10:11:12
        return trained_at[:19].replace("T", " ")
    from datetime import datetime
    return datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")


def change_str(prev_acc, curr_acc) -> str:
    """Return a change indicator string comparing two accuracy values."""
    if prev_acc is None or curr_acc is None:
        return "—"
    delta = curr_acc - prev_acc
    pct = delta * 100
    if abs(pct) < 0.01:
        return "—"
    arrow = "▲" if delta > 0 else "▼"
    sign = "+" if delta > 0 else ""
    return f"{arrow} {sign}{pct:.1f}%"


def print_table(runs: list) -> None:
    """Print ASCII table of training runs."""
    # Column widths
    w_run = 4
    w_date = 19
    w_acc = 8
    w_loss = 8
    w_epochs = 6
    w_time = 7
    w_sha = 10
    w_change = 10

    header = (
        f"{'Run':<{w_run}}  "
        f"{'Date':<{w_date}}  "
        f"{'Accuracy':>{w_acc}}  "
        f"{'Loss':>{w_loss}}  "
        f"{'Epochs':>{w_epochs}}  "
        f"{'Time(s)':>{w_time}}  "
        f"{'SHA':<{w_sha}}  "
        f"{'Change':<{w_change}}"
    )
    sep = "-" * len(header)
    print(header)
    print(sep)

    prev_acc = None
    for i, run in enumerate(runs, start=1):
        curr_acc = run["accuracy"]
        chg = change_str(prev_acc, curr_acc) if i > 1 else "—"

        acc_str = f"{curr_acc:.4f}" if curr_acc is not None else "  N/A  "
        loss_str = f"{run['loss']:.4f}" if run["loss"] is not None else "  N/A  "
        epochs_str = str(run["epochs_run"]) if run["epochs_run"] is not None else " N/A"
        time_str = f"{run['training_time_s']:.1f}" if run["training_time_s"] is not None else "  N/A"
        sha_str = (run["git_sha"] or "")[:w_sha]
        date_str = format_date(run["trained_at"], run["mtime"])

        print(
            f"{i:<{w_run}}  "
            f"{date_str:<{w_date}}  "
            f"{acc_str:>{w_acc}}  "
            f"{loss_str:>{w_loss}}  "
            f"{epochs_str:>{w_epochs}}  "
            f"{time_str:>{w_time}}  "
            f"{sha_str:<{w_sha}}  "
            f"{chg:<{w_change}}"
        )

        prev_acc = curr_acc


def print_summary(runs: list) -> None:
    """Print summary line with best and latest accuracy."""
    accs = [(i + 1, r["accuracy"]) for i, r in enumerate(runs) if r["accuracy"] is not None]
    if not accs:
        print("\nNo accuracy values found.")
        return

    best_run, best_acc = max(accs, key=lambda x: x[1])
    latest_run, latest_acc = accs[-1]
    print(f"\nBest accuracy: {best_acc:.3f} (run {best_run}), Latest: {latest_acc:.3f} (run {latest_run})")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Display ML training run history and accuracy trends."
    )
    parser.add_argument(
        "--model-dir",
        default=DEFAULT_MODEL_DIR,
        help="Directory containing training metrics JSON files",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        metavar="N",
        help="Show only last N runs (default: all)",
    )
    args = parser.parse_args(argv)

    paths = find_metrics_files(args.model_dir)
    if not paths:
        print("No training runs found")
        return 0

    runs = [parse_metrics(p) for p in paths]
    runs = [r for r in runs if r]  # drop parse failures

    if not runs:
        print("No training runs found")
        return 0

    if args.limit and args.limit > 0:
        runs = runs[-args.limit:]

    print_table(runs)
    print_summary(runs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
