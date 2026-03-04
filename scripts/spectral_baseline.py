#!/usr/bin/env python3
"""
spectral_baseline.py — Compute spectral baseline from collected vibration CSVs.

Usage:
    python scripts/spectral_baseline.py [--data-dir DIR] [--save] [--compare FILE]

Computes mean power spectrum from all normal (non-alert) readings.
Use --save to write baseline_spectrum.json to data dir.
Use --compare FILE to compare current data against saved baseline.
"""

import argparse
import csv
import json
import math
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Frequency band definitions (Hz)
# ---------------------------------------------------------------------------

BANDS = [
    ("0-10Hz",   0,   10),
    ("10-50Hz",  10,  50),
    ("50-100Hz", 50,  100),
    ("100Hz+",   100, None),
]

# Assumed sample rate for band estimation from diff-based proxy
ASSUMED_SAMPLE_RATE_HZ = 200.0


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_csvs(data_dir: Path) -> list:
    """Load all CSV files from data_dir. Returns list of (filename, rows) tuples."""
    files = []
    for csv_path in sorted(data_dir.glob("**/*.csv")):
        try:
            with open(csv_path, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                rows = list(reader)
            if rows:
                files.append((csv_path.name, rows))
        except Exception:
            pass
    return files


def extract_accel_columns(rows: list, filename: str) -> tuple:
    """
    Extract ax, ay, az float lists from rows.
    Returns (ax_list, ay_list, az_list) or raises ValueError if columns missing.
    """
    if not rows:
        raise ValueError("empty rows")
    required = {"ax", "ay", "az"}
    available = set(rows[0].keys())
    missing = required - available
    if missing:
        raise ValueError(f"missing columns: {sorted(missing)}")

    ax, ay, az = [], [], []
    for row in rows:
        try:
            ax.append(float(row["ax"]))
            ay.append(float(row["ay"]))
            az.append(float(row["az"]))
        except (ValueError, TypeError):
            pass  # skip malformed rows
    return ax, ay, az


# ---------------------------------------------------------------------------
# Spectral energy proxy
# ---------------------------------------------------------------------------

def diffs(values: list) -> list:
    """Return list of absolute sample-to-sample differences."""
    if len(values) < 2:
        return []
    return [abs(values[i] - values[i - 1]) for i in range(1, len(values))]


def band_energy_from_diffs(diff_sequence: list, sample_rate: float = ASSUMED_SAMPLE_RATE_HZ) -> dict:
    """
    Estimate energy per frequency band using diff magnitude as high-frequency proxy.

    The Nyquist frequency of first differences is sample_rate / 2.
    We treat each diff as representing one sample's worth of change and apportion
    energy into bands by a simple linear mapping of the diff index to frequency:
      freq_i = (i / N) * (sample_rate / 2)
    where N = len(diff_sequence).

    Band energy = mean squared diff within that band's frequency range.
    """
    n = len(diff_sequence)
    if n == 0:
        return {band[0]: 0.0 for band in BANDS}

    nyquist = sample_rate / 2.0
    band_energies = {band[0]: [] for band in BANDS}

    for i, d in enumerate(diff_sequence):
        freq = (i / n) * nyquist
        d_sq = d * d
        for band_name, lo, hi in BANDS:
            if hi is None:
                if freq >= lo:
                    band_energies[band_name].append(d_sq)
                    break
            elif lo <= freq < hi:
                band_energies[band_name].append(d_sq)
                break

    result = {}
    for band_name, values in band_energies.items():
        result[band_name] = sum(values) / len(values) if values else 0.0
    return result


def compute_band_energies(ax: list, ay: list, az: list) -> dict:
    """
    Compute per-band energies from 3-axis accelerometer data.
    Combines diffs from all three axes.
    """
    combined_diffs = diffs(ax) + diffs(ay) + diffs(az)
    return band_energy_from_diffs(combined_diffs)


# ---------------------------------------------------------------------------
# Baseline computation
# ---------------------------------------------------------------------------

def compute_baseline(files: list) -> tuple:
    """
    Compute aggregate band energies across all loaded files.
    Returns (band_energies_dict, total_samples, skipped_files).
    """
    totals = {band[0]: 0.0 for band in BANDS}
    count = 0
    skipped = []

    for filename, rows in files:
        try:
            ax, ay, az = extract_accel_columns(rows, filename)
        except ValueError as e:
            print(f"  WARNING: {filename} — {e}, skipping.")
            skipped.append(filename)
            continue

        if not ax:
            skipped.append(filename)
            continue

        energies = compute_band_energies(ax, ay, az)
        for band_name in totals:
            totals[band_name] += energies[band_name]
        count += 1

    if count == 0:
        return {band[0]: 0.0 for band in BANDS}, 0, skipped

    averaged = {band_name: totals[band_name] / count for band_name in totals}
    return averaged, count, skipped


# ---------------------------------------------------------------------------
# ASCII output helpers
# ---------------------------------------------------------------------------

def print_band_table(energies: dict, title: str = "Band Energies") -> None:
    print(f"\n{title}:")
    print(f"  {'Band':<12}  {'Energy (mean sq diff)':>22}")
    print("  " + "-" * 38)
    for band_name, _, __ in BANDS:
        energy = energies.get(band_name, 0.0)
        print(f"  {band_name:<12}  {energy:>22.6e}")


def print_comparison_table(current: dict, baseline: dict, deviation_threshold: float = 2.0) -> None:
    print(f"\nComparison vs Baseline (flag if deviation > {deviation_threshold}x):")
    print(f"  {'Band':<12}  {'Current':>14}  {'Baseline':>14}  {'Ratio':>8}  {'Status':<12}")
    print("  " + "-" * 68)
    for band_name, _, __ in BANDS:
        curr_val = current.get(band_name, 0.0)
        base_val = baseline.get(band_name, 0.0)
        if base_val == 0.0:
            ratio = float("inf") if curr_val > 0 else 1.0
            status = "NO BASELINE"
        else:
            ratio = curr_val / base_val
            status = "DEVIATED" if ratio > deviation_threshold else "OK"
        if math.isinf(ratio):
            ratio_str = "inf"
        else:
            ratio_str = f"{ratio:.2f}x"
        print(
            f"  {band_name:<12}  {curr_val:>14.6e}  {base_val:>14.6e}  "
            f"{ratio_str:>8}  {status:<12}"
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Compute spectral baseline from collected vibration CSVs."
    )
    parser.add_argument(
        "--data-dir",
        default="./data",
        help="Directory containing field CSV files (default: ./data)",
    )
    parser.add_argument(
        "--save",
        action="store_true",
        help="Save computed baseline to data_dir/baseline_spectrum.json",
    )
    parser.add_argument(
        "--compare",
        metavar="FILE",
        default=None,
        help="Compare current data against saved baseline JSON file",
    )
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        print("No data directory found.")
        return 0

    files = load_csvs(data_dir)
    if not files:
        print("No CSV files found.")
        return 0

    print(f"Loaded {len(files)} CSV file(s) from {data_dir}.")
    band_energies, sample_count, skipped = compute_baseline(files)

    if sample_count == 0:
        print("No valid ax/ay/az data found in any CSV file.")
        return 0

    print_band_table(band_energies, title=f"Computed Spectral Baseline ({sample_count} file(s))")

    if args.save:
        out_path = data_dir / "baseline_spectrum.json"
        payload = {
            "band_energies": band_energies,
            "sample_count": sample_count,
            "bands": [b[0] for b in BANDS],
        }
        out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nBaseline saved to: {out_path}")

    if args.compare:
        compare_path = Path(args.compare)
        if not compare_path.exists():
            print(f"\nERROR: Compare file not found: {compare_path}")
            return 0
        try:
            saved = json.loads(compare_path.read_text(encoding="utf-8"))
            saved_energies = saved.get("band_energies", {})
        except Exception as e:
            print(f"\nERROR: Could not read baseline file: {e}")
            return 0
        print_comparison_table(band_energies, saved_energies)

    return 0


if __name__ == "__main__":
    sys.exit(main())
