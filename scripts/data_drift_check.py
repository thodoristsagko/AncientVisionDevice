#!/usr/bin/env python3
"""Check if field data has drifted from training distribution.

Compares feature statistics in recent field CSVs against the model scaler
(which encodes training distribution mean/std). Reports z-score deviations
and Jensen-Shannon divergence per feature.

Usage:
    python scripts/data_drift_check.py
    python scripts/data_drift_check.py --data-dir ./data/field --threshold 3.0
    python scripts/data_drift_check.py --data-dir ./data/field --output-csv drift.csv
"""
import argparse, csv, json, math, os, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

# Jensen-Shannon divergence threshold above which drift is flagged
JS_ALERT_THRESHOLD = 0.1

# ---------------------------------------------------------------------------
# Jensen-Shannon divergence
# ---------------------------------------------------------------------------

try:
    import numpy as np
    from scipy.special import rel_entr as _rel_entr

    def _make_histogram(values, bins=50):
        """Return a normalised probability histogram for a list of floats."""
        if len(values) < 2:
            return None
        min_v, max_v = min(values), max(values)
        if min_v == max_v:
            return None
        bin_width = (max_v - min_v) / bins
        counts = [0] * bins
        for v in values:
            idx = int((v - min_v) / bin_width)
            idx = min(idx, bins - 1)
            counts[idx] += 1
        total = sum(counts)
        return [c / total for c in counts]

    def js_divergence(p_list, q_list):
        """
        Jensen-Shannon divergence between two empirical distributions.

        Both inputs are lists of floats representing samples. Returns a value
        in [0.0, ln(2)] ≈ [0.0, 0.693], normalised here to [0.0, 1.0] by
        dividing by ln(2).

        Returns None if distributions cannot be computed.
        """
        p_hist = _make_histogram(p_list)
        q_hist = _make_histogram(q_list)
        if p_hist is None or q_hist is None:
            return None
        # Pad to equal length if binning produced different lengths
        n = max(len(p_hist), len(q_hist))
        p = np.array(p_hist + [0.0] * (n - len(p_hist)), dtype=np.float64)
        q = np.array(q_hist + [0.0] * (n - len(q_hist)), dtype=np.float64)
        # Add small epsilon to avoid log(0)
        p = np.where(p == 0, 1e-12, p)
        q = np.where(q == 0, 1e-12, q)
        p /= p.sum()
        q /= q.sum()
        m = 0.5 * (p + q)
        js = 0.5 * np.sum(_rel_entr(p, m)) + 0.5 * np.sum(_rel_entr(q, m))
        # Normalise to [0, 1]
        return float(js / math.log(2))

    _HAS_SCIPY = True

except ImportError:
    _HAS_SCIPY = False
    np = None

    def js_divergence(p_list, q_list):  # type: ignore[misc]
        """Fallback KL-divergence approximation when scipy is unavailable."""
        return None

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
            stats[f] = {"mean": mean, "std": std, "n": n, "values": vals}
    return stats


def _gaussian_samples(mean, std, n=500):
    """Generate n Gaussian samples given mean and std (no numpy required)."""
    import random
    if std <= 0:
        return [mean] * n
    samples = []
    # Box-Muller transform
    for _ in range(n // 2 + 1):
        import math as _math
        u1 = max(1e-15, random.random())
        u2 = random.random()
        z0 = _math.sqrt(-2.0 * _math.log(u1)) * _math.cos(2.0 * _math.pi * u2)
        z1 = _math.sqrt(-2.0 * _math.log(u1)) * _math.sin(2.0 * _math.pi * u2)
        samples.append(mean + std * z0)
        samples.append(mean + std * z1)
    return samples[:n]

def main():
    parser = argparse.ArgumentParser(description="Check field data drift vs training distribution")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--threshold", type=float, default=3.0, help="Z-score alert threshold")
    parser.add_argument(
        "--output-csv",
        default=None,
        metavar="FILE",
        help="Write drift statistics (one row per feature) to this CSV file.",
    )
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

    if not _HAS_SCIPY:
        print("  (scipy not available — JS divergence will be skipped)")

    print(f"\nDrift Analysis (threshold z-score={args.threshold:.1f}):")
    print(f"  {'Feature':<26} {'Train_μ':>10} {'Train_σ':>10} {'Field_μ':>10} {'Field_σ':>10} {'Z-score':>8} {'JS':>7} {'Status'}")
    print("  " + "-"*100)

    alerts = []
    js_alerts = []
    drift_rows = []  # for --output-csv

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

        # Jensen-Shannon divergence between training (Gaussian approx) and field samples
        js_val = None
        if _HAS_SCIPY:
            train_samples = _gaussian_samples(tmean, tstd, n=min(len(st["values"]) * 2, 1000))
            js_val = js_divergence(train_samples, st["values"])

        js_str = f"{js_val:.3f}" if js_val is not None else "N/A"
        if js_val is not None and js_val > JS_ALERT_THRESHOLD:
            js_alerts.append((name, js_val))

        print(f"  {name:<26} {tmean:>10.4f} {tstd:>10.4f} {st['mean']:>10.4f} {st['std']:>10.4f} {zscore:>8.2f} {js_str:>7} {status}")

        drift_rows.append({
            "feature":     name,
            "train_mean":  tmean,
            "train_std":   tstd,
            "field_mean":  st["mean"],
            "field_std":   st["std"],
            "field_n":     st["n"],
            "zscore":      zscore,
            "js_divergence": js_val if js_val is not None else "",
            "status":      status,
        })

    # Z-score alerts
    if alerts:
        print(f"\n⚠ DRIFT DETECTED in {len(alerts)} feature(s):")
        for name, z in sorted(alerts, key=lambda x: -x[1]):
            print(f"  {name}: z={z:.2f}")
        print("\nConsider: collect more calibration data or retrain the model.")

    # JS divergence alerts and recommendations
    if js_alerts:
        print(f"\nJS Divergence Alerts (threshold={JS_ALERT_THRESHOLD}):")
        for name, js in sorted(js_alerts, key=lambda x: -x[1]):
            print(
                f"  RECOMMENDATION: Feature '{name}' shows significant drift (JS={js:.2f}). "
                "Consider collecting more training data from current conditions."
            )

    if not alerts and not js_alerts:
        print("\n✓ No significant drift detected. Field data matches training distribution.")

    # Write CSV output if requested
    if args.output_csv and drift_rows:
        fieldnames = list(drift_rows[0].keys())
        try:
            with open(args.output_csv, "w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(drift_rows)
            print(f"\nDrift statistics written to: {args.output_csv}")
        except OSError as exc:
            print(f"WARNING: Could not write --output-csv: {exc}", file=sys.stderr)

    if alerts:
        sys.exit(1)
    else:
        return

if __name__ == "__main__":
    main()
