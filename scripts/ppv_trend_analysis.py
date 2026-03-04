#!/usr/bin/env python3
"""
ppv_trend_analysis.py — Analyze PPV trend acceleration in collected field data.

Usage:
    python scripts/ppv_trend_analysis.py [--data-dir DIR] [--window MINUTES]

Computes rolling mean PPV in windows of --window minutes (default 10).
Detects trend: stable, increasing, decreasing, or accelerating.
"Accelerating" = rolling mean increases by >20% per consecutive window.
Outputs ASCII line chart and trend summary.
"""

import argparse
import csv
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data")
DEFAULT_WINDOW_MINUTES = 10

# Trend detection parameters
STABLE_THRESHOLD = 0.05       # < 5% change per window → STABLE
ACCELERATING_THRESHOLD = 1.20  # each window > 120% of previous → ACCELERATING

# ASCII chart dimensions
CHART_ROWS = 10
CHART_COLS = 40


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


def _parse_timestamp(ts_str: str) -> float:
    """Parse ISO 8601 timestamp to Unix epoch float. Returns -1 on failure."""
    if not ts_str:
        return -1.0
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
    ):
        try:
            dt = datetime.strptime(ts_str, fmt)
            dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            continue
    return -1.0


def prepare_series(rows: list) -> list:
    """
    Extract and sort (timestamp, ppv) pairs from rows.
    Skips rows with invalid timestamps or ppv.
    Returns list of (float, float) sorted by timestamp.
    """
    series = []
    for row in rows:
        ts = _parse_timestamp(row.get("timestamp", ""))
        if ts < 0:
            continue
        try:
            ppv = float(row.get("ppv", "0") or "0")
        except (ValueError, TypeError):
            ppv = 0.0
        series.append((ts, ppv))
    series.sort(key=lambda x: x[0])
    return series


def compute_window_means(series: list, window_s: float) -> list:
    """
    Compute mean PPV per time window of `window_s` seconds.

    Returns list of (window_center_ts, mean_ppv) for each window that
    contains at least one reading.
    """
    if not series:
        return []

    start_ts = series[0][0]
    end_ts = series[-1][0]

    # Build windows
    windows = []
    w_start = start_ts
    while w_start <= end_ts:
        w_end = w_start + window_s
        bucket = [ppv for ts, ppv in series if w_start <= ts < w_end]
        if bucket:
            mean_ppv = sum(bucket) / len(bucket)
            center = (w_start + w_end) / 2.0
            windows.append((center, mean_ppv))
        w_start = w_end

    return windows


def classify_trend(window_means: list) -> str:
    """
    Classify trend from a list of (ts, mean_ppv) pairs.

    Rules (applied in order):
      ACCELERATING : every consecutive pair satisfies next > 1.20 * prev
                     (requires at least 2 windows)
      STABLE       : max fractional change < STABLE_THRESHOLD across all pairs
      INCREASING   : all changes >= 0 (and not STABLE)
      DECREASING   : all changes <= 0 (and not STABLE)
      VARIABLE     : none of the above
    """
    if len(window_means) < 2:
        return "STABLE"

    values = [v for _, v in window_means]

    # Compute fractional changes between consecutive windows
    changes = []
    for i in range(1, len(values)):
        prev = values[i - 1]
        curr = values[i]
        if prev > 0:
            frac = (curr - prev) / prev
        else:
            # treat jump from 0 as large positive if curr > 0, else 0
            frac = 1.0 if curr > 0 else 0.0
        changes.append(frac)

    # ACCELERATING: every window is > 120% of the previous
    if all(frac > (ACCELERATING_THRESHOLD - 1.0) for frac in changes):
        return "ACCELERATING"

    # STABLE: max absolute fractional change < threshold
    if max(abs(c) for c in changes) < STABLE_THRESHOLD:
        return "STABLE"

    # INCREASING: all changes >= 0
    if all(c >= 0 for c in changes):
        return "INCREASING"

    # DECREASING: all changes <= 0
    if all(c <= 0 for c in changes):
        return "DECREASING"

    return "VARIABLE"


def build_ascii_chart(window_means: list, rows: int = CHART_ROWS, cols: int = CHART_COLS) -> list:
    """
    Build a 2-D ASCII line chart as a list of strings (one per line).

    10 rows × up to 40 columns (one column per window, capped at cols).
    Returns list of strings to print.
    """
    if not window_means:
        return ["(no data to chart)"]

    values = [v for _, v in window_means]

    # Subsample to at most `cols` columns
    if len(values) > cols:
        # Pick evenly spaced indices
        step = len(values) / cols
        sampled = [values[int(i * step)] for i in range(cols)]
    else:
        sampled = list(values)

    n_cols = len(sampled)
    max_val = max(sampled) if sampled else 1.0
    min_val = min(sampled) if sampled else 0.0
    val_range = max_val - min_val if max_val != min_val else 1.0

    # Map each value to a row index (0 = top, rows-1 = bottom)
    def _row_idx(v: float) -> int:
        normalized = (v - min_val) / val_range  # 0..1
        r = int((1.0 - normalized) * (rows - 1))
        return max(0, min(rows - 1, r))

    # Build grid
    grid = [[" "] * n_cols for _ in range(rows)]
    for col_i, val in enumerate(sampled):
        r = _row_idx(val)
        grid[r][col_i] = "*"

    # Format with Y-axis labels
    chart_lines = []
    for row_i in range(rows):
        y_val = max_val - (row_i / (rows - 1)) * val_range if rows > 1 else max_val
        label = f"{y_val:6.3f} |"
        line = label + "".join(grid[row_i])
        chart_lines.append(line)

    # X-axis
    x_axis = "       +" + "-" * n_cols
    chart_lines.append(x_axis)
    chart_lines.append(f"        Time -->  ({n_cols} windows of data)")

    return chart_lines


def main(argv=None):
    """Entry point. Always exits 0."""
    parser = argparse.ArgumentParser(
        description="Analyze PPV trend acceleration in collected field data."
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        help=f"Directory containing field CSV files (default: {DEFAULT_DATA_DIR})",
    )
    parser.add_argument(
        "--window",
        type=float,
        default=DEFAULT_WINDOW_MINUTES,
        help=f"Window size in minutes for rolling mean (default: {DEFAULT_WINDOW_MINUTES})",
    )
    args = parser.parse_args(argv)

    rows = load_csv_files(args.data_dir)
    series = prepare_series(rows)

    if not series:
        print("No data found")
        sys.exit(0)

    window_s = args.window * 60.0
    window_means = compute_window_means(series, window_s)

    if not window_means:
        print("No data found")
        sys.exit(0)

    trend = classify_trend(window_means)
    n_windows = len(window_means)
    overall_min = min(v for _, v in window_means)
    overall_max = max(v for _, v in window_means)
    overall_mean = sum(v for _, v in window_means) / n_windows

    # Print chart
    print(f"\nPPV Trend Analysis  ({n_windows} windows x {args.window:.0f} min)\n")
    chart_lines = build_ascii_chart(window_means)
    for line in chart_lines:
        print(line)

    # Print summary
    print()
    print("=" * 50)
    print(f"  Windows:     {n_windows}")
    print(f"  Min PPV:     {overall_min:.4f} mm/s")
    print(f"  Max PPV:     {overall_max:.4f} mm/s")
    print(f"  Mean PPV:    {overall_mean:.4f} mm/s")
    print(f"  Trend:       {trend}")
    if trend == "ACCELERATING":
        print()
        print("  *** WARNING: ACCELERATING trend detected! ***")
        print("  *** Each window PPV >20% higher than previous. ***")
        print("  *** This is an early warning signal for avalanche precursor. ***")
    print("=" * 50)
    print()

    sys.exit(0)


if __name__ == "__main__":
    main()
