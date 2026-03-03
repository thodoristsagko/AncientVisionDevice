#!/usr/bin/env python3
"""Evaluate saved TFLite models against a field CSV test file.

Usage:
    python scripts/evaluate_models.py --test-csv data/field/2026-03-03.csv
    python scripts/evaluate_models.py --test-csv data/field/2026-03-03.csv --model precursor
    python scripts/evaluate_models.py --test-csv data/field/2026-03-03.csv --model anomaly
    python scripts/evaluate_models.py --test-csv data/field/2026-03-03.csv --model both

CSV columns expected (extra columns ignored, missing feature columns default to 0.0):
    device_id, timestamp, rms, ppv, freq, crest, centroid, kurtosis,
    stalta, arias, cav, label

Dependencies: tensorflow (already in ML Docker image), numpy, stdlib only.
"""

import argparse
import csv
import json
import os
import sys

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

PRECURSOR_TFLITE = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
PRECURSOR_SCALER = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
PRECURSOR_CONFIG = os.path.join(ASSETS_DIR, "precursor_classifier_config.json")

ANOMALY_TFLITE = os.path.join(ASSETS_DIR, "vibration_anomaly.tflite")
ANOMALY_SCALER = os.path.join(ASSETS_DIR, "vibration_scaler.json")
ANOMALY_CONFIG = os.path.join(ASSETS_DIR, "vibration_model_config.json")

# ---------------------------------------------------------------------------
# Feature defaults for trend/derived fields absent from field CSV
# ---------------------------------------------------------------------------

# Neutral defaults: ratios=1.0 (no change), cusum/score=0.0
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


def build_feature_vector(row: dict, feature_names: list) -> list:
    """Build a feature vector from a CSV row dict.

    Missing features default to TREND_DEFAULTS if defined, else 0.0.
    Values are parsed as float; parse errors default to 0.0.

    Args:
        row: Dict mapping column name -> string value.
        feature_names: Ordered list of feature names for the model.

    Returns:
        List of float values in feature_names order.
    """
    vec = []
    for name in feature_names:
        raw = row.get(name)
        if raw is not None and raw != "":
            try:
                vec.append(float(raw))
            except ValueError:
                vec.append(TREND_DEFAULTS.get(name, 0.0))
        else:
            vec.append(TREND_DEFAULTS.get(name, 0.0))
    return vec


# ---------------------------------------------------------------------------
# Scaler helpers
# ---------------------------------------------------------------------------

def load_scaler(path: str) -> dict:
    """Load a JSON scaler with 'mean', 'scale', 'feature_names' keys."""
    with open(path, "r") as f:
        return json.load(f)


def apply_scaler(vec: list, scaler: dict) -> list:
    """Z-score normalize a feature vector using the loaded scaler.

    Args:
        vec: Raw feature values (length must match scaler).
        scaler: Dict with 'mean' and 'scale' lists.

    Returns:
        Normalized list of floats.
    """
    mean = scaler["mean"]
    scale = scaler["scale"]
    if len(vec) != len(mean):
        raise ValueError(
            f"Feature vector length {len(vec)} != scaler length {len(mean)}"
        )
    return [(v - m) / max(s, 1e-10) for v, m, s in zip(vec, mean, scale)]


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def load_csv(path: str) -> list:
    """Load CSV file; return list of dicts (one per row)."""
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))
    return rows


# ---------------------------------------------------------------------------
# TFLite inference
# ---------------------------------------------------------------------------

def load_interpreter(tflite_path: str):
    """Load a TFLite model and return an allocated Interpreter."""
    try:
        import tensorflow as tf  # noqa: PLC0415
    except ImportError as exc:
        raise ImportError(
            "tensorflow is required. Install it or use the ML Docker image."
        ) from exc
    interpreter = tf.lite.Interpreter(model_path=tflite_path)
    interpreter.allocate_tensors()
    return interpreter


def run_inference(interpreter, input_array: np.ndarray) -> np.ndarray:
    """Run one inference pass; return output array."""
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()
    interpreter.set_tensor(input_details[0]["index"], input_array)
    interpreter.invoke()
    return interpreter.get_tensor(output_details[0]["index"])


# ---------------------------------------------------------------------------
# Label helpers
# ---------------------------------------------------------------------------

CLASS_NAMES_PRECURSOR = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]


def label_to_index(label: str, class_names: list) -> int:
    """Map a string label to a class index, or -1 if unknown."""
    label = label.strip().lower()
    for i, name in enumerate(class_names):
        if name.lower() == label:
            return i
    return -1


# ---------------------------------------------------------------------------
# Evaluation — precursor classifier
# ---------------------------------------------------------------------------

def evaluate_precursor(rows: list) -> None:
    """Run precursor classifier evaluation and print results."""
    print("\n" + "=" * 60)
    print("PRECURSOR CLASSIFIER (17-feature, 4-class)")
    print("=" * 60)

    # Load config / scaler / model
    with open(PRECURSOR_CONFIG, "r") as f:
        config = json.load(f)
    feature_names = config["feature_names"]
    class_names = config.get("class_names", CLASS_NAMES_PRECURSOR)

    scaler = load_scaler(PRECURSOR_SCALER)
    interpreter = load_interpreter(PRECURSOR_TFLITE)
    input_details = interpreter.get_input_details()
    dtype = input_details[0]["dtype"]

    predictions = []
    ground_truth = []
    prediction_probs = []

    for row in rows:
        raw_vec = build_feature_vector(row, feature_names)
        norm_vec = apply_scaler(raw_vec, scaler)
        arr = np.array([norm_vec], dtype=dtype)
        out = run_inference(interpreter, arr)          # shape (1, 4)
        pred_idx = int(np.argmax(out[0]))
        predictions.append(pred_idx)
        prediction_probs.append(out[0].tolist())

        label = row.get("label", "").strip()
        gt_idx = label_to_index(label, class_names)
        ground_truth.append(gt_idx)

    _print_classification_report(
        ground_truth, predictions, prediction_probs, class_names, rows
    )


# ---------------------------------------------------------------------------
# Evaluation — anomaly autoencoder
# ---------------------------------------------------------------------------

def evaluate_anomaly(rows: list) -> None:
    """Run anomaly autoencoder evaluation and print results.

    The autoencoder reconstructs input; reconstruction error is compared
    against thresholds from vibration_model_config.json to assign a label:
      - error <= low_threshold  => 'normal'
      - low < error <= high     => 'elevated'
      - error > high_threshold  => 'anomaly'
    """
    print("\n" + "=" * 60)
    print("ANOMALY AUTOENCODER (11-feature)")
    print("=" * 60)

    with open(ANOMALY_CONFIG, "r") as f:
        config = json.load(f)
    thresholds = config.get("thresholds", {"low": 1.195327, "high": 1.788009})
    low_t = thresholds["low"]
    high_t = thresholds["high"]

    scaler = load_scaler(ANOMALY_SCALER)
    feature_names = scaler["feature_names"]  # vibration_scaler defines order

    interpreter = load_interpreter(ANOMALY_TFLITE)
    input_details = interpreter.get_input_details()
    dtype = input_details[0]["dtype"]

    anomaly_class_names = ["normal", "elevated", "anomaly"]
    predictions = []
    ground_truth = []
    errors = []

    for row in rows:
        raw_vec = build_feature_vector(row, feature_names)
        norm_vec = apply_scaler(raw_vec, scaler)
        arr = np.array([norm_vec], dtype=dtype)
        out = run_inference(interpreter, arr)          # shape (1, 11) reconstructed

        # Mean absolute reconstruction error
        recon_error = float(np.mean(np.abs(out[0] - np.array(norm_vec, dtype=dtype))))
        errors.append(recon_error)

        if recon_error <= low_t:
            pred_idx = 0  # normal
        elif recon_error <= high_t:
            pred_idx = 1  # elevated
        else:
            pred_idx = 2  # anomaly
        predictions.append(pred_idx)

        label = row.get("label", "").strip().lower()
        # Map ground-truth: treat non-normal as anomaly for comparison
        if label == "normal" or label == "":
            gt_idx = 0
        elif label == "imminent_failure":
            gt_idx = 2
        else:
            gt_idx = 1
        ground_truth.append(gt_idx)

    # Print error stats
    err_arr = np.array(errors)
    print(f"\nReconstruction error stats:")
    print(f"  mean={err_arr.mean():.4f}  std={err_arr.std():.4f}")
    print(f"  min={err_arr.min():.4f}  max={err_arr.max():.4f}")
    print(f"  Thresholds: low={low_t:.4f}  high={high_t:.4f}")

    _print_classification_report(
        ground_truth, predictions, None, anomaly_class_names, rows
    )


# ---------------------------------------------------------------------------
# Shared reporting helpers
# ---------------------------------------------------------------------------

def _print_classification_report(
    ground_truth: list,
    predictions: list,
    probs,          # list of prob-lists or None
    class_names: list,
    rows: list,
) -> None:
    """Print accuracy, per-class counts, and sample predictions."""
    n = len(predictions)
    if n == 0:
        print("No samples to evaluate.")
        return

    # Filter to rows with valid ground-truth labels
    labeled = [(gt, p) for gt, p in zip(ground_truth, predictions) if gt >= 0]
    unlabeled = n - len(labeled)

    if labeled:
        correct = sum(1 for gt, p in labeled if gt == p)
        acc = correct / len(labeled)
        print(f"\nTotal samples : {n}")
        print(f"Labeled       : {len(labeled)}")
        if unlabeled:
            print(f"Unlabeled     : {unlabeled} (excluded from accuracy)")
        print(f"Accuracy      : {acc:.4f} ({correct}/{len(labeled)} correct)")
    else:
        print(f"\nTotal samples : {n}  (no labeled ground truth — showing predictions only)")

    # Per-class prediction counts
    print("\nPer-class prediction counts:")
    pred_counts = [0] * len(class_names)
    for p in predictions:
        if 0 <= p < len(class_names):
            pred_counts[p] += 1
    for i, name in enumerate(class_names):
        pct = pred_counts[i] / n * 100 if n else 0.0
        bar = "#" * int(pct / 2)
        print(f"  {name:<22} {pred_counts[i]:5d}  ({pct:5.1f}%)  {bar}")

    # Per-class accuracy when ground truth available
    if labeled:
        print("\nPer-class accuracy:")
        for i, name in enumerate(class_names):
            class_rows = [(gt, p) for gt, p in labeled if gt == i]
            if class_rows:
                cls_correct = sum(1 for gt, p in class_rows if gt == p)
                print(f"  {name:<22} {cls_correct}/{len(class_rows)} "
                      f"({cls_correct / len(class_rows) * 100:.1f}%)")
            else:
                print(f"  {name:<22} 0/0  (no samples)")

    # Sample predictions (first 10)
    print("\nSample predictions (first 10):")
    header = f"  {'#':>4}  {'Ground Truth':<22}  {'Predicted':<22}"
    if probs:
        header += "  Confidence"
    print(header)
    print("  " + "-" * (len(header) - 2))

    for i in range(min(10, n)):
        gt_idx = ground_truth[i]
        p_idx = predictions[i]
        gt_name = class_names[gt_idx] if 0 <= gt_idx < len(class_names) else "unknown"
        p_name = class_names[p_idx] if 0 <= p_idx < len(class_names) else "unknown"
        match = "OK" if gt_idx == p_idx else "MISMATCH"
        line = f"  {i:>4}  {gt_name:<22}  {p_name:<22}  {match}"
        if probs:
            conf = max(probs[i])
            line += f"  {conf:.3f}"
        print(line)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Evaluate TFLite models against a field CSV test file."
    )
    parser.add_argument(
        "--test-csv",
        required=True,
        metavar="PATH",
        help="Path to CSV file (device_id,timestamp,rms,ppv,...,label).",
    )
    parser.add_argument(
        "--model",
        choices=["precursor", "anomaly", "both"],
        default="both",
        help="Which model(s) to evaluate (default: both).",
    )
    args = parser.parse_args()

    csv_path = args.test_csv
    if not os.path.isfile(csv_path):
        print(f"ERROR: CSV file not found: {csv_path}", file=sys.stderr)
        sys.exit(1)

    rows = load_csv(csv_path)
    if not rows:
        print("ERROR: CSV file is empty or has no data rows.", file=sys.stderr)
        sys.exit(1)

    print(f"Loaded {len(rows)} rows from {csv_path}")

    if args.model in ("precursor", "both"):
        if not os.path.isfile(PRECURSOR_TFLITE):
            print(
                f"WARNING: Precursor model not found at {PRECURSOR_TFLITE}. "
                "Skipping.",
                file=sys.stderr,
            )
        else:
            evaluate_precursor(rows)

    if args.model in ("anomaly", "both"):
        if not os.path.isfile(ANOMALY_TFLITE):
            print(
                f"WARNING: Anomaly model not found at {ANOMALY_TFLITE}. "
                "Skipping.",
                file=sys.stderr,
            )
        else:
            evaluate_anomaly(rows)

    print("\nDone.")


if __name__ == "__main__":
    main()
