#!/usr/bin/env python3
"""Generate a Markdown report from field vibration CSV data.

Usage:
    python scripts/generate_report.py
    python scripts/generate_report.py --data-dir ./data/field
    python scripts/generate_report.py --data-dir ./data/field --output report.md

Reads all CSVs in --data-dir and produces a Markdown report with sections:
  1. Executive Summary
  2. PPV Distribution (ASCII histogram)
  3. Per-Device Statistics
  4. Anomaly Summary  (only if 'label' column present)
  5. Data Quality
  6. Recommendations

Writes Markdown to --output file and also prints to stdout.

Uses only stdlib — no matplotlib or numpy required.
"""

import argparse
import csv
import math
import os
import sys
from datetime import datetime

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_DATA_DIR = "./data/field"
DEFAULT_OUTPUT = "./data/field_report.md"

STANDARD_FEATURES = ["ppv", "rms", "freq", "kurtosis", "psd_slope", "arias_intensity", "cav"]
PPV_SAFE_THRESHOLD = 0.3       # mm/s — DIN 4150-3 residential
PPV_ALERT_THRESHOLD = 2.0      # mm/s — escalation trigger
RETRAIN_THRESHOLD = 100        # new samples since last training to suggest retrain
TIMESTAMP_COLS = ("timestamp", "time", "ts", "datetime")
DEVICE_COLS = ("device_id", "device", "id", "node_id")

NUM_HISTOGRAM_BINS = 10
BAR_CHAR = "\u2588"   # █
MAX_BAR_WIDTH = 40    # columns for 100%

# PPV range sanity bounds
PPV_MIN_VALID = 0.0
PPV_MAX_VALID = 100.0   # mm/s — beyond this is clearly a sensor error


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def load_all_csv(data_dir: str) -> list:
    """Return list of row-dicts from all CSV files in data_dir."""
    rows = []
    if not os.path.isdir(data_dir):
        return rows
    for fname in sorted(os.listdir(data_dir)):
        if not fname.endswith(".csv"):
            continue
        fpath = os.path.join(data_dir, fname)
        try:
            with open(fpath, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(dict(row))
        except (OSError, csv.Error):
            pass
    return rows


# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------

def _floats(rows: list, col: str) -> list:
    """Extract non-null floats from a column."""
    vals = []
    for row in rows:
        raw = row.get(col)
        if raw is None or str(raw).strip() == "":
            continue
        try:
            vals.append(float(raw))
        except ValueError:
            pass
    return vals


def _detect_col(rows: list, candidates: tuple) -> str | None:
    if not rows:
        return None
    for c in candidates:
        if c in rows[0]:
            return c
    return None


def _timestamps(rows: list) -> list:
    col = _detect_col(rows, TIMESTAMP_COLS)
    if not col:
        return []
    return [row[col].strip() for row in rows if row.get(col, "").strip()]


def _device_ids(rows: list) -> list:
    col = _detect_col(rows, DEVICE_COLS)
    if not col:
        return []
    return [row[col].strip() for row in rows if row.get(col, "").strip()]


# ---------------------------------------------------------------------------
# Stats helpers
# ---------------------------------------------------------------------------

def _stats(values: list) -> dict | None:
    n = len(values)
    if n == 0:
        return None
    mean = sum(values) / n
    variance = sum((v - mean) ** 2 for v in values) / n if n > 1 else 0.0
    return {
        "count": n,
        "min": min(values),
        "max": max(values),
        "mean": mean,
        "std": math.sqrt(variance),
    }


# ---------------------------------------------------------------------------
# ASCII histogram
# ---------------------------------------------------------------------------

def _ascii_histogram(values: list, title: str, num_bins: int = NUM_HISTOGRAM_BINS) -> list:
    """Return list of Markdown-compatible lines for an ASCII histogram."""
    lines = []
    n = len(values)
    lines.append(f"**{title}** (N={n})")
    lines.append("```")
    if n == 0:
        lines.append("  (no data)")
        lines.append("```")
        return lines

    v_min = min(values)
    v_max = max(values)
    if v_min == v_max:
        v_max = v_min + 1.0
    bin_width = (v_max - v_min) / num_bins

    counts = [0] * num_bins
    for v in values:
        idx = int((v - v_min) / bin_width)
        if idx >= num_bins:
            idx = num_bins - 1
        counts[idx] += 1

    for i in range(num_bins):
        lo = v_min + i * bin_width
        hi = v_min + (i + 1) * bin_width
        count = counts[i]
        bar_width = int(count / n * MAX_BAR_WIDTH) if n > 0 else 0
        bar = BAR_CHAR * bar_width
        pct = count / n * 100
        lines.append(f"  {lo:7.3f}-{hi:7.3f}: {bar:<{MAX_BAR_WIDTH}} {count:5d} ({pct:5.1f}%)")

    lines.append("```")
    return lines


# ---------------------------------------------------------------------------
# Section builders
# ---------------------------------------------------------------------------

def section_executive_summary(rows: list) -> list:
    lines = ["## 1. Executive Summary", ""]
    n = len(rows)
    ts_list = _timestamps(rows)
    dev_list = _device_ids(rows)
    ppv_vals = _floats(rows, "ppv")

    lines.append(f"- **Total samples**: {n}")
    if ts_list:
        lines.append(f"- **Date range**: {ts_list[0]} — {ts_list[-1]}")
    else:
        lines.append("- **Date range**: (no timestamp column found)")
    unique_devs = sorted(set(dev_list))
    lines.append(f"- **Unique devices**: {len(unique_devs)}"
                 + (f" ({', '.join(unique_devs)})" if unique_devs else ""))
    if ppv_vals:
        avg_ppv = sum(ppv_vals) / len(ppv_vals)
        lines.append(f"- **Average PPV**: {avg_ppv:.4f} mm/s")
        lines.append(f"- **Max PPV**: {max(ppv_vals):.4f} mm/s")
    else:
        lines.append("- **Average PPV**: N/A (no ppv column)")
    lines.append(f"- **Report generated**: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    lines.append("")
    return lines


def section_ppv_distribution(rows: list) -> list:
    lines = ["## 2. PPV Distribution", ""]
    ppv_vals = _floats(rows, "ppv")
    hist_lines = _ascii_histogram(ppv_vals, "PPV Distribution (mm/s)")
    lines.extend(hist_lines)
    lines.append("")
    if ppv_vals:
        st = _stats(ppv_vals)
        lines.append(
            f"min={st['min']:.4f}  max={st['max']:.4f}  "
            f"mean={st['mean']:.4f}  std={st['std']:.4f}"
        )
    lines.append("")
    return lines


def section_per_device_stats(rows: list) -> list:
    lines = ["## 3. Per-Device Statistics", ""]
    dev_col = _detect_col(rows, DEVICE_COLS)
    ts_col = _detect_col(rows, TIMESTAMP_COLS)

    if not dev_col:
        lines.append("_(no device_id column found)_")
        lines.append("")
        return lines

    # Group rows by device
    devices: dict = {}
    for row in rows:
        dev = row.get(dev_col, "").strip() or "(unknown)"
        devices.setdefault(dev, []).append(row)

    # Table header
    header = (
        f"| {'Device':<20} | {'Count':>7} | {'Mean PPV':>10} | "
        f"{'Max PPV':>9} | {'First Seen':<22} | {'Last Seen':<22} |"
    )
    divider = (
        f"| {'-'*20} | {'-'*7} | {'-'*10} | "
        f"{'-'*9} | {'-'*22} | {'-'*22} |"
    )
    lines.append(header)
    lines.append(divider)

    for dev in sorted(devices.keys()):
        dev_rows = devices[dev]
        ppv_vals = _floats(dev_rows, "ppv")
        mean_ppv = (sum(ppv_vals) / len(ppv_vals)) if ppv_vals else None
        max_ppv = max(ppv_vals) if ppv_vals else None
        ts_list = []
        if ts_col:
            ts_list = [r[ts_col].strip() for r in dev_rows if r.get(ts_col, "").strip()]
        first_seen = ts_list[0] if ts_list else "N/A"
        last_seen = ts_list[-1] if ts_list else "N/A"
        mean_str = f"{mean_ppv:.4f}" if mean_ppv is not None else "N/A"
        max_str = f"{max_ppv:.4f}" if max_ppv is not None else "N/A"
        lines.append(
            f"| {dev:<20} | {len(dev_rows):>7} | {mean_str:>10} | "
            f"{max_str:>9} | {first_seen:<22} | {last_seen:<22} |"
        )

    lines.append("")
    return lines


def section_anomaly_summary(rows: list) -> list:
    lines = ["## 4. Anomaly Summary", ""]

    if not rows or "label" not in rows[0]:
        lines.append("_(no `label` column found in data)_")
        lines.append("")
        return lines

    label_counts: dict = {}
    for row in rows:
        label = row.get("label", "").strip() or "(blank)"
        label_counts[label] = label_counts.get(label, 0) + 1

    total = sum(label_counts.values())
    lines.append(f"| {'Label':<25} | {'Count':>7} | {'% of total':>12} |")
    lines.append(f"| {'-'*25} | {'-'*7} | {'-'*12} |")
    for label in sorted(label_counts.keys()):
        count = label_counts[label]
        pct = count / total * 100 if total > 0 else 0.0
        lines.append(f"| {label:<25} | {count:>7} | {pct:>11.1f}% |")
    lines.append("")
    return lines


def section_data_quality(rows: list) -> list:
    lines = ["## 5. Data Quality", ""]

    if not rows:
        lines.append("_(no data)_")
        lines.append("")
        return lines

    total = len(rows)
    # Missing fields count (any standard feature that is blank/missing)
    missing_counts: dict = {}
    for feat in STANDARD_FEATURES:
        count = sum(
            1 for row in rows
            if row.get(feat) is None or str(row.get(feat, "")).strip() == ""
        )
        if count > 0:
            missing_counts[feat] = count

    # Out-of-range PPV
    ppv_oor = sum(
        1 for row in rows
        if (v := row.get("ppv")) is not None and str(v).strip() != ""
        and (
            (lambda x: x < PPV_MIN_VALID or x > PPV_MAX_VALID)(
                float(v) if _is_float(str(v)) else float("inf")
            )
        )
    )

    if missing_counts:
        lines.append("**Missing values per feature:**")
        lines.append("")
        lines.append(f"| {'Feature':<20} | {'Missing':>8} | {'% missing':>12} |")
        lines.append(f"| {'-'*20} | {'-'*8} | {'-'*12} |")
        for feat, count in sorted(missing_counts.items()):
            pct = count / total * 100
            lines.append(f"| {feat:<20} | {count:>8} | {pct:>11.1f}% |")
        lines.append("")
    else:
        lines.append("No missing values found for standard features.")
        lines.append("")

    lines.append(
        f"**Out-of-range PPV values** (outside [{PPV_MIN_VALID}, {PPV_MAX_VALID}]): "
        f"{ppv_oor} rows"
    )
    lines.append("")
    return lines


def _is_float(s: str) -> bool:
    try:
        float(s)
        return True
    except ValueError:
        return False


def section_recommendations(rows: list) -> list:
    lines = ["## 6. Recommendations", ""]

    n = len(rows)
    ppv_vals = _floats(rows, "ppv")
    recs = []

    # Sample count recommendation
    if n < 50:
        recs.append(
            f"Only {n} samples collected. **Collect more field data** before training ML models "
            "(minimum 200 samples recommended)."
        )
    elif n >= RETRAIN_THRESHOLD:
        recs.append(
            f"{n} samples collected. Consider **retraining models** if more than "
            f"{RETRAIN_THRESHOLD} new samples have been added since last training run."
        )
    else:
        recs.append(
            f"{n} samples collected. Continue gathering data toward the {RETRAIN_THRESHOLD}-sample "
            "retraining threshold."
        )

    # PPV-based recommendation
    if ppv_vals:
        high_ppv = sum(1 for v in ppv_vals if v > PPV_SAFE_THRESHOLD)
        pct_high = high_ppv / len(ppv_vals) * 100
        if pct_high > 20:
            recs.append(
                f"{pct_high:.1f}% of samples exceed the safe PPV threshold "
                f"({PPV_SAFE_THRESHOLD} mm/s). **Review site conditions** and verify "
                "sensor calibration."
            )
        alert_count = sum(1 for v in ppv_vals if v > PPV_ALERT_THRESHOLD)
        if alert_count > 0:
            recs.append(
                f"{alert_count} sample(s) exceed the alert threshold "
                f"({PPV_ALERT_THRESHOLD} mm/s). **Investigate those events** for potential "
                "ground instability."
            )

    # Label coverage
    if rows and "label" not in rows[0]:
        recs.append(
            "No `label` column found. Run `scripts/label_session.py` to annotate sessions "
            "before training supervised models."
        )
    else:
        unlabeled = sum(1 for row in rows if not row.get("label", "").strip())
        if unlabeled > 0:
            recs.append(
                f"{unlabeled} unlabeled sample(s) found. "
                "Run `scripts/label_session.py --relabel` to complete annotation."
            )

    for rec in recs:
        lines.append(f"- {rec}")

    lines.append("")
    return lines


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

def build_report(rows: list, data_dir: str) -> str:
    """Assemble the full Markdown report as a string."""
    doc_lines = [
        "# AncientVision Field Data Report",
        "",
        f"_Source directory: `{data_dir}`_",
        "",
    ]

    doc_lines.extend(section_executive_summary(rows))
    doc_lines.extend(section_ppv_distribution(rows))
    doc_lines.extend(section_per_device_stats(rows))
    doc_lines.extend(section_anomaly_summary(rows))
    doc_lines.extend(section_data_quality(rows))
    doc_lines.extend(section_recommendations(rows))

    return "\n".join(doc_lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a Markdown report from field vibration CSV data."
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help=f"Directory containing field CSV files (default: {DEFAULT_DATA_DIR}).",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        metavar="FILE",
        help=f"Output Markdown file path (default: {DEFAULT_OUTPUT}).",
    )
    args = parser.parse_args()

    rows = load_all_csv(args.data_dir)

    if not rows:
        print(
            f"Warning: no CSV data found in '{args.data_dir}'. "
            "Report will be generated with empty sections.",
            file=sys.stderr,
        )

    report_md = build_report(rows, args.data_dir)

    # Print to stdout
    print(report_md)

    # Write to file
    out_dir = os.path.dirname(args.output)
    if out_dir and not os.path.isdir(out_dir):
        try:
            os.makedirs(out_dir, exist_ok=True)
        except OSError as exc:
            print(f"Error creating output directory: {exc}", file=sys.stderr)
            sys.exit(1)

    try:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(report_md)
        print(f"\n[Report written to: {args.output}]", file=sys.stderr)
    except OSError as exc:
        print(f"Error writing report to {args.output}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
