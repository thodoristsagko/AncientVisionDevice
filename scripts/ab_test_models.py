#!/usr/bin/env python3
"""
A/B comparison of two TFLite precursor classifier models.

Usage:
    python scripts/ab_test_models.py --model-a path/to/a.tflite --model-b path/to/b.tflite
    python scripts/ab_test_models.py \\
        --model-a app/assets/ml/precursor_classifier.tflite \\
        --model-b app/assets/ml/precursor_classifier_v2.tflite \\
        --scaler app/assets/ml/precursor_classifier_scaler.json \\
        --n-samples 200
"""

import argparse
import json
import os
import random
import sys
import time
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# TFLite import
# ---------------------------------------------------------------------------

try:
    from tflite_runtime.interpreter import Interpreter as TFLiteInterpreter
    _TFLITE_BACKEND = "tflite_runtime"
except ImportError:
    try:
        import tensorflow as tf
        TFLiteInterpreter = tf.lite.Interpreter
        _TFLITE_BACKEND = "tensorflow"
    except ImportError:
        TFLiteInterpreter = None
        _TFLITE_BACKEND = None

# ---------------------------------------------------------------------------
# Constants — must match generate_precursor_data.py / evaluate_models.py
# ---------------------------------------------------------------------------

LABELS = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]

FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
    "stalta", "arias", "cav",
    "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
    "cusum_max", "autoencoder_score", "temp", "psdSlope",
]

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
# Data generation (replicates simulate_field_data.py logic)
# ---------------------------------------------------------------------------


def _rng(lo: float, hi: float) -> float:
    return lo + random.random() * (hi - lo)


def _normal_features():
    return {
        "rms":      _rng(0.001, 0.05),
        "ppv":      _rng(0.01,  0.3),
        "freq":     _rng(5.0,   50.0),
        "crest":    _rng(2.0,   6.0),
        "centroid": _rng(10.0,  40.0),
        "kurtosis": _rng(-1.0,  3.0),
        "stalta":   _rng(0.5,   2.0),
        "arias":    _rng(0.0,   0.001),
        "cav":      _rng(0.0,   0.01),
    }


def _soil_creep_features(index: int, total: int):
    progress = index / max(total - 1, 1)
    ppv_base = 0.3 + progress * (1.5 - 0.3)
    freq_base = 40.0 - progress * 30.0
    feat = {
        "rms":      _rng(0.01,  0.08),
        "ppv":      max(0.31, ppv_base + _rng(-0.05, 0.05)),
        "freq":     max(5.0, freq_base + _rng(-3.0, 3.0)),
        "crest":    _rng(3.0,   7.0),
        "centroid": _rng(8.0,   25.0),
        "kurtosis": _rng(1.0,   5.0),
        "stalta":   _rng(1.5,   5.0),
        "arias":    _rng(0.0002, 0.005),
        "cav":      _rng(0.002,  0.02),
    }
    return feat


def _crack_propagation_features():
    return {
        "rms":      _rng(0.01,  0.08),
        "ppv":      _rng(0.5,   3.0),
        "freq":     _rng(10.0,  50.0),
        "crest":    _rng(8.0,   18.0),
        "centroid": _rng(15.0,  40.0),
        "kurtosis": _rng(8.0,   14.0),
        "stalta":   _rng(2.0,   8.0),
        "arias":    _rng(0.0005, 0.008),
        "cav":      _rng(0.005,  0.05),
    }


def _imminent_failure_features():
    return {
        "rms":      _rng(0.05,  0.3),
        "ppv":      _rng(2.0,   10.0),
        "freq":     _rng(1.0,   15.0),
        "crest":    _rng(10.0,  25.0),
        "centroid": _rng(3.0,   15.0),
        "kurtosis": _rng(12.0,  30.0),
        "stalta":   _rng(8.0,   20.0),
        "arias":    _rng(0.01,  0.5),
        "cav":      _rng(0.05,  1.0),
    }


def generate_test_set(n_samples: int):
    """
    Generate a balanced test set of (features_dict, label) pairs.
    n_samples is rounded up to the nearest multiple of len(LABELS).
    """
    per_class = max(1, n_samples // len(LABELS))
    samples = []

    for label in LABELS:
        for i in range(per_class):
            if label == "normal":
                feat = _normal_features()
            elif label == "soil_creep":
                feat = _soil_creep_features(i, per_class)
            elif label == "crack_propagation":
                feat = _crack_propagation_features()
            else:
                feat = _imminent_failure_features()
            feat.update(TREND_DEFAULTS)
            samples.append((feat, label))

    random.shuffle(samples)
    return samples


# ---------------------------------------------------------------------------
# Scaler
# ---------------------------------------------------------------------------


def load_scaler(path: str):
    """Load mean/std scaler from JSON.  Returns (mean_arr, std_arr, names)."""
    with open(path) as f:
        data = json.load(f)
    names = data.get("feature_names", FEATURE_NAMES)
    mean = np.array(data.get("mean", data.get("means", [0.0] * len(names))), dtype=np.float32)
    std  = np.array(data.get("std",  data.get("stds",  [1.0] * len(names))), dtype=np.float32)
    std  = np.where(std == 0, 1.0, std)
    return mean, std, names


def build_vector(feat_dict: dict, feature_names: list) -> np.ndarray:
    vec = np.array([float(feat_dict.get(n, 0.0)) for n in feature_names], dtype=np.float32)
    return vec


# ---------------------------------------------------------------------------
# TFLite model wrapper
# ---------------------------------------------------------------------------


class ModelRunner:
    """Wraps a TFLite interpreter for repeated inference."""

    def __init__(self, model_path: str):
        if TFLiteInterpreter is None:
            raise RuntimeError(
                "No TFLite backend available. "
                "Install tflite-runtime or tensorflow."
            )
        self.path = model_path
        self.size_bytes = os.path.getsize(model_path)
        self.interp = TFLiteInterpreter(model_path=model_path)
        self.interp.allocate_tensors()
        self.input_details  = self.interp.get_input_details()
        self.output_details = self.interp.get_output_details()
        self.input_shape    = self.input_details[0]["shape"]   # e.g. [1, 17]
        self.n_features     = int(self.input_shape[-1])

    def predict(self, vec: np.ndarray) -> np.ndarray:
        """Run inference on a 1-D feature vector.  Returns output array."""
        inp = vec.reshape(self.input_shape).astype(np.float32)
        self.interp.set_tensor(self.input_details[0]["index"], inp)
        self.interp.invoke()
        out = self.interp.get_tensor(self.output_details[0]["index"])
        return out.flatten()


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------


def evaluate_model(
    runner: ModelRunner,
    test_samples: list,
    scaler_mean: np.ndarray,
    scaler_std: np.ndarray,
    feature_names: list,
) -> dict:
    """
    Run inference on all test_samples.

    Returns dict with keys:
        per_class_correct, per_class_total, latencies_ms, predictions
    """
    per_class_correct = {lbl: 0 for lbl in LABELS}
    per_class_total   = {lbl: 0 for lbl in LABELS}
    latencies_ms = []
    predictions = []

    for feat_dict, true_label in test_samples:
        vec = build_vector(feat_dict, feature_names)
        # Apply scaler if dimensions match
        if len(scaler_mean) == len(vec):
            vec = (vec - scaler_mean) / scaler_std

        # Pad or truncate to match model input size
        n = runner.n_features
        if len(vec) < n:
            vec = np.concatenate([vec, np.zeros(n - len(vec), dtype=np.float32)])
        elif len(vec) > n:
            vec = vec[:n]

        t0 = time.perf_counter()
        out = runner.predict(vec)
        t1 = time.perf_counter()
        latencies_ms.append((t1 - t0) * 1000.0)

        pred_idx = int(np.argmax(out))
        # Map index → label (assume output order matches LABELS)
        pred_label = LABELS[pred_idx] if pred_idx < len(LABELS) else "unknown"
        predictions.append(pred_label)

        per_class_total[true_label] += 1
        if pred_label == true_label:
            per_class_correct[true_label] += 1

    return {
        "per_class_correct": per_class_correct,
        "per_class_total":   per_class_total,
        "latencies_ms":      latencies_ms,
        "predictions":       predictions,
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

COL_W = 14  # column width for table cells


def _pct(correct: int, total: int) -> float:
    return 100.0 * correct / total if total > 0 else 0.0


def _delta_str(a: float, b: float) -> str:
    d = b - a
    sign = "+" if d >= 0 else ""
    return f"{sign}{d:.1f}%"


def print_table(res_a: dict, res_b: dict, name_a: str, name_b: str):
    """Print a Unicode box-drawing comparison table."""
    header_a = name_a[:COL_W]
    header_b = name_b[:COL_W]

    top    = f"\u250c{'─'*22}\u252c{'─'*COL_W}\u252c{'─'*COL_W}\u252c{'─'*10}\u2510"
    mid    = f"\u251c{'─'*22}\u253c{'─'*COL_W}\u253c{'─'*COL_W}\u253c{'─'*10}\u2524"
    bot    = f"\u2514{'─'*22}\u2534{'─'*COL_W}\u2534{'─'*COL_W}\u2534{'─'*10}\u2518"

    def row(c1, c2, c3, c4):
        return f"\u2502{c1:<22}\u2502{c2:<{COL_W}}\u2502{c3:<{COL_W}}\u2502{c4:<10}\u2502"

    print()
    print(top)
    print(row("  Class", f"  {header_a}", f"  {header_b}", "  Delta"))
    print(mid)

    for lbl in LABELS:
        pct_a = _pct(res_a["per_class_correct"][lbl], res_a["per_class_total"][lbl])
        pct_b = _pct(res_b["per_class_correct"][lbl], res_b["per_class_total"][lbl])
        delta = _delta_str(pct_a, pct_b)
        print(row(f"  {lbl}", f"  {pct_a:.1f}%", f"  {pct_b:.1f}%", f"  {delta}"))

    print(mid)

    # Overall accuracy
    tot_correct_a = sum(res_a["per_class_correct"].values())
    tot_correct_b = sum(res_b["per_class_correct"].values())
    tot = sum(res_a["per_class_total"].values())
    overall_a = _pct(tot_correct_a, tot)
    overall_b = _pct(tot_correct_b, tot)
    delta_overall = _delta_str(overall_a, overall_b)
    print(row("  OVERALL", f"  {overall_a:.1f}%", f"  {overall_b:.1f}%", f"  {delta_overall}"))
    print(bot)

    # Inference timing
    avg_a = float(np.mean(res_a["latencies_ms"])) if res_a["latencies_ms"] else 0.0
    avg_b = float(np.mean(res_b["latencies_ms"])) if res_b["latencies_ms"] else 0.0
    print()
    print(f"  Inference time  Model A: {avg_a:.2f} ms avg    Model B: {avg_b:.2f} ms avg")

    return overall_a, overall_b, avg_a, avg_b


def print_model_info(runner_a: ModelRunner, runner_b: ModelRunner):
    def fmt(path, size_bytes):
        kb = size_bytes / 1024.0
        return f"  {path}  ({kb:.1f} KB)"

    print()
    print("Model files:")
    print(f"  A: {fmt(runner_a.path, runner_a.size_bytes)}")
    print(f"  B: {fmt(runner_b.path, runner_b.size_bytes)}")


def print_recommendation(overall_a: float, overall_b: float, avg_a: float, avg_b: float):
    print()
    print("Recommendation:")
    if overall_a == overall_b:
        # Tie on accuracy — prefer faster
        if avg_a <= avg_b:
            print(f"  Accuracy is equal ({overall_a:.1f}%). Model A is faster ({avg_a:.2f} ms vs {avg_b:.2f} ms). Use Model A.")
        else:
            print(f"  Accuracy is equal ({overall_b:.1f}%). Model B is faster ({avg_b:.2f} ms vs {avg_a:.2f} ms). Use Model B.")
    elif overall_b > overall_a:
        gain = overall_b - overall_a
        speed_note = ""
        if avg_b > avg_a * 1.5:
            speed_note = f" (note: Model B is {avg_b/avg_a:.1f}x slower)"
        print(f"  Model B has higher accuracy (+{gain:.1f}% overall). Recommend Model B.{speed_note}")
    else:
        gain = overall_a - overall_b
        speed_note = ""
        if avg_a > avg_b * 1.5:
            speed_note = f" (note: Model A is {avg_a/avg_b:.1f}x slower)"
        print(f"  Model A has higher accuracy (+{gain:.1f}% overall). Recommend Model A.{speed_note}")
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser():
    p = argparse.ArgumentParser(
        description="A/B comparison of two TFLite precursor classifier models."
    )
    p.add_argument("--model-a", required=True, help="Path to Model A .tflite file")
    p.add_argument("--model-b", required=True, help="Path to Model B .tflite file")
    p.add_argument(
        "--scaler",
        default=None,
        help="Path to scaler JSON (default: app/assets/ml/precursor_classifier_scaler.json)",
    )
    p.add_argument(
        "--data-dir",
        default="./data/field",
        help="Field data directory (currently unused but reserved for CSV-based test sets)",
    )
    p.add_argument(
        "--n-samples",
        type=int,
        default=200,
        help="Number of synthetic test samples to generate (default: 200)",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducibility (default: 42)",
    )
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    random.seed(args.seed)
    np.random.seed(args.seed)

    # Verify model files exist
    for label, path in (("A", args.model_a), ("B", args.model_b)):
        if not os.path.isfile(path):
            print(f"Error: Model {label} not found: {path}", file=sys.stderr)
            return 1

    # Load TFLite models
    if TFLiteInterpreter is None:
        print(
            "Error: No TFLite backend found.\n"
            "  Install tflite-runtime:   pip install tflite-runtime\n"
            "  or tensorflow:            pip install tensorflow",
            file=sys.stderr,
        )
        return 1

    print("Loading models...")
    try:
        runner_a = ModelRunner(args.model_a)
        runner_b = ModelRunner(args.model_b)
    except Exception as exc:
        print(f"Error loading model: {exc}", file=sys.stderr)
        return 1

    print_model_info(runner_a, runner_b)

    # Scaler
    scaler_path = args.scaler
    if scaler_path is None:
        default_scaler = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "app", "assets", "ml", "precursor_classifier_scaler.json",
        )
        if os.path.isfile(default_scaler):
            scaler_path = default_scaler

    if scaler_path and os.path.isfile(scaler_path):
        print(f"Using scaler: {scaler_path}")
        scaler_mean, scaler_std, feature_names = load_scaler(scaler_path)
    else:
        print("No scaler found — features will NOT be normalised.")
        feature_names = FEATURE_NAMES
        scaler_mean = np.zeros(len(feature_names), dtype=np.float32)
        scaler_std  = np.ones(len(feature_names),  dtype=np.float32)

    # Generate test set
    n = args.n_samples
    print(f"\nGenerating {n} synthetic test samples (balanced across {len(LABELS)} classes)...")
    test_samples = generate_test_set(n)
    print(f"Generated {len(test_samples)} samples.")

    # Run evaluation
    print(f"\nEvaluating Model A ({_TFLITE_BACKEND})...")
    res_a = evaluate_model(runner_a, test_samples, scaler_mean, scaler_std, feature_names)

    print(f"Evaluating Model B ({_TFLITE_BACKEND})...")
    res_b = evaluate_model(runner_b, test_samples, scaler_mean, scaler_std, feature_names)

    # Print comparison
    name_a = Path(args.model_a).name
    name_b = Path(args.model_b).name
    print("\nA/B Model Comparison")
    overall_a, overall_b, avg_a, avg_b = print_table(res_a, res_b, name_a, name_b)
    print_recommendation(overall_a, overall_b, avg_a, avg_b)

    return 0


if __name__ == "__main__":
    sys.exit(main())
