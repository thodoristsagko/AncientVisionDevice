#!/usr/bin/env python3
"""
signal_quality_report.py — Analyze signal quality from collected vibration data.

Usage:
    python scripts/signal_quality_report.py [--data-dir DIR]

Checks for: packet gaps (missing seq numbers), outlier values, timestamp jitter,
duplicate packets, and overall data completeness.
"""

import argparse
import csv
import math
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Scoring weights (must sum to 100)
# ---------------------------------------------------------------------------
# no_gaps=30, low_jitter=20, no_outliers=20, no_duplicates=30

SCORE_NO_GAPS = 30
SCORE_LOW_JITTER = 20
SCORE_NO_OUTLIERS = 20
SCORE_NO_DUPLICATES = 30

# Jitter threshold: std dev of inter-sample intervals vs mean interval
JITTER_THRESHOLD_RATIO = 0.5   # std/mean > 0.5 is considered high jitter

# Outlier detection: mark values > mean ± N * std
OUTLIER_SIGMA = 5.0

# Overall quality thresholds
QUALITY_EXCELLENT = 80
QUALITY_GOOD = 60


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_float(val) -> float | None:
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def _parse_int(val) -> int | None:
    try:
        return int(float(val))
    except (ValueError, TypeError):
        return None


def _mean(values: list[float]) -> float:
    if not values:
        return 0.0
    return sum(values) / len(values)


def _std(values: list[float]) -> float:
    if len(values) < 2:
        return 0.0
    m = _mean(values)
    variance = sum((v - m) ** 2 for v in values) / len(values)
    return math.sqrt(variance)


# ---------------------------------------------------------------------------
# Per-file analysis
# ---------------------------------------------------------------------------

def analyze_file(csv_path: Path) -> dict:
    """
    Analyze a single CSV file for signal quality issues.
    Returns a dict with per-metric results and a completeness score (0-100).
    """
    rows = []
    try:
        with open(csv_path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(row)
    except Exception as e:
        return {
            "file": csv_path.name,
            "n_rows": 0,
            "error": str(e),
            "score": 0,
            "quality": "POOR",
        }

    if not rows:
        return {
            "file": csv_path.name,
            "n_rows": 0,
            "gap_count": 0,
            "jitter_ratio": 0.0,
            "outlier_count": 0,
            "duplicate_count": 0,
            "score": 100,
            "quality": "EXCELLENT",
        }

    n = len(rows)
    has_seq = "seq" in rows[0]

    # ------------------------------------------------------------------
    # 1. Packet gap detection (if seq column exists)
    # ------------------------------------------------------------------
    gap_count = 0
    if has_seq:
        seq_vals = []
        for row in rows:
            v = _parse_int(row.get("seq"))
            if v is not None:
                seq_vals.append(v)

        if len(seq_vals) >= 2:
            for i in range(1, len(seq_vals)):
                diff = seq_vals[i] - seq_vals[i - 1]
                # Handle wraparound (seq is typically uint8 or uint16)
                if diff < 0:
                    diff += 256  # assume uint8 rollover
                if diff > 1:
                    gap_count += diff - 1

    # ------------------------------------------------------------------
    # 2. Timestamp jitter
    # ------------------------------------------------------------------
    timestamps = []
    for row in rows:
        ts_str = row.get("timestamp", "")
        if not ts_str:
            continue
        # Try numeric Unix timestamp first
        v = _parse_float(ts_str)
        if v is not None:
            timestamps.append(v)
        else:
            # Try ISO format: extract seconds component for rough ordering
            from datetime import datetime, timezone
            for fmt in (
                "%Y-%m-%dT%H:%M:%S.%fZ",
                "%Y-%m-%dT%H:%M:%SZ",
                "%Y-%m-%dT%H:%M:%S",
                "%Y-%m-%d %H:%M:%S",
            ):
                try:
                    dt = datetime.strptime(ts_str.strip(), fmt)
                    timestamps.append(dt.replace(tzinfo=timezone.utc).timestamp())
                    break
                except ValueError:
                    continue

    jitter_ratio = 0.0
    if len(timestamps) >= 3:
        intervals = [timestamps[i] - timestamps[i - 1] for i in range(1, len(timestamps))]
        # Filter out negative intervals (clock jumps)
        pos_intervals = [iv for iv in intervals if iv > 0]
        if pos_intervals:
            mean_iv = _mean(pos_intervals)
            std_iv = _std(pos_intervals)
            jitter_ratio = std_iv / mean_iv if mean_iv > 0 else 0.0

    # ------------------------------------------------------------------
    # 3. Outlier detection on PPV (and ax/ay/az if present)
    # ------------------------------------------------------------------
    outlier_count = 0
    numeric_cols = [c for c in ("ppv", "ax", "ay", "az", "rms") if c in (rows[0] if rows else {})]
    for col in numeric_cols:
        vals = [_parse_float(row.get(col)) for row in rows]
        vals = [v for v in vals if v is not None]
        if len(vals) < 3:
            continue
        m = _mean(vals)
        s = _std(vals)
        if s == 0:
            continue
        outlier_count += sum(1 for v in vals if abs(v - m) > OUTLIER_SIGMA * s)

    # ------------------------------------------------------------------
    # 4. Duplicate detection (exact duplicate rows)
    # ------------------------------------------------------------------
    row_tuples = [tuple(sorted(row.items())) for row in rows]
    duplicate_count = len(row_tuples) - len(set(row_tuples))

    # ------------------------------------------------------------------
    # 5. Completeness score (0-100)
    # ------------------------------------------------------------------
    # Gaps component
    if not has_seq or gap_count == 0:
        gap_score = SCORE_NO_GAPS
    else:
        # Partial credit: 0 score if gaps >= 10% of packets
        gap_pct = gap_count / max(n, 1)
        gap_score = max(0, SCORE_NO_GAPS * (1.0 - gap_pct / 0.10))

    # Jitter component
    if jitter_ratio <= JITTER_THRESHOLD_RATIO:
        jitter_score = SCORE_LOW_JITTER
    else:
        # Linearly reduce from threshold to 2x threshold
        excess = (jitter_ratio - JITTER_THRESHOLD_RATIO) / JITTER_THRESHOLD_RATIO
        jitter_score = max(0.0, SCORE_LOW_JITTER * (1.0 - excess))

    # Outlier component
    if n > 0:
        outlier_pct = outlier_count / n
        outlier_score = max(0.0, SCORE_NO_OUTLIERS * (1.0 - outlier_pct / 0.05))
    else:
        outlier_score = SCORE_NO_OUTLIERS

    # Duplicate component
    if n > 0:
        dup_pct = duplicate_count / n
        dup_score = max(0.0, SCORE_NO_DUPLICATES * (1.0 - dup_pct / 0.05))
    else:
        dup_score = SCORE_NO_DUPLICATES

    total_score = int(round(gap_score + jitter_score + outlier_score + dup_score))
    total_score = min(100, max(0, total_score))

    if total_score >= QUALITY_EXCELLENT:
        quality = "EXCELLENT"
    elif total_score >= QUALITY_GOOD:
        quality = "GOOD"
    else:
        quality = "POOR"

    return {
        "file": csv_path.name,
        "n_rows": n,
        "has_seq": has_seq,
        "gap_count": gap_count,
        "jitter_ratio": jitter_ratio,
        "outlier_count": outlier_count,
        "duplicate_count": duplicate_count,
        "score": total_score,
        "quality": quality,
    }


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def print_table(file_results: list[dict]) -> None:
    """Print per-file stats table."""
    if not file_results:
        return

    file_w = max(20, max(len(r["file"]) for r in file_results) + 2)
    rows_w = 8
    gaps_w = 8
    jitter_w = 10
    outlier_w = 10
    dup_w = 8
    score_w = 7
    quality_w = 10

    header = (
        f"{'File':<{file_w}} "
        f"{'Rows':>{rows_w}} "
        f"{'Gaps':>{gaps_w}} "
        f"{'Jitter':>{jitter_w}} "
        f"{'Outliers':>{outlier_w}} "
        f"{'Dups':>{dup_w}} "
        f"{'Score':>{score_w}} "
        f"{'Quality':<{quality_w}}"
    )
    sep = "-" * len(header)

    print()
    print("Signal Quality Report")
    print(sep)
    print(header)
    print(sep)

    for r in file_results:
        if "error" in r:
            print(f"{r['file']:<{file_w}} ERROR: {r['error']}")
            continue

        jitter_str = f"{r['jitter_ratio']:.2f}"
        print(
            f"{r['file']:<{file_w}} "
            f"{r['n_rows']:>{rows_w}} "
            f"{r['gap_count']:>{gaps_w}} "
            f"{jitter_str:>{jitter_w}} "
            f"{r['outlier_count']:>{outlier_w}} "
            f"{r['duplicate_count']:>{dup_w}} "
            f"{r['score']:>{score_w}} "
            f"{r['quality']:<{quality_w}}"
        )

    print(sep)
    print()


def print_overall(file_results: list[dict]) -> None:
    """Print overall signal quality summary."""
    valid = [r for r in file_results if "error" not in r and r["n_rows"] > 0]
    if not valid:
        print("Overall signal quality: N/A (no data)")
        print()
        return

    avg_score = sum(r["score"] for r in valid) / len(valid)
    avg_score_int = int(round(avg_score))

    if avg_score >= QUALITY_EXCELLENT:
        overall = "EXCELLENT"
    elif avg_score >= QUALITY_GOOD:
        overall = "GOOD"
    else:
        overall = "POOR"

    total_gaps = sum(r["gap_count"] for r in valid)
    total_outliers = sum(r["outlier_count"] for r in valid)
    total_dups = sum(r["duplicate_count"] for r in valid)
    total_rows = sum(r["n_rows"] for r in valid)

    print(f"Overall signal quality: {overall} ({avg_score_int}%)")
    print(f"  Files analyzed : {len(valid)}")
    print(f"  Total rows     : {total_rows}")
    print(f"  Total gaps     : {total_gaps}")
    print(f"  Total outliers : {total_outliers}")
    print(f"  Total duplicates: {total_dups}")
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Analyze signal quality from collected vibration data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        help="Directory containing field CSV files (default: ./data/field)",
    )
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)

    if not data_dir.exists():
        print(f"Data directory not found: {data_dir}")
        print("No data to analyze.")
        print()
        print("Overall signal quality: N/A (no data)")
        return 0

    csv_files = sorted(data_dir.glob("*.csv"))
    if not csv_files:
        print("No CSV files found.")
        print()
        print("Overall signal quality: N/A (no data)")
        return 0

    file_results = [analyze_file(f) for f in csv_files]

    print_table(file_results)
    print_overall(file_results)

    return 0


if __name__ == "__main__":
    sys.exit(main())
