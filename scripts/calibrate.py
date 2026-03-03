#!/usr/bin/env python3
"""Compute device-specific noise floor and safe thresholds from field CSV data.

Usage:
    python scripts/calibrate.py
    python scripts/calibrate.py --csv data/field/session_001.csv
    python scripts/calibrate.py --device-id DEV001
    python scripts/calibrate.py --csv data/field/session_001.csv --device-id DEV001 --output calibration.json

Loads the specified CSV (or all CSVs in ./data/field/ if none given). If
--device-id is provided, filters to that device only.

Computes:
  noise_floor_ppv    — mean PPV of the bottom 20th percentile (assumed safe)
  safe_threshold_ppv — noise_floor * 3.0 (trigger level)
  freq_baseline      — mean dominant frequency over the full dataset
  kurtosis_baseline  — mean kurtosis over the full dataset

Writes a JSON calibration file and prints results to stdout.

Uses only stdlib — no external packages required.
"""

import argparse
import csv
import json
import math
import os
import sys
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_DATA_DIR = "./data/field"
DEFAULT_OUTPUT = "calibration.json"
NOISE_PERCENTILE = 20          # % — bottom percentile treated as noise floor
THRESHOLD_MULTIPLIER = 3.0     # noise_floor * multiplier = safe threshold
DEVICE_COLS = ("device_id", "device", "id", "node_id")


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _load_csv_file(path: str) -> list:
    rows = []
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(dict(row))
    except (OSError, csv.Error) as exc:
        print(f"Warning: could not read {path}: {exc}", file=sys.stderr)
    return rows


def load_data(csv_path: str | None, data_dir: str) -> list:
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
# Helpers
# ---------------------------------------------------------------------------

def _detect_col(rows: list, candidates: tuple) -> str | None:
    if not rows:
        return None
    for c in candidates:
        if c in rows[0]:
            return c
    return None


def _floats(rows: list, col: str) -> list:
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


def _percentile(sorted_vals: list, pct: float) -> float:
    """Return the value at the given percentile (0-100) using linear interpolation."""
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    if n == 1:
        return sorted_vals[0]
    idx = pct / 100.0 * (n - 1)
    lo = int(idx)
    hi = lo + 1
    if hi >= n:
        return sorted_vals[-1]
    frac = idx - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def _mean(vals: list) -> float:
    if not vals:
        return 0.0
    return sum(vals) / len(vals)


# ---------------------------------------------------------------------------
# Calibration logic
# ---------------------------------------------------------------------------

def filter_by_device(rows: list, device_id: str) -> list:
    """Return only rows matching the given device_id."""
    col = _detect_col(rows, DEVICE_COLS)
    if col is None:
        print(
            f"Warning: no device_id column found; ignoring --device-id filter.",
            file=sys.stderr,
        )
        return rows
    filtered = [r for r in rows if r.get(col, "").strip() == device_id]
    return filtered


def compute_calibration(rows: list, device_id: str | None) -> dict:
    """Compute calibration parameters from a list of row-dicts.

    Returns a dict with calibration results.
    """
    ppv_vals = _floats(rows, "ppv")
    freq_vals = _floats(rows, "freq")
    kurtosis_vals = _floats(rows, "kurtosis")

    if not ppv_vals:
        print("Error: no valid PPV values found in data.", file=sys.stderr)
        sys.exit(1)

    # Noise floor: mean of bottom NOISE_PERCENTILE %
    sorted_ppv = sorted(ppv_vals)
    cutoff_val = _percentile(sorted_ppv, NOISE_PERCENTILE)
    noise_samples = [v for v in sorted_ppv if v <= cutoff_val]
    noise_floor = _mean(noise_samples) if noise_samples else _mean(sorted_ppv[:max(1, len(sorted_ppv) // 5)])

    safe_threshold = noise_floor * THRESHOLD_MULTIPLIER
    freq_baseline = _mean(freq_vals) if freq_vals else 0.0
    kurtosis_baseline = _mean(kurtosis_vals) if kurtosis_vals else 0.0

    return {
        "device_id": device_id or "all",
        "calibrated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "noise_floor_ppv": round(noise_floor, 6),
        "safe_threshold_ppv": round(safe_threshold, 6),
        "freq_baseline": round(freq_baseline, 4),
        "kurtosis_baseline": round(kurtosis_baseline, 4),
        "sample_count": len(rows),
        "ppv_sample_count": len(ppv_vals),
        "noise_percentile_used": NOISE_PERCENTILE,
        "threshold_multiplier": THRESHOLD_MULTIPLIER,
    }


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def print_results(cal: dict) -> None:
    """Print calibration results in a human-readable format."""
    print()
    print("Calibration Results")
    print("===================")
    print(f"  Device ID            : {cal['device_id']}")
    print(f"  Calibrated at        : {cal['calibrated_at']}")
    print(f"  Total rows loaded    : {cal['sample_count']}")
    print(f"  PPV samples used     : {cal['ppv_sample_count']}")
    print(f"  Noise percentile     : bottom {cal['noise_percentile_used']}%")
    print()
    print(f"  Noise floor PPV      : {cal['noise_floor_ppv']:.6f} mm/s")
    print(f"  Safe threshold PPV   : {cal['safe_threshold_ppv']:.6f} mm/s"
          f"  (noise_floor x {cal['threshold_multiplier']})")
    print(f"  Frequency baseline   : {cal['freq_baseline']:.4f} Hz")
    print(f"  Kurtosis baseline    : {cal['kurtosis_baseline']:.4f}")
    print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Compute device-specific noise floor and safe thresholds from field CSV data."
        )
    )
    parser.add_argument(
        "--csv",
        default=None,
        metavar="PATH",
        help="Path to a single CSV file. If omitted, loads all CSVs in ./data/field/.",
    )
    parser.add_argument(
        "--device-id",
        default=None,
        metavar="DEV",
        help="Filter to a specific device_id. If omitted, uses all devices.",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        metavar="FILE",
        help=f"Output JSON file path (default: {DEFAULT_OUTPUT}).",
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help=f"Directory of field CSVs used when --csv is omitted (default: {DEFAULT_DATA_DIR}).",
    )
    args = parser.parse_args()

    rows = load_data(args.csv, args.data_dir)

    if not rows:
        print("No data loaded. Use --csv or ensure --data-dir contains CSV files.")
        sys.exit(1)

    if args.device_id:
        rows = filter_by_device(rows, args.device_id)
        if not rows:
            print(f"Error: no rows found for device_id='{args.device_id}'.", file=sys.stderr)
            sys.exit(1)

    cal = compute_calibration(rows, args.device_id)

    print_results(cal)

    # Write JSON
    out_dir = os.path.dirname(args.output)
    if out_dir and not os.path.isdir(out_dir):
        try:
            os.makedirs(out_dir, exist_ok=True)
        except OSError as exc:
            print(f"Error creating output directory: {exc}", file=sys.stderr)
            sys.exit(1)

    try:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(cal, f, indent=2)
        print(f"Calibration written to: {args.output}")
    except OSError as exc:
        print(f"Error writing {args.output}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
