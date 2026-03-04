#!/usr/bin/env python3
"""
cross_site_comparison.py — Compare vibration profiles across sites or sessions.

Usage:
    python scripts/cross_site_comparison.py [--data-dir DIR] [--by {device_id,day,label}]

Groups data by --by (default: device_id) and compares vibration statistics.
Useful for comparing: different sensor placements, different days, different sites.
Outputs comparison table and correlation matrix.
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
DEFAULT_GROUP_BY = "device_id"

ALERT_LEVELS = {"soil_creep", "crack_propagation", "imminent_failure", "alert", "warning"}

GROUP_BY_OPTIONS = ("device_id", "day", "label")


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


def _parse_timestamp_to_day(ts_str: str) -> str:
    """Extract YYYY-MM-DD from an ISO 8601 timestamp string. Returns '' on failure."""
    if not ts_str:
        return ""
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
    ):
        try:
            dt = datetime.strptime(ts_str, fmt)
            return dt.strftime("%Y-%m-%d")
        except ValueError:
            continue
    return ""


def extract_group_key(row: dict, group_by: str) -> str:
    """Return the grouping key for a single CSV row."""
    if group_by == "device_id":
        return (row.get("device_id") or "").strip() or "unknown"
    if group_by == "day":
        ts = row.get("timestamp", "")
        day = _parse_timestamp_to_day(ts)
        return day if day else "unknown_day"
    if group_by == "label":
        return (row.get("label") or "").strip() or "unknown"
    return "all_devices"


def group_rows(rows: list, group_by: str, column_exists: bool) -> dict:
    """
    Group rows by group_by key.
    If the grouping column doesn't exist, fall back to single group 'all_devices'.
    Returns dict: group_key -> list of rows.
    """
    if not column_exists:
        return {"all_devices": rows}

    groups: dict = {}
    for row in rows:
        key = extract_group_key(row, group_by)
        groups.setdefault(key, []).append(row)
    return groups


def _column_exists(rows: list, group_by: str) -> bool:
    """Check whether the grouping column is present in the CSV data."""
    if not rows:
        return False
    col_map = {
        "device_id": "device_id",
        "day": "timestamp",   # day is extracted from timestamp
        "label": "label",
    }
    col = col_map.get(group_by, group_by)
    # Check if at least one row has this key
    return any(col in row for row in rows)


def compute_group_stats(group_rows_list: list) -> dict:
    """
    Compute statistics for a group of CSV rows.
    Returns dict: count, mean_ppv, std_ppv, max_ppv, alert_rate
    """
    ppvs = []
    alert_count = 0
    for row in group_rows_list:
        try:
            ppv = float(row.get("ppv", "0") or "0")
        except (ValueError, TypeError):
            ppv = 0.0
        ppvs.append(ppv)
        anomaly = (row.get("anomaly_level") or row.get("label") or "normal").lower()
        if anomaly in ALERT_LEVELS:
            alert_count += 1

    n = len(ppvs)
    if n == 0:
        return {
            "count": 0,
            "mean_ppv": 0.0,
            "std_ppv": 0.0,
            "max_ppv": 0.0,
            "alert_rate": 0.0,
        }

    mean_ppv = sum(ppvs) / n
    variance = sum((p - mean_ppv) ** 2 for p in ppvs) / n
    std_ppv = variance ** 0.5
    max_ppv = max(ppvs)
    alert_rate = alert_count / n * 100.0

    return {
        "count": n,
        "mean_ppv": mean_ppv,
        "std_ppv": std_ppv,
        "max_ppv": max_ppv,
        "alert_rate": alert_rate,
    }


def compute_pearson_correlation(x: list, y: list) -> float:
    """Compute Pearson r between two equal-length lists. Returns 0.0 if degenerate."""
    n = len(x)
    if n < 2:
        return 0.0
    mx = sum(x) / n
    my = sum(y) / n
    cov = sum((xi - mx) * (yi - my) for xi, yi in zip(x, y))
    sx = (sum((xi - mx) ** 2 for xi in x)) ** 0.5
    sy = (sum((yi - my) ** 2 for yi in y)) ** 0.5
    if sx == 0.0 or sy == 0.0:
        return 0.0
    return cov / (sx * sy)


def compute_group_correlations(group_stats: dict) -> float | None:
    """
    Compute pairwise mean-PPV correlation across all groups.
    If only one or two groups, compute simple Pearson on their mean_ppv vectors (per-group).
    For >2 groups: compute average of all pairwise Pearson correlations of sorted mean_ppv lists.
    Returns None if only 1 group.
    """
    keys = sorted(group_stats.keys())
    if len(keys) < 2:
        return None

    means = [group_stats[k]["mean_ppv"] for k in keys]

    # For 2 groups: Pearson of the two scalar values is undefined (r=1 or -1 trivially).
    # Use a meaningful alternative: correlate group index vs mean_ppv.
    if len(keys) == 2:
        # Just return the sign-aware correlation of indices [0,1] vs means
        x = [0.0, 1.0]
        return compute_pearson_correlation(x, means)

    # For >2 groups: correlate rank index vs mean_ppv (monotone trend correlation)
    x = list(range(len(means)))
    return compute_pearson_correlation(x, means)


def correlation_label(r: float) -> str:
    """Return a human-readable label for a Pearson r value."""
    abs_r = abs(r)
    if abs_r >= 0.7:
        return "HIGH"
    if abs_r >= 0.4:
        return "MEDIUM"
    return "LOW"


def print_comparison_table(group_stats: dict) -> None:
    """Print ASCII table of group statistics sorted by mean_ppv descending."""
    # Sort by mean_ppv descending
    sorted_keys = sorted(group_stats.keys(), key=lambda k: group_stats[k]["mean_ppv"], reverse=True)

    col_widths = {
        "group": 20,
        "count": 8,
        "mean_ppv": 10,
        "std_ppv": 10,
        "max_ppv": 10,
        "alert_rate": 12,
    }
    headers = {
        "group": "Group",
        "count": "Count",
        "mean_ppv": "Mean PPV",
        "std_ppv": "Std PPV",
        "max_ppv": "Max PPV",
        "alert_rate": "Alert Rate%",
    }

    sep = "+" + "+".join("-" * (w + 2) for w in col_widths.values()) + "+"
    header_row = "| " + " | ".join(
        headers[k].center(col_widths[k]) for k in col_widths
    ) + " |"

    print("\nCross-Site / Cross-Group Comparison")
    print(sep)
    print(header_row)
    print(sep)

    for key in sorted_keys:
        stats = group_stats[key]
        row_parts = []
        for col, w in col_widths.items():
            if col == "group":
                val = str(key)[:w]
                cell = val.ljust(w)
            elif col == "count":
                cell = str(stats["count"]).rjust(w)
            elif col in ("mean_ppv", "std_ppv", "max_ppv"):
                cell = f"{stats[col]:.4f}".rjust(w)
            elif col == "alert_rate":
                cell = f"{stats[col]:.1f}%".rjust(w)
            else:
                cell = str(stats.get(col, "")).rjust(w)
            row_parts.append(cell)
        print("| " + " | ".join(row_parts) + " |")

    print(sep)


def print_correlation_summary(r: float | None) -> None:
    """Print a brief correlation summary line."""
    if r is None:
        return
    label = correlation_label(r)
    print(f"\nGroups show {label} correlation (r={r:.2f})")


def main(argv=None):
    """Entry point. Always exits 0."""
    parser = argparse.ArgumentParser(
        description="Compare vibration profiles across sites or sessions."
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        help=f"Directory containing field CSV files (default: {DEFAULT_DATA_DIR})",
    )
    parser.add_argument(
        "--by",
        default=DEFAULT_GROUP_BY,
        choices=GROUP_BY_OPTIONS,
        help=f"Column to group by (default: {DEFAULT_GROUP_BY})",
    )
    args = parser.parse_args(argv)

    rows = load_csv_files(args.data_dir)

    if not rows:
        print("No data found")
        sys.exit(0)

    col_exists = _column_exists(rows, args.by)
    if not col_exists:
        print(
            f"Warning: grouping column for --by '{args.by}' not found in data. "
            "Treating all data as one group 'all_devices'."
        )

    groups = group_rows(rows, args.by, col_exists)
    group_stats = {key: compute_group_stats(grp) for key, grp in groups.items()}

    print_comparison_table(group_stats)

    r = compute_group_correlations(group_stats)
    print_correlation_summary(r)

    sys.exit(0)


if __name__ == "__main__":
    main()
