#!/usr/bin/env python3
"""Find optimal detection thresholds for TFLite models by sweeping over labeled data.

Usage:
    python scripts/threshold_optimizer.py --csv path/to/labeled.csv
    python scripts/threshold_optimizer.py --csv path/to/labeled.csv --model precursor
    python scripts/threshold_optimizer.py --csv path/to/labeled.csv --model anomaly --target-recall 0.95

Requires a CSV with a 'label' column:
    normal / anomaly (for anomaly model)
    normal / soil_creep / crack_propagation / imminent_failure (for precursor model)

For the precursor model any non-normal label is treated as positive (hazard) for
the binary-threshold sweep.  The 'score' used is max(prob[non-normal classes]).

For the anomaly model the score is the mean absolute reconstruction error
normalised by the configured high threshold.

Algorithm:
1. Load labeled CSV and run inference on all rows.
2. Sweep thresholds 0.00 → 1.00 in steps of 0.01.
3. For each threshold compute: precision, recall, F1, false_alarm_rate.
4. Report best-F1 threshold and the threshold that meets --target-recall
   with the lowest false_alarm_rate.
5. Print a table every 10th step plus the two recommended rows.
6. Print a human-readable recommendation line.
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
# TFLite loader
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
# Helpers
# ---------------------------------------------------------------------------

def _load_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _apply_scaler(vec: list, scaler: dict) -> list:
    mean = scaler["mean"]
    scale = scaler["scale"]
    return [(v - m) / max(s, 1e-10) for v, m, s in zip(vec, mean, scale)]


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


def _load_csv(path: str) -> list:
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))
    return rows


# ---------------------------------------------------------------------------
# Metric computation
# ---------------------------------------------------------------------------

def _metrics(scores: np.ndarray, labels_binary: np.ndarray, threshold: float) -> dict:
    """Compute precision, recall, F1, and false_alarm_rate at a threshold."""
    preds = (scores >= threshold).astype(int)
    tp = int(np.sum((preds == 1) & (labels_binary == 1)))
    fp = int(np.sum((preds == 1) & (labels_binary == 0)))
    fn = int(np.sum((preds == 0) & (labels_binary == 1)))
    tn = int(np.sum((preds == 0) & (labels_binary == 0)))

    precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    f1 = (2 * precision * recall / (precision + recall)
          if (precision + recall) > 0 else 0.0)
    far = fp / (fp + tn) if (fp + tn) > 0 else 0.0

    return {"threshold": threshold, "precision": precision, "recall": recall,
            "f1": f1, "false_alarm_rate": far, "tp": tp, "fp": fp, "fn": fn, "tn": tn}


# ---------------------------------------------------------------------------
# Score extraction — precursor model
# ---------------------------------------------------------------------------

def _get_precursor_scores(rows: list) -> tuple:
    """Return (scores, labels_binary, n_labeled)."""
    config = _load_json(PRECURSOR_CONFIG)
    scaler = _load_json(PRECURSOR_SCALER)
    feature_names = config["feature_names"]
    class_names = config.get("class_names", [
        "normal", "soil_creep", "crack_propagation", "imminent_failure"
    ])

    interp = _load_interpreter(PRECURSOR_TFLITE)
    dtype = interp.get_input_details()[0]["dtype"]

    scores = []
    labels_binary = []
    n_labeled = 0

    for row in rows:
        vec = _build_vec(row, feature_names)
        norm_vec = _apply_scaler(vec, scaler)
        arr = np.array([norm_vec], dtype=dtype)
        out = _run_inference(interp, arr)
        probs = out[0].tolist()
        # Non-normal score: max of classes 1..N
        score = max(probs[1:]) if len(probs) > 1 else 0.0
        scores.append(score)

        label = row.get("label", "").strip().lower()
        if label:
            n_labeled += 1
            labels_binary.append(0 if label == "normal" else 1)
        else:
            labels_binary.append(-1)  # unknown

    return np.array(scores), np.array(labels_binary), n_labeled


# ---------------------------------------------------------------------------
# Score extraction — anomaly model
# ---------------------------------------------------------------------------

def _get_anomaly_scores(rows: list) -> tuple:
    """Return (scores, labels_binary, n_labeled).

    Score is reconstruction error normalised by the high threshold.
    """
    scaler = _load_json(ANOMALY_SCALER)
    config = _load_json(ANOMALY_CONFIG)
    feature_names = scaler["feature_names"]
    high_t = config.get("thresholds", {}).get("high", 1.788009)

    interp = _load_interpreter(ANOMALY_TFLITE)
    dtype = interp.get_input_details()[0]["dtype"]

    scores = []
    labels_binary = []
    n_labeled = 0

    for row in rows:
        vec = _build_vec(row, feature_names)
        norm_vec = _apply_scaler(vec, scaler)
        arr = np.array([norm_vec], dtype=dtype)
        out = _run_inference(interp, arr)
        err = float(np.mean(np.abs(out[0] - np.array(norm_vec, dtype=dtype))))
        scores.append(min(err / max(high_t, 1e-10), 1.0))

        label = row.get("label", "").strip().lower()
        if label:
            n_labeled += 1
            labels_binary.append(0 if label == "normal" else 1)
        else:
            labels_binary.append(-1)

    return np.array(scores), np.array(labels_binary), n_labeled


# ---------------------------------------------------------------------------
# Threshold sweep
# ---------------------------------------------------------------------------

def _sweep(scores: np.ndarray, labels_binary: np.ndarray,
           target_recall: float) -> list:
    """Sweep thresholds and return list of metric dicts."""
    results = []
    thresholds = np.round(np.arange(0.0, 1.01, 0.01), 2)
    # Only use labeled samples
    mask = labels_binary >= 0
    s = scores[mask]
    l = labels_binary[mask]  # noqa: E741
    if len(s) == 0:
        return []
    for t in thresholds:
        m = _metrics(s, l, float(t))
        results.append(m)
    return results


def _find_best_f1(results: list) -> dict:
    return max(results, key=lambda r: r["f1"])


def _find_target_recall(results: list, target: float) -> dict:
    """Find threshold that meets target recall with lowest false_alarm_rate."""
    candidates = [r for r in results if r["recall"] >= target]
    if not candidates:
        # Relax: find closest recall >= target - 0.1
        relax_target = max(0.0, target - 0.1)
        candidates = [r for r in results if r["recall"] >= relax_target]
    if not candidates:
        return None
    # Among candidates, prefer highest threshold (lower FAR) with sufficient recall
    return min(candidates, key=lambda r: r["false_alarm_rate"])


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

def _print_table(results: list, highlight_thresholds: set) -> None:
    header = (
        f"  {'Threshold':>9}  {'Precision':>9}  {'Recall':>6}  "
        f"{'F1':>6}  {'FAR':>6}  {'TP':>5}  {'FP':>5}  {'FN':>5}  {'TN':>5}"
    )
    print(header)
    print("  " + "-" * (len(header) - 2))
    # Print every 10th step (0.0, 0.1, ..., 1.0) plus highlighted rows
    for i, r in enumerate(results):
        t = r["threshold"]
        if i % 10 != 0 and t not in highlight_thresholds:
            continue
        marker = " <--" if t in highlight_thresholds else ""
        print(
            f"  {t:>9.2f}  {r['precision']:>9.4f}  {r['recall']:>6.4f}  "
            f"{r['f1']:>6.4f}  {r['false_alarm_rate']:>6.4f}  "
            f"{r['tp']:>5}  {r['fp']:>5}  {r['fn']:>5}  {r['tn']:>5}{marker}"
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Find optimal detection thresholds via threshold sweep."
    )
    parser.add_argument("--csv", default=None, metavar="PATH",
                        help="Path to labeled CSV file (requires 'label' column).")
    parser.add_argument("--model", choices=["precursor", "anomaly"], default="precursor",
                        help="Which model to evaluate (default: precursor).")
    parser.add_argument("--target-recall", type=float, default=0.95,
                        help="Target recall for recommendation (default: 0.95).")
    args = parser.parse_args()

    # Determine which TFLite file is needed
    if args.model == "precursor":
        tflite_path = PRECURSOR_TFLITE
        model_label = "Precursor Classifier"
    else:
        tflite_path = ANOMALY_TFLITE
        model_label = "Anomaly Autoencoder"

    # Check model availability
    if not os.path.isfile(tflite_path):
        print(f"WARNING: Model not found at {tflite_path}", file=sys.stderr)
        print("Cannot run threshold sweep without a trained model.", file=sys.stderr)
        print("Train the model first with generate_precursor_data.py / train_autoencoder.py.")
        sys.exit(0)

    # Check / load CSV
    if args.csv is None or not os.path.isfile(args.csv):
        if args.csv:
            print(f"WARNING: CSV file not found: {args.csv}", file=sys.stderr)
        else:
            print("WARNING: No CSV file provided.", file=sys.stderr)
        print("A labeled CSV (with 'label' column) is required for threshold optimization.")
        print("Provide one with --csv path/to/labeled.csv")
        sys.exit(0)

    rows = _load_csv(args.csv)
    if not rows:
        print("ERROR: CSV file is empty.", file=sys.stderr)
        sys.exit(1)

    # Check that any rows have a label
    labeled_count = sum(1 for r in rows if r.get("label", "").strip())
    if labeled_count == 0:
        print(f"ERROR: CSV has {len(rows)} rows but none have a 'label' column value.", file=sys.stderr)
        print("Add a 'label' column with values: normal, anomaly (or precursor class names).")
        sys.exit(1)

    print(f"Loaded {len(rows)} rows ({labeled_count} labeled) from {args.csv}")
    print(f"Model: {model_label}")
    print(f"Target recall: {args.target_recall:.2f}")

    # Run inference and get scores
    try:
        if args.model == "precursor":
            scores, labels_binary, n_lab = _get_precursor_scores(rows)
        else:
            scores, labels_binary, n_lab = _get_anomaly_scores(rows)
    except ImportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"ERROR during inference: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"Labeled samples used: {n_lab}")
    print(f"Positive (hazard) samples: {int(np.sum(labels_binary == 1))}")
    print(f"Negative (normal) samples: {int(np.sum(labels_binary == 0))}")
    print()

    # Sweep
    results = _sweep(scores, labels_binary, args.target_recall)
    if not results:
        print("ERROR: No labeled samples available for sweep.", file=sys.stderr)
        sys.exit(1)

    best_f1 = _find_best_f1(results)
    best_recall = _find_target_recall(results, args.target_recall)

    highlight = {best_f1["threshold"]}
    if best_recall:
        highlight.add(best_recall["threshold"])

    print("=" * 75)
    print(f"THRESHOLD SWEEP - {model_label}")
    print("=" * 75)
    print("(Showing every 10th step + recommended thresholds marked <--)")
    print()
    _print_table(results, highlight)

    print()
    print("=" * 75)
    print("RECOMMENDATIONS")
    print("=" * 75)

    # Best F1
    print(f"\n  Best F1 threshold:")
    print(f"    threshold={best_f1['threshold']:.2f}  "
          f"F1={best_f1['f1']:.4f}  "
          f"precision={best_f1['precision']:.4f}  "
          f"recall={best_f1['recall']:.4f}  "
          f"FAR={best_f1['false_alarm_rate']:.4f}")

    # Target recall
    if best_recall:
        actual_recall = best_recall["recall"]
        far_pct = best_recall["false_alarm_rate"] * 100
        print(f"\n  Target-recall threshold (>= {args.target_recall:.0%}):")
        print(f"    threshold={best_recall['threshold']:.2f}  "
              f"F1={best_recall['f1']:.4f}  "
              f"precision={best_recall['precision']:.4f}  "
              f"recall={actual_recall:.4f}  "
              f"FAR={best_recall['false_alarm_rate']:.4f}")
        print()
        print(f"  Set anomaly_threshold = {best_recall['threshold']:.2f} for "
              f"{actual_recall * 100:.0f}% recall with {far_pct:.1f}% false alarm rate")
    else:
        print(f"\n  Could not find a threshold meeting {args.target_recall:.0%} recall.")
        print(f"  Using best-F1 threshold as fallback:")
        far_pct = best_f1["false_alarm_rate"] * 100
        actual_recall = best_f1["recall"]
        print(f"  Set anomaly_threshold = {best_f1['threshold']:.2f} for "
              f"{actual_recall * 100:.0f}% recall with {far_pct:.1f}% false alarm rate")

    print()


if __name__ == "__main__":
    main()
