#!/usr/bin/env python3
"""
long_term_trend_report.py — Generate long-term vibration trend report.

Usage:
    python scripts/long_term_trend_report.py [--data-dir DIR] [--period {daily,weekly}]

Aggregates data into daily or weekly buckets.
Reports: PPV trend, alert frequency trend, device uptime.
Identifies: recurring high-risk periods, seasonal patterns.
"""

import argparse
import csv
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data")

ALERT_LEVELS = {"soil_creep", "crack_propagation", "imminent_failure", "alert", "warning"}

# A bucket is considered high-risk if alert_rate > this threshold (%)
HIGH_RISK_ALERT_RATE = 20.0


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


def _parse_date(ts_str: str):
    """
    Parse an ISO 8601 timestamp string and return a datetime.date.
    Returns None on failure.
    """
    if not ts_str:
        return None
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
            return dt.date()
        except ValueError:
            continue
    return None


def _week_start(d) -> str:
    """Return ISO string for the Monday of the week containing date d."""
    import datetime as _dt
    monday = d - _dt.timedelta(days=d.weekday())
    return monday.isoformat()


def choose_period(rows: list) -> str:
    """
    Auto-select period: 'daily' if span < 14 days, 'weekly' otherwise.
    """
    dates = []
    for row in rows:
        d = _parse_date(row.get("timestamp", ""))
        if d is not None:
            dates.append(d)
    if not dates:
        return "daily"
    span = (max(dates) - min(dates)).days
    return "daily" if span < 14 else "weekly"


def bucket_key(row: dict, period: str) -> str | None:
    """Return the bucket key string for a row, or None if timestamp is missing."""
    d = _parse_date(row.get("timestamp", ""))
    if d is None:
        return None
    if period == "daily":
        return d.isoformat()
    # weekly: use Monday of that week
    return _week_start(d)


def aggregate_buckets(rows: list, period: str) -> list:
    """
    Group rows into time buckets and compute per-bucket statistics.
    Returns list of dicts sorted by date ascending:
        bucket, sample_count, mean_ppv, max_ppv, alert_count, alert_rate
    """
    buckets: dict = {}

    for row in rows:
        key = bucket_key(row, period)
        if key is None:
            continue

        if key not in buckets:
            buckets[key] = {"ppvs": [], "alerts": 0}

        try:
            ppv = float(row.get("ppv", "0") or "0")
        except (ValueError, TypeError):
            ppv = 0.0
        buckets[key]["ppvs"].append(ppv)

        anomaly = (row.get("anomaly_level") or row.get("label") or "normal").lower()
        if anomaly in ALERT_LEVELS:
            buckets[key]["alerts"] += 1

    records = []
    for key in sorted(buckets.keys()):
        ppvs = buckets[key]["ppvs"]
        n = len(ppvs)
        alert_count = buckets[key]["alerts"]
        mean_ppv = sum(ppvs) / n if n > 0 else 0.0
        max_ppv = max(ppvs) if ppvs else 0.0
        alert_rate = (alert_count / n * 100.0) if n > 0 else 0.0
        records.append({
            "bucket": key,
            "sample_count": n,
            "mean_ppv": mean_ppv,
            "max_ppv": max_ppv,
            "alert_count": alert_count,
            "alert_rate": alert_rate,
        })

    return records


def compute_trend_slope(records: list) -> float:
    """
    Compute simple linear trend slope of mean_ppv over buckets.
    slope = (last_ppv - first_ppv) / n_buckets
    Returns 0.0 if fewer than 2 buckets.
    """
    n = len(records)
    if n < 2:
        return 0.0
    first_ppv = records[0]["mean_ppv"]
    last_ppv = records[-1]["mean_ppv"]
    return (last_ppv - first_ppv) / n


def classify_trend(slope: float, threshold: float = 0.005) -> str:
    """
    Classify slope as UP, DOWN, or STABLE.
    threshold: mm/s per bucket — values within ±threshold are STABLE.
    """
    if slope > threshold:
        return "UP"
    if slope < -threshold:
        return "DOWN"
    return "STABLE"


def identify_high_risk_buckets(records: list) -> list:
    """Return list of bucket keys where alert_rate > HIGH_RISK_ALERT_RATE."""
    return [r["bucket"] for r in records if r["alert_rate"] > HIGH_RISK_ALERT_RATE]


def print_table(records: list, period: str) -> None:
    """Print ASCII table of bucket statistics."""
    period_label = "Date" if period == "daily" else "Week Starting"
    col_widths = {
        "bucket": 14,
        "sample_count": 10,
        "mean_ppv": 10,
        "max_ppv": 10,
        "alert_count": 12,
        "alert_rate": 12,
    }
    headers = {
        "bucket": period_label,
        "sample_count": "Samples",
        "mean_ppv": "Mean PPV",
        "max_ppv": "Max PPV",
        "alert_count": "Alerts",
        "alert_rate": "Alert Rate%",
    }

    sep = "+" + "+".join("-" * (w + 2) for w in col_widths.values()) + "+"
    header_row = "| " + " | ".join(
        headers[k].center(col_widths[k]) for k in col_widths
    ) + " |"

    label = "Daily" if period == "daily" else "Weekly"
    print(f"\n{label} Vibration Trend Report")
    print(sep)
    print(header_row)
    print(sep)

    for rec in records:
        row_parts = []
        for col, w in col_widths.items():
            if col == "bucket":
                cell = str(rec[col]).ljust(w)
            elif col == "sample_count":
                cell = str(rec[col]).rjust(w)
            elif col in ("mean_ppv", "max_ppv"):
                cell = f"{rec[col]:.4f}".rjust(w)
            elif col == "alert_count":
                cell = str(rec[col]).rjust(w)
            elif col == "alert_rate":
                cell = f"{rec[col]:.1f}%".rjust(w)
            else:
                cell = str(rec.get(col, "")).rjust(w)
            row_parts.append(cell)
        print("| " + " | ".join(row_parts) + " |")

    print(sep)


def print_trend_summary(records: list, period: str) -> None:
    """Print a trend summary line at the end of the report."""
    slope = compute_trend_slope(records)
    direction = classify_trend(slope)
    period_unit = "day" if period == "daily" else "week"

    if direction == "UP":
        print(f"\nPPV trending UP (+{slope:.4f} mm/s/{period_unit})")
    elif direction == "DOWN":
        print(f"\nPPV trending DOWN ({slope:.4f} mm/s/{period_unit})")
    else:
        print(f"\nPPV trend STABLE ({slope:.4f} mm/s/{period_unit})")

    high_risk = identify_high_risk_buckets(records)
    if high_risk:
        hr_label = "periods" if len(high_risk) > 1 else "period"
        print(f"High-risk {hr_label} (alert rate >{HIGH_RISK_ALERT_RATE:.0f}%): {', '.join(high_risk)}")
    else:
        print(f"No high-risk periods detected (alert rate threshold: {HIGH_RISK_ALERT_RATE:.0f}%)")


def main(argv=None):
    """Entry point. Always exits 0."""
    parser = argparse.ArgumentParser(
        description="Generate long-term vibration trend report from collected CSV data."
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        help=f"Directory containing field CSV files (default: {DEFAULT_DATA_DIR})",
    )
    parser.add_argument(
        "--period",
        choices=("daily", "weekly"),
        default=None,
        help="Aggregation period: daily or weekly (default: auto-select based on data span)",
    )
    args = parser.parse_args(argv)

    rows = load_csv_files(args.data_dir)

    if not rows:
        print("No data found")
        sys.exit(0)

    period = args.period if args.period else choose_period(rows)
    records = aggregate_buckets(rows, period)

    if not records:
        print("No timestamped data found")
        sys.exit(0)

    print_table(records, period)
    print_trend_summary(records, period)

    sys.exit(0)


if __name__ == "__main__":
    main()
