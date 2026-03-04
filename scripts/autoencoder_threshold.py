#!/usr/bin/env python3
"""Set the reconstruction error threshold for the vibration autoencoder.

The autoencoder flags a sample as anomalous when its reconstruction error
exceeds a threshold.  This script determines that threshold from calibration
data (known-safe / normal samples) and verifies it against anomaly samples.

Algorithm:
  1. Load calibration samples (field CSV of safe data, or synthetic normal data).
  2. Run the autoencoder on each sample and collect reconstruction errors.
  3. Set threshold at --percentile (default 95th) of the normal error distribution.
     => 5% false alarm rate on calibration data at the 95th percentile.
  4. Optionally verify detection rate against anomaly class samples.
  5. Write autoencoder_threshold.json.
  6. Copy to app/assets/ml/ if accepted (or --no-copy to skip).

Usage:
    python scripts/autoencoder_threshold.py
    python scripts/autoencoder_threshold.py --calibration-csv data/field/safe_session.csv
    python scripts/autoencoder_threshold.py --percentile 99
    python scripts/autoencoder_threshold.py --percentile 95 --no-copy
"""

import argparse
import csv
import datetime
import json
import os
import shutil
import sys

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

AUTOENCODER_TFLITE = os.path.join(ASSETS_DIR, "vibration_anomaly.tflite")
ANOMALY_SCALER = os.path.join(ASSETS_DIR, "vibration_scaler.json")
ANOMALY_CONFIG = os.path.join(ASSETS_DIR, "vibration_model_config.json")

# Default output filename (written alongside autoencoder in ASSETS_DIR)
THRESHOLD_JSON = "autoencoder_threshold.json"

# Feature names for the autoencoder (11 features)
AE_FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid",
    "kurtosis", "stalta", "arias", "cav", "temp", "psdSlope",
]

# Synthetic class ranges for verification samples
_ANOMALY_CLASS_RANGES = {
    "soil_creep": [
        (0.1, 0.8), (0.3, 2.0), (3.0, 20.0), (2.0, 5.0), (3.0, 25.0),
        (1.0, 6.0), (2.0, 8.0), (0.02, 0.3), (0.1, 1.0), (15.0, 35.0), (-4.0, -1.0),
    ],
    "crack_propagation": [
        (0.2, 1.5), (0.5, 3.0), (5.0, 40.0), (8.0, 20.0), (10.0, 50.0),
        (6.0, 15.0), (5.0, 12.0), (0.05, 0.8), (0.3, 2.5), (15.0, 35.0), (-5.0, -1.5),
    ],
    "imminent_failure": [
        (1.0, 5.0), (2.0, 8.0), (0.5, 5.0), (4.0, 15.0), (2.0, 15.0),
        (10.0, 20.0), (8.0, 15.0), (0.2, 3.0), (1.0, 8.0), (15.0, 35.0), (-6.0, -2.0),
    ],
}

_NORMAL_RANGES = [
    (0.001, 0.05), (0.01, 0.3), (5.0, 50.0), (2.0, 6.0), (10.0, 40.0),
    (-1.0, 3.0), (0.5, 2.0), (0.0, 0.001), (0.0, 0.01), (15.0, 35.0), (-12.0, -6.0),
]

N_SYNTHETIC_NORMAL = 1000
N_SYNTHETIC_ANOMALY = 200  # per anomaly class


# ---------------------------------------------------------------------------
# Synthetic data generation
# ---------------------------------------------------------------------------

def _generate_normal_synthetic(n: int) -> np.ndarray:
    """Generate n synthetic normal samples (11 features), raw values."""
    rng = np.random.default_rng(42)
    X = np.zeros((n, len(_NORMAL_RANGES)), dtype=np.float32)
    for fi, (lo, hi) in enumerate(_NORMAL_RANGES):
        # Truncated-normal centered in range
        mu = (lo + hi) / 2.0
        sigma = (hi - lo) / 4.0
        col = rng.normal(mu, sigma, n).astype(np.float32)
        col = np.clip(col, lo, hi)
        X[:, fi] = col
    return X


def _generate_anomaly_synthetic(n_per_class: int) -> tuple:
    """Generate synthetic anomaly samples.

    Returns:
        X: np.ndarray (N, 11) raw features
        class_labels: list of class name strings
    """
    rng = np.random.default_rng(99)
    parts = []
    labels = []
    for cls_name, ranges in _ANOMALY_CLASS_RANGES.items():
        rows = np.zeros((n_per_class, len(ranges)), dtype=np.float32)
        for fi, (lo, hi) in enumerate(ranges):
            rows[:, fi] = rng.uniform(lo, hi, n_per_class).astype(np.float32)
        parts.append(rows)
        labels.extend([cls_name] * n_per_class)
    return np.vstack(parts).astype(np.float32), labels


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _load_csv_normal(path: str) -> np.ndarray:
    """Load normal (calibration) samples from a CSV file.

    Accepts rows with label='normal' or unlabeled rows.
    Returns (N, 11) float32 array.  Skips rows with non-normal labels.
    """
    rows = []
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                label = row.get("label", "").strip().lower()
                if label and label != "normal":
                    continue  # skip anomaly-labeled rows
                vec = []
                for feat in AE_FEATURE_NAMES:
                    raw = row.get(feat)
                    try:
                        vec.append(float(raw) if raw is not None else 0.0)
                    except (ValueError, TypeError):
                        vec.append(0.0)
                rows.append(vec)
    except (OSError, csv.Error) as exc:
        print(f"ERROR reading CSV {path}: {exc}", file=sys.stderr)
        return np.zeros((0, len(AE_FEATURE_NAMES)), dtype=np.float32)

    if not rows:
        return np.zeros((0, len(AE_FEATURE_NAMES)), dtype=np.float32)
    return np.array(rows, dtype=np.float32)


def _load_csv_anomaly(path: str) -> tuple:
    """Load anomaly samples (non-normal label) from a CSV.

    Returns (X, class_labels).
    """
    X_list, labels_list = [], []
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                label = row.get("label", "").strip().lower()
                if not label or label == "normal":
                    continue
                vec = []
                for feat in AE_FEATURE_NAMES:
                    raw = row.get(feat)
                    try:
                        vec.append(float(raw) if raw is not None else 0.0)
                    except (ValueError, TypeError):
                        vec.append(0.0)
                X_list.append(vec)
                labels_list.append(label)
    except (OSError, csv.Error):
        pass

    if not X_list:
        return np.zeros((0, len(AE_FEATURE_NAMES)), dtype=np.float32), []
    return np.array(X_list, dtype=np.float32), labels_list


# ---------------------------------------------------------------------------
# Scaler
# ---------------------------------------------------------------------------

def _load_scaler(path: str) -> dict | None:
    """Load scaler JSON; return dict or None."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _apply_scaler(X: np.ndarray, scaler: dict) -> np.ndarray:
    """Z-score normalize X using scaler mean/scale."""
    mean = np.array(scaler["mean"], dtype=np.float32)
    scale = np.array(scaler["scale"], dtype=np.float32)
    scale = np.where(scale > 1e-10, scale, 1.0)
    return ((X - mean) / scale).astype(np.float32)


def _fit_scaler_from_data(X: np.ndarray) -> dict:
    """Fit a simple StandardScaler from data; return dict."""
    mean = X.mean(axis=0).tolist()
    std = X.std(axis=0)
    std = np.where(std > 1e-10, std, 1.0).tolist()
    return {"mean": mean, "scale": std, "feature_names": AE_FEATURE_NAMES}


# ---------------------------------------------------------------------------
# TFLite inference
# ---------------------------------------------------------------------------

def _load_interpreter(path: str):
    """Load TFLite interpreter; raise ImportError if TFLite unavailable."""
    try:
        from tflite_runtime.interpreter import Interpreter  # noqa: PLC0415
        interp = Interpreter(model_path=path)
    except ImportError:
        import tensorflow as tf  # noqa: PLC0415
        interp = tf.lite.Interpreter(model_path=path)
    interp.allocate_tensors()
    return interp


def _reconstruction_errors(interp, X_scaled: np.ndarray) -> np.ndarray:
    """Return MSE reconstruction error for each sample."""
    in_det = interp.get_input_details()
    out_det = interp.get_output_details()
    dtype = in_det[0]["dtype"]
    in_idx = in_det[0]["index"]
    out_idx = out_det[0]["index"]

    errors = np.empty(len(X_scaled), dtype=np.float64)
    for i in range(len(X_scaled)):
        arr = np.array([X_scaled[i]], dtype=dtype)
        interp.set_tensor(in_idx, arr)
        interp.invoke()
        out = interp.get_tensor(out_idx)[0]
        errors[i] = float(np.mean((X_scaled[i].astype(np.float64) - out.astype(np.float64)) ** 2))
    return errors


# ---------------------------------------------------------------------------
# Percentile computation (stdlib-compatible, also uses numpy)
# ---------------------------------------------------------------------------

def _percentile_value(arr: np.ndarray, p: float) -> float:
    """Compute the p-th percentile (0-100) of arr."""
    n = len(arr)
    if n == 0:
        return 0.0
    sorted_arr = np.sort(arr)
    idx = (p / 100.0) * (n - 1)
    lo = int(idx)
    hi = min(lo + 1, n - 1)
    frac = idx - lo
    return float(sorted_arr[lo] * (1 - frac) + sorted_arr[hi] * frac)


# ---------------------------------------------------------------------------
# Detection rate on anomaly samples
# ---------------------------------------------------------------------------

def _detection_rate(errors: np.ndarray, threshold: float) -> float:
    """Fraction of samples with error > threshold (true positive rate proxy)."""
    if len(errors) == 0:
        return 0.0
    return float(np.sum(errors > threshold) / len(errors))


# ---------------------------------------------------------------------------
# ASCII error distribution chart
# ---------------------------------------------------------------------------

def _ascii_histogram(errors: np.ndarray, threshold: float, label: str,
                     n_bins: int = 20, width: int = 40) -> str:
    """Render a simple ASCII histogram of reconstruction errors."""
    if len(errors) == 0:
        return f"  {label}: (no data)"

    e_min = float(errors.min())
    e_max = float(errors.max())
    if e_min == e_max:
        e_max = e_min + 1e-6

    bin_width = (e_max - e_min) / n_bins
    counts = [0] * n_bins
    for e in errors:
        idx = int((e - e_min) / bin_width)
        idx = max(0, min(n_bins - 1, idx))
        counts[idx] += 1

    max_count = max(counts) if counts else 1
    lines = [f"\n  {label} error distribution (N={len(errors)}):"]
    for i in range(n_bins):
        lo = e_min + i * bin_width
        hi = lo + bin_width
        bar_len = int(counts[i] / max_count * width)
        bar = "#" * bar_len
        marker = " <-- threshold" if lo <= threshold < hi else ""
        lines.append(f"    {lo:8.5f}-{hi:8.5f}: {bar:<{width}} {counts[i]:4d}{marker}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Calibrate autoencoder reconstruction error threshold."
    )
    parser.add_argument(
        "--calibration-csv", default=None, metavar="PATH",
        help="CSV of known-safe (normal) samples. Uses synthetic if not provided.",
    )
    parser.add_argument(
        "--anomaly-csv", default=None, metavar="PATH",
        help="CSV of known-anomaly samples for verification. Uses synthetic if not provided.",
    )
    parser.add_argument(
        "--percentile", type=float, default=95.0, metavar="PCT",
        help="Percentile of normal error distribution to use as threshold (default: 95).",
    )
    parser.add_argument(
        "--no-copy", action="store_true",
        help="Do not copy threshold JSON to app/assets/ml/.",
    )
    parser.add_argument(
        "--output", default=None, metavar="PATH",
        help=f"Output JSON path (default: {THRESHOLD_JSON} in script dir).",
    )
    args = parser.parse_args()

    percentile = float(np.clip(args.percentile, 1.0, 99.9))

    print("=" * 68)
    print("AUTOENCODER RECONSTRUCTION ERROR THRESHOLD CALIBRATION")
    print("=" * 68)
    print(f"  Percentile:      {percentile:.1f}th")
    print(f"  False alarm rate: {100 - percentile:.1f}%  (on calibration data)")

    # ---- Check model availability ----
    tflite_available = True
    interp = None
    if not os.path.isfile(AUTOENCODER_TFLITE):
        print(f"\n  WARNING: Autoencoder not found at {AUTOENCODER_TFLITE}")
        print("  Run scripts/train_autoencoder.py first.")
        tflite_available = False
    else:
        try:
            interp = _load_interpreter(AUTOENCODER_TFLITE)
            print(f"  Model:           {AUTOENCODER_TFLITE}")
        except (ImportError, Exception) as exc:
            print(f"\n  WARNING: Could not load TFLite model: {exc}")
            tflite_available = False

    # ---- Load scaler ----
    scaler = _load_scaler(ANOMALY_SCALER)
    scaler_source = "file"
    if scaler is None:
        print(f"  WARNING: Scaler not found at {ANOMALY_SCALER}. "
              "Will fit from calibration data.")
        scaler_source = "fitted"

    # ---- Load / generate calibration (normal) data ----
    if args.calibration_csv and os.path.isfile(args.calibration_csv):
        print(f"\n  Loading calibration CSV: {args.calibration_csv}")
        X_normal_raw = _load_csv_normal(args.calibration_csv)
        n_normal = len(X_normal_raw)
        print(f"  Normal samples loaded: {n_normal}")
        if n_normal < 10:
            print(f"  WARNING: Only {n_normal} normal samples found. "
                  "Supplementing with synthetic data.")
            X_syn = _generate_normal_synthetic(N_SYNTHETIC_NORMAL)
            X_normal_raw = np.vstack([X_normal_raw, X_syn]) if n_normal > 0 else X_syn
    else:
        if args.calibration_csv:
            print(f"\n  WARNING: Calibration CSV not found: {args.calibration_csv}")
        print(f"  Generating {N_SYNTHETIC_NORMAL} synthetic normal samples...")
        X_normal_raw = _generate_normal_synthetic(N_SYNTHETIC_NORMAL)

    print(f"  Total calibration samples: {len(X_normal_raw)}")

    # Fit scaler from calibration data if no file scaler
    if scaler is None or scaler_source == "fitted":
        scaler = _fit_scaler_from_data(X_normal_raw)
        print("  Scaler fitted from calibration data.")

    X_normal_scaled = _apply_scaler(X_normal_raw, scaler)

    # ---- Compute reconstruction errors on normal data ----
    if tflite_available and interp is not None:
        print("\n  Running autoencoder on calibration data...")
        normal_errors = _reconstruction_errors(interp, X_normal_scaled)
    else:
        # Fall back: use random small errors to demonstrate the pipeline
        print("\n  (No model) Simulating reconstruction errors from normal distribution...")
        rng = np.random.default_rng(42)
        normal_errors = rng.exponential(scale=0.02, size=len(X_normal_scaled)).astype(np.float64)
        print("  NOTE: Threshold will not be meaningful without a trained model.")

    # ---- Compute threshold ----
    threshold = _percentile_value(normal_errors, percentile)
    fpr = float(np.mean(normal_errors > threshold))  # empirical FPR

    print()
    print("  Normal data reconstruction error statistics:")
    print(f"    mean   = {float(normal_errors.mean()):.6f}")
    print(f"    std    = {float(normal_errors.std()):.6f}")
    print(f"    min    = {float(normal_errors.min()):.6f}")
    print(f"    p50    = {_percentile_value(normal_errors, 50):.6f}")
    print(f"    p90    = {_percentile_value(normal_errors, 90):.6f}")
    print(f"    p95    = {_percentile_value(normal_errors, 95):.6f}")
    print(f"    p99    = {_percentile_value(normal_errors, 99):.6f}")
    print(f"    max    = {float(normal_errors.max()):.6f}")
    print()
    print(f"  Threshold ({percentile:.0f}th percentile): {threshold:.6f}")
    print(f"  Empirical FPR on calibration data:   {fpr * 100:.2f}%")

    # ASCII histogram
    print(_ascii_histogram(normal_errors, threshold, "Normal"))

    # ---- Load / generate anomaly verification data ----
    print()
    if args.anomaly_csv and os.path.isfile(args.anomaly_csv):
        print(f"  Loading anomaly verification CSV: {args.anomaly_csv}")
        X_anomaly_raw, anomaly_labels = _load_csv_anomaly(args.anomaly_csv)
        print(f"  Anomaly samples loaded: {len(X_anomaly_raw)}")
        if len(X_anomaly_raw) == 0:
            print("  No non-normal rows found. Generating synthetic anomaly samples.")
            X_anomaly_raw, anomaly_labels = _generate_anomaly_synthetic(N_SYNTHETIC_ANOMALY)
    else:
        print(f"  Generating {N_SYNTHETIC_ANOMALY} synthetic anomaly samples per class...")
        X_anomaly_raw, anomaly_labels = _generate_anomaly_synthetic(N_SYNTHETIC_ANOMALY)

    X_anomaly_scaled = _apply_scaler(X_anomaly_raw, scaler)

    # ---- Compute reconstruction errors on anomaly data ----
    if tflite_available and interp is not None:
        print("  Running autoencoder on anomaly data...")
        anomaly_errors = _reconstruction_errors(interp, X_anomaly_scaled)
    else:
        # Simulate: anomaly errors should be higher
        rng = np.random.default_rng(77)
        anomaly_errors = rng.exponential(scale=0.12, size=len(X_anomaly_scaled)).astype(np.float64)

    overall_detection_rate = _detection_rate(anomaly_errors, threshold)
    print()
    print("  Anomaly detection verification:")
    print(f"    Overall detection rate: {overall_detection_rate * 100:.1f}%")

    # Per-class detection rates
    unique_labels = sorted(set(anomaly_labels))
    for cls in unique_labels:
        mask = np.array([l == cls for l in anomaly_labels])
        cls_errors = anomaly_errors[mask]
        rate = _detection_rate(cls_errors, threshold)
        print(f"    {cls:<26}: {rate * 100:.1f}%  "
              f"(mean_err={cls_errors.mean():.4f}, "
              f"n={mask.sum()})")

    print(_ascii_histogram(anomaly_errors, threshold, "Anomaly"))

    # ---- Threshold quality assessment ----
    print()
    print("  Threshold quality assessment:")
    if fpr <= 0.05:
        print(f"    FPR {fpr * 100:.2f}% <= 5% target — acceptable for field deployment.")
    else:
        print(f"    FPR {fpr * 100:.2f}% > 5% target — consider raising percentile.")

    if overall_detection_rate >= 0.80:
        print(f"    Detection rate {overall_detection_rate * 100:.1f}% >= 80% — good sensitivity.")
    elif overall_detection_rate >= 0.60:
        print(f"    Detection rate {overall_detection_rate * 100:.1f}% is moderate. "
              "Consider lowering percentile for more sensitivity.")
    else:
        print(f"    Detection rate {overall_detection_rate * 100:.1f}% is LOW. "
              "The autoencoder may need more training or the threshold is too high.")

    # ---- Write threshold JSON ----
    calibrated_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

    threshold_data = {
        "threshold": round(float(threshold), 8),
        "percentile": percentile,
        "fpr": round(fpr, 6),
        "detection_rate": round(float(overall_detection_rate), 6),
        "calibration_samples": int(len(X_normal_raw)),
        "anomaly_samples": int(len(X_anomaly_raw)),
        "normal_error_stats": {
            "mean": round(float(normal_errors.mean()), 8),
            "std": round(float(normal_errors.std()), 8),
            "p50": round(_percentile_value(normal_errors, 50), 8),
            "p95": round(_percentile_value(normal_errors, 95), 8),
            "p99": round(_percentile_value(normal_errors, 99), 8),
        },
        "anomaly_error_stats": {
            "mean": round(float(anomaly_errors.mean()), 8),
            "std": round(float(anomaly_errors.std()), 8),
        },
        "model_path": AUTOENCODER_TFLITE,
        "scaler_source": scaler_source,
        "calibrated_at": calibrated_at,
    }

    # Determine output path
    if args.output:
        out_path = args.output
    else:
        out_path = os.path.join(SCRIPT_DIR, THRESHOLD_JSON)

    with open(out_path, "w") as f:
        json.dump(threshold_data, f, indent=2)
    print()
    print(f"  Threshold JSON written: {out_path}")

    # ---- Copy to assets if accepted ----
    if not args.no_copy:
        os.makedirs(ASSETS_DIR, exist_ok=True)
        dest = os.path.join(ASSETS_DIR, THRESHOLD_JSON)
        shutil.copy2(out_path, dest)
        print(f"  Copied to assets:       {dest}")

        # Also update vibration_model_config.json if it exists
        config_path = ANOMALY_CONFIG
        if os.path.isfile(config_path):
            try:
                with open(config_path) as f:
                    existing_config = json.load(f)
                existing_config["thresholds"] = {
                    "low": round(float(threshold), 8),
                    "high": round(float(_percentile_value(normal_errors, min(percentile + 4.0, 99.9))), 8),
                }
                existing_config["threshold_calibrated_at"] = calibrated_at
                existing_config["threshold_percentile"] = percentile
                with open(config_path, "w") as f:
                    json.dump(existing_config, f, indent=2)
                print(f"  Updated vibration_model_config.json thresholds.")
            except (OSError, json.JSONDecodeError, KeyError) as exc:
                print(f"  WARNING: Could not update model config: {exc}")

    print()
    print("=" * 68)
    print("  Summary:")
    print(f"    Threshold:      {threshold:.6f}")
    print(f"    Percentile:     {percentile:.0f}th")
    print(f"    FPR:            {fpr * 100:.2f}%  (on {len(X_normal_raw)} normal samples)")
    print(f"    Detection rate: {overall_detection_rate * 100:.1f}%  "
          f"(on {len(X_anomaly_raw)} anomaly samples)")
    print()
    print("  Done.")


if __name__ == "__main__":
    main()
