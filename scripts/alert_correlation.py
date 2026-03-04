#!/usr/bin/env python3
"""
alert_correlation.py — Analyze alert event correlations in collected vibration data.

Usage:
    python scripts/alert_correlation.py [--data-dir DIR] [--min-ppv FLOAT]

Finds patterns: time-of-day clusters, inter-alert intervals, PPV escalation sequences.
Outputs ASCII summary to stdout.
"""

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_csvs(data_dir: Path, min_ppv: float = 0.0) -> list:
    """Load all CSV files from data_dir, returning list of row dicts."""
    rows = []
    for csv_path in sorted(data_dir.glob("**/*.csv")):
        try:
            with open(csv_path, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    try:
                        ppv_val = float(row.get("ppv", 0.0) or 0.0)
                    except (ValueError, TypeError):
                        ppv_val = 0.0
                    if ppv_val < min_ppv:
                        continue
                    rows.append(row)
        except Exception:
            pass  # skip malformed files gracefully
    return rows


def parse_timestamp(ts_str: str):
    """Parse ISO-8601 timestamp string to datetime. Returns None on failure."""
    if not ts_str:
        return None
    # Try common formats
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
    ):
        try:
            return datetime.strptime(ts_str.strip(), fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


# ---------------------------------------------------------------------------
# Analysis helpers
# ---------------------------------------------------------------------------

DAYS_OF_WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def hour_of_day_distribution(alert_rows: list) -> dict:
    """Return {hour: count} for rows that have parseable timestamps."""
    counts = defaultdict(int)
    for row in alert_rows:
        ts = parse_timestamp(row.get("timestamp", ""))
        if ts is not None:
            counts[ts.hour] += 1
    return dict(counts)


def day_of_week_distribution(alert_rows: list) -> dict:
    """Return {day_name: count} for rows that have parseable timestamps."""
    counts = defaultdict(int)
    for row in alert_rows:
        ts = parse_timestamp(row.get("timestamp", ""))
        if ts is not None:
            counts[DAYS_OF_WEEK[ts.weekday()]] += 1
    return dict(counts)


def inter_alert_intervals(alert_rows: list) -> dict:
    """
    Compute inter-alert intervals per device_id.
    Returns {device_id: [interval_seconds, ...]}
    """
    by_device = defaultdict(list)
    for row in alert_rows:
        device_id = row.get("device_id", "unknown") or "unknown"
        ts = parse_timestamp(row.get("timestamp", ""))
        if ts is not None:
            by_device[device_id].append(ts)

    intervals = {}
    for device_id, timestamps in by_device.items():
        timestamps_sorted = sorted(timestamps)
        if len(timestamps_sorted) < 2:
            continue
        device_intervals = []
        for i in range(1, len(timestamps_sorted)):
            delta = (timestamps_sorted[i] - timestamps_sorted[i - 1]).total_seconds()
            device_intervals.append(delta)
        if device_intervals:
            intervals[device_id] = device_intervals
    return intervals


def detect_ppv_escalation(rows: list, threshold_ratio: float = 1.5, min_run: int = 3) -> list:
    """
    Detect sequences where PPV increases by >50% over 3+ consecutive readings.
    Returns list of dicts describing each escalation sequence.
    """
    # Sort by timestamp, group by device_id
    by_device = defaultdict(list)
    for row in rows:
        device_id = row.get("device_id", "unknown") or "unknown"
        try:
            ppv = float(row.get("ppv", 0.0) or 0.0)
        except (ValueError, TypeError):
            continue
        ts = parse_timestamp(row.get("timestamp", ""))
        by_device[device_id].append((ts, ppv))

    escalations = []
    for device_id, readings in by_device.items():
        # Sort by timestamp (None timestamps go last)
        readings_sorted = sorted(readings, key=lambda x: (x[0] is None, x[0]))
        ppvs = [r[1] for r in readings_sorted]

        # Sliding window: find runs of consecutive increases >= threshold_ratio
        run_start = 0
        while run_start < len(ppvs) - 1:
            run = [run_start]
            i = run_start + 1
            while i < len(ppvs):
                if ppvs[i - 1] > 0 and (ppvs[i] / ppvs[i - 1]) >= threshold_ratio:
                    run.append(i)
                    i += 1
                else:
                    break
            if len(run) >= min_run:
                escalations.append({
                    "device_id": device_id,
                    "start_ppv": ppvs[run[0]],
                    "end_ppv": ppvs[run[-1]],
                    "length": len(run),
                    "start_ts": readings_sorted[run[0]][0],
                    "end_ts": readings_sorted[run[-1]][0],
                })
                run_start = run[-1] + 1
            else:
                run_start += 1

    return escalations


# ---------------------------------------------------------------------------
# ASCII table rendering
# ---------------------------------------------------------------------------

def _bar(count: int, max_count: int, width: int = 20) -> str:
    if max_count == 0:
        return ""
    filled = int(round(count / max_count * width))
    return "#" * filled + "." * (width - filled)


def print_hour_table(counts: dict) -> None:
    print("\nAlerts by Hour of Day:")
    print(f"  {'Hour':>4}  {'Count':>6}  {'Bar':<22}")
    print("  " + "-" * 36)
    max_count = max(counts.values(), default=0)
    for hour in range(24):
        count = counts.get(hour, 0)
        bar = _bar(count, max_count)
        print(f"  {hour:>4}  {count:>6}  {bar:<22}")


def print_dow_table(counts: dict) -> None:
    print("\nAlerts by Day of Week:")
    print(f"  {'Day':>3}  {'Count':>6}  {'Bar':<22}")
    print("  " + "-" * 34)
    max_count = max(counts.values(), default=0)
    for day in DAYS_OF_WEEK:
        count = counts.get(day, 0)
        bar = _bar(count, max_count)
        print(f"  {day:>3}  {count:>6}  {bar:<22}")


def print_interval_table(intervals: dict) -> None:
    print("\nInter-Alert Intervals (seconds) by Device:")
    print(f"  {'Device':<20}  {'Count':>5}  {'Min':>8}  {'Mean':>8}  {'Max':>8}")
    print("  " + "-" * 58)
    for device_id in sorted(intervals.keys()):
        vals = intervals[device_id]
        mean_val = sum(vals) / len(vals)
        print(
            f"  {device_id:<20}  {len(vals):>5}  {min(vals):>8.1f}  "
            f"{mean_val:>8.1f}  {max(vals):>8.1f}"
        )


def print_escalation_table(escalations: list) -> None:
    print("\nPPV Escalation Sequences (>=3 readings, each >=50% increase):")
    if not escalations:
        print("  None detected.")
        return
    print(f"  {'Device':<20}  {'Len':>4}  {'Start PPV':>10}  {'End PPV':>10}  {'Start Time':<24}")
    print("  " + "-" * 78)
    for esc in escalations:
        ts_str = esc["start_ts"].strftime("%Y-%m-%dT%H:%M:%SZ") if esc["start_ts"] else "unknown"
        print(
            f"  {esc['device_id']:<20}  {esc['length']:>4}  "
            f"{esc['start_ppv']:>10.4f}  {esc['end_ppv']:>10.4f}  {ts_str:<24}"
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze alert event correlations in collected vibration data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data",
        help="Directory containing field CSV files (default: ./data)",
    )
    parser.add_argument(
        "--min-ppv",
        type=float,
        default=0.0,
        help="Minimum PPV threshold for rows to consider (default: 0.0)",
    )
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        print("No data found")
        return 0

    all_rows = load_csvs(data_dir, min_ppv=args.min_ppv)
    if not all_rows:
        print("No data found")
        return 0

    # Separate alert rows (label != "normal")
    alert_rows = [
        r for r in all_rows
        if (r.get("label") or "normal").strip().lower() != "normal"
    ]

    print(f"Loaded {len(all_rows)} total readings, {len(alert_rows)} alert events.")

    if not alert_rows:
        print("\nNo alert events found (all readings labelled 'normal').")
    else:
        hour_counts = hour_of_day_distribution(alert_rows)
        dow_counts = day_of_week_distribution(alert_rows)
        print_hour_table(hour_counts)
        print_dow_table(dow_counts)

        intervals = inter_alert_intervals(alert_rows)
        if intervals:
            print_interval_table(intervals)
        else:
            print("\nInter-Alert Intervals: not enough data per device.")

    # Escalation detection runs on ALL rows (not just alerts)
    escalations = detect_ppv_escalation(all_rows)
    print_escalation_table(escalations)

    return 0


if __name__ == "__main__":
    sys.exit(main())
