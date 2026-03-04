#!/usr/bin/env python3
"""
Visualize PPV vibration timeline from field session CSVs.

Renders an ASCII timeline showing PPV intensity over time,
with threshold markers and anomaly level annotations.

Usage:
    python scripts/vibration_timeline.py --data-dir ./data/field
    python scripts/vibration_timeline.py --csv session.csv --width 80
"""

import argparse
import sys
from pathlib import Path
from datetime import datetime

import numpy as np

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False


# ASCII intensity characters (low to high)
INTENSITY_CHARS = " ▁▂▃▄▅▆▇█"
ALERT_CHARS = {
    "CRITICAL": "!",
    "ANOMALY":  "^",
    "SAFE":     " ",
}


def load_csv(csv_path: Path):
    """Load a single session CSV."""
    if not HAS_PANDAS:
        return None, "pandas not available"
    try:
        df = pd.read_csv(csv_path)
        return df, None
    except Exception as e:
        return None, str(e)


def ppv_to_char(ppv: float, max_ppv: float) -> str:
    """Convert PPV value to intensity character."""
    chars = INTENSITY_CHARS
    if max_ppv <= 0:
        return chars[0]
    frac = min(1.0, ppv / max_ppv)
    idx = int(frac * (len(chars) - 1))
    return chars[idx]


def render_timeline(df, width: int = 60, ppv_col: str = "ppv") -> list:
    """Render ASCII timeline lines."""
    if ppv_col not in df.columns:
        return ["  No PPV data column found"]

    ppv = df[ppv_col].fillna(0).values
    n = len(ppv)

    if n == 0:
        return ["  No data"]

    # Downsample or upsample to width
    indices = np.linspace(0, n - 1, width, dtype=int)
    sampled = ppv[indices]

    max_ppv = max(ppv.max(), 0.001)
    lines = []

    # Header
    lines.append(f"  PPV Timeline (max={max_ppv:.3f} mm/s, n={n} samples)")
    lines.append("")

    # Threshold lines at heights
    chart_height = 8
    for row in range(chart_height, 0, -1):
        level = (row / chart_height) * max_ppv
        row_chars = []
        for v in sampled:
            if v >= level:
                row_chars.append("█")
            else:
                row_chars.append(" ")
        line_label = f"{level:>6.3f} |"
        lines.append(f"  {line_label}{''.join(row_chars)}|")

    # X-axis
    lines.append(f"  {'0.000':>6} +{'─' * width}+")

    # Time axis labels
    if "timestamp" in df.columns:
        ts = pd.to_datetime(df["timestamp"], errors="coerce")
        valid_ts = ts.dropna()
        if len(valid_ts) > 0:
            start = valid_ts.iloc[0].strftime("%H:%M:%S")
            end = valid_ts.iloc[-1].strftime("%H:%M:%S")
            mid = valid_ts.iloc[len(valid_ts) // 2].strftime("%H:%M")
            pad = width // 2 - len(mid) // 2
            lines.append(f"  {'':>8}{start}{' ' * pad}{mid}{' ' * (width - pad - len(start) - len(mid))}{end}")

    # Anomaly annotations
    if "anomaly_level" in df.columns:
        anomaly_events = df[df["anomaly_level"].isin(["ANOMALY", "CRITICAL"])]
        if not anomaly_events.empty:
            lines.append("")
            lines.append(f"  Alert events: {len(anomaly_events)} "
                         f"({(len(anomaly_events)/n*100):.1f}% of readings)")

    # Stats
    lines.append("")
    lines.append(f"  Mean: {ppv.mean():.4f}  P95: {np.percentile(ppv, 95):.4f}  Max: {ppv.max():.4f} mm/s")

    return lines


def main():
    parser = argparse.ArgumentParser(description="ASCII vibration PPV timeline")
    parser.add_argument("--data-dir", default="./data/field", help="Directory with field CSVs")
    parser.add_argument("--csv", help="Single CSV file to visualize")
    parser.add_argument("--width", type=int, default=60, help="Chart width in chars")
    args = parser.parse_args()

    if not HAS_PANDAS:
        print("pandas required: pip install pandas")
        return 1

    csv_files = []
    if args.csv:
        csv_files = [Path(args.csv)]
    else:
        data_dir = Path(args.data_dir)
        csv_files = sorted(data_dir.glob("*.csv")) if data_dir.exists() else []

    if not csv_files:
        print(f"No CSV files found. Use --csv FILE or --data-dir DIR")
        return 0

    enc = getattr(sys.stdout, "encoding", "utf-8") or "utf-8"
    if not enc.lower().startswith("utf"):
        # Fallback to ASCII-only mode
        global INTENSITY_CHARS
        INTENSITY_CHARS = " .:;|IH#@"

    for csv_path in csv_files:
        df, err = load_csv(csv_path)
        if err:
            print(f"  Error reading {csv_path.name}: {err}")
            continue

        print()
        print(f"{'=' * (args.width + 15)}")
        print(f"  File: {csv_path.name}")
        print(f"{'=' * (args.width + 15)}")

        lines = render_timeline(df, width=args.width)
        for line in lines:
            print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
