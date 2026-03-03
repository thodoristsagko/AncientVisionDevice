#!/usr/bin/env python3
"""Combine autoencoder + precursor classifier scores into an ensemble prediction.

Usage:
    python scripts/ensemble_predict.py
    python scripts/ensemble_predict.py --csv path/to/field.csv
    python scripts/ensemble_predict.py --csv path/to/field.csv --anomaly-weight 0.4 --precursor-weight 0.6

The ensemble score is:
    ensemble = anomaly_weight * norm_anomaly_score + precursor_weight * precursor_score

where:
    norm_anomaly_score  = reconstruction_error / high_threshold  (clamped to [0, 1])
    precursor_score     = max probability of non-normal classes from precursor classifier

A sample is flagged when ensemble_score > 0.5 (default threshold).
"""

import argparse
import csv
import json
import os
import sys

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

PRECURSOR_TFLITE = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
PRECURSOR_SCALER = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
PRECURSOR_CONFIG = os.path.join(ASSETS_DIR, "precursor_classifier_config.json")

ANOMALY_TFLITE = os.path.join(ASSETS_DIR, "vibration_anomaly.tflite")
ANOMALY_SCALER = os.path.join(ASSETS_DIR, "vibration_scaler.json")
ANOMALY_CONFIG = os.path.join(ASSETS_DIR, "vibration_model_config.json")

ENSEMBLE_THRESHOLD = 0.5

# Neutral defaults for derived / trend columns absent from basic field CSVs
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
# TFLite loader — tries tflite_runtime first, then tensorflow
# ---------------------------------------------------------------------------

def _load_interpreter(path: str):
    """Load a TFLite Interpreter, trying tflite_runtime then tensorflow.

    Returns the allocated Interpreter, or raises ImportError if neither
    package is available.
    """
    try:
        from tflite_runtime.interpreter import Interpreter  # noqa: PLC0415
        interp = Interpreter(model_path=path)
    except ImportError:
        try:
            import tensorflow as tf  # noqa: PLC0415
            interp = tf.lite.Interpreter(model_path=path)
        except ImportError as exc:
            raise ImportError(
                "Neither tflite_runtime nor tensorflow is installed. "
                "Install one of them to run TFLite inference."
            ) from exc
    interp.allocate_tensors()
    return interp


def _run_inference(interp, arr: np.ndarray) -> np.ndarray:
    """Run one inference pass and return the output tensor."""
    in_det = interp.get_input_details()
    out_det = interp.get_output_details()
    interp.set_tensor(in_det[0]["index"], arr)
    interp.invoke()
    return interp.get_tensor(out_det[0]["index"])


# ---------------------------------------------------------------------------
# Scaler helpers
# ---------------------------------------------------------------------------

def _load_json(path: str) -> dict:
    with open(path, "r") as f:
        return json.load(f)


def _apply_scaler(vec: list, scaler: dict) -> list:
    mean = scaler["mean"]
    scale = scaler["scale"]
    return [(v - m) / max(s, 1e-10) for v, m, s in zip(vec, mean, scale)]


def _build_vec(row: dict, feature_names: list) -> list:
    """Build a raw feature vector from a CSV row dict."""
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


# ---------------------------------------------------------------------------
# Synthetic data generation
# ---------------------------------------------------------------------------

def _make_synthetic(n: int = 100) -> list:
    """Generate n synthetic rows with all 17 precursor features."""
    rng = np.random.default_rng(42)
    feature_names = [
        "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
        "stalta", "arias", "cav", "temp", "psdSlope",
        "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
        "cusum_max", "autoencoder_score",
    ]
    rows = []
    for i in range(n):
        # Alternate between normal-ish and anomalous-ish
        if i % 5 == 0:  # 20% look anomalous
            ppv = rng.uniform(0.8, 2.5)
            rms = ppv * rng.uniform(0.4, 0.7)
            kurtosis = rng.uniform(4.0, 10.0)
            stalta = rng.uniform(3.0, 8.0)
        else:
            ppv = rng.uniform(0.01, 0.25)
            rms = ppv * rng.uniform(0.3, 0.6)
            kurtosis = rng.uniform(0.5, 3.0)
            stalta = rng.uniform(0.5, 2.0)

        row = {
            "rms": rms,
            "ppv": ppv,
            "freq": rng.uniform(1.0, 80.0),
            "crest": rng.uniform(2.0, 6.0),
            "centroid": rng.uniform(5.0, 40.0),
            "kurtosis": kurtosis,
            "stalta": stalta,
            "arias": ppv * 0.001 * rng.uniform(0.5, 2.0),
            "cav": ppv * 0.005 * rng.uniform(0.5, 2.0),
            "temp": rng.uniform(15.0, 35.0),
            "psdSlope": rng.uniform(-12.0, -4.0),
            "ppv_trend": rng.uniform(0.5, 2.0),
            "freq_trend": rng.uniform(0.8, 1.5),
            "kurtosis_trend": rng.uniform(0.8, 1.5),
            "stalta_trend": rng.uniform(0.8, 2.0),
            "cusum_max": rng.uniform(0.0, 5.0) if ppv > 0.5 else 0.0,
            "autoencoder_score": rng.uniform(0.0, 1.0),
            "_synthetic": True,
            "_index": i,
        }
        rows.append(row)
    return rows, feature_names


# ---------------------------------------------------------------------------
# Inference helpers
# ---------------------------------------------------------------------------

def _anomaly_score(interp, row: dict, anomaly_feature_names: list,
                   anomaly_scaler: dict, anomaly_config: dict,
                   dtype) -> tuple:
    """Return (raw_error, normalized_score_0_to_1)."""
    high_t = anomaly_config.get("thresholds", {}).get("high", 1.788009)
    raw_vec = _build_vec(row, anomaly_feature_names)
    norm_vec = _apply_scaler(raw_vec, anomaly_scaler)
    arr = np.array([norm_vec], dtype=dtype)
    out = _run_inference(interp, arr)
    err = float(np.mean(np.abs(out[0] - np.array(norm_vec, dtype=dtype))))
    norm_score = min(err / max(high_t, 1e-10), 1.0)
    return err, norm_score


def _precursor_score(interp, row: dict, precursor_feature_names: list,
                     precursor_scaler: dict, class_names: list,
                     dtype) -> tuple:
    """Return (predicted_class_name, max_non_normal_prob)."""
    raw_vec = _build_vec(row, precursor_feature_names)
    norm_vec = _apply_scaler(raw_vec, precursor_scaler)
    arr = np.array([norm_vec], dtype=dtype)
    out = _run_inference(interp, arr)
    probs = out[0].tolist()
    pred_idx = int(np.argmax(probs))
    pred_class = class_names[pred_idx] if pred_idx < len(class_names) else "unknown"
    # Non-normal score: max probability across classes 1, 2, 3
    non_normal = max(probs[1:]) if len(probs) > 1 else 0.0
    return pred_class, non_normal, probs


# ---------------------------------------------------------------------------
# CSV loader
# ---------------------------------------------------------------------------

def _load_csv(path: str) -> list:
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))
    if not rows:
        raise ValueError(f"CSV file is empty or has no data rows: {path}")
    return rows


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Ensemble autoencoder + precursor classifier scores."
    )
    parser.add_argument("--csv", default=None, metavar="PATH",
                        help="Path to field CSV. If omitted, 100 synthetic samples are used.")
    parser.add_argument("--anomaly-weight", type=float, default=0.4,
                        help="Weight for the anomaly (autoencoder) score (default: 0.4).")
    parser.add_argument("--precursor-weight", type=float, default=0.6,
                        help="Weight for the precursor classifier score (default: 0.6).")
    parser.add_argument("--threshold", type=float, default=ENSEMBLE_THRESHOLD,
                        help="Ensemble threshold for flagging (default: 0.5).")
    args = parser.parse_args()

    # Validate weights
    total_weight = args.anomaly_weight + args.precursor_weight
    if abs(total_weight - 1.0) > 0.01:
        print(f"WARNING: anomaly_weight + precursor_weight = {total_weight:.3f} (expected ~1.0). "
              "Normalizing.", file=sys.stderr)
        args.anomaly_weight /= total_weight
        args.precursor_weight /= total_weight

    # Load or generate data
    if args.csv:
        if not os.path.isfile(args.csv):
            print(f"ERROR: CSV file not found: {args.csv}", file=sys.stderr)
            sys.exit(1)
        rows = _load_csv(args.csv)
        synthetic = False
        print(f"Loaded {len(rows)} rows from {args.csv}")
    else:
        rows, _ = _make_synthetic(100)
        synthetic = True
        print("No CSV provided - using 100 synthetic samples.")

    # Check models
    anomaly_available = os.path.isfile(ANOMALY_TFLITE)
    precursor_available = os.path.isfile(PRECURSOR_TFLITE)

    if not anomaly_available:
        print(f"WARNING: Anomaly model not found at {ANOMALY_TFLITE}", file=sys.stderr)
    if not precursor_available:
        print(f"WARNING: Precursor model not found at {PRECURSOR_TFLITE}", file=sys.stderr)

    if not anomaly_available and not precursor_available:
        print("ERROR: No TFLite models available. Cannot run ensemble prediction.", file=sys.stderr)
        sys.exit(1)

    # Load models
    try:
        tflite_available = True
        if anomaly_available:
            anomaly_interp = _load_interpreter(ANOMALY_TFLITE)
            anomaly_in_dtype = anomaly_interp.get_input_details()[0]["dtype"]
            anomaly_scaler = _load_json(ANOMALY_SCALER)
            anomaly_config = _load_json(ANOMALY_CONFIG)
            anomaly_feature_names = anomaly_scaler["feature_names"]
            anomaly_high_t = anomaly_config.get("thresholds", {}).get("high", 1.788009)
        else:
            anomaly_interp = None

        if precursor_available:
            precursor_interp = _load_interpreter(PRECURSOR_TFLITE)
            precursor_in_dtype = precursor_interp.get_input_details()[0]["dtype"]
            precursor_scaler = _load_json(PRECURSOR_SCALER)
            precursor_config = _load_json(PRECURSOR_CONFIG)
            precursor_feature_names = precursor_config["feature_names"]
            precursor_class_names = precursor_config.get("class_names", [
                "normal", "soil_creep", "crack_propagation", "imminent_failure"
            ])
        else:
            precursor_interp = None
    except ImportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    # Header
    print()
    print(f"  Ensemble weights: anomaly={args.anomaly_weight:.2f}  "
          f"precursor={args.precursor_weight:.2f}  threshold={args.threshold:.2f}")
    print()
    col_w = [6, 12, 12, 12, 12, 18, 8]
    header = (
        f"  {'#':>{col_w[0]}}  "
        f"{'Anomaly_Err':>{col_w[1]}}  "
        f"{'Anom_Score':>{col_w[2]}}  "
        f"{'Prec_Score':>{col_w[3]}}  "
        f"{'Ensemble':>{col_w[4]}}  "
        f"{'Predicted_Class':<{col_w[5]}}  "
        f"{'FLAG':>{col_w[6]}}"
    )
    print(header)
    print("  " + "-" * (len(header) - 2))

    flagged = 0
    total = len(rows)
    ensemble_scores = []

    for i, row in enumerate(rows):
        # Anomaly score
        if anomaly_interp is not None:
            try:
                raw_err, norm_anom = _anomaly_score(
                    anomaly_interp, row, anomaly_feature_names,
                    anomaly_scaler, anomaly_config, anomaly_in_dtype
                )
            except Exception as exc:
                print(f"  WARNING: row {i} anomaly inference failed: {exc}", file=sys.stderr)
                raw_err, norm_anom = 0.0, 0.0
        else:
            raw_err, norm_anom = 0.0, 0.0

        # Precursor score
        if precursor_interp is not None:
            try:
                pred_class, prec_score, probs = _precursor_score(
                    precursor_interp, row, precursor_feature_names,
                    precursor_scaler, precursor_class_names, precursor_in_dtype
                )
            except Exception as exc:
                print(f"  WARNING: row {i} precursor inference failed: {exc}", file=sys.stderr)
                pred_class, prec_score = "unknown", 0.0
        else:
            # Fall back: use anomaly score to derive class
            pred_class = "anomaly" if norm_anom > 0.5 else "normal"
            prec_score = norm_anom

        # Ensemble
        ensemble = args.anomaly_weight * norm_anom + args.precursor_weight * prec_score
        ensemble_scores.append(ensemble)

        flag = "*** ALERT" if ensemble >= args.threshold else ""
        if ensemble >= args.threshold:
            flagged += 1

        print(
            f"  {i:>{col_w[0]}}  "
            f"{raw_err:>{col_w[1]}.4f}  "
            f"{norm_anom:>{col_w[2]}.4f}  "
            f"{prec_score:>{col_w[3]}.4f}  "
            f"{ensemble:>{col_w[4]}.4f}  "
            f"{pred_class:<{col_w[5]}}  "
            f"{flag}"
        )

    # Summary
    pct_flagged = flagged / total * 100 if total else 0.0
    arr = np.array(ensemble_scores)
    print()
    print("=" * 65)
    print("SUMMARY")
    print("=" * 65)
    print(f"  Total samples           : {total}")
    if synthetic:
        print(f"  Data source             : synthetic (no CSV provided)")
    print(f"  Ensemble threshold      : {args.threshold:.2f}")
    print(f"  Samples above threshold : {flagged} / {total}  ({pct_flagged:.1f}%)")
    print(f"  Ensemble score - mean   : {arr.mean():.4f}")
    print(f"  Ensemble score - max    : {arr.max():.4f}")
    print(f"  Ensemble score - std    : {arr.std():.4f}")
    if anomaly_interp is None:
        print("  NOTE: Anomaly model was unavailable; anomaly_score=0.0 for all rows.")
    if precursor_interp is None:
        print("  NOTE: Precursor model was unavailable; precursor_score derived from anomaly.")
    print()


if __name__ == "__main__":
    main()
