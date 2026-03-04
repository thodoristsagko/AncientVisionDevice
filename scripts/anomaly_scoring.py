#!/usr/bin/env python3
"""
anomaly_scoring.py — Composite anomaly scoring from multiple signal sources.

Usage:
    python scripts/anomaly_scoring.py [--data-dir DIR] [--window MINUTES]

Combines PPV, class labels, STA/LTA ratio, and frequency analysis
into a single composite score 0.0-1.0 per time window.
Score interpretation: 0.0=safe, 0.3=monitor, 0.6=warning, 1.0=critical.
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
DEFAULT_WINDOW_MINUTES = 5

# Composite weights
WEIGHT_PPV = 0.40
WEIGHT_LABEL = 0.30
WEIGHT_STALTA = 0.20
WEIGHT_FREQ = 0.10

# Score thresholds
LEVEL_SAFE = 0.3
LEVEL_WARNING = 0.6
LEVEL_CRITICAL = 0.9

# PPV saturation point (mm/s)
PPV_MAX = 5.0

# STA/LTA saturation point
STALTA_MAX = 5.0

# Seismic frequency range (Hz)
SEISMIC_FREQ_LOW = 1.0
SEISMIC_FREQ_HIGH = 10.0

# Normal class label
NORMAL_LABEL = "normal"

# ASCII bar chart chars: safe, monitor, warning, critical
BAR_CHARS = {
    "safe": ".",
    "monitor": "-",
    "warning": "#",
    "critical": "*",
}

BAR_WIDTH = 30


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


def _parse_float(value: str, default: float = 0.0) -> float:
    """Safely parse a float string, returning default on failure."""
    try:
        return float(value or default)
    except (ValueError, TypeError):
        return default


def group_into_windows(rows: list, window_s: float) -> list:
    """
    Group CSV rows into time windows of `window_s` seconds.

    Returns list of (window_start_ts, window_rows) sorted by window start.
    Rows with invalid timestamps are discarded.
    """
    tagged = []
    for row in rows:
        ts = _parse_timestamp(row.get("timestamp", ""))
        if ts < 0:
            continue
        tagged.append((ts, row))

    if not tagged:
        return []

    tagged.sort(key=lambda x: x[0])
    start_ts = tagged[0][0]
    end_ts = tagged[-1][0]

    windows = []
    w_start = start_ts
    while w_start <= end_ts:
        w_end = w_start + window_s
        bucket = [row for ts, row in tagged if w_start <= ts < w_end]
        if bucket:
            windows.append((w_start, bucket))
        w_start = w_end

    return windows


def score_window(window_rows: list) -> dict:
    """
    Compute composite anomaly score for a list of CSV rows in one window.

    Returns dict with:
      ppv_score, label_score, stalta_score, freq_score, composite,
      max_ppv, dominant_signal
    """
    if not window_rows:
        return {
            "ppv_score": 0.0,
            "label_score": 0.0,
            "stalta_score": 0.0,
            "freq_score": 0.0,
            "composite": 0.0,
            "max_ppv": 0.0,
            "dominant_signal": "none",
        }

    n = len(window_rows)

    # --- PPV score ---
    ppv_values = [_parse_float(row.get("ppv", "0")) for row in window_rows]
    max_ppv = max(ppv_values) if ppv_values else 0.0
    ppv_score = min(1.0, max_ppv / PPV_MAX)

    # --- Label score ---
    non_normal = sum(
        1 for row in window_rows
        if (row.get("anomaly_level") or row.get("label") or NORMAL_LABEL).lower() != NORMAL_LABEL
    )
    label_score = non_normal / n

    # --- STA/LTA score ---
    stalta_col = None
    for candidate in ("sta_lta", "stalta", "sta/lta"):
        if candidate in window_rows[0]:
            stalta_col = candidate
            break
    if stalta_col:
        stalta_values = [_parse_float(row.get(stalta_col, "0")) for row in window_rows]
        mean_stalta = sum(stalta_values) / len(stalta_values)
        stalta_score = min(1.0, mean_stalta / STALTA_MAX)
    else:
        stalta_score = 0.0

    # --- Frequency score ---
    freq_col = None
    for candidate in ("hz_dominant", "freq", "dominant_freq", "frequency"):
        if candidate in window_rows[0]:
            freq_col = candidate
            break
    if freq_col:
        seismic_count = sum(
            1 for row in window_rows
            if SEISMIC_FREQ_LOW <= _parse_float(row.get(freq_col, "0")) <= SEISMIC_FREQ_HIGH
        )
        freq_score = seismic_count / n
    else:
        freq_score = 0.0

    # --- Composite score ---
    composite = (
        WEIGHT_PPV * ppv_score
        + WEIGHT_LABEL * label_score
        + WEIGHT_STALTA * stalta_score
        + WEIGHT_FREQ * freq_score
    )
    composite = max(0.0, min(1.0, composite))

    # --- Dominant signal ---
    signal_scores = {
        "ppv": WEIGHT_PPV * ppv_score,
        "label": WEIGHT_LABEL * label_score,
        "sta_lta": WEIGHT_STALTA * stalta_score,
        "freq": WEIGHT_FREQ * freq_score,
    }
    dominant_signal = max(signal_scores, key=lambda k: signal_scores[k])

    return {
        "ppv_score": ppv_score,
        "label_score": label_score,
        "stalta_score": stalta_score,
        "freq_score": freq_score,
        "composite": composite,
        "max_ppv": max_ppv,
        "dominant_signal": dominant_signal,
    }


def score_level(composite: float) -> str:
    """Map composite score to human-readable level."""
    if composite >= LEVEL_CRITICAL:
        return "CRITICAL"
    if composite >= LEVEL_WARNING:
        return "WARNING"
    if composite >= LEVEL_SAFE:
        return "MONITOR"
    return "SAFE"


def bar_char(composite: float) -> str:
    """Return ASCII bar character for this composite score."""
    level = score_level(composite)
    if level == "CRITICAL":
        return BAR_CHARS["critical"]
    if level == "WARNING":
        return BAR_CHARS["warning"]
    if level == "MONITOR":
        return BAR_CHARS["monitor"]
    return BAR_CHARS["safe"]


def render_bar(composite: float, width: int = BAR_WIDTH) -> str:
    """Render a filled ASCII progress bar of given width."""
    filled = max(0, min(width, int(composite * width)))
    ch = bar_char(composite)
    return "[" + ch * filled + " " * (width - filled) + "]"


def format_window_time(ts: float) -> str:
    """Format epoch timestamp as HH:MM:SS (UTC)."""
    try:
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
        return dt.strftime("%H:%M:%S")
    except (OSError, OverflowError, ValueError):
        return "??:??:??"


def main(argv=None):
    """Entry point. Always exits 0."""
    parser = argparse.ArgumentParser(
        description="Composite anomaly scoring from multiple signal sources."
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
        help=f"Window size in minutes (default: {DEFAULT_WINDOW_MINUTES})",
    )
    args = parser.parse_args(argv)

    rows = load_csv_files(args.data_dir)
    window_s = args.window * 60.0
    windows = group_into_windows(rows, window_s)

    if not windows:
        print("No data found.")
        sys.exit(0)

    # Score each window
    results = []
    for w_start, w_rows in windows:
        scores = score_window(w_rows)
        results.append((w_start, w_rows, scores))

    # Print header
    print()
    print("=" * 70)
    print(f"  Composite Anomaly Scoring  ({len(results)} windows x {args.window:.0f} min)")
    print(f"  Weights: PPV {WEIGHT_PPV:.0%}  Label {WEIGHT_LABEL:.0%}  "
          f"STA/LTA {WEIGHT_STALTA:.0%}  Freq {WEIGHT_FREQ:.0%}")
    print("=" * 70)
    print()
    print(f"  {'Time':8s}  {'Score':6s}  {'Level':8s}  {'Bar':{BAR_WIDTH + 2}s}  Dominant")
    print(f"  {'-' * 8}  {'-' * 6}  {'-' * 8}  {'-' * (BAR_WIDTH + 2)}  {'-' * 10}")

    for w_start, _w_rows, scores in results:
        time_str = format_window_time(w_start)
        composite = scores["composite"]
        level = score_level(composite)
        bar = render_bar(composite)
        dominant = scores["dominant_signal"]
        print(f"  {time_str}  {composite:.3f}   {level:8s}  {bar}  {dominant}")

    print()

    # Summary
    all_scores = [s["composite"] for _, _, s in results]
    max_score = max(all_scores)
    mean_score = sum(all_scores) / len(all_scores)
    n_monitor = sum(1 for s in all_scores if s >= LEVEL_SAFE)
    n_warning = sum(1 for s in all_scores if s >= LEVEL_WARNING)
    n_critical = sum(1 for s in all_scores if s >= LEVEL_CRITICAL)

    print("=" * 70)
    print(f"  Summary:")
    print(f"    Total windows:          {len(results)}")
    print(f"    Max composite score:    {max_score:.3f}  ({score_level(max_score)})")
    print(f"    Mean composite score:   {mean_score:.3f}  ({score_level(mean_score)})")
    print(f"    Windows >= MONITOR:     {n_monitor}")
    print(f"    Windows >= WARNING:     {n_warning}")
    print(f"    Windows >= CRITICAL:    {n_critical}")
    print()
    print("  Score legend:")
    print(f"    {BAR_CHARS['safe']}  SAFE     (< {LEVEL_SAFE:.1f})")
    print(f"    {BAR_CHARS['monitor']}  MONITOR  ({LEVEL_SAFE:.1f} - {LEVEL_WARNING:.1f})")
    print(f"    {BAR_CHARS['warning']}  WARNING  ({LEVEL_WARNING:.1f} - {LEVEL_CRITICAL:.1f})")
    print(f"    {BAR_CHARS['critical']}  CRITICAL (>= {LEVEL_CRITICAL:.1f})")
    print("=" * 70)
    print()

    sys.exit(0)


if __name__ == "__main__":
    main()
