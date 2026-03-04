#!/usr/bin/env python3
"""
Seismic frequency band analysis for AncientVision field data.

Analyzes frequency composition of vibration events across:
- Microseismic band (0-1 Hz): deep fault activity
- Low seismic (1-10 Hz): soil resonance, structural
- Construction band (10-50 Hz): machinery, human activity
- High frequency (50-100 Hz): surface impact events

Usage:
    python scripts/seismic_frequency_analysis.py --data-dir ./data/field
    python scripts/seismic_frequency_analysis.py --data-dir ./data/field --output band_report.json
"""

import argparse
import json
import sys
from pathlib import Path
from collections import defaultdict

import numpy as np

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False


# Seismic frequency bands (Hz)
BANDS = {
    "microseismic": (0, 1),
    "low_seismic":  (1, 10),
    "construction": (10, 50),
    "high_freq":    (50, 100),
}

BAND_DESCRIPTIONS = {
    "microseismic": "Deep fault / tectonic activity",
    "low_seismic":  "Soil resonance / structural modes",
    "construction": "Machinery / human activity",
    "high_freq":    "Surface impact / high-energy events",
}

LABELS = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]


def classify_frequency(freq_hz: float) -> str:
    """Return band name for a dominant frequency."""
    for band, (low, high) in BANDS.items():
        if low <= freq_hz < high:
            return band
    return "high_freq"


def bar(fraction: float, width: int = 30) -> str:
    filled = int(fraction * width)
    return "█" * filled + "░" * (width - filled)


def analyze_csv(csv_path: Path) -> dict:
    """Analyze a single CSV file's frequency distribution."""
    if not HAS_PANDAS:
        return {}

    try:
        df = pd.read_csv(csv_path)
    except Exception as e:
        return {"error": str(e)}

    if "dominant_freq" not in df.columns:
        return {"error": "No dominant_freq column"}

    df = df.dropna(subset=["dominant_freq"])
    if df.empty:
        return {"error": "No valid rows"}

    band_counts = defaultdict(int)
    band_ppv = defaultdict(list)

    for _, row in df.iterrows():
        freq = float(row["dominant_freq"])
        band = classify_frequency(freq)
        band_counts[band] += 1
        if "ppv" in row and not np.isnan(float(row.get("ppv", float("nan")))):
            band_ppv[band].append(float(row["ppv"]))

    total = sum(band_counts.values()) or 1

    result = {
        "total_rows": len(df),
        "bands": {}
    }

    for band in BANDS:
        count = band_counts.get(band, 0)
        ppv_list = band_ppv.get(band, [])
        result["bands"][band] = {
            "count": count,
            "fraction": round(count / total, 4),
            "avg_ppv": round(float(np.mean(ppv_list)), 4) if ppv_list else 0.0,
            "max_ppv": round(float(np.max(ppv_list)), 4) if ppv_list else 0.0,
        }

    # Per-class frequency distribution
    if "label" in df.columns:
        class_bands = {}
        for label in LABELS:
            sub = df[df["label"] == label]
            if sub.empty:
                continue
            cb = defaultdict(int)
            for freq in sub["dominant_freq"].dropna():
                cb[classify_frequency(float(freq))] += 1
            n = sum(cb.values()) or 1
            class_bands[label] = {b: round(cb[b] / n, 3) for b in BANDS}
        result["class_band_distribution"] = class_bands

    return result


def print_report(results: dict, data_dir: Path):
    """Print formatted analysis report."""
    enc = "utf-8" if sys.platform != "win32" else sys.stdout.encoding
    use_unicode = enc and enc.lower().startswith("utf")

    FULL = "█" if use_unicode else "#"
    EMPTY = "░" if use_unicode else "-"

    def bbar(frac, w=28):
        filled = int(frac * w)
        return FULL * filled + EMPTY * (w - filled)

    print()
    print("=" * 60)
    print("  AncientVision — Seismic Frequency Band Analysis")
    print(f"  Data: {data_dir}")
    print("=" * 60)

    if "error" in results:
        print(f"  Error: {results['error']}")
        print("=" * 60)
        return

    total_rows = results.get("total_rows", 0)
    print(f"  Total samples: {total_rows}")
    print()
    print(f"  {'Band':<14} {'Range':<12} {'%':>5}  {'Distribution':<30}  {'Avg PPV':>8}  {'Description'}")
    print("  " + "-" * 90)

    for band, (low, high) in BANDS.items():
        info = results.get("bands", {}).get(band, {})
        frac = info.get("fraction", 0.0)
        avg_ppv = info.get("avg_ppv", 0.0)
        desc = BAND_DESCRIPTIONS[band]
        print(f"  {band:<14} {low}-{high} Hz   {frac*100:>4.1f}%  {bbar(frac):<30}  {avg_ppv:>7.4f}   {desc}")

    # Class breakdown
    if "class_band_distribution" in results:
        print()
        print("  Class × Band breakdown:")
        print()
        classes = results["class_band_distribution"]
        band_names = list(BANDS.keys())
        header = f"  {'Class':<22}" + "".join(f"  {b[:8]:>8}" for b in band_names)
        print(header)
        print("  " + "-" * 70)
        for cls, bands in classes.items():
            row = f"  {cls:<22}" + "".join(f"  {bands.get(b,0)*100:>7.1f}%" for b in band_names)
            print(row)

    print("=" * 60)
    print()


def main():
    parser = argparse.ArgumentParser(description="Seismic frequency band analysis")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--output", help="Write JSON results to file")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)

    if not HAS_PANDAS:
        print("pandas required: pip install pandas")
        return 1

    csv_files = list(data_dir.glob("*.csv")) if data_dir.exists() else []
    if not csv_files:
        print(f"No CSV files found in {data_dir}")
        return 0

    # Aggregate across all files
    all_rows_info = []
    for f in csv_files:
        r = analyze_csv(f)
        if "error" not in r:
            all_rows_info.append(r)

    if not all_rows_info:
        print("No valid data found")
        return 0

    # Merge results
    merged_bands = defaultdict(lambda: {"count": 0, "ppv_sum": 0.0, "ppv_count": 0, "max_ppv": 0.0})
    total_rows = sum(r["total_rows"] for r in all_rows_info)

    for r in all_rows_info:
        for band, info in r["bands"].items():
            merged_bands[band]["count"] += info["count"]
            if info["avg_ppv"] > 0:
                merged_bands[band]["ppv_sum"] += info["avg_ppv"] * info["count"]
                merged_bands[band]["ppv_count"] += info["count"]
            merged_bands[band]["max_ppv"] = max(merged_bands[band]["max_ppv"], info["max_ppv"])

    total_band_count = sum(v["count"] for v in merged_bands.values()) or 1
    final_bands = {}
    for band, v in merged_bands.items():
        final_bands[band] = {
            "count": v["count"],
            "fraction": round(v["count"] / total_band_count, 4),
            "avg_ppv": round(v["ppv_sum"] / v["ppv_count"], 4) if v["ppv_count"] > 0 else 0.0,
            "max_ppv": round(v["max_ppv"], 4),
        }

    results = {"total_rows": total_rows, "bands": final_bands}
    # Merge class distributions
    class_band_dist = {}
    for r in all_rows_info:
        if "class_band_distribution" in r:
            for cls, bands in r["class_band_distribution"].items():
                if cls not in class_band_dist:
                    class_band_dist[cls] = defaultdict(float)
                for b, v in bands.items():
                    class_band_dist[cls][b] += v
    if class_band_dist:
        results["class_band_distribution"] = {
            cls: {b: round(v / len(all_rows_info), 3) for b, v in bd.items()}
            for cls, bd in class_band_dist.items()
        }

    print_report(results, data_dir)

    if args.output:
        with open(args.output, "w") as f:
            json.dump(results, f, indent=2)
        print(f"Results written to: {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
