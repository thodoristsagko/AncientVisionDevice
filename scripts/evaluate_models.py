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
from collections import defaultdict

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
        ground_truth, predictions, prediction_probs, class_names, rows, feature_names
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
        ground_truth, predictions, None, anomaly_class_names, rows, feature_names
    )


# ---------------------------------------------------------------------------
# Shared reporting helpers
# ---------------------------------------------------------------------------

def _compute_roc_curve_ascii(
    ground_truth: list,
    probs: list,
    class_names: list,
    pos_class_idx: int = 1,
) -> float:
    """Compute and display ROC curve for binary classification.

    For multi-class, treats pos_class_idx vs rest as binary.
    Returns AUC.
    """
    # Convert multi-class GT to binary (pos_class vs rest)
    binary_gt = [1 if gt == pos_class_idx else 0 for gt in ground_truth]

    # Extract probability for positive class
    binary_probs = [p[pos_class_idx] if pos_class_idx < len(p) else 0.0 for p in probs]

    # Sort by probability (descending) and compute TPR/FPR at each threshold
    sorted_pairs = sorted(zip(binary_probs, binary_gt), reverse=True)

    total_pos = sum(binary_gt)
    total_neg = len(binary_gt) - total_pos

    if total_pos == 0 or total_neg == 0:
        return 0.0  # Can't compute ROC if only one class

    # Compute ROC points
    roc_points = [(0.0, 0.0)]  # (FPR, TPR) starting at origin
    tp = 0
    fp = 0
    auc = 0.0

    for prob, label in sorted_pairs:
        if label == 1:
            tp += 1
        else:
            fp += 1
        tpr = tp / total_pos
        fpr = fp / total_neg
        roc_points.append((fpr, tpr))
        # Trapezoidal rule for AUC
        if len(roc_points) > 1:
            prev_fpr, prev_tpr = roc_points[-2]
            auc += (fpr - prev_fpr) * (tpr + prev_tpr) / 2

    # ASCII plot (20x10 grid)
    width, height = 40, 12
    grid = [["." for _ in range(width)] for _ in range(height)]

    # Plot diagonal line (random classifier)
    for h in range(height):
        w_diag = int(h * width / height)
        if 0 <= w_diag < width:
            grid[h][w_diag] = "-"

    # Plot ROC curve
    for fpr, tpr in roc_points:
        x = int(fpr * (width - 1))
        y = height - 1 - int(tpr * (height - 1))
        if 0 <= x < width and 0 <= y < height:
            grid[y][x] = "*"

    print(f"\nROC Curve (binary: {class_names[pos_class_idx]} vs rest):")
    print("  TPR")
    print("    |")
    for h, row in enumerate(grid):
        tpr_label = f"{1.0 - h / height:.1f}" if h % 2 == 0 else "   "
        print(f"    {tpr_label}  {''.join(row)}")
    print("    +--" + "-" * (width - 3) + "→ FPR")
    print(f"    0.0                1.0")
    print(f"  AUC: {auc:.4f}")
    return auc


def _compute_calibration_curve_ascii(
    ground_truth: list,
    probs: list,
    class_names: list,
) -> None:
    """Compute and display calibration curves (reliability diagrams).

    For each class, compares predicted probability vs actual frequency.
    A well-calibrated model has points near the diagonal.
    """
    print("\nCalibration Curves (Reliability Diagrams):")

    for class_idx, class_name in enumerate(class_names):
        # Filter to samples where this class appears
        class_probs = [p[class_idx] if class_idx < len(p) else 0.0 for p in probs]
        is_true_class = [1 if gt == class_idx else 0 for gt in ground_truth]

        if sum(is_true_class) == 0:
            print(f"  {class_name:<22} (no samples of this class)")
            continue

        # Bin predictions into 10 bins (0-0.1, 0.1-0.2, ..., 0.9-1.0)
        bins = [[] for _ in range(10)]
        for prob, true_label in zip(class_probs, is_true_class):
            bin_idx = min(int(prob * 10), 9)
            bins[bin_idx].append(true_label)

        # Compute calibration points
        calib_points = []
        for bin_idx, bin_samples in enumerate(bins):
            if bin_samples:
                pred_prob = (bin_idx + 0.5) / 10
                actual_freq = sum(bin_samples) / len(bin_samples)
                calib_points.append((pred_prob, actual_freq))

        # ASCII plot (20x10)
        width, height = 40, 12
        grid = [["." for _ in range(width)] for _ in range(height)]

        # Diagonal line (perfect calibration)
        for h in range(height):
            w_diag = int(h * width / height)
            if 0 <= w_diag < width:
                grid[h][w_diag] = "-"

        # Plot calibration points
        for pred_prob, actual_freq in calib_points:
            x = int(pred_prob * (width - 1))
            y = height - 1 - int(actual_freq * (height - 1))
            if 0 <= x < width and 0 <= y < height:
                grid[y][x] = "*"

        print(f"\n  {class_name}:")
        print("    |")
        for h, row in enumerate(grid):
            actual_label = f"{1.0 - h / height:.1f}" if h % 2 == 0 else "   "
            print(f"    {actual_label}  {''.join(row)}")
        print("    +--" + "-" * (width - 3) + "→ Predicted")
        print(f"    0.0                1.0")


def _compute_top_k_accuracy(
    ground_truth: list,
    probs: list,
    k: int = 2,
) -> float:
    """Compute top-K accuracy: fraction where correct class is in top-K predictions."""
    if not probs or k < 1:
        return 0.0

    correct = 0
    total = 0
    for gt, p_list in zip(ground_truth, probs):
        if gt >= 0:  # Only count labeled samples
            total += 1
            # Get indices of top-K predictions
            top_k_indices = np.argsort(p_list)[-k:]
            if gt in top_k_indices:
                correct += 1

    return correct / total if total > 0 else 0.0


def _analyze_errors(
    ground_truth: list,
    predictions: list,
    probs,  # list of prob lists or None
    class_names: list,
    rows: list,
    feature_names: list,
) -> None:
    """Analyze error patterns: top confused pairs and feature stats for errors."""
    print("\nError Analysis:")

    # Find confused class pairs
    confusion_pairs = defaultdict(int)
    error_indices = []

    for idx, (gt, pred) in enumerate(zip(ground_truth, predictions)):
        if gt >= 0 and gt != pred:
            gt_name = class_names[gt] if gt < len(class_names) else "unknown"
            pred_name = class_names[pred] if pred < len(class_names) else "unknown"
            confusion_pairs[(gt_name, pred_name)] += 1
            error_indices.append(idx)

    if not confusion_pairs:
        print("  No errors found!")
        return

    # Top 5 confused pairs
    top_pairs = sorted(confusion_pairs.items(), key=lambda x: x[1], reverse=True)[:5]
    print(f"\n  Top {len(top_pairs)} confused class pairs:")
    for (true_class, pred_class), count in top_pairs:
        print(f"    {true_class:20s} → {pred_class:20s}: {count:3d} times")

    # Feature stats for errors
    if rows and feature_names and len(rows) == len(ground_truth):
        print(f"\n  Mean feature values for misclassified samples ({len(error_indices)} errors):")

        error_features = defaultdict(list)
        for err_idx in error_indices:
            row = rows[err_idx]
            for fname in feature_names:
                try:
                    val = float(row.get(fname, 0.0))
                    error_features[fname].append(val)
                except (ValueError, TypeError):
                    pass

        if error_features:
            for fname in feature_names[:8]:  # Show first 8 features to keep output manageable
                if fname in error_features and error_features[fname]:
                    mean_val = np.mean(error_features[fname])
                    std_val = np.std(error_features[fname])
                    print(f"    {fname:<22} mean={mean_val:8.4f}  std={std_val:8.4f}")


def _print_classification_report(
    ground_truth: list,
    predictions: list,
    probs,          # list of prob-lists or None
    class_names: list,
    rows: list,
    feature_names: list = None,
) -> None:
    """Print accuracy, per-class counts, sample predictions, ROC, calibration, top-K, and errors."""
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

    # Top-2 accuracy (only if we have probabilities)
    if probs:
        top2_acc = _compute_top_k_accuracy(ground_truth, probs, k=2)
        print(f"\nTop-2 Accuracy: {top2_acc:.4f}")

    # ROC curve (for binary: normal vs anomaly, or for multi-class use first anomaly-like class)
    if probs and len(class_names) >= 2:
        # For precursor (4 classes): anomaly = imminent_failure (index 3)
        # For anomaly (3 classes): anomaly = anomaly (index 2)
        pos_idx = len(class_names) - 1 if "imminent_failure" not in class_names else list(class_names).index("imminent_failure") if "imminent_failure" in class_names else 2
        _compute_roc_curve_ascii(ground_truth, probs, class_names, pos_class_idx=pos_idx)

    # Calibration curves
    if probs:
        _compute_calibration_curve_ascii(ground_truth, probs, class_names)

    # Error analysis
    _analyze_errors(ground_truth, predictions, probs, class_names, rows, feature_names or [])

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
