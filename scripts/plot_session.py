#!/usr/bin/env python3
"""ASCII time-series plot of a numeric feature (default: PPV) from field CSV data.

Usage:
    python scripts/plot_session.py
    python scripts/plot_session.py --csv data/field/session_001.csv
    python scripts/plot_session.py --csv data/field/session_001.csv --feature rms
    python scripts/plot_session.py --feature kurtosis

If --csv is omitted, all CSVs in ./data/field/ are concatenated in filename order.

Output example:
    PPV over time  (N=120 samples)
    0.850 │                                           █
          │                            █         █ █ █
    0.567 │              █         █ █   █   █ █       █
          │        █ █ █   █   █ █                       █
    0.283 │    █ █           █
          │  █
    0.000 └──────────────────────────────────────────────────────────────
          2025-03-01 09:00                         2025-03-01 09:02

    count=120  min=0.000  max=0.850  mean=0.412  std=0.231

Uses only stdlib — no matplotlib or numpy required.
"""

import argparse
import csv
import math
import os
import statistics
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CHART_WIDTH = 80   # columns for the plot area (excluding Y-axis label)
CHART_HEIGHT = 20  # rows for the plot area (excluding X axis)
Y_LABEL_WIDTH = 7  # characters reserved for Y-axis numeric labels
DATA_CHAR = "\u2588"   # █  full block
Y_AXIS_CHAR = "\u2502"  # │  box drawings light vertical
X_AXIS_CHAR = "\u2500"  # ─  box drawings light horizontal
CORNER_CHAR = "\u2514"  # └  box drawings light up and right


# ---------------------------------------------------------------------------
# CSV loading helpers
# ---------------------------------------------------------------------------

def _load_csv_file(path: str) -> list:
    """Return list of row-dicts from a single CSV file."""
    rows = []
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(dict(row))
    except (OSError, csv.Error) as exc:
        print(f"Warning: could not read {path}: {exc}", file=sys.stderr)
    return rows


def load_data(csv_path: str | None, data_dir: str = "./data/field") -> list:
    """Load rows from a specific CSV or all CSVs in data_dir."""
    if csv_path:
        if not os.path.isfile(csv_path):
            print(f"Error: file not found: {csv_path}", file=sys.stderr)
            sys.exit(1)
        return _load_csv_file(csv_path)

    if not os.path.isdir(data_dir):
        print(f"Error: data directory not found: {data_dir}", file=sys.stderr)
        sys.exit(1)

    rows = []
    for fname in sorted(os.listdir(data_dir)):
        if fname.endswith(".csv"):
            rows.extend(_load_csv_file(os.path.join(data_dir, fname)))
    return rows


# ---------------------------------------------------------------------------
# Data extraction
# ---------------------------------------------------------------------------

def extract_series(rows: list, feature: str) -> tuple:
    """Extract (timestamps, values) from rows.

    Returns:
        (timestamps, values) where timestamps are raw strings (or row index
        strings if no timestamp column) and values are floats.
    """
    timestamps = []
    values = []
    ts_col = None
    # Detect timestamp column
    for candidate in ("timestamp", "time", "ts", "datetime"):
        if rows and candidate in rows[0]:
            ts_col = candidate
            break

    for i, row in enumerate(rows):
        raw_val = row.get(feature)
        if raw_val is None or raw_val == "":
            continue
        try:
            val = float(raw_val)
        except ValueError:
            continue
        ts = row.get(ts_col, str(i)) if ts_col else str(i)
        timestamps.append(ts)
        values.append(val)

    return timestamps, values


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------

def compute_stats(values: list) -> dict:
    """Return count/min/max/mean/std for a list of floats."""
    n = len(values)
    if n == 0:
        return {"count": 0, "min": 0.0, "max": 0.0, "mean": 0.0, "std": 0.0}
    v_min = min(values)
    v_max = max(values)
    mean = sum(values) / n
    variance = sum((v - mean) ** 2 for v in values) / n if n > 1 else 0.0
    std = math.sqrt(variance)
    return {"count": n, "min": v_min, "max": v_max, "mean": mean, "std": std}


# ---------------------------------------------------------------------------
# ASCII chart renderer
# ---------------------------------------------------------------------------

def render_chart(timestamps: list, values: list, feature: str) -> str:
    """Render an 80-column ASCII line chart.

    Args:
        timestamps: List of timestamp strings (same length as values).
        values:     List of float data points.
        feature:    Feature name for title.

    Returns:
        Multi-line string ready to print.
    """
    n = len(values)
    if n == 0:
        return f"{feature.upper()} over time  (N=0 samples)\n  (no data)"

    stats = compute_stats(values)
    v_min = stats["min"]
    v_max = stats["max"]

    # Avoid zero range
    v_range = v_max - v_min if v_max != v_min else 1.0

    # ---- Sample down to CHART_WIDTH columns --------------------------------
    # Each column gets zero or more values; we plot the max in that column.
    col_values: list = [None] * CHART_WIDTH
    for i, v in enumerate(values):
        col = int(i / n * CHART_WIDTH)
        if col >= CHART_WIDTH:
            col = CHART_WIDTH - 1
        if col_values[col] is None or v > col_values[col]:
            col_values[col] = v

    # ---- Build grid (row 0 = top) ------------------------------------------
    grid = [[" "] * CHART_WIDTH for _ in range(CHART_HEIGHT)]
    for col, v in enumerate(col_values):
        if v is None:
            continue
        # Map value to row: row 0 is top (v_max), row CHART_HEIGHT-1 is bottom (v_min)
        row = int((v_max - v) / v_range * (CHART_HEIGHT - 1))
        row = max(0, min(CHART_HEIGHT - 1, row))
        grid[row][col] = DATA_CHAR

    # ---- Y-axis labels (3 tick marks) -------------------------------------
    # We want labels at top (v_max), middle (mean), bottom (v_min)
    label_rows = {
        0: v_max,
        CHART_HEIGHT // 2: stats["mean"],
        CHART_HEIGHT - 1: v_min,
    }

    # ---- Render lines -------------------------------------------------------
    lines = []
    title = f"{feature.upper()} over time  (N={n} samples)"
    lines.append(title)
    lines.append("")

    for row_idx in range(CHART_HEIGHT):
        label_val = label_rows.get(row_idx)
        if label_val is not None:
            y_label = f"{label_val:>{Y_LABEL_WIDTH}.3f}"
        else:
            y_label = " " * Y_LABEL_WIDTH

        row_str = "".join(grid[row_idx])
        lines.append(f"{y_label} {Y_AXIS_CHAR}{row_str}")

    # ---- X axis -------------------------------------------------------------
    x_axis_line = " " * Y_LABEL_WIDTH + " " + CORNER_CHAR + X_AXIS_CHAR * CHART_WIDTH
    lines.append(x_axis_line)

    # X labels: first and last timestamp
    first_ts = timestamps[0] if timestamps else ""
    last_ts = timestamps[-1] if timestamps else ""
    # Truncate timestamps to fit
    max_ts_len = CHART_WIDTH // 2 - 2
    first_ts = first_ts[:max_ts_len]
    last_ts = last_ts[:max_ts_len]
    padding = CHART_WIDTH - len(first_ts) - len(last_ts)
    if padding < 1:
        padding = 1
    x_label_line = (
        " " * (Y_LABEL_WIDTH + 2)
        + first_ts
        + " " * padding
        + last_ts
    )
    lines.append(x_label_line)

    # ---- Summary statistics -------------------------------------------------
    lines.append("")
    lines.append(
        f"  count={stats['count']}  "
        f"min={stats['min']:.3f}  "
        f"max={stats['max']:.3f}  "
        f"mean={stats['mean']:.3f}  "
        f"std={stats['std']:.3f}"
    )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print an ASCII time-series chart for a field CSV feature."
    )
    parser.add_argument(
        "--csv",
        default=None,
        metavar="PATH",
        help="Path to a single CSV file. If omitted, loads all CSVs in ./data/field/.",
    )
    parser.add_argument(
        "--feature",
        default="ppv",
        metavar="FEATURE",
        help="Column name to plot (default: ppv).",
    )
    args = parser.parse_args()

    rows = load_data(args.csv)

    if not rows:
        print("No data loaded. Use --csv or ensure ./data/field/ contains CSV files.")
        sys.exit(1)

    timestamps, values = extract_series(rows, args.feature)

    if not values:
        print(f"No numeric values found for feature '{args.feature}'.")
        available = sorted(rows[0].keys()) if rows else []
        print(f"Available columns: {', '.join(available)}")
        sys.exit(1)

    chart = render_chart(timestamps, values, args.feature)
    print(chart)


if __name__ == "__main__":
    main()
