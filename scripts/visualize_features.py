#!/usr/bin/env python3
"""Print ASCII feature distribution charts for field CSV data.

Usage:
    python scripts/visualize_features.py
    python scripts/visualize_features.py --data-dir ./data/field
    python scripts/visualize_features.py --data-dir ./data/field --features ppv,freq,kurtosis

Output example:
    PPV Distribution (N=500 samples):
      0.00-0.10: ████████████████████ 200 (40.0%)
      0.10-0.20: ████████████ 120 (24.0%)
      ...
      Per-class:
        normal:            mean=0.05  std=0.03  max=0.29
        soil_creep:        mean=0.85  std=0.42  max=2.10
        crack_propagation: mean=1.20  std=0.65  max=3.00
        imminent_failure:  mean=4.50  std=1.20  max=8.00

Uses only stdlib — no matplotlib or numpy required.
"""

import argparse
import csv
import math
import os
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_FEATURES = ["ppv", "freq", "kurtosis", "crest", "stalta"]
ALL_CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]
BAR_CHAR = "\u2588"   # Unicode full block  ░▒▓█
MAX_BAR_WIDTH = 40    # characters for 100%
NUM_BINS = 10


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def load_all_csv(data_dir: str) -> list:
    """Load all CSV files from data_dir; return list of row dicts."""
    rows = []
    if not os.path.isdir(data_dir):
        return rows
    for fname in sorted(os.listdir(data_dir)):
        if not fname.endswith(".csv"):
            continue
        fpath = os.path.join(data_dir, fname)
        try:
            with open(fpath, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(dict(row))
        except (OSError, csv.Error):
            pass
    return rows


# ---------------------------------------------------------------------------
# Histogram computation
# ---------------------------------------------------------------------------

def build_histogram(values: list, num_bins: int = NUM_BINS) -> dict:
    """Compute a histogram of numeric values.

    Args:
        values: List of floats.
        num_bins: Number of equal-width bins.

    Returns:
        Dict with keys:
          'bins': list of (low, high) tuples
          'counts': list of int (one per bin)
          'total': int total count
          'min': float
          'max': float
    """
    if not values:
        return {
            "bins": [],
            "counts": [],
            "total": 0,
            "min": 0.0,
            "max": 0.0,
        }

    v_min = min(values)
    v_max = max(values)

    # Avoid zero-width range
    if v_min == v_max:
        v_max = v_min + 1.0

    bin_width = (v_max - v_min) / num_bins
    counts = [0] * num_bins
    bins = []
    for i in range(num_bins):
        lo = v_min + i * bin_width
        hi = v_min + (i + 1) * bin_width
        bins.append((lo, hi))

    for v in values:
        idx = int((v - v_min) / bin_width)
        if idx >= num_bins:
            idx = num_bins - 1
        counts[idx] += 1

    return {
        "bins": bins,
        "counts": counts,
        "total": len(values),
        "min": v_min,
        "max": v_max,
    }


# ---------------------------------------------------------------------------
# Per-class statistics
# ---------------------------------------------------------------------------

def compute_stats(values: list) -> dict:
    """Compute mean, std, min, max for a list of floats.

    Returns dict with keys 'mean', 'std', 'min', 'max', or None if empty.
    """
    if not values:
        return None
    n = len(values)
    mean = sum(values) / n
    variance = sum((v - mean) ** 2 for v in values) / n if n > 1 else 0.0
    std = math.sqrt(variance)
    return {
        "mean": mean,
        "std": std,
        "min": min(values),
        "max": max(values),
        "count": n,
    }


def per_class_stats(rows: list, feature: str, class_names: list) -> dict:
    """Compute stats per class for a given feature.

    Args:
        rows: List of CSV row dicts.
        feature: Feature column name.
        class_names: List of known class names.

    Returns:
        Dict mapping class_name -> stats dict (or None if no samples).
    """
    buckets = {name: [] for name in class_names}
    for row in rows:
        label = row.get("label", "").strip().lower()
        raw = row.get(feature)
        if raw is None or raw == "":
            continue
        try:
            val = float(raw)
        except ValueError:
            continue
        if label in buckets:
            buckets[label].append(val)
        else:
            # Unknown label — add to a catch-all
            buckets.setdefault("other", []).append(val)

    return {name: compute_stats(vals) for name, vals in buckets.items()}


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------

def _bar(count: int, total: int, max_width: int = MAX_BAR_WIDTH) -> str:
    """Return an ASCII bar proportional to count/total."""
    if total == 0:
        return ""
    width = int(count / total * max_width)
    return BAR_CHAR * width


def render_histogram(feature: str, hist: dict, stats_by_class: dict) -> str:
    """Render a full histogram block as a string.

    Args:
        feature: Feature name (used for title).
        hist: Output of build_histogram().
        stats_by_class: Output of per_class_stats().

    Returns:
        Multi-line string ready to print.
    """
    lines = []
    total = hist["total"]
    title = feature.upper()
    lines.append(f"\n{title} Distribution (N={total} samples):")

    if total == 0:
        lines.append("  (no data)")
    else:
        for i, (lo, hi) in enumerate(hist["bins"]):
            count = hist["counts"][i]
            bar = _bar(count, total)
            pct = count / total * 100
            lines.append(f"  {lo:7.2f}-{hi:7.2f}: {bar:<{MAX_BAR_WIDTH}} {count:5d} ({pct:5.1f}%)")

    # Per-class stats
    lines.append("  Per-class:")
    # Collect known classes in order, then any extras
    ordered = list(ALL_CLASS_NAMES)
    for name in stats_by_class:
        if name not in ordered:
            ordered.append(name)

    for name in ordered:
        st = stats_by_class.get(name)
        if st is None:
            continue
        label_pad = f"{name}:"
        lines.append(
            f"    {label_pad:<26} mean={st['mean']:7.4f}  "
            f"std={st['std']:7.4f}  max={st['max']:7.4f}  n={st['count']}"
        )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print ASCII feature distribution charts for field CSV data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        metavar="DIR",
        help="Directory containing field CSV files (default: ./data/field).",
    )
    parser.add_argument(
        "--features",
        default=",".join(DEFAULT_FEATURES),
        metavar="FEATURES",
        help=(
            f"Comma-separated feature names to visualize "
            f"(default: {','.join(DEFAULT_FEATURES)})."
        ),
    )
    args = parser.parse_args()

    features = [f.strip() for f in args.features.split(",") if f.strip()]
    data_dir = args.data_dir

    rows = load_all_csv(data_dir)

    if not rows:
        print(f"No data found in '{data_dir}'.")
        return

    print(f"Loaded {len(rows)} rows from {data_dir}")

    for feature in features:
        # Extract numeric values for this feature
        values = []
        for row in rows:
            raw = row.get(feature)
            if raw is None or raw == "":
                continue
            try:
                values.append(float(raw))
            except ValueError:
                pass

        if not values:
            print(f"\n{feature.upper()}: no numeric data found in CSV.")
            continue

        hist = build_histogram(values, num_bins=NUM_BINS)
        stats = per_class_stats(rows, feature, ALL_CLASS_NAMES)
        output = render_histogram(feature, hist, stats)
        print(output)

    print()


if __name__ == "__main__":
    main()
