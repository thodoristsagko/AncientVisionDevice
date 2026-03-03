#!/usr/bin/env python3
"""Diff two field CSV sessions by comparing feature statistics.

Usage:
    python scripts/compare_sessions.py <csv1> <csv2>
    python scripts/compare_sessions.py data/field/session_a.csv data/field/session_b.csv --feature ppv

Compares mean values of standard numeric features across two CSV files and
prints a formatted comparison table.

Output example:

    Session Comparison
    ==================
    File 1: data/field/session_a.csv  (N=300)
    File 2: data/field/session_b.csv  (N=450)

    Feature            File1 Mean   File2 Mean   Diff         % Change
    -------            ----------   ----------   ----         --------
    ppv                     0.123        0.456       +0.333     +270.7%
    rms                     0.089        0.312       +0.223     +250.6%
    ...

    Date ranges:
      File 1: 2025-03-01 09:00 — 2025-03-01 10:00
      File 2: 2025-03-02 08:30 — 2025-03-02 09:45

    Device IDs:
      File 1: DEV001, DEV002
      File 2: DEV001

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

STANDARD_FEATURES = [
    "ppv",
    "rms",
    "freq",
    "kurtosis",
    "psd_slope",
    "arias_intensity",
    "cav",
]

TIMESTAMP_COLS = ("timestamp", "time", "ts", "datetime")
DEVICE_COLS = ("device_id", "device", "id", "node_id")


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def load_csv(path: str) -> list:
    """Load rows from a CSV file; exit with error on failure."""
    if not os.path.isfile(path):
        print(f"Error: file not found: {path}", file=sys.stderr)
        sys.exit(1)
    rows = []
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(dict(row))
    except (OSError, csv.Error) as exc:
        print(f"Error reading {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    return rows


# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------

def extract_values(rows: list, feature: str) -> list:
    """Return list of floats for the given feature column, skipping blanks."""
    values = []
    for row in rows:
        raw = row.get(feature)
        if raw is None or str(raw).strip() == "":
            continue
        try:
            values.append(float(raw))
        except ValueError:
            pass
    return values


def mean_of(values: list) -> float | None:
    """Return mean or None if list is empty."""
    if not values:
        return None
    return sum(values) / len(values)


def detect_column(rows: list, candidates: tuple) -> str | None:
    """Return the first candidate column name present in the data."""
    if not rows:
        return None
    for candidate in candidates:
        if candidate in rows[0]:
            return candidate
    return None


def extract_timestamps(rows: list) -> list:
    """Return all non-empty timestamp strings from rows."""
    col = detect_column(rows, TIMESTAMP_COLS)
    if col is None:
        return []
    ts_list = []
    for row in rows:
        val = row.get(col, "").strip()
        if val:
            ts_list.append(val)
    return ts_list


def extract_device_ids(rows: list) -> set:
    """Return set of unique device_id values from rows."""
    col = detect_column(rows, DEVICE_COLS)
    if col is None:
        return set()
    ids = set()
    for row in rows:
        val = row.get(col, "").strip()
        if val:
            ids.add(val)
    return ids


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def _fmt_val(v: float | None) -> str:
    """Format a float for table display."""
    if v is None:
        return "N/A"
    return f"{v:>12.4f}"


def _fmt_diff(diff: float | None) -> str:
    """Format a signed difference."""
    if diff is None:
        return f"{'N/A':>12}"
    sign = "+" if diff >= 0 else ""
    return f"{sign}{diff:>11.4f}"


def _fmt_pct(pct: float | None) -> str:
    """Format a percentage change."""
    if pct is None:
        return f"{'N/A':>10}"
    sign = "+" if pct >= 0 else ""
    return f"{sign}{pct:>8.1f}%"


# ---------------------------------------------------------------------------
# Comparison logic
# ---------------------------------------------------------------------------

def compare_sessions(
    rows1: list,
    rows2: list,
    path1: str,
    path2: str,
) -> None:
    """Print a full comparison report between two session datasets."""

    # Header
    print("\nSession Comparison")
    print("==================")
    print(f"File 1: {path1}  (N={len(rows1)})")
    print(f"File 2: {path2}  (N={len(rows2)})")
    print()

    # Feature comparison table
    col_w = 18
    header = (
        f"{'Feature':<{col_w}}"
        f"{'File1 Mean':>13}"
        f"{'File2 Mean':>13}"
        f"{'Diff':>13}"
        f"{'% Change':>12}"
    )
    separator = (
        f"{'-' * col_w}"
        f"{'----------':>13}"
        f"{'----------':>13}"
        f"{'----':>13}"
        f"{'--------':>12}"
    )
    print(header)
    print(separator)

    any_data = False
    for feature in STANDARD_FEATURES:
        vals1 = extract_values(rows1, feature)
        vals2 = extract_values(rows2, feature)

        if not vals1 and not vals2:
            continue  # feature not present in either file

        any_data = True
        mean1 = mean_of(vals1)
        mean2 = mean_of(vals2)

        if mean1 is not None and mean2 is not None:
            diff = mean2 - mean1
            pct = (diff / mean1 * 100) if mean1 != 0 else None
        else:
            diff = None
            pct = None

        row_str = (
            f"{feature:<{col_w}}"
            f"{_fmt_val(mean1)}"
            f"{_fmt_val(mean2)}"
            f"{_fmt_diff(diff)}"
            f"{_fmt_pct(pct)}"
        )
        print(row_str)

    if not any_data:
        print("  (none of the standard features found in these files)")

    # Sample counts
    print()
    print(f"{'Sample counts:'}")
    print(f"  File 1: {len(rows1)} rows")
    print(f"  File 2: {len(rows2)} rows")

    # Date ranges
    ts1 = extract_timestamps(rows1)
    ts2 = extract_timestamps(rows2)
    print()
    print("Date ranges:")
    if ts1:
        print(f"  File 1: {ts1[0]} — {ts1[-1]}")
    else:
        print("  File 1: (no timestamp column found)")
    if ts2:
        print(f"  File 2: {ts2[0]} — {ts2[-1]}")
    else:
        print("  File 2: (no timestamp column found)")

    # Device IDs
    ids1 = extract_device_ids(rows1)
    ids2 = extract_device_ids(rows2)
    print()
    print("Device IDs:")
    print(f"  File 1: {', '.join(sorted(ids1)) if ids1 else '(none found)'}")
    print(f"  File 2: {', '.join(sorted(ids2)) if ids2 else '(none found)'}")
    print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare feature statistics between two field CSV sessions."
    )
    parser.add_argument("csv1", metavar="CSV1", help="Path to first CSV file.")
    parser.add_argument("csv2", metavar="CSV2", help="Path to second CSV file.")
    parser.add_argument(
        "--feature",
        default=None,
        metavar="FEATURE",
        help=(
            "If provided, shows detailed per-row stats for this single feature "
            "in addition to the standard comparison table."
        ),
    )
    args = parser.parse_args()

    rows1 = load_csv(args.csv1)
    rows2 = load_csv(args.csv2)

    compare_sessions(rows1, rows2, args.csv1, args.csv2)

    # Optional single-feature deep-dive
    if args.feature:
        feat = args.feature
        vals1 = extract_values(rows1, feat)
        vals2 = extract_values(rows2, feat)
        print(f"Detailed stats for '{feat}':")
        for label, vals, path in [
            ("File 1", vals1, args.csv1),
            ("File 2", vals2, args.csv2),
        ]:
            if not vals:
                print(f"  {label} ({path}): no data for '{feat}'")
                continue
            n = len(vals)
            v_min = min(vals)
            v_max = max(vals)
            mean = sum(vals) / n
            variance = sum((v - mean) ** 2 for v in vals) / n if n > 1 else 0.0
            std = math.sqrt(variance)
            median = sorted(vals)[n // 2]
            print(
                f"  {label} ({path}):  n={n}  min={v_min:.4f}  max={v_max:.4f}"
                f"  mean={mean:.4f}  std={std:.4f}  median={median:.4f}"
            )
        print()


if __name__ == "__main__":
    main()
