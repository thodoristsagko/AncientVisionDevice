#!/usr/bin/env python3
"""
Report on training data distribution and augmentation potential.

Scans ./data/field/*.csv for labeled samples, counts per class,
identifies under-represented classes and recommends augmentation targets.

Usage:
    python scripts/data_augmentation_report.py [--data-dir ./data/field]
    python scripts/data_augmentation_report.py --data-dir ./data/field --output report.json
    python scripts/data_augmentation_report.py --min-samples 500
"""

import argparse
import csv
import json
import os
import sys
from pathlib import Path

import numpy as np

# Force UTF-8 output on Windows so block-character bar charts render correctly.
if sys.platform == "win32":
    try:
        import io as _io
        sys.stdout = _io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LABELS = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]

# Features we report statistics for
STAT_FEATURES = ["ppv", "rms", "crest", "kurtosis"]

# Fraction of majority class below which a class is under-represented
UNDER_REP_THRESHOLD = 0.50

# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------


def load_field_csvs(data_dir: Path) -> list:
    """
    Load all CSV files in data_dir.

    Returns list of dicts (one per sample row).
    Rows with missing or empty 'label' are skipped.
    """
    rows = []
    csv_files = sorted(data_dir.glob("*.csv"))
    if not csv_files:
        return rows

    for csv_path in csv_files:
        try:
            with open(csv_path, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for r in reader:
                    label = (r.get("label") or "").strip()
                    if not label:
                        continue
                    rows.append(r)
        except Exception as exc:
            print(f"  Warning: could not read {csv_path.name}: {exc}", file=sys.stderr)

    return rows


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------


def count_per_class(rows: list) -> dict:
    counts = {lbl: 0 for lbl in LABELS}
    for r in rows:
        lbl = r.get("label", "").strip()
        if lbl in counts:
            counts[lbl] += 1
        else:
            counts[lbl] = counts.get(lbl, 0) + 1
    return counts


def feature_stats_per_class(rows: list, features: list) -> dict:
    """
    Compute mean, std for each (class, feature) combination.

    Returns nested dict: result[label][feature] = {"mean": float, "std": float, "n": int}
    """
    # Accumulate raw values
    buckets = {lbl: {f: [] for f in features} for lbl in LABELS}

    for r in rows:
        lbl = r.get("label", "").strip()
        if lbl not in buckets:
            continue
        for f in features:
            raw = r.get(f, "")
            try:
                buckets[lbl][f].append(float(raw))
            except (ValueError, TypeError):
                pass

    result = {}
    for lbl in LABELS:
        result[lbl] = {}
        for f in features:
            vals = buckets[lbl][f]
            if vals:
                arr = np.array(vals, dtype=np.float64)
                result[lbl][f] = {
                    "mean": float(np.mean(arr)),
                    "std":  float(np.std(arr)),
                    "n":    len(arr),
                }
            else:
                result[lbl][f] = {"mean": 0.0, "std": 0.0, "n": 0}

    return result


def count_outliers_per_class(rows: list, features: list, stats: dict, threshold: float = 3.0) -> dict:
    """
    Count samples that have at least one feature > threshold std from the class mean.

    Returns {label: outlier_count}
    """
    outliers = {lbl: 0 for lbl in LABELS}

    for r in rows:
        lbl = r.get("label", "").strip()
        if lbl not in outliers:
            continue
        is_outlier = False
        for f in features:
            raw = r.get(f, "")
            try:
                val = float(raw)
            except (ValueError, TypeError):
                continue
            mean = stats[lbl][f]["mean"]
            std  = stats[lbl][f]["std"]
            if std > 0 and abs(val - mean) > threshold * std:
                is_outlier = True
                break
        if is_outlier:
            outliers[lbl] += 1

    return outliers


# ---------------------------------------------------------------------------
# Augmentation recommendations
# ---------------------------------------------------------------------------


def augmentation_recommendations(counts: dict, min_samples: int) -> dict:
    """
    For each class, decide how many synthetic samples to add.

    Rules:
    - The target for each class is max(majority_count, min_samples).
    - If a class has < UNDER_REP_THRESHOLD * majority_count → under-represented.
    - Recommended additions = target - current_count  (0 if already at target).

    Returns {label: {"current": int, "target": int, "to_add": int, "status": str}}
    """
    majority = max(counts.values()) if counts else 0
    target_base = max(majority, min_samples)

    recs = {}
    for lbl in LABELS:
        current = counts.get(lbl, 0)
        target  = target_base
        to_add  = max(0, target - current)

        if majority == 0:
            status = "NO DATA"
        elif current < UNDER_REP_THRESHOLD * majority:
            ratio = majority / max(current, 1)
            status = f"UNDER-REPRESENTED: augment to {ratio:.1f}x"
        elif current < min_samples:
            status = "BELOW MINIMUM: needs more samples"
        else:
            status = "OK"

        recs[lbl] = {
            "current": current,
            "target":  target,
            "to_add":  to_add,
            "status":  status,
        }

    return recs


# ---------------------------------------------------------------------------
# ASCII bar chart
# ---------------------------------------------------------------------------

BAR_WIDTH = 40


def _bar(value: int, max_value: int, width: int = BAR_WIDTH) -> str:
    if max_value == 0:
        return " " * width
    filled = int(round(width * value / max_value))
    filled = min(filled, width)
    return "\u2588" * filled + " " * (width - filled)


# ---------------------------------------------------------------------------
# Print helpers
# ---------------------------------------------------------------------------

LINE_W = 80


def _section(title: str):
    print()
    print("=" * LINE_W)
    print(f"  {title}")
    print("=" * LINE_W)


def print_class_distribution(counts: dict):
    _section("Class Distribution")
    max_count = max(counts.values()) if counts.values() else 1
    total = sum(counts.values())

    print(f"  {'Class':<24} {'Count':>6}  {'%':>5}  Bar")
    print(f"  {'-'*24} {'-'*6}  {'-'*5}  {'-'*BAR_WIDTH}")

    for lbl in LABELS:
        count = counts.get(lbl, 0)
        pct   = 100.0 * count / total if total > 0 else 0.0
        bar   = _bar(count, max_count)
        print(f"  {lbl:<24} {count:>6}  {pct:>4.1f}%  {bar}")

    print(f"\n  Total samples: {total}")
    if total > 0 and max(counts.values()) > 0 and min(counts.values()) > 0:
        imbalance = max(counts.values()) / min(counts.values())
        print(f"  Class imbalance ratio (max/min): {imbalance:.2f}x")


def print_augmentation_plan(recs: dict):
    _section("Augmentation Recommendations")
    print(f"  {'Class':<24} {'Current':>8} {'Target':>8} {'To Add':>8}  Status")
    print(f"  {'-'*24} {'-'*8} {'-'*8} {'-'*8}  {'-'*40}")

    any_needed = False
    for lbl in LABELS:
        r = recs[lbl]
        to_add_str = f"+{r['to_add']}" if r["to_add"] > 0 else "—"
        print(f"  {lbl:<24} {r['current']:>8} {r['target']:>8} {to_add_str:>8}  {r['status']}")
        if r["to_add"] > 0:
            any_needed = True

    if not any_needed:
        print("\n  All classes are adequately represented.")
    else:
        print("\n  Run `make augment` or `python scripts/augment_training_data.py` to add synthetic samples.")


def print_feature_stats(stats: dict):
    _section("Feature Statistics per Class")

    for lbl in LABELS:
        print(f"\n  [{lbl}]")
        if not any(stats[lbl][f]["n"] > 0 for f in STAT_FEATURES):
            print("    No data.")
            continue
        print(f"    {'Feature':<16} {'Mean':>10} {'Std':>10} {'N':>6}")
        print(f"    {'-'*16} {'-'*10} {'-'*10} {'-'*6}")
        for f in STAT_FEATURES:
            s = stats[lbl][f]
            if s["n"] > 0:
                print(f"    {f:<16} {s['mean']:>10.4f} {s['std']:>10.4f} {s['n']:>6}")
            else:
                print(f"    {f:<16} {'N/A':>10} {'N/A':>10} {0:>6}")


def print_outliers(outliers: dict, counts: dict):
    _section("Outlier Summary  (samples > 3 std from class mean on any feature)")
    print(f"  {'Class':<24} {'Outliers':>10} {'Total':>8} {'%':>7}")
    print(f"  {'-'*24} {'-'*10} {'-'*8} {'-'*7}")
    for lbl in LABELS:
        n_out = outliers.get(lbl, 0)
        n_tot = counts.get(lbl, 0)
        pct   = 100.0 * n_out / n_tot if n_tot > 0 else 0.0
        print(f"  {lbl:<24} {n_out:>10} {n_tot:>8} {pct:>6.1f}%")


# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------


def build_report_dict(counts, recs, stats, outliers, data_dir, n_files):
    return {
        "data_dir":           str(data_dir),
        "csv_files_scanned":  n_files,
        "total_samples":      sum(counts.values()),
        "class_counts":       counts,
        "augmentation_plan":  recs,
        "feature_stats":      stats,
        "outlier_counts":     outliers,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser():
    p = argparse.ArgumentParser(
        description="Report on training data distribution and augmentation potential."
    )
    p.add_argument(
        "--data-dir",
        default="./data/field",
        help="Directory containing field CSV files (default: ./data/field)",
    )
    p.add_argument(
        "--assets-dir",
        default="./app/assets/ml",
        help="ML assets directory (reserved for future use, default: ./app/assets/ml)",
    )
    p.add_argument(
        "--output",
        default=None,
        metavar="FILE",
        help="Write report as JSON to FILE (optional)",
    )
    p.add_argument(
        "--min-samples",
        type=int,
        default=200,
        help="Minimum acceptable samples per class (default: 200)",
    )
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        print(f"Warning: data directory not found: {data_dir}", file=sys.stderr)
        print("  Creating empty report.\n", file=sys.stderr)
        rows = []
        n_files = 0
    else:
        csv_files = sorted(data_dir.glob("*.csv"))
        n_files   = len(csv_files)
        print(f"Scanning {n_files} CSV file(s) in {data_dir}...")
        rows = load_field_csvs(data_dir)

    # Compute statistics
    counts   = count_per_class(rows)
    stats    = feature_stats_per_class(rows, STAT_FEATURES)
    outliers = count_outliers_per_class(rows, STAT_FEATURES, stats)
    recs     = augmentation_recommendations(counts, args.min_samples)

    # Print report
    print_class_distribution(counts)
    print_augmentation_plan(recs)
    print_feature_stats(stats)
    print_outliers(outliers, counts)

    print()
    print("=" * LINE_W)

    # Optionally write JSON
    if args.output:
        report = build_report_dict(counts, recs, stats, outliers, data_dir, n_files)
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with open(out_path, "w") as f:
            json.dump(report, f, indent=2)
        print(f"  Report written to: {out_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
