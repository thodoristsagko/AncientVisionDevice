#!/usr/bin/env python3
"""
PPV exceedance probability analysis for AncientVision.

Analyzes the probability that PPV will exceed critical thresholds
based on historical field data, using empirical exceedance curves.

Usage:
    python scripts/ppv_exceedance_analysis.py --data-dir ./data/field
    python scripts/ppv_exceedance_analysis.py --data-dir ./data/field --thresholds 0.3 1.0 3.0 5.0
"""

import argparse
import sys
from pathlib import Path

import numpy as np

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

# DIN 4150-3 standard thresholds (mm/s)
STANDARD_THRESHOLDS = {
    "DIN 4150-3 Line 1 (sensitive)": 0.2,
    "DIN 4150-3 Line 2 (residential)": 0.5,
    "DIN 4150-3 Line 3 (commercial)": 1.0,
    "Archaeological alert (custom)": 0.3,
    "High-risk threshold": 3.0,
    "Critical structural threshold": 5.0,
}


def load_ppv_data(data_dir: Path):
    """Load PPV values from all field CSVs."""
    if not HAS_PANDAS:
        return None, "pandas not available"

    csv_files = list(data_dir.glob("*.csv"))
    if not csv_files:
        return None, f"No CSV files in {data_dir}"

    all_ppv = []
    for f in csv_files:
        try:
            df = pd.read_csv(f)
            if "ppv" in df.columns:
                vals = df["ppv"].dropna().values
                all_ppv.extend(vals[vals >= 0].tolist())
        except Exception:
            continue

    if not all_ppv:
        return None, "No PPV data found in CSV files"

    return np.array(all_ppv, dtype=np.float64), None


def compute_exceedance(ppv_values: np.ndarray, threshold: float) -> float:
    """Fraction of readings that exceed threshold."""
    return float(np.mean(ppv_values > threshold))


def compute_return_period(ppv_values: np.ndarray, threshold: float,
                           sample_rate_hz: float = 10.0) -> float:
    """Estimated return period in seconds for exceeding threshold."""
    prob = compute_exceedance(ppv_values, threshold)
    if prob <= 0:
        return float("inf")
    return 1.0 / (prob * sample_rate_hz)


def compute_percentiles(ppv_values: np.ndarray) -> dict:
    """Compute key percentiles."""
    return {
        "p50": float(np.percentile(ppv_values, 50)),
        "p90": float(np.percentile(ppv_values, 90)),
        "p95": float(np.percentile(ppv_values, 95)),
        "p99": float(np.percentile(ppv_values, 99)),
        "max": float(np.max(ppv_values)),
        "mean": float(np.mean(ppv_values)),
        "std": float(np.std(ppv_values)),
    }


def bar_chart(value, max_value, width=20):
    """Render a simple ASCII bar."""
    if max_value <= 0:
        return "░" * width
    filled = int(min(1.0, value / max_value) * width)
    return "█" * filled + "░" * (width - filled)


def print_report(ppv_values: np.ndarray, custom_thresholds: list):
    """Print formatted exceedance analysis report."""
    enc = getattr(sys.stdout, "encoding", "utf-8") or "utf-8"
    use_unicode = enc.lower().startswith("utf")
    FULL = "█" if use_unicode else "#"
    EMPTY = "░" if use_unicode else "-"

    def bbar(prob, w=20):
        f = int(min(1.0, prob) * w)
        return FULL * f + EMPTY * (w - f)

    n = len(ppv_values)
    pct = compute_percentiles(ppv_values)

    print()
    print("=" * 65)
    print("  AncientVision — PPV Exceedance Probability Analysis")
    print("=" * 65)
    print(f"  Total readings : {n:,}")
    print(f"  Mean PPV       : {pct['mean']:.4f} mm/s")
    print(f"  Std dev        : {pct['std']:.4f} mm/s")
    print(f"  P50 (median)   : {pct['p50']:.4f} mm/s")
    print(f"  P95            : {pct['p95']:.4f} mm/s")
    print(f"  P99            : {pct['p99']:.4f} mm/s")
    print(f"  Maximum        : {pct['max']:.4f} mm/s")
    print()

    # Standard thresholds
    print(f"  {'Standard':<38} {'Thresh':>7}  {'Exceed%':>7}  {'Return':>8}  Distribution")
    print("  " + "-" * 80)

    all_thresholds = dict(STANDARD_THRESHOLDS)
    for i, t in enumerate(custom_thresholds):
        all_thresholds[f"Custom threshold {i+1}"] = t

    for name, threshold in sorted(all_thresholds.items(), key=lambda x: x[1]):
        prob = compute_exceedance(ppv_values, threshold)
        ret = compute_return_period(ppv_values, threshold)
        ret_str = f"{ret:.0f}s" if ret < 3600 else f"{ret/3600:.1f}h" if ret < 86400 else ">1day"
        b = bbar(prob)
        print(f"  {name[:38]:<38} {threshold:>7.2f}  {prob*100:>6.2f}%  {ret_str:>8}  {b}")

    print()
    print("  Note: Return period = avg time between exceedances at 10 Hz sample rate")
    print("=" * 65)
    print()


def main():
    parser = argparse.ArgumentParser(description="PPV exceedance probability analysis")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--thresholds", nargs="*", type=float, default=[],
                        help="Additional custom PPV thresholds (mm/s)")
    parser.add_argument("--output", help="Write JSON results to file")
    args = parser.parse_args()

    if not HAS_PANDAS:
        print("pandas required: pip install pandas")
        return 1

    data_dir = Path(args.data_dir)
    ppv_values, err = load_ppv_data(data_dir)

    if err:
        print(f"Info: {err}")
        return 0

    print_report(ppv_values, args.thresholds)

    if args.output:
        import json
        results = {
            "n_samples": len(ppv_values),
            "percentiles": compute_percentiles(ppv_values),
            "exceedance": {
                name: {
                    "threshold": threshold,
                    "probability": compute_exceedance(ppv_values, threshold),
                    "return_period_s": compute_return_period(ppv_values, threshold),
                }
                for name, threshold in STANDARD_THRESHOLDS.items()
            }
        }
        with open(args.output, "w") as f:
            json.dump(results, f, indent=2)
        print(f"Results written to: {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
