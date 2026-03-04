#!/usr/bin/env python3
"""
Compare vibration measurements across multiple AncientVision devices.

Groups field CSV data by device_id and computes per-device statistics,
helping identify sensor calibration differences, placement effects,
and cross-device consistency.

Usage:
    python scripts/compare_devices.py --data-dir ./data/field
    python scripts/compare_devices.py --data-dir ./data/field --output comparison.json
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

METRIC_COLS = ["ppv", "rms", "kurtosis", "dominant_freq", "crest", "sta_lta"]
METRIC_LABELS = {
    "ppv": "PPV (mm/s)",
    "rms": "RMS",
    "kurtosis": "Kurtosis",
    "dominant_freq": "Dom. Freq (Hz)",
    "crest": "Crest Factor",
    "sta_lta": "STA/LTA",
}


def bar(val, min_val, max_val, width=20):
    """Normalized ASCII bar."""
    if max_val <= min_val:
        return "░" * width
    frac = min(1.0, max(0.0, (val - min_val) / (max_val - min_val)))
    filled = int(frac * width)
    return "█" * filled + "░" * (width - filled)


def load_all_data(data_dir: Path):
    """Load and merge all field CSVs, return DataFrame with device_id column."""
    if not HAS_PANDAS:
        return None, "pandas not available"

    csv_files = list(data_dir.glob("*.csv"))
    if not csv_files:
        return None, f"No CSV files in {data_dir}"

    frames = []
    for f in csv_files:
        try:
            df = pd.read_csv(f)
            if "device_id" not in df.columns:
                df["device_id"] = f.stem  # use filename as device ID
            frames.append(df)
        except Exception as e:
            print(f"  Warning: could not read {f.name}: {e}")

    if not frames:
        return None, "No readable CSV files"

    return pd.concat(frames, ignore_index=True), None


def compute_device_stats(df) -> dict:
    """Return per-device statistics dict."""
    devices = {}
    for device_id, group in df.groupby("device_id"):
        stats = {"n_samples": len(group)}
        for col in METRIC_COLS:
            if col in group.columns:
                vals = group[col].dropna()
                if len(vals) > 0:
                    stats[col] = {
                        "mean": round(float(vals.mean()), 4),
                        "std": round(float(vals.std()), 4),
                        "min": round(float(vals.min()), 4),
                        "max": round(float(vals.max()), 4),
                        "p95": round(float(vals.quantile(0.95)), 4),
                    }
        if "label" in group.columns:
            stats["class_distribution"] = group["label"].value_counts().to_dict()
        if "timestamp" in group.columns:
            stats["first_seen"] = str(group["timestamp"].min())
            stats["last_seen"] = str(group["timestamp"].max())
        devices[str(device_id)] = stats
    return devices


def compute_cross_device_consistency(devices: dict) -> dict:
    """Compute CV (coefficient of variation) across devices per metric."""
    consistency = {}
    for col in METRIC_COLS:
        means = [
            d[col]["mean"]
            for d in devices.values()
            if col in d and "mean" in d[col]
        ]
        if len(means) < 2:
            continue
        mean_of_means = float(np.mean(means))
        std_of_means = float(np.std(means))
        cv = std_of_means / mean_of_means if mean_of_means > 1e-10 else 0.0
        consistency[col] = {
            "cv": round(cv, 4),
            "status": "Good" if cv < 0.10 else ("Moderate" if cv < 0.25 else "High variation"),
        }
    return consistency


def print_report(devices: dict, consistency: dict):
    """Print formatted comparison report."""
    enc = getattr(sys.stdout, "encoding", "utf-8") or "utf-8"
    use_unicode = enc.lower().startswith("utf")
    FULL = "█" if use_unicode else "#"
    EMPTY = "░" if use_unicode else "-"

    def bbar(val, lo, hi, w=16):
        if hi <= lo:
            return EMPTY * w
        frac = min(1.0, max(0.0, (val - lo) / (hi - lo)))
        f = int(frac * w)
        return FULL * f + EMPTY * (w - f)

    print()
    print("=" * 70)
    print("  AncientVision — Cross-Device Comparison")
    print("=" * 70)
    print(f"  Devices found: {len(devices)}")
    print()

    if not devices:
        print("  No device data found.")
        print("=" * 70)
        return

    # Per-metric comparison table
    for col in METRIC_COLS:
        label = METRIC_LABELS.get(col, col)
        means = {
            dev: d[col]["mean"]
            for dev, d in devices.items()
            if col in d and "mean" in d[col]
        }
        if not means:
            continue

        lo = min(means.values())
        hi = max(means.values())

        print(f"  {label}")
        print(f"  {'Device':<20}  {'Mean':>8}  {'±Std':>8}  {'P95':>8}  Bar")
        print("  " + "-" * 65)
        for dev, d in devices.items():
            if col not in d:
                continue
            m = d[col]["mean"]
            s = d[col].get("std", 0.0)
            p95 = d[col].get("p95", m)
            b = bbar(m, lo, hi)
            print(f"  {dev[:20]:<20}  {m:>8.4f}  {s:>8.4f}  {p95:>8.4f}  {b}")
        print()

    # Cross-device consistency summary
    if consistency:
        print("  Cross-device consistency (CV = σ/μ of per-device means):")
        print(f"  {'Metric':<20}  {'CV':>6}  Status")
        print("  " + "-" * 45)
        for col, info in consistency.items():
            label = METRIC_LABELS.get(col, col)
            cv = info["cv"]
            status = info["status"]
            flag = " !" if cv > 0.25 else ""
            print(f"  {label:<20}  {cv:>6.3f}  {status}{flag}")
        print()

    print("=" * 70)
    print()


def main():
    parser = argparse.ArgumentParser(description="Compare vibration data across devices")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--output", help="Write JSON results to file")
    args = parser.parse_args()

    if not HAS_PANDAS:
        print("pandas required: pip install pandas")
        return 1

    data_dir = Path(args.data_dir)
    df, err = load_all_data(data_dir)
    if err:
        print(f"Error: {err}")
        return 0 if "No CSV" in (err or "") else 1

    devices = compute_device_stats(df)
    consistency = compute_cross_device_consistency(devices)

    print_report(devices, consistency)

    if args.output:
        result = {"devices": devices, "consistency": consistency}
        with open(args.output, "w") as f:
            json.dump(result, f, indent=2)
        print(f"Results written to: {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
