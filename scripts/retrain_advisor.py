#!/usr/bin/env python3
"""
retrain_advisor.py — Evaluate whether ML model retraining is recommended.

Usage:
    python scripts/retrain_advisor.py [--data-dir DIR] [--model-dir DIR]

Checks: data volume, data age, class imbalance, drift signals.
Prints recommendation: RETRAIN_NOW, RETRAIN_SOON, or NO_ACTION.
Exit code:
  0 = NO_ACTION
  1 = RETRAIN_SOON
  2 = RETRAIN_NOW
"""

import argparse
import csv
import os
import sys
import time
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data")
DEFAULT_MODEL_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")
TFLITE_MODEL = "precursor_classifier.tflite"
BASELINE_FILE = os.path.join(REPO_DIR, "data", "drift_baseline.json")

# Scoring thresholds
SCORE_NO_ACTION = 2
SCORE_RETRAIN_SOON = 4

# Import drift logic from data_drift_detector (same package, no subprocess)
try:
    # Allow running from scripts/ dir or repo root
    if SCRIPT_DIR not in sys.path:
        sys.path.insert(0, SCRIPT_DIR)
    from data_drift_detector import (
        load_csv_files,
        compute_stats,
        detect_drift,
        FEATURES as DRIFT_FEATURES,
    )
    _DRIFT_AVAILABLE = True
except ImportError:
    _DRIFT_AVAILABLE = False


# ---------------------------------------------------------------------------
# Signal checks
# ---------------------------------------------------------------------------

def _count_samples(data_dir: str) -> int:
    """Count total CSV rows across all files in data_dir."""
    rows = load_csv_files(data_dir) if _DRIFT_AVAILABLE else _fallback_load(data_dir)
    return len(rows)


def _fallback_load(data_dir: str) -> list:
    """Minimal CSV loader when data_drift_detector is unavailable."""
    rows = []
    if not os.path.isdir(data_dir):
        return rows
    for fname in sorted(os.listdir(data_dir)):
        if not fname.endswith(".csv"):
            continue
        fpath = os.path.join(data_dir, fname)
        try:
            with open(fpath, newline="", encoding="utf-8") as fh:
                reader = csv.DictReader(fh)
                rows.extend(list(reader))
        except OSError:
            pass
    return rows


def _data_age_days(data_dir: str) -> float:
    """Return age of oldest CSV file in data_dir, in days. Returns 0 if none."""
    oldest_mtime = None
    if not os.path.isdir(data_dir):
        return 0.0
    for fname in os.listdir(data_dir):
        if not fname.endswith(".csv"):
            continue
        fpath = os.path.join(data_dir, fname)
        try:
            mtime = os.path.getmtime(fpath)
            if oldest_mtime is None or mtime < oldest_mtime:
                oldest_mtime = mtime
        except OSError:
            pass
    if oldest_mtime is None:
        return 0.0
    return (time.time() - oldest_mtime) / 86400.0


def _class_imbalance(data_dir: str) -> tuple:
    """
    Check class imbalance in CSV data.

    Returns (is_imbalanced: bool, class_counts: dict, minority_pct: float).
    A class is considered imbalanced if it represents < 10% of total samples.
    """
    rows = load_csv_files(data_dir) if _DRIFT_AVAILABLE else _fallback_load(data_dir)
    if not rows:
        return False, {}, 100.0

    counts = {}
    for row in rows:
        label = row.get("label", row.get("anomaly_level", "unknown"))
        counts[label] = counts.get(label, 0) + 1

    total = sum(counts.values())
    if total == 0:
        return False, counts, 100.0

    min_pct = min(v / total * 100.0 for v in counts.values())
    imbalanced = min_pct < 10.0
    return imbalanced, counts, min_pct


def _check_drift(data_dir: str) -> bool:
    """Return True if significant drift is detected against the saved baseline."""
    if not _DRIFT_AVAILABLE:
        return False
    if not os.path.isfile(BASELINE_FILE):
        return False
    import json
    try:
        with open(BASELINE_FILE, encoding="utf-8") as fh:
            baseline_stats = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return False

    rows = load_csv_files(data_dir)
    if not rows:
        return False

    current_stats = compute_stats(rows, DRIFT_FEATURES)
    results = detect_drift(current_stats, baseline_stats, DRIFT_FEATURES)
    return any(r["status"] == "DRIFT" for r in results)


def _model_age_days(model_dir: str) -> float:
    """Return age of the TFLite model in days. Returns 0 if not found."""
    model_path = os.path.join(model_dir, TFLITE_MODEL)
    if not os.path.isfile(model_path):
        return 0.0
    mtime = os.path.getmtime(model_path)
    return (time.time() - mtime) / 86400.0


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def evaluate(data_dir: str, model_dir: str) -> tuple:
    """
    Run all checks and return (score, signals) where signals is a list of
    (signal_name, value_str, points, description) tuples.
    """
    signals = []
    score = 0

    # 1. Data volume
    n_samples = _count_samples(data_dir)
    if n_samples > 500:
        pts = 2
        desc = "> 500 new samples"
    elif n_samples > 200:
        pts = 1
        desc = "> 200 new samples"
    else:
        pts = 0
        desc = "<= 200 new samples"
    score += pts
    signals.append(("Data volume", f"{n_samples} samples", pts, desc))

    # 2. Class imbalance
    imbalanced, class_counts, min_pct = _class_imbalance(data_dir)
    if imbalanced:
        pts = 2
        desc = f"minority class at {min_pct:.1f}% (< 10%)"
    else:
        pts = 0
        if class_counts:
            desc = f"balanced (min class {min_pct:.1f}%)"
        else:
            desc = "no labeled data"
    score += pts
    signals.append(("Class imbalance", f"min={min_pct:.1f}%" if class_counts else "N/A", pts, desc))

    # 3. Data drift
    drift_detected = _check_drift(data_dir)
    if drift_detected:
        pts = 3
        desc = "significant drift vs baseline"
    else:
        pts = 0
        desc = "no significant drift" if os.path.isfile(BASELINE_FILE) else "no baseline available"
    score += pts
    signals.append(("Data drift", "YES" if drift_detected else "NO", pts, desc))

    # 4. Model age
    model_age = _model_age_days(model_dir)
    if model_age > 30:
        pts = 2
        desc = f"model {model_age:.0f}d old (> 30d)"
    elif model_age > 7:
        pts = 1
        desc = f"model {model_age:.0f}d old (> 7d)"
    else:
        pts = 0
        if model_age > 0:
            desc = f"model {model_age:.1f}d old (fresh)"
        else:
            desc = "model not found"
    score += pts
    signals.append(("Model age", f"{model_age:.1f}d" if model_age > 0 else "N/A", pts, desc))

    return score, signals


def _recommendation(score: int) -> str:
    if score >= 5:
        return "RETRAIN_NOW"
    elif score >= 3:
        return "RETRAIN_SOON"
    else:
        return "NO_ACTION"


def _exit_code(recommendation: str) -> int:
    return {"NO_ACTION": 0, "RETRAIN_SOON": 1, "RETRAIN_NOW": 2}[recommendation]


def _print_table(signals: list, score: int) -> None:
    max_score = 8  # 2 + 2 + 3 + 2 = 9 theoretical max, but 8 is typical ceiling
    print("Retrain Advisor — Signal Summary")
    print("-" * 68)
    print(f"  {'Signal':<20} {'Value':>12} {'Points':>7}  Notes")
    print("  " + "-" * 64)
    for name, value, pts, desc in signals:
        print(f"  {name:<20} {value:>12} {('+' + str(pts) if pts > 0 else str(pts)):>7}  {desc}")
    print("  " + "-" * 64)
    print(f"  {'TOTAL':<20} {'':>12} {score:>7}")
    print()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Evaluate whether ML model retraining is recommended."
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        help="Directory containing field CSV files (default: ./data)",
    )
    parser.add_argument(
        "--model-dir",
        default=DEFAULT_MODEL_DIR,
        help="Directory containing TFLite model (default: app/assets/ml)",
    )
    args = parser.parse_args(argv)

    score, signals = evaluate(args.data_dir, args.model_dir)
    rec = _recommendation(score)

    _print_table(signals, score)

    max_score = sum(s[2] for s in signals) or 1
    possible = 9  # 2+2+3+2
    print(f"*** {rec}: Score {score}/{possible} ***")
    print()

    rc = _exit_code(rec)
    sys.exit(rc)


if __name__ == "__main__":
    main()
