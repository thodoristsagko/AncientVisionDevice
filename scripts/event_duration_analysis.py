#!/usr/bin/env python3
"""
event_duration_analysis.py — Analyze alert event durations and shapes.

Usage:
    python scripts/event_duration_analysis.py [--data-dir DIR] [--min-ppv FLOAT]

Groups consecutive alert readings into events.
For each event: start, peak PPV, duration, rise time, fall time, shape type.
Shape types: IMPULSIVE (fast rise+fall <1s), SUSTAINED (>5s), GRADUAL (slow rise).
Useful for distinguishing human activity from genuine precursors.
"""

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

# Default threshold to consider a sample an "alert" reading (mm/s)
DEFAULT_MIN_PPV = 0.1

# Gap in seconds between consecutive alert readings that starts a new event
EVENT_GAP_S = 2.0

# Shape classification thresholds (seconds)
IMPULSIVE_DURATION_MAX = 1.0   # total duration < 1s
SUSTAINED_DURATION_MIN = 5.0   # total duration > 5s
GRADUAL_RISE_FRACTION = 0.6    # rise_time > total_duration * 0.6


def _parse_timestamp(ts_str: str) -> float | None:
    """Parse a timestamp string to a POSIX float. Returns None on failure."""
    if not ts_str:
        return None
    # Try common formats
    formats = [
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
    ]
    for fmt in formats:
        try:
            dt = datetime.strptime(ts_str.strip(), fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            continue
    # Try float directly
    try:
        return float(ts_str)
    except (ValueError, TypeError):
        return None


def classify_shape(
    total_duration: float,
    rise_time: float,
) -> str:
    """Classify an event by its temporal shape."""
    if total_duration < IMPULSIVE_DURATION_MAX:
        return "IMPULSIVE"
    if total_duration > SUSTAINED_DURATION_MIN:
        return "SUSTAINED"
    if total_duration > 0 and rise_time > total_duration * GRADUAL_RISE_FRACTION:
        return "GRADUAL"
    return "TRANSIENT"


def load_rows(data_dir: Path) -> list:
    """Load all CSV rows from data_dir, sorted by timestamp."""
    if HAS_PANDAS:
        csv_files = list(data_dir.glob("*.csv"))
        if not csv_files:
            return []
        dfs = []
        for f in csv_files:
            try:
                df = pd.read_csv(f)
                dfs.append(df)
            except Exception:
                continue
        if not dfs:
            return []
        combined = pd.concat(dfs, ignore_index=True)
        # Convert to list of dicts for uniform processing
        return combined.to_dict(orient="records")
    else:
        import csv as _csv
        rows = []
        for csv_path in sorted(data_dir.glob("*.csv")):
            try:
                with open(csv_path, newline="", encoding="utf-8") as f:
                    reader = _csv.DictReader(f)
                    for row in reader:
                        rows.append(dict(row))
            except Exception:
                continue
        return rows


def extract_alert_readings(rows: list, min_ppv: float) -> list:
    """
    Filter rows to alert readings (PPV >= min_ppv) and attach parsed timestamp.
    Returns list of dicts with added 't' key (POSIX float).
    """
    alert = []
    for row in rows:
        # Get PPV value
        ppv_raw = row.get("ppv", None)
        if ppv_raw is None:
            continue
        try:
            ppv = float(ppv_raw)
        except (ValueError, TypeError):
            continue
        if ppv < min_ppv:
            continue

        # Get timestamp
        ts_raw = row.get("timestamp", None)
        t = _parse_timestamp(str(ts_raw)) if ts_raw is not None else None
        if t is None:
            continue

        row_copy = dict(row)
        row_copy["_ppv"] = ppv
        row_copy["_t"] = t
        alert.append(row_copy)

    # Sort by timestamp
    alert.sort(key=lambda r: r["_t"])
    return alert


def group_events(alert_readings: list) -> list:
    """Group consecutive alert readings into events (gap > EVENT_GAP_S = new event)."""
    if not alert_readings:
        return []

    events = []
    current_group = [alert_readings[0]]

    for reading in alert_readings[1:]:
        prev_t = current_group[-1]["_t"]
        curr_t = reading["_t"]
        if curr_t - prev_t > EVENT_GAP_S:
            events.append(current_group)
            current_group = [reading]
        else:
            current_group.append(reading)

    if current_group:
        events.append(current_group)

    return events


def analyze_event(group: list) -> dict:
    """Compute statistics for a single event group."""
    times = [r["_t"] for r in group]
    ppvs = [r["_ppv"] for r in group]

    start_t = times[0]
    end_t = times[-1]
    total_duration = max(end_t - start_t, 0.0)

    peak_ppv = max(ppvs)
    peak_idx = ppvs.index(peak_ppv)
    peak_t = times[peak_idx]

    rise_time = max(peak_t - start_t, 0.0)
    fall_time = max(end_t - peak_t, 0.0)

    shape = classify_shape(total_duration, rise_time)

    # Format start time for display
    try:
        start_str = datetime.fromtimestamp(start_t, tz=timezone.utc).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
    except (OSError, OverflowError, ValueError):
        start_str = str(start_t)

    return {
        "start_time": start_str,
        "peak_ppv": peak_ppv,
        "total_duration_s": total_duration,
        "rise_time_s": rise_time,
        "fall_time_s": fall_time,
        "shape_type": shape,
        "n_readings": len(group),
    }


def print_events_table(events_data: list) -> None:
    """Print ASCII table of events sorted by peak_ppv descending."""
    if not events_data:
        print("No alert events found.")
        return

    # Sort by peak_ppv descending
    sorted_events = sorted(events_data, key=lambda e: e["peak_ppv"], reverse=True)

    col_w = {
        "start":    22,
        "peak_ppv": 12,
        "duration": 12,
        "rise":     10,
        "fall":     10,
        "shape":    11,
        "n":        8,
    }

    header = (
        f"{'Start Time':<{col_w['start']}} "
        f"{'Peak PPV (mm/s)':>{col_w['peak_ppv']}} "
        f"{'Duration (s)':>{col_w['duration']}} "
        f"{'Rise (s)':>{col_w['rise']}} "
        f"{'Fall (s)':>{col_w['fall']}} "
        f"{'Shape':>{col_w['shape']}} "
        f"{'Readings':>{col_w['n']}}"
    )
    sep = "-" * len(header)

    print()
    print("Alert Event Duration Analysis")
    print(sep)
    print(header)
    print(sep)

    for ev in sorted_events:
        print(
            f"{ev['start_time']:<{col_w['start']}} "
            f"{ev['peak_ppv']:>{col_w['peak_ppv']}.4f} "
            f"{ev['total_duration_s']:>{col_w['duration']}.3f} "
            f"{ev['rise_time_s']:>{col_w['rise']}.3f} "
            f"{ev['fall_time_s']:>{col_w['fall']}.3f} "
            f"{ev['shape_type']:>{col_w['shape']}} "
            f"{ev['n_readings']:>{col_w['n']}}"
        )

    print(sep)
    print()


def print_summary(events_data: list) -> None:
    """Print summary line with shape breakdown."""
    total = len(events_data)
    counts = {"IMPULSIVE": 0, "SUSTAINED": 0, "GRADUAL": 0, "TRANSIENT": 0}
    for ev in events_data:
        shape = ev["shape_type"]
        if shape in counts:
            counts[shape] += 1

    n_i = counts["IMPULSIVE"]
    n_s = counts["SUSTAINED"]
    n_g = counts["GRADUAL"]
    n_t = counts["TRANSIENT"]

    print(
        f"{total} events: "
        f"{n_i} impulsive, "
        f"{n_s} sustained, "
        f"{n_g} gradual, "
        f"{n_t} transient"
        + (f" — {n_g} gradual events most concerning" if n_g > 0 else "")
    )
    print()

    if n_i > 0:
        print(
            f"  IMPULSIVE ({n_i}): < {IMPULSIVE_DURATION_MAX:.0f}s — "
            "likely human footstep or tool impact"
        )
    if n_s > 0:
        print(
            f"  SUSTAINED ({n_s}): > {SUSTAINED_DURATION_MIN:.0f}s — "
            "continuous activity (machinery, wind)"
        )
    if n_g > 0:
        print(
            f"  GRADUAL   ({n_g}): slow build-up (rise > {GRADUAL_RISE_FRACTION:.0%} of duration) — "
            "precursor signature, investigate immediately"
        )
    if n_t > 0:
        print(f"  TRANSIENT ({n_t}): short but not impulsive, or irregular shape")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Analyze alert event durations and shapes from collected vibration data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        help="Directory containing field CSV files (default: ./data/field)",
    )
    parser.add_argument(
        "--min-ppv",
        type=float,
        default=DEFAULT_MIN_PPV,
        help=f"Minimum PPV (mm/s) to consider a reading an alert (default: {DEFAULT_MIN_PPV})",
    )
    args = parser.parse_args()

    data_dir = Path(args.data_dir)

    if not data_dir.exists():
        print(f"Data directory not found: {data_dir}")
        print("No data to analyze.")
        sys.exit(0)

    rows = load_rows(data_dir)

    if not rows:
        print("No CSV data found.")
        print("No alert events found.")
        sys.exit(0)

    alert_readings = extract_alert_readings(rows, args.min_ppv)

    if not alert_readings:
        print(
            f"No alert readings found (min-ppv = {args.min_ppv} mm/s). "
            "All readings are below threshold."
        )
        sys.exit(0)

    events = group_events(alert_readings)
    events_data = [analyze_event(g) for g in events]

    print_events_table(events_data)
    print_summary(events_data)

    sys.exit(0)


if __name__ == "__main__":
    main()
