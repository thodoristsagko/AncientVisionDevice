#!/usr/bin/env python3
"""Render an ASCII timeline of anomaly events from a field CSV.

Usage:
    python scripts/anomaly_timeline.py
    python scripts/anomaly_timeline.py --csv path/to/field.csv
    python scripts/anomaly_timeline.py --csv path/to/field.csv --threshold 0.3
    python scripts/anomaly_timeline.py --csv path/to/field.csv --threshold 0.3 --width 80
    python scripts/anomaly_timeline.py --csv path/to/field.csv --per-device

Output example:

    AncientVision Anomaly Timeline -- device_001
    2026-03-01 ---------------------------------- 2026-03-03
               .....|||||.............||...|||||.....
                    ^                 ^   ^
                13:45:23           09:12  11:30

    Legend: . = normal  | = anomaly (PPV > 0.30 mm/s)
    Events: 3 anomaly period(s), longest: 45s, max PPV: 0.712 mm/s

With --per-device one timeline row is printed per device_id.
"""

import argparse
import csv
import json
import os
import sys
from datetime import datetime, timezone
from itertools import groupby

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

# Default number of character columns for the timeline bar
DEFAULT_WIDTH = 80

# Synthetic data fallback
N_SYNTHETIC = 200

# Characters used in the ASCII bar
CHAR_NORMAL = "."
CHAR_ANOMALY = "|"
CHAR_EMPTY = " "


# ---------------------------------------------------------------------------
# Timestamp parsing
# ---------------------------------------------------------------------------

def _parse_ts(ts_str: str):
    """Parse a timestamp string to a datetime object.

    Tries ISO 8601 first (with or without timezone), then common formats.
    Returns None on failure.
    """
    if not ts_str or not ts_str.strip():
        return None
    ts_str = ts_str.strip()
    formats = [
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
    ]
    for fmt in formats:
        try:
            dt = datetime.strptime(ts_str, fmt)
            # Ensure timezone-naive for uniform arithmetic
            if dt.tzinfo is not None:
                dt = dt.replace(tzinfo=None)
            return dt
        except ValueError:
            continue
    # Try unix timestamp (float seconds)
    try:
        return datetime.utcfromtimestamp(float(ts_str))
    except (ValueError, OSError, OverflowError):
        pass
    return None


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _load_csv(path: str) -> list:
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))
    return rows


# ---------------------------------------------------------------------------
# Synthetic data
# ---------------------------------------------------------------------------

def _make_synthetic(n: int = N_SYNTHETIC) -> list:
    """Generate n synthetic rows spanning 2 days with PPV values."""
    rng = np.random.default_rng(42)
    start = datetime(2026, 3, 1, 8, 0, 0)
    rows = []
    for i in range(n):
        # Timestamp: evenly spaced over 2 days (172800 s)
        offset_s = int(i * 172800 / n)
        ts = datetime(2026, 3, 1, 8, 0, 0)
        from datetime import timedelta  # noqa: PLC0415
        ts = ts + timedelta(seconds=offset_s)

        # PPV: mostly low with a few spikes
        if i % 40 in (15, 16, 17, 18, 19, 60, 61, 90, 91, 92, 93):
            ppv = rng.uniform(0.4, 1.5)
        else:
            ppv = rng.uniform(0.01, 0.25)

        rows.append({
            "device_id": "synthetic_device",
            "timestamp": ts.isoformat(),
            "ppv": str(ppv),
        })
    return rows


# ---------------------------------------------------------------------------
# Event detection
# ---------------------------------------------------------------------------

def _detect_events(rows: list, threshold: float) -> tuple:
    """Return (ppv_values, is_anomaly_flags, timestamps, max_ppv).

    Rows without a parseable timestamp or PPV are skipped.
    """
    ppvs = []
    flags = []
    timestamps = []
    max_ppv = 0.0

    for row in rows:
        raw_ppv = row.get("ppv", "")
        try:
            ppv = float(raw_ppv)
        except (ValueError, TypeError):
            ppv = 0.0
        ts = _parse_ts(row.get("timestamp", ""))
        if ts is None:
            continue

        ppvs.append(ppv)
        flags.append(ppv >= threshold)
        timestamps.append(ts)
        if ppv > max_ppv:
            max_ppv = ppv

    return ppvs, flags, timestamps, max_ppv


# ---------------------------------------------------------------------------
# Anomaly period detection
# ---------------------------------------------------------------------------

def _find_anomaly_periods(flags: list, timestamps: list) -> list:
    """Return list of (start_ts, end_ts, duration_s) for contiguous anomaly runs."""
    periods = []
    in_period = False
    start_ts = None
    for i, flag in enumerate(flags):
        if flag and not in_period:
            in_period = True
            start_ts = timestamps[i]
        elif not flag and in_period:
            in_period = False
            end_ts = timestamps[i - 1]
            dur = (end_ts - start_ts).total_seconds()
            periods.append((start_ts, end_ts, dur))
    if in_period:
        end_ts = timestamps[-1]
        dur = (end_ts - start_ts).total_seconds()
        periods.append((start_ts, end_ts, dur))
    return periods


# ---------------------------------------------------------------------------
# Timeline rendering
# ---------------------------------------------------------------------------

def _render_timeline(device_id: str, rows: list, threshold: float,
                     width: int) -> None:
    """Render an ASCII timeline for a single device."""
    ppvs, flags, timestamps, max_ppv = _detect_events(rows, threshold)

    if not timestamps:
        print(f"  {device_id}: no rows with parseable timestamps and PPV.")
        return

    n = len(timestamps)
    t_start = min(timestamps)
    t_end = max(timestamps)
    total_s = max((t_end - t_start).total_seconds(), 1.0)

    # Map each sample to a bar position [0, width-1]
    bar = [CHAR_EMPTY] * width
    for i, (flag, ts) in enumerate(zip(flags, timestamps)):
        pos = int((ts - t_start).total_seconds() / total_s * (width - 1))
        pos = max(0, min(width - 1, pos))
        if bar[pos] == CHAR_EMPTY:
            bar[pos] = CHAR_ANOMALY if flag else CHAR_NORMAL
        elif flag:
            # Anomaly wins over normal in the same cell
            bar[pos] = CHAR_ANOMALY

    # Replace any remaining CHAR_EMPTY with CHAR_NORMAL if there are samples nearby
    # (fill gaps in the bar with normal for readability)
    for i in range(width):
        if bar[i] == CHAR_EMPTY:
            bar[i] = CHAR_NORMAL

    bar_str = "".join(bar)

    # Detect anomaly periods
    periods = _find_anomaly_periods(flags, timestamps)
    n_periods = len(periods)
    longest_s = max((p[2] for p in periods), default=0.0)

    # Anomaly fraction
    anomaly_count = sum(1 for f in flags if f)
    anomaly_pct = anomaly_count / n * 100 if n else 0.0

    # Print timeline
    start_label = t_start.strftime("%Y-%m-%d %H:%M")
    end_label = t_end.strftime("%Y-%m-%d %H:%M")
    indent = "  "

    print(f"AncientVision Anomaly Timeline -- {device_id}")
    dash_count = max(0, width - len(start_label) - len(end_label) - 2)
    print(f"{indent}{start_label} {'-' * dash_count} {end_label}")
    print(f"{indent}{bar_str}")

    # Mark first few anomaly period starts with ^ and timestamp below
    markers = []
    for period_start, _, _ in periods[:3]:
        pos = int((period_start - t_start).total_seconds() / total_s * (width - 1))
        pos = max(0, min(width - 1, pos))
        label = period_start.strftime("%H:%M:%S")
        markers.append((pos, label))

    if markers:
        # Caret row
        caret_row = [" "] * width
        for pos, _ in markers:
            if 0 <= pos < width:
                caret_row[pos] = "^"
        print(f"{indent}{''.join(caret_row)}")

        # Label row — try to print non-overlapping labels
        label_row = [" "] * (width + 20)
        for pos, label in markers:
            # Place label centred at pos if it fits
            start_col = max(0, pos - len(label) // 2)
            for k, ch in enumerate(label):
                if start_col + k < len(label_row):
                    label_row[start_col + k] = ch
        print(f"{indent}{''.join(label_row).rstrip()}")

    print()
    print(f"{indent}Legend: {CHAR_NORMAL} = normal  "
          f"{CHAR_ANOMALY} = anomaly (PPV > {threshold:.2f} mm/s)")
    print(f"{indent}Samples: {n} total, {anomaly_count} anomalous ({anomaly_pct:.1f}%)")

    if n_periods > 0:
        print(f"{indent}Events: {n_periods} anomaly period(s), "
              f"longest: {longest_s:.0f}s, max PPV: {max_ppv:.3f} mm/s")
    else:
        print(f"{indent}Events: 0 anomaly periods  (max PPV: {max_ppv:.3f} mm/s)")
    print()


def _render_per_device_summary(all_rows: list, threshold: float, width: int) -> None:
    """Print a compact one-line bar per device, then full detail for each."""
    # Group by device_id
    devices: dict = {}
    for row in all_rows:
        did = row.get("device_id", "unknown").strip() or "unknown"
        devices.setdefault(did, []).append(row)

    device_ids = sorted(devices.keys())

    if len(device_ids) == 1:
        # Only one device — just use the full renderer
        _render_timeline(device_ids[0], devices[device_ids[0]], threshold, width)
        return

    # Multi-device: compact summary table first
    print("=" * (width + 20))
    print("MULTI-DEVICE SUMMARY")
    print("=" * (width + 20))

    id_w = max(len(d) for d in device_ids)
    compact_bar_w = min(40, width)

    header = f"  {'Device':<{id_w}}  {'Samples':>7}  {'Anomalous':>9}  {'MaxPPV':>7}  {'Bar'}"
    print(header)
    print("  " + "-" * (len(header) - 2))

    for did in device_ids:
        rows = devices[did]
        ppvs, flags, timestamps, max_ppv = _detect_events(rows, threshold)
        n = len(timestamps)
        anomaly_count = sum(1 for f in flags if f)
        anom_pct = anomaly_count / n * 100 if n else 0.0

        # Build compact bar
        if timestamps:
            t_start = min(timestamps)
            t_end = max(timestamps)
            total_s = max((t_end - t_start).total_seconds(), 1.0)
            bar = [CHAR_NORMAL] * compact_bar_w
            for i, (flag, ts) in enumerate(zip(flags, timestamps)):
                pos = int((ts - t_start).total_seconds() / total_s * (compact_bar_w - 1))
                pos = max(0, min(compact_bar_w - 1, pos))
                if flag:
                    bar[pos] = CHAR_ANOMALY
            bar_str = "".join(bar)
        else:
            bar_str = CHAR_NORMAL * compact_bar_w

        print(f"  {did:<{id_w}}  {n:>7}  {anom_pct:>8.1f}%  {max_ppv:>7.3f}  {bar_str}")

    print()

    # Full detail per device
    for did in device_ids:
        print("-" * (width + 20))
        _render_timeline(did, devices[did], threshold, width)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="ASCII timeline of anomaly events from a field CSV."
    )
    parser.add_argument("--csv", default=None, metavar="PATH",
                        help="Path to field CSV. If omitted, synthetic data is used.")
    parser.add_argument("--threshold", type=float, default=0.3,
                        help="PPV threshold (mm/s) for flagging anomaly (default: 0.3).")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH,
                        help="Width of the ASCII timeline bar in characters (default: 80).")
    parser.add_argument("--per-device", action="store_true",
                        help="Show one timeline per device_id.")
    args = parser.parse_args()

    width = max(20, min(args.width, 200))  # clamp to sane range

    # Load data
    if args.csv:
        if not os.path.isfile(args.csv):
            print(f"ERROR: CSV file not found: {args.csv}", file=sys.stderr)
            sys.exit(1)
        rows = _load_csv(args.csv)
        if not rows:
            print(f"ERROR: CSV file is empty: {args.csv}", file=sys.stderr)
            sys.exit(1)
        print(f"Loaded {len(rows)} rows from {args.csv}")
        print()
    else:
        print("No CSV provided - using synthetic demonstration data.")
        print()
        rows = _make_synthetic(N_SYNTHETIC)

    if args.per_device:
        _render_per_device_summary(rows, args.threshold, width)
    else:
        # Single timeline: group all rows (or use first device_id found)
        devices: dict = {}
        for row in rows:
            did = row.get("device_id", "unknown").strip() or "unknown"
            devices.setdefault(did, []).append(row)

        device_ids = sorted(devices.keys())
        if len(device_ids) > 1:
            print(f"Found {len(device_ids)} devices: {', '.join(device_ids)}")
            print("Tip: use --per-device to show one timeline per device.")
            print()

        # Render all rows together (merged timeline) if multiple devices,
        # or just the single device
        if len(device_ids) == 1:
            _render_timeline(device_ids[0], rows, args.threshold, width)
        else:
            # Merged timeline with device_id = "all devices"
            _render_timeline("all devices", rows, args.threshold, width)


if __name__ == "__main__":
    main()
