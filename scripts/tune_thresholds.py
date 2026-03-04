#!/usr/bin/env python3
"""Calibration-based threshold optimization for the precursor classifier.

Uses a CSV of known-safe (calibration) samples to find the anomaly detection
threshold that gives the target false positive rate (FPR).

Usage:
    python scripts/tune_thresholds.py --calibration-csv data/field/calibration.csv
    python scripts/tune_thresholds.py --calibration-csv data/field/calibration.csv --target-fpr 0.02
    python scripts/tune_thresholds.py --calibration-csv data/field/calibration.csv --output data/thresholds.json

Algorithm:
1. Run precursor classifier on all samples in the calibration CSV.
2. Compute the "anomaly score" for each sample: max(prob[non-normal classes]).
3. Sort scores ascending; find the threshold at the (1 - target_fpr) percentile.
   At that threshold, exactly target_fpr fraction of normal samples are flagged.
4. Also compute a PPV-based threshold: noise_floor * 3 (from vibration_model_config).
5. Recommend the lower threshold (more conservative = fewer missed hazards).
6. Write calibration_thresholds.json to --output path.
"""

import argparse
import csv
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")
DATA_DIR = os.path.join(REPO_DIR, "data")

PRECURSOR_TFLITE = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
PRECURSOR_SCALER = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
PRECURSOR_CONFIG = os.path.join(ASSETS_DIR, "precursor_classifier_config.json")

VIBRATION_CONFIG = os.path.join(ASSETS_DIR, "vibration_model_config.json")
VIBRATION_SCALER = os.path.join(ASSETS_DIR, "vibration_scaler.json")

DEFAULT_OUTPUT = os.path.join(DATA_DIR, "calibration_thresholds.json")

TREND_DEFAULTS = {
    "ppv_trend": 1.0,
    "freq_trend": 1.0,
    "kurtosis_trend": 1.0,
    "stalta_trend": 1.0,
    "cusum_max": 0.0,
    "autoencoder_score": 0.0,
    "temp": 0.0,
    "psdSlope": 0.0,
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _load_csv(path: str) -> list:
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))
    return rows


def _build_vec(row: dict, feature_names: list) -> list:
    vec = []
    for name in feature_names:
        raw = row.get(name)
        if raw is not None and str(raw).strip() != "":
            try:
                vec.append(float(raw))
            except ValueError:
                vec.append(TREND_DEFAULTS.get(name, 0.0))
        else:
            vec.append(TREND_DEFAULTS.get(name, 0.0))
    return vec


def _apply_scaler(vec: list, scaler: dict) -> list:
    mean = scaler["mean"]
    scale = scaler.get("scale", scaler.get("std", [1.0] * len(mean)))
    return [(v - m) / max(s, 1e-10) for v, m, s in zip(vec, mean, scale)]


# ---------------------------------------------------------------------------
# TFLite inference
# ---------------------------------------------------------------------------

def _load_interpreter(path: str):
    try:
        from tflite_runtime.interpreter import Interpreter  # noqa: PLC0415
        interp = Interpreter(model_path=path)
    except ImportError:
        try:
            import tensorflow as tf  # noqa: PLC0415
            interp = tf.lite.Interpreter(model_path=path)
        except ImportError as exc:
            raise ImportError(
                "Neither tflite_runtime nor tensorflow is installed."
            ) from exc
    interp.allocate_tensors()
    return interp


def _run_inference(interp, arr: np.ndarray) -> np.ndarray:
    in_det = interp.get_input_details()
    out_det = interp.get_output_details()
    interp.set_tensor(in_det[0]["index"], arr)
    interp.invoke()
    return interp.get_tensor(out_det[0]["index"])


# ---------------------------------------------------------------------------
# Score computation
# ---------------------------------------------------------------------------

def _compute_anomaly_scores(rows: list, feature_names: list, scaler: dict, interp) -> np.ndarray:
    """Run inference on all rows and return array of anomaly scores.

    The anomaly score is max(prob[non-normal classes]), i.e. the maximum
    probability assigned to any hazard class. Higher score = more anomalous.

    Args:
        rows: List of CSV row dicts.
        feature_names: Ordered feature names for the model.
        scaler: Scaler dict with 'mean' and 'scale' keys.
        interp: Allocated TFLite interpreter.

    Returns:
        Float32 array of shape (N,) with anomaly scores in [0, 1].
    """
    dtype = interp.get_input_details()[0]["dtype"]
    scores = []
    for row in rows:
        vec = _build_vec(row, feature_names)
        norm_vec = _apply_scaler(vec, scaler)
        arr = np.array([norm_vec], dtype=dtype)
        out = _run_inference(interp, arr)
        probs = out[0].tolist()
        # Score = max probability of any non-normal class
        score = max(probs[1:]) if len(probs) > 1 else 0.0
        scores.append(score)
    return np.array(scores, dtype=np.float32)


# ---------------------------------------------------------------------------
# ML threshold from FPR
# ---------------------------------------------------------------------------

def _ml_threshold_from_fpr(scores: np.ndarray, target_fpr: float) -> tuple:
    """Find threshold where FPR on calibration data = target_fpr.

    Since all calibration samples are assumed normal, every flagged sample
    is a false positive. We find the percentile threshold.

    Args:
        scores: Anomaly scores for normal (calibration) samples.
        target_fpr: Desired false positive rate in [0, 1].

    Returns:
        Tuple (threshold, actual_fpr):
          - threshold: float in [0, 1]
          - actual_fpr: actual FPR achieved (may differ slightly due to discrete scores)
    """
    # Sort scores; threshold = value at (1 - target_fpr) percentile
    percentile = (1.0 - target_fpr) * 100.0
    threshold = float(np.percentile(scores, percentile))

    # Compute actual FPR at this threshold
    flagged = float(np.mean(scores >= threshold))
    return threshold, flagged


# ---------------------------------------------------------------------------
# PPV-based threshold
# ---------------------------------------------------------------------------

def _ppv_threshold() -> float | None:
    """Compute PPV-based threshold: noise_floor * 3.

    Reads reconstruction_error_stats.mean from vibration_model_config.json
    as a proxy for the noise floor (since PPV calibration values are not
    stored directly). Falls back to None if config is unavailable.

    Returns:
        Float threshold or None if unavailable.
    """
    if not os.path.isfile(VIBRATION_CONFIG):
        return None
    try:
        config = _load_json(VIBRATION_CONFIG)
        # Use the low threshold as a proxy for typical normal reconstruction error
        noise_floor = config.get("reconstruction_error_stats", {}).get("mean")
        if noise_floor is None:
            # Fallback: use the 'low' threshold directly
            noise_floor = config.get("thresholds", {}).get("low")
        if noise_floor is not None:
            return float(noise_floor) * 3.0
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def _print_score_distribution(scores: np.ndarray) -> None:
    """Print a compact ASCII histogram of the anomaly scores."""
    bins = np.linspace(0.0, 1.0, 11)  # 10 bins
    counts, edges = np.histogram(scores, bins=bins)
    total = len(scores)
    bar_max = 30
    print("\n  Anomaly Score Distribution (calibration samples):")
    for i, count in enumerate(counts):
        low, high = edges[i], edges[i + 1]
        bar_len = int(bar_max * count / max(total, 1))
        bar = "#" * bar_len
        pct = 100.0 * count / max(total, 1)
        print(f"  {low:.1f}-{high:.1f}  {bar:<{bar_max}}  {count:5d} ({pct:4.1f}%)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Calibration-based threshold optimization for the precursor classifier."
    )
    parser.add_argument(
        "--calibration-csv",
        required=True,
        metavar="PATH",
        help="CSV of known-safe (normal) samples for FPR calibration.",
    )
    parser.add_argument(
        "--target-fpr",
        type=float,
        default=0.05,
        metavar="FPR",
        help="Target false positive rate in [0, 1] (default: 0.05 = 5%%).",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        metavar="PATH",
        help=f"Output JSON file path (default: {DEFAULT_OUTPUT}).",
    )
    args = parser.parse_args()

    print("=" * 60)
    print("Calibration-Based Threshold Tuning")
    print("=" * 60)
    print(f"Calibration CSV: {args.calibration_csv}")
    print(f"Target FPR:      {args.target_fpr:.1%}")
    print(f"Output:          {args.output}")
    print()

    # --- Validate inputs ---
    if not 0.0 < args.target_fpr < 1.0:
        print("ERROR: --target-fpr must be between 0 and 1 (exclusive).", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(args.calibration_csv):
        print(f"ERROR: Calibration CSV not found: {args.calibration_csv}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(PRECURSOR_TFLITE):
        print(f"ERROR: Precursor model not found: {PRECURSOR_TFLITE}", file=sys.stderr)
        print("Train the model first with scripts/generate_precursor_data.py")
        sys.exit(1)

    # --- Load config, scaler, model ---
    if not os.path.isfile(PRECURSOR_CONFIG):
        print(f"ERROR: Config not found: {PRECURSOR_CONFIG}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(PRECURSOR_SCALER):
        print(f"ERROR: Scaler not found: {PRECURSOR_SCALER}", file=sys.stderr)
        sys.exit(1)

    config = _load_json(PRECURSOR_CONFIG)
    scaler = _load_json(PRECURSOR_SCALER)
    feature_names = config["feature_names"]

    # --- Load calibration data ---
    rows = _load_csv(args.calibration_csv)
    if not rows:
        print("ERROR: Calibration CSV is empty.", file=sys.stderr)
        sys.exit(1)
    print(f"Loaded {len(rows)} calibration samples")

    # --- Run inference ---
    try:
        interp = _load_interpreter(PRECURSOR_TFLITE)
    except ImportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"ERROR: Could not load TFLite model: {exc}", file=sys.stderr)
        sys.exit(1)

    print("Running inference on calibration samples...")
    try:
        scores = _compute_anomaly_scores(rows, feature_names, scaler, interp)
    except Exception as exc:
        print(f"ERROR: Inference failed: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"Score range: [{scores.min():.4f}, {scores.max():.4f}]  mean={scores.mean():.4f}")
    _print_score_distribution(scores)

    # --- Compute ML threshold ---
    ml_threshold, actual_fpr = _ml_threshold_from_fpr(scores, args.target_fpr)

    print(f"\n  ML threshold at {args.target_fpr:.1%} FPR: {ml_threshold:.4f}")
    print(f"  Actual FPR achieved:                   {actual_fpr:.4f} ({actual_fpr * 100:.1f}%)")

    # --- Compute PPV threshold ---
    ppv_threshold = _ppv_threshold()
    if ppv_threshold is not None:
        print(f"  PPV-based threshold (noise_floor * 3): {ppv_threshold:.4f}")
    else:
        print("  PPV-based threshold: N/A (vibration_model_config.json not found)")

    # --- Recommendation ---
    if ppv_threshold is not None:
        recommended = "ml" if ml_threshold <= ppv_threshold else "ppv"
        recommended_val = min(ml_threshold, ppv_threshold)
    else:
        recommended = "ml"
        recommended_val = ml_threshold

    print(f"\n  Recommended threshold: {recommended.upper()} = {recommended_val:.4f}")
    print("  (Lower threshold = more conservative = fewer missed hazards)")

    # --- Write output ---
    result = {
        "ml_threshold": round(ml_threshold, 6),
        "ppv_threshold": round(ppv_threshold, 6) if ppv_threshold is not None else None,
        "recommended": recommended,
        "recommended_value": round(recommended_val, 6),
        "fpr": round(actual_fpr, 6),
        "target_fpr": args.target_fpr,
        "n_calibration_samples": int(len(scores)),
        "score_mean": round(float(scores.mean()), 6),
        "score_std": round(float(scores.std()), 6),
        "score_max": round(float(scores.max()), 6),
        "calibrated_at": datetime.now(timezone.utc).isoformat(),
        "calibration_csv": os.path.abspath(args.calibration_csv),
    }

    output_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    Path(output_path).write_text(json.dumps(result, indent=2))

    print(f"\nThresholds written to: {output_path}")
    print()
    print("To apply in the Flutter app, update AppConstants.anomalyThreshold to:")
    print(f"  {recommended_val:.4f}")
    print()


if __name__ == "__main__":
    main()
