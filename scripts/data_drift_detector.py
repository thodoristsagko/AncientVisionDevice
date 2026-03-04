#!/usr/bin/env python3
"""
data_drift_detector.py — Detect data drift between collected field data and training baseline.

Usage:
    python scripts/data_drift_detector.py [--data-dir DIR] [--baseline FILE] [--save-baseline]

Computes statistical distribution of PPV, ax/ay/az values from CSV data.
Compares against saved baseline using simple mean/std deviation test.
Flags features where current distribution deviates >2 sigma from baseline.
Exit code 1 if significant drift detected, 0 otherwise.
"""

import argparse
import csv
import json
import math
import os
import sys
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_BASELINE = os.path.join(REPO_DIR, "data", "drift_baseline.json")
FEATURES = ["ppv", "ax", "ay", "az"]

# Drift thresholds
MEAN_SIGMA_THRESHOLD = 2.0   # flag if |current_mean - baseline_mean| > 2 * baseline_std
VARIANCE_RATIO_THRESHOLD = 3.0  # flag if current_std > 3 * baseline_std


def load_csv_files(data_dir: str) -> list:
    """Load all CSV rows from data_dir. Returns list of dicts."""
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


def compute_stats(rows: list, features: list) -> dict:
    """
    Compute per-feature statistics from a list of CSV row dicts.

    Returns dict mapping feature name to:
        mean, std, min, max, p25, p50, p75, p95, n
    """
    buckets = {f: [] for f in features}
    for row in rows:
        for feat in features:
            val = row.get(feat)
            if val is None:
                continue
            try:
                buckets[feat].append(float(val))
            except (ValueError, TypeError):
                pass

    stats = {}
    for feat, vals in buckets.items():
        n = len(vals)
        if n == 0:
            continue
        vals_sorted = sorted(vals)
        mean = sum(vals) / n
        variance = sum((v - mean) ** 2 for v in vals) / n if n > 1 else 0.0
        std = math.sqrt(variance)

        def _percentile(sorted_vals, pct):
            idx = pct / 100.0 * (len(sorted_vals) - 1)
            lo = int(idx)
            hi = min(lo + 1, len(sorted_vals) - 1)
            frac = idx - lo
            return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac

        stats[feat] = {
            "n": n,
            "mean": mean,
            "std": std,
            "min": vals_sorted[0],
            "max": vals_sorted[-1],
            "p25": _percentile(vals_sorted, 25),
            "p50": _percentile(vals_sorted, 50),
            "p75": _percentile(vals_sorted, 75),
            "p95": _percentile(vals_sorted, 95),
        }
    return stats


def detect_drift(current_stats: dict, baseline_stats: dict, features: list) -> list:
    """
    Compare current stats against baseline.

    Returns list of dicts with drift results per feature.
    Each dict has keys: feature, baseline_mean, current_mean, baseline_std,
    current_std, drift_score, mean_drift, variance_drift, status.
    """
    results = []
    for feat in features:
        if feat not in current_stats or feat not in baseline_stats:
            continue

        cur = current_stats[feat]
        base = baseline_stats[feat]

        b_mean = base["mean"]
        b_std = base["std"]
        c_mean = cur["mean"]
        c_std = cur["std"]

        # Avoid division by zero
        safe_b_std = max(b_std, 1e-12)

        # Mean drift: deviation in units of baseline std
        mean_drift_score = abs(c_mean - b_mean) / safe_b_std
        mean_drift = mean_drift_score > MEAN_SIGMA_THRESHOLD

        # Variance explosion: current std relative to baseline std
        variance_ratio = c_std / safe_b_std
        variance_drift = variance_ratio > VARIANCE_RATIO_THRESHOLD

        drift_score = mean_drift_score
        status = "DRIFT" if (mean_drift or variance_drift) else "OK"

        results.append({
            "feature": feat,
            "baseline_mean": b_mean,
            "current_mean": c_mean,
            "baseline_std": b_std,
            "current_std": c_std,
            "drift_score": drift_score,
            "mean_drift": mean_drift,
            "variance_drift": variance_drift,
            "status": status,
        })
    return results


def print_drift_table(results: list) -> None:
    """Print ASCII table of drift results."""
    header = (
        f"  {'Feature':<10} {'Base_mean':>10} {'Curr_mean':>10} "
        f"{'Base_std':>9} {'Curr_std':>9} {'DriftScore':>11} {'Status'}"
    )
    separator = "  " + "-" * 74
    print(header)
    print(separator)
    for r in results:
        print(
            f"  {r['feature']:<10} {r['baseline_mean']:>10.4f} {r['current_mean']:>10.4f} "
            f"{r['baseline_std']:>9.4f} {r['current_std']:>9.4f} {r['drift_score']:>11.2f} "
            f"  {r['status']}"
        )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Detect data drift between collected field data and training baseline."
    )
    parser.add_argument(
        "--data-dir",
        default=os.path.join(REPO_DIR, "data"),
        help="Directory containing field CSV files (default: ./data)",
    )
    parser.add_argument(
        "--baseline",
        default=DEFAULT_BASELINE,
        help="Path to baseline JSON file (default: data/drift_baseline.json)",
    )
    parser.add_argument(
        "--save-baseline",
        action="store_true",
        help="Save current data statistics as the new baseline (does not compare)",
    )
    args = parser.parse_args(argv)

    rows = load_csv_files(args.data_dir)

    if not rows:
        print(f"No CSV data found in {args.data_dir}")
        if not args.save_baseline:
            print("No baseline found — run with --save-baseline first" if not os.path.isfile(args.baseline)
                  else "No data to compare.")
        sys.exit(0)

    current_stats = compute_stats(rows, FEATURES)

    if args.save_baseline:
        baseline_path = args.baseline
        os.makedirs(os.path.dirname(baseline_path) if os.path.dirname(baseline_path) else ".", exist_ok=True)
        with open(baseline_path, "w", encoding="utf-8") as fh:
            json.dump(current_stats, fh, indent=2)
        print(f"Baseline saved to: {baseline_path}")
        print(f"  Features: {list(current_stats.keys())}")
        for feat, s in current_stats.items():
            print(f"  {feat}: mean={s['mean']:.4f}, std={s['std']:.4f}, n={s['n']}")
        sys.exit(0)

    # Load baseline
    if not os.path.isfile(args.baseline):
        print("No baseline found — run with --save-baseline first")
        sys.exit(0)

    with open(args.baseline, encoding="utf-8") as fh:
        baseline_stats = json.load(fh)

    print(f"Loaded {len(rows)} samples from {args.data_dir}")
    print(f"Baseline: {args.baseline}")
    print()

    results = detect_drift(current_stats, baseline_stats, FEATURES)

    if not results:
        print("No features in common between current data and baseline.")
        sys.exit(0)

    print("Drift Analysis:")
    print_drift_table(results)
    print()

    drifted = [r for r in results if r["status"] == "DRIFT"]
    if drifted:
        print(f"  {len(drifted)} feature(s) show significant drift:")
        for r in drifted:
            reasons = []
            if r["mean_drift"]:
                reasons.append(f"mean shift {r['drift_score']:.2f}σ")
            if r["variance_drift"]:
                reasons.append(f"variance x{r['current_std'] / max(r['baseline_std'], 1e-12):.1f}")
            print(f"    {r['feature']}: {', '.join(reasons)}")
        sys.exit(1)
    else:
        print("  No significant drift detected")
        sys.exit(0)


if __name__ == "__main__":
    main()
