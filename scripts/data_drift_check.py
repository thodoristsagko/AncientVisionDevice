#!/usr/bin/env python3
"""Check if field data has drifted from training distribution.

Compares feature statistics in recent field CSVs against the model scaler
(which encodes training distribution mean/std). Reports z-score deviations.

Usage:
    python scripts/data_drift_check.py
    python scripts/data_drift_check.py --data-dir ./data/field --threshold 3.0
"""
import argparse, csv, json, math, os, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

def load_field_data(data_dir):
    rows = []
    if not os.path.isdir(data_dir):
        return rows
    for f in sorted(os.listdir(data_dir)):
        if not f.endswith(".csv"):
            continue
        with open(os.path.join(data_dir, f), newline="") as fh:
            reader = csv.DictReader(fh)
            rows.extend(list(reader))
    return rows

def field_stats(rows, feature_names):
    buckets = {f: [] for f in feature_names}
    for row in rows:
        for f in feature_names:
            try:
                buckets[f].append(float(row.get(f) or 0))
            except ValueError:
                pass
    stats = {}
    for f, vals in buckets.items():
        if vals:
            n = len(vals)
            mean = sum(vals)/n
            std = math.sqrt(sum((v-mean)**2 for v in vals)/n) if n > 1 else 0.0
            stats[f] = {"mean": mean, "std": std, "n": n}
    return stats

def main():
    parser = argparse.ArgumentParser(description="Check field data drift vs training distribution")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--threshold", type=float, default=3.0, help="Z-score alert threshold")
    args = parser.parse_args()

    scaler_path = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
    if not os.path.isfile(scaler_path):
        print(f"ERROR: scaler not found at {scaler_path}")
        sys.exit(1)
    with open(scaler_path) as f:
        scaler = json.load(f)

    feature_names = scaler.get("feature_names", [])
    train_mean = scaler["mean"]
    train_std = scaler["scale"]

    rows = load_field_data(args.data_dir)
    if not rows:
        print(f"No field data found in {args.data_dir}")
        return

    print(f"Loaded {len(rows)} field samples from {args.data_dir}")
    fstats = field_stats(rows, feature_names)

    print(f"\nDrift Analysis (threshold z-score={args.threshold:.1f}):")
    print(f"  {'Feature':<26} {'Train_μ':>10} {'Train_σ':>10} {'Field_μ':>10} {'Field_σ':>10} {'Z-score':>8} {'Status'}")
    print("  " + "-"*88)

    alerts = []
    for i, name in enumerate(feature_names):
        if name not in fstats:
            continue
        st = fstats[name]
        tmean, tstd = train_mean[i], train_std[i]
        # Z-score of field mean relative to training distribution
        zscore = abs(st["mean"] - tmean) / max(tstd, 1e-10)
        status = "ALERT" if zscore > args.threshold else "OK"
        if status == "ALERT":
            alerts.append((name, zscore))
        print(f"  {name:<26} {tmean:>10.4f} {tstd:>10.4f} {st['mean']:>10.4f} {st['std']:>10.4f} {zscore:>8.2f} {status}")

    if alerts:
        print(f"\n⚠ DRIFT DETECTED in {len(alerts)} feature(s):")
        for name, z in sorted(alerts, key=lambda x: -x[1]):
            print(f"  {name}: z={z:.2f}")
        print("\nConsider: collect more calibration data or retrain the model.")
        sys.exit(1)
    else:
        print("\n✓ No significant drift detected. Field data matches training distribution.")

if __name__ == "__main__":
    main()
