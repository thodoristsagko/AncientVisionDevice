#!/usr/bin/env python3
"""Evaluate model generalisation across devices using leave-one-device-out cross-validation.

Usage:
    python scripts/cross_device_eval.py
    python scripts/cross_device_eval.py --data-dir ./data/field
    python scripts/cross_device_eval.py --data-dir ./data/field --model precursor
    python scripts/cross_device_eval.py --data-dir ./data/field --model anomaly

For each unique device_id found in the field CSVs:
  1. Treat that device as the holdout set.
  2. Build a feature matrix from all *other* devices' labeled rows.
  3. Run the pre-trained TFLite model on the holdout device rows.
  4. Report per-device accuracy, precision, recall.

Also produces a device similarity matrix (cosine similarity of per-device
feature means) to identify outlier devices whose behaviour diverges from
the rest of the fleet.

If labeled data is insufficient or TFLite is unavailable, prints an
explanatory message and exits cleanly (exit code 0).
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

MIN_LABELED_SAMPLES = 5  # minimum labeled rows required to attempt evaluation

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
                "Neither tflite_runtime nor tensorflow is installed. "
                "Cannot run TFLite cross-device evaluation."
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
# Data helpers
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


def _load_all_csvs(data_dir: str) -> list:
    """Load all CSV files from data_dir; return combined list of row dicts."""
    all_rows = []
    if not os.path.isdir(data_dir):
        return all_rows
    for fname in sorted(os.listdir(data_dir)):
        if not fname.endswith(".csv"):
            continue
        path = os.path.join(data_dir, fname)
        try:
            with open(path, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    all_rows.append(dict(row))
        except Exception as exc:
            print(f"  WARNING: could not read {path}: {exc}", file=sys.stderr)
    return all_rows


# ---------------------------------------------------------------------------
# Label helpers
# ---------------------------------------------------------------------------

def _label_to_binary(label: str) -> int:
    """Return 0 for normal, 1 for any hazard class, -1 for unknown."""
    label = label.strip().lower()
    if not label:
        return -1
    return 0 if label == "normal" else 1


def _label_to_multiclass(label: str, class_names: list) -> int:
    label = label.strip().lower()
    for i, name in enumerate(class_names):
        if name.lower() == label:
            return i
    return -1


# ---------------------------------------------------------------------------
# Per-row inference
# ---------------------------------------------------------------------------

def _infer_precursor(interp, row: dict, feature_names: list,
                     scaler: dict, dtype) -> tuple:
    """Return (pred_class_idx, non_normal_score)."""
    vec = _build_vec(row, feature_names)
    norm_vec = _apply_scaler(vec, scaler)
    arr = np.array([norm_vec], dtype=dtype)
    out = _run_inference(interp, arr)
    probs = out[0].tolist()
    pred_idx = int(np.argmax(probs))
    non_normal = max(probs[1:]) if len(probs) > 1 else 0.0
    return pred_idx, non_normal


def _infer_anomaly(interp, row: dict, feature_names: list,
                   scaler: dict, high_t: float, dtype) -> tuple:
    """Return (pred_class_idx, normalised_error).

    pred_class_idx: 0=normal, 1=elevated, 2=anomaly
    """
    config_path = os.path.join(ASSETS_DIR, "vibration_model_config.json")
    vec = _build_vec(row, feature_names)
    norm_vec = _apply_scaler(vec, scaler)
    arr = np.array([norm_vec], dtype=dtype)
    out = _run_inference(interp, arr)
    err = float(np.mean(np.abs(out[0] - np.array(norm_vec, dtype=dtype))))
    low_t = high_t * 0.67  # approximate low threshold
    if err <= low_t:
        pred = 0
    elif err <= high_t:
        pred = 1
    else:
        pred = 2
    return pred, min(err / max(high_t, 1e-10), 1.0)


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def _compute_metrics(gt_binary: list, pred_binary: list) -> dict:
    """Compute accuracy, precision, recall from binary lists."""
    if not gt_binary:
        return {"accuracy": 0.0, "precision": 0.0, "recall": 0.0, "n": 0}
    n = len(gt_binary)
    tp = sum(1 for g, p in zip(gt_binary, pred_binary) if g == 1 and p == 1)
    fp = sum(1 for g, p in zip(gt_binary, pred_binary) if g == 0 and p == 1)
    fn = sum(1 for g, p in zip(gt_binary, pred_binary) if g == 1 and p == 0)
    correct = sum(1 for g, p in zip(gt_binary, pred_binary) if g == p)
    acc = correct / n
    prec = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    rec = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    return {"accuracy": acc, "precision": prec, "recall": rec, "n": n,
            "tp": tp, "fp": fp, "fn": fn}


# ---------------------------------------------------------------------------
# Device similarity matrix
# ---------------------------------------------------------------------------

def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Cosine similarity between two 1-D vectors."""
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    if denom < 1e-12:
        return 0.0
    return float(np.dot(a, b) / denom)


def _device_similarity_matrix(device_feature_means: dict) -> None:
    """Print a cosine similarity matrix between device feature means."""
    device_ids = sorted(device_feature_means.keys())
    n = len(device_ids)
    if n < 2:
        print("  (Need at least 2 devices for similarity matrix)")
        return

    matrix = np.zeros((n, n))
    for i, di in enumerate(device_ids):
        for j, dj in enumerate(device_ids):
            matrix[i, j] = _cosine_similarity(
                device_feature_means[di], device_feature_means[dj]
            )

    # Print matrix
    id_w = max(len(d) for d in device_ids)
    header = " " * (id_w + 2)
    for did in device_ids:
        header += f"  {did[:8]:>8}"
    print(header)
    print("  " + "-" * (len(header) - 2))
    for i, di in enumerate(device_ids):
        row_str = f"  {di:<{id_w}}"
        for j in range(n):
            row_str += f"  {matrix[i, j]:>8.4f}"
        print(row_str)

    # Flag outliers: devices with mean similarity < 0.8 to all others
    outliers = []
    for i, di in enumerate(device_ids):
        others = [matrix[i, j] for j in range(n) if j != i]
        if others and np.mean(others) < 0.80:
            outliers.append((di, float(np.mean(others))))
    if outliers:
        print()
        print("  Potential outlier devices (mean similarity < 0.80):")
        for did, sim in outliers:
            print(f"    {did}  mean_similarity={sim:.4f}")
    else:
        print()
        print("  No outlier devices detected (all mean similarities >= 0.80).")


# ---------------------------------------------------------------------------
# Main evaluation loop
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Leave-one-device-out cross-device model evaluation."
    )
    parser.add_argument("--data-dir", default="./data/field", metavar="DIR",
                        help="Directory containing field CSV files (default: ./data/field).")
    parser.add_argument("--model", choices=["precursor", "anomaly"], default="precursor",
                        help="Model to evaluate (default: precursor).")
    args = parser.parse_args()

    # Resolve data-dir
    if not os.path.isabs(args.data_dir):
        args.data_dir = os.path.join(os.getcwd(), args.data_dir)

    # Check model
    if args.model == "precursor":
        tflite_path = PRECURSOR_TFLITE
        model_label = "Precursor Classifier"
    else:
        tflite_path = ANOMALY_TFLITE
        model_label = "Anomaly Autoencoder"

    if not os.path.isfile(tflite_path):
        print(f"Model not found at {tflite_path}.")
        print("Train the model first before running cross-device evaluation.")
        sys.exit(0)

    # Load TFLite interpreter and configs
    try:
        interp = _load_interpreter(tflite_path)
    except ImportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(0)

    dtype = interp.get_input_details()[0]["dtype"]

    if args.model == "precursor":
        config = _load_json(PRECURSOR_CONFIG)
        scaler = _load_json(PRECURSOR_SCALER)
        feature_names = config["feature_names"]
        class_names = config.get("class_names", [
            "normal", "soil_creep", "crack_propagation", "imminent_failure"
        ])
        high_t = None
    else:
        scaler = _load_json(ANOMALY_SCALER)
        config = _load_json(ANOMALY_CONFIG)
        feature_names = scaler["feature_names"]
        class_names = ["normal", "elevated", "anomaly"]
        high_t = config.get("thresholds", {}).get("high", 1.788009)

    # Load data
    print(f"Loading CSV files from: {args.data_dir}")
    all_rows = _load_all_csvs(args.data_dir)
    if not all_rows:
        print("No CSV files found in data directory.")
        print(f"Expected path: {args.data_dir}")
        print("Collect field data first with simulate_field_data.py or a real device.")
        sys.exit(0)

    print(f"Loaded {len(all_rows)} total rows from all CSVs.")

    # Group rows by device_id
    devices: dict = {}
    for row in all_rows:
        did = row.get("device_id", "unknown").strip() or "unknown"
        devices.setdefault(did, []).append(row)

    device_ids = sorted(devices.keys())
    print(f"Found {len(device_ids)} unique device(s): {', '.join(device_ids)}")

    # Check overall labeled count
    total_labeled = sum(
        1 for r in all_rows if r.get("label", "").strip()
    )
    if total_labeled < MIN_LABELED_SAMPLES:
        print(f"\nInsufficient labeled data: only {total_labeled} labeled rows found "
              f"(minimum {MIN_LABELED_SAMPLES} required).")
        print("Label rows with the 'label' column (normal/anomaly/soil_creep/etc.) and rerun.")
        sys.exit(0)

    if len(device_ids) < 2:
        print("\nOnly one device found. Cross-device evaluation requires >= 2 devices.")
        print("Collect data from multiple devices first.")
        sys.exit(0)

    # Build per-device feature means for similarity matrix
    device_feature_means: dict = {}
    for did, rows in devices.items():
        vecs = [_build_vec(r, feature_names) for r in rows]
        device_feature_means[did] = np.mean(vecs, axis=0)

    # Leave-one-device-out evaluation
    print()
    print("=" * 70)
    print(f"LEAVE-ONE-DEVICE-OUT CROSS-VALIDATION - {model_label}")
    print("=" * 70)

    col_w = [16, 8, 10, 10, 8, 6, 6, 6]
    header = (
        f"  {'Device':<{col_w[0]}}  {'N_test':>{col_w[1]}}  "
        f"{'Accuracy':>{col_w[2]}}  {'Precision':>{col_w[3]}}  "
        f"{'Recall':>{col_w[4]}}  {'TP':>{col_w[5]}}  {'FP':>{col_w[6]}}  {'FN':>{col_w[7]}}"
    )
    print(header)
    print("  " + "-" * (len(header) - 2))

    all_results = []
    skipped = []

    for holdout_id in device_ids:
        holdout_rows = devices[holdout_id]
        labeled_holdout = [r for r in holdout_rows if r.get("label", "").strip()]

        if len(labeled_holdout) < MIN_LABELED_SAMPLES:
            skipped.append((holdout_id, len(labeled_holdout)))
            print(f"  {holdout_id:<{col_w[0]}}  SKIPPED (only {len(labeled_holdout)} labeled rows)")
            continue

        gt_binary = []
        pred_binary = []

        for row in labeled_holdout:
            gt = _label_to_binary(row.get("label", ""))
            if gt < 0:
                continue  # skip unlabeled

            try:
                if args.model == "precursor":
                    pred_idx, score = _infer_precursor(
                        interp, row, feature_names, scaler, dtype
                    )
                    pred_bin = 0 if pred_idx == 0 else 1
                else:
                    pred_idx, score = _infer_anomaly(
                        interp, row, feature_names, scaler, high_t, dtype
                    )
                    pred_bin = 0 if pred_idx == 0 else 1
            except Exception as exc:
                print(f"    WARNING: inference error for device {holdout_id}: {exc}",
                      file=sys.stderr)
                continue

            gt_binary.append(gt)
            pred_binary.append(pred_bin)

        if not gt_binary:
            skipped.append((holdout_id, 0))
            print(f"  {holdout_id:<{col_w[0]}}  SKIPPED (no usable labeled rows after inference)")
            continue

        m = _compute_metrics(gt_binary, pred_binary)
        all_results.append((holdout_id, m))

        print(
            f"  {holdout_id:<{col_w[0]}}  {m['n']:>{col_w[1]}}  "
            f"{m['accuracy']:>{col_w[2]}.4f}  {m['precision']:>{col_w[3]}.4f}  "
            f"{m['recall']:>{col_w[4]}.4f}  {m['tp']:>{col_w[5]}}  "
            f"{m['fp']:>{col_w[6]}}  {m['fn']:>{col_w[7]}}"
        )

    # Aggregate
    if all_results:
        all_acc = [r["accuracy"] for _, r in all_results]
        all_prec = [r["precision"] for _, r in all_results]
        all_rec = [r["recall"] for _, r in all_results]
        print("  " + "-" * (len(header) - 2))
        total_n = sum(r["n"] for _, r in all_results)
        print(
            f"  {'MEAN':<{col_w[0]}}  {total_n:>{col_w[1]}}  "
            f"{np.mean(all_acc):>{col_w[2]}.4f}  {np.mean(all_prec):>{col_w[3]}.4f}  "
            f"{np.mean(all_rec):>{col_w[4]}.4f}"
        )
        print()

        # Identify worst-performing device
        worst_id, worst_m = min(all_results, key=lambda x: x[1]["accuracy"])
        best_id, best_m = max(all_results, key=lambda x: x[1]["accuracy"])
        print(f"  Best performing device : {best_id}  (accuracy={best_m['accuracy']:.4f})")
        print(f"  Worst performing device: {worst_id}  (accuracy={worst_m['accuracy']:.4f})")
        if worst_m["accuracy"] < 0.7:
            print(f"  WARNING: {worst_id} has low cross-device accuracy - "
                  "may need device-specific calibration or data collection.")
    else:
        print("\n  No devices had sufficient labeled data for evaluation.")

    if skipped:
        print()
        print(f"  Skipped {len(skipped)} device(s) due to insufficient labeled data:")
        for did, n in skipped:
            print(f"    {did} ({n} labeled rows)")

    # Device similarity matrix
    print()
    print("=" * 70)
    print("DEVICE SIMILARITY MATRIX (cosine similarity of feature means)")
    print("=" * 70)
    print()
    _device_similarity_matrix(device_feature_means)
    print()


if __name__ == "__main__":
    main()
