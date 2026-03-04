#!/usr/bin/env python3
"""
sensor_noise_floor.py — Analyze sensor noise floor from collected vibration data.

Usage:
    python scripts/sensor_noise_floor.py [--data-dir DIR] [--device DEVICE_ID]

Computes noise floor (RMS of "quiet" samples where PPV < 0.01 mm/s).
Per-device analysis: mean, std of quiet samples.
Flags devices where noise floor has increased >50% vs. baseline.
Helps detect: sensor damage, mounting issues, or environmental interference.
"""

import argparse
import math
import sys
from pathlib import Path

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

# MEMS IMU expected quiet-state noise floor range (g)
NOISE_FLOOR_MIN_G = 0.001
NOISE_FLOOR_MAX_G = 0.01
# Flag threshold: above this in quiet state indicates a sensor issue (g)
NOISE_FLAG_THRESHOLD_G = 0.05

# PPV threshold to consider a sample "quiet" (mm/s)
QUIET_PPV_THRESHOLD = 0.01
# Percentile to use as fallback quiet-sample filter
QUIET_PERCENTILE = 10


def _rms(values) -> float:
    """Compute RMS of a sequence of floats."""
    if len(values) == 0:
        return 0.0
    sq_sum = sum(v * v for v in values)
    return math.sqrt(sq_sum / len(values))


def load_data(data_dir: Path, device_id: str | None):
    """Load all CSV files from data_dir and return a combined list of dicts."""
    if not HAS_PANDAS:
        # Fallback: manual CSV reading
        import csv as _csv
        rows = []
        for csv_path in sorted(data_dir.glob("*.csv")):
            try:
                with open(csv_path, newline="", encoding="utf-8") as f:
                    reader = _csv.DictReader(f)
                    for row in reader:
                        rows.append(row)
            except Exception:
                continue
        return rows, None

    csv_files = list(data_dir.glob("*.csv"))
    if not csv_files:
        return None, f"No CSV files found in {data_dir}"

    dfs = []
    for f in csv_files:
        try:
            df = pd.read_csv(f)
            dfs.append(df)
        except Exception:
            continue

    if not dfs:
        return None, "Could not read any CSV files"

    combined = pd.concat(dfs, ignore_index=True)

    if device_id:
        if "device_id" in combined.columns:
            combined = combined[combined["device_id"] == device_id]
            if combined.empty:
                return None, f"No data found for device '{device_id}'"
        else:
            pass  # No device_id column — treat all data as one device

    return combined, None


def extract_quiet_rows(df, use_pandas: bool):
    """Return subset of df with only quiet samples (PPV below threshold)."""
    if use_pandas:
        if "ppv" not in df.columns:
            return df  # No PPV column — use everything
        ppv_vals = pd.to_numeric(df["ppv"], errors="coerce")
        threshold = QUIET_PPV_THRESHOLD
        quiet = df[ppv_vals < threshold]
        if quiet.empty:
            # Fallback: lowest 10th percentile
            p10 = ppv_vals.quantile(0.10)
            quiet = df[ppv_vals <= p10]
        return quiet
    else:
        # rows is a list of dicts
        if not df or "ppv" not in df[0]:
            return df
        try:
            threshold = QUIET_PPV_THRESHOLD
            quiet = [r for r in df if float(r["ppv"]) < threshold]
            if not quiet:
                ppv_vals = [float(r["ppv"]) for r in df]
                ppv_vals_sorted = sorted(ppv_vals)
                idx = max(0, int(len(ppv_vals_sorted) * 0.10) - 1)
                p10 = ppv_vals_sorted[idx]
                quiet = [r for r in df if float(r["ppv"]) <= p10]
        except (ValueError, KeyError):
            quiet = df
        return quiet


def compute_per_device_stats(df, use_pandas: bool) -> dict:
    """Return dict of device_id -> {rms_ax, rms_ay, rms_az, rms_total, n_quiet}."""
    results = {}

    if use_pandas:
        if "device_id" in df.columns:
            groups = {dev: grp for dev, grp in df.groupby("device_id")}
        else:
            groups = {"ALL": df}

        for device, grp in groups.items():
            quiet = extract_quiet_rows(grp, use_pandas=True)
            n = len(quiet)

            ax_vals = _get_numeric_series(quiet, "ax")
            ay_vals = _get_numeric_series(quiet, "ay")
            az_vals = _get_numeric_series(quiet, "az")

            rms_ax = _rms(ax_vals)
            rms_ay = _rms(ay_vals)
            rms_az = _rms(az_vals)

            # Combined RMS across all axes
            all_vals = ax_vals + ay_vals + az_vals
            rms_total = _rms(all_vals) if all_vals else 0.0

            results[device] = {
                "n_quiet": n,
                "rms_ax": rms_ax,
                "rms_ay": rms_ay,
                "rms_az": rms_az,
                "rms_total": rms_total,
            }
    else:
        # df is list of dicts
        from collections import defaultdict
        device_rows: dict = defaultdict(list)
        for row in df:
            dev = row.get("device_id", "ALL")
            device_rows[dev].append(row)

        for device, rows in device_rows.items():
            quiet = extract_quiet_rows(rows, use_pandas=False)
            n = len(quiet)

            ax_vals = _get_values_from_dicts(quiet, "ax")
            ay_vals = _get_values_from_dicts(quiet, "ay")
            az_vals = _get_values_from_dicts(quiet, "az")

            rms_ax = _rms(ax_vals)
            rms_ay = _rms(ay_vals)
            rms_az = _rms(az_vals)
            all_vals = ax_vals + ay_vals + az_vals
            rms_total = _rms(all_vals) if all_vals else 0.0

            results[device] = {
                "n_quiet": n,
                "rms_ax": rms_ax,
                "rms_ay": rms_ay,
                "rms_az": rms_az,
                "rms_total": rms_total,
            }

    return results


def _get_numeric_series(df, col: str) -> list:
    """Extract a list of floats from a pandas DataFrame column, ignoring NaN."""
    if col not in df.columns:
        return []
    try:
        import pandas as pd
        series = pd.to_numeric(df[col], errors="coerce").dropna()
        return series.tolist()
    except Exception:
        return []


def _get_values_from_dicts(rows: list, col: str) -> list:
    """Extract numeric values from list-of-dicts."""
    vals = []
    for row in rows:
        if col in row:
            try:
                vals.append(float(row[col]))
            except (ValueError, TypeError):
                pass
    return vals


def classify_status(rms_total: float) -> str:
    """Return OK or FLAGGED based on noise floor threshold."""
    if rms_total > NOISE_FLAG_THRESHOLD_G:
        return "FLAGGED"
    return "OK"


def print_table(stats: dict) -> bool:
    """Print ASCII table. Returns True if any device was flagged."""
    col_widths = {
        "device": max(16, max(len(str(d)) for d in stats) + 2),
        "quiet":  14,
        "rms_ax": 10,
        "rms_ay": 10,
        "rms_az": 10,
        "rms_total": 11,
        "status": 8,
    }

    header = (
        f"{'Device':<{col_widths['device']}} "
        f"{'Quiet Samples':>{col_widths['quiet']}} "
        f"{'RMS_ax (g)':>{col_widths['rms_ax']}} "
        f"{'RMS_ay (g)':>{col_widths['rms_ay']}} "
        f"{'RMS_az (g)':>{col_widths['rms_az']}} "
        f"{'RMS_total (g)':>{col_widths['rms_total']}} "
        f"{'Status':>{col_widths['status']}}"
    )

    sep = "-" * len(header)
    print()
    print("Sensor Noise Floor Analysis")
    print(sep)
    print(header)
    print(sep)

    any_flagged = False
    for device, s in sorted(stats.items()):
        status = classify_status(s["rms_total"])
        if status == "FLAGGED":
            any_flagged = True

        print(
            f"{str(device):<{col_widths['device']}} "
            f"{s['n_quiet']:>{col_widths['quiet']}} "
            f"{s['rms_ax']:>{col_widths['rms_ax']}.6f} "
            f"{s['rms_ay']:>{col_widths['rms_ay']}.6f} "
            f"{s['rms_az']:>{col_widths['rms_az']}.6f} "
            f"{s['rms_total']:>{col_widths['rms_total']}.6f} "
            f"{status:>{col_widths['status']}}"
        )

    print(sep)
    print()

    # Expected range note
    print(
        f"Expected quiet-state noise floor for MEMS IMU: "
        f"{NOISE_FLOOR_MIN_G:.3f}–{NOISE_FLOOR_MAX_G:.3f} g"
    )
    print(f"Flag threshold: > {NOISE_FLAG_THRESHOLD_G:.3f} g (quiet state)")
    print()

    return any_flagged


def main():
    parser = argparse.ArgumentParser(
        description="Analyze sensor noise floor from collected vibration data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        help="Directory containing field CSV files (default: ./data/field)",
    )
    parser.add_argument(
        "--device",
        default=None,
        help="Filter analysis to a single device_id",
    )
    args = parser.parse_args()

    data_dir = Path(args.data_dir)

    if not data_dir.exists():
        print(f"Data directory not found: {data_dir}")
        print("No data to analyze.")
        sys.exit(0)

    df, err = load_data(data_dir, args.device)
    if err or df is None:
        print(err or "No data loaded.")
        sys.exit(0)

    # Check whether we have ax/ay/az columns at all
    has_accel = False
    if HAS_PANDAS:
        import pandas as pd
        if isinstance(df, pd.DataFrame):
            has_accel = any(c in df.columns for c in ("ax", "ay", "az"))
    else:
        if df:
            has_accel = any(k in df[0] for k in ("ax", "ay", "az"))

    if not has_accel:
        print("No accelerometer columns (ax, ay, az) found in data.")
        print("Cannot compute noise floor.")
        sys.exit(0)

    stats = compute_per_device_stats(df, use_pandas=HAS_PANDAS)

    # Check for no quiet samples
    total_quiet = sum(s["n_quiet"] for s in stats.values())
    if total_quiet == 0:
        print("No quiet samples found — all readings above threshold")
        sys.exit(0)

    any_flagged = print_table(stats)

    if any_flagged:
        print("RECOMMENDATION: Check device mounting or replace sensor")
        print()

    sys.exit(0)


if __name__ == "__main__":
    main()
