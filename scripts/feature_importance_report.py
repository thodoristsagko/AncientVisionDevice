#!/usr/bin/env python3
"""
feature_importance_report.py — Analyze feature importance for the precursor classifier.

Usage:
    python scripts/feature_importance_report.py [--model-dir DIR] [--n-samples N]

Uses permutation importance: shuffle each feature, measure accuracy drop.
Higher drop = more important feature.
Requires: precursor_classifier.tflite + precursor_classifier_config.json
Uses synthetic test data (no field data required).
"""
import argparse
import json
import os
import sys
import numpy as np

# Force UTF-8 output on Windows so block characters in bar charts render correctly.
if sys.platform == "win32":
    try:
        import io as _io
        sys.stdout = _io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    except Exception:
        pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_MODEL_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

# Feature order used when generating synthetic data (matches config order)
FEATURE_NAMES_DEFAULT = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis", "stalta",
    "arias", "cav", "temp", "psdSlope", "ppv_trend", "freq_trend",
    "kurtosis_trend", "stalta_trend", "cusum_max", "autoencoder_score",
]

N_CLASSES = 4


def load_model_files(model_dir: str):
    """Load tflite interpreter and config. Returns (interpreter, config) or (None, None)."""
    tflite_path = os.path.join(model_dir, "precursor_classifier.tflite")
    config_path = os.path.join(model_dir, "precursor_classifier_config.json")

    if not os.path.isfile(tflite_path) or not os.path.isfile(config_path):
        return None, None

    try:
        import tensorflow as tf
        interpreter = tf.lite.Interpreter(model_path=tflite_path)
        interpreter.allocate_tensors()
    except Exception:
        try:
            import tflite_runtime.interpreter as tflite
            interpreter = tflite.Interpreter(model_path=tflite_path)
            interpreter.allocate_tensors()
        except Exception:
            return None, None

    try:
        with open(config_path) as f:
            config = json.load(f)
    except Exception:
        return None, None

    return interpreter, config


def generate_synthetic_data(n_samples: int, n_features: int, rng: np.random.Generator):
    """
    Generate synthetic test samples with class-separated distributions.
    Returns (X, y) where y ∈ {0,1,2,3}.
    """
    per_class = n_samples // N_CLASSES
    remainder = n_samples - per_class * N_CLASSES

    chunks_X = []
    chunks_y = []

    # Class 0: normal — low PPV (index 1), low kurtosis (index 5)
    n0 = per_class + remainder
    X0 = rng.standard_normal((n0, n_features)) * 0.3
    X0[:, 1] = np.abs(X0[:, 1]) * 0.05   # ppv very low
    X0[:, 5] = np.abs(X0[:, 5]) * 0.5 + 1.5  # kurtosis near normal
    chunks_X.append(X0)
    chunks_y.extend([0] * n0)

    # Class 1: soil_creep — gradually elevated ppv_trend (index 11)
    X1 = rng.standard_normal((per_class, n_features)) * 0.4
    X1[:, 1] = np.abs(X1[:, 1]) * 0.2 + 0.3   # ppv moderate
    X1[:, 11] = np.abs(X1[:, 11]) * 0.3 + 0.5  # ppv_trend elevated
    chunks_X.append(X1)
    chunks_y.extend([1] * per_class)

    # Class 2: crack_propagation — elevated kurtosis and crest (indices 5, 3)
    X2 = rng.standard_normal((per_class, n_features)) * 0.5
    X2[:, 5] = np.abs(X2[:, 5]) * 1.0 + 4.0   # kurtosis high
    X2[:, 3] = np.abs(X2[:, 3]) * 0.8 + 3.5   # crest high
    X2[:, 1] = np.abs(X2[:, 1]) * 0.3 + 0.5   # ppv moderate-high
    chunks_X.append(X2)
    chunks_y.extend([2] * per_class)

    # Class 3: imminent_failure — very high ppv, high stalta (indices 1, 6)
    X3 = rng.standard_normal((per_class, n_features)) * 0.6
    X3[:, 1] = np.abs(X3[:, 1]) * 0.5 + 2.0   # ppv very high
    X3[:, 6] = np.abs(X3[:, 6]) * 1.0 + 5.0   # stalta very high
    chunks_X.append(X3)
    chunks_y.extend([3] * per_class)

    X = np.vstack(chunks_X)
    y = np.array(chunks_y, dtype=np.int32)
    return X, y


def predict_batch(interpreter, X: np.ndarray) -> np.ndarray:
    """Run TFLite inference on all rows; return predicted class indices."""
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()
    dtype = input_details[0]["dtype"]

    preds = []
    for row in X:
        interpreter.set_tensor(
            input_details[0]["index"],
            row.astype(dtype).reshape(1, -1),
        )
        interpreter.invoke()
        out = interpreter.get_tensor(output_details[0]["index"])[0]
        preds.append(int(np.argmax(out)))
    return np.array(preds, dtype=np.int32)


def permutation_importance(interpreter, X: np.ndarray, y: np.ndarray, rng) -> tuple:
    """
    Compute permutation importance for each feature.
    Returns (baseline_accuracy, list_of_importance_values).
    """
    baseline_preds = predict_batch(interpreter, X)
    baseline_acc = float(np.mean(baseline_preds == y))

    importances = []
    for col in range(X.shape[1]):
        X_perm = X.copy()
        rng.shuffle(X_perm[:, col])
        perm_preds = predict_batch(interpreter, X_perm)
        perm_acc = float(np.mean(perm_preds == y))
        importances.append(baseline_acc - perm_acc)

    return baseline_acc, importances


def print_bar_chart(feature_names: list, importances: list, max_bar: int = 20) -> None:
    """Print ASCII bar chart of feature importances."""
    max_imp = max(importances) if importances else 1.0
    if max_imp <= 0:
        max_imp = 1.0

    name_width = max(len(n) for n in feature_names) if feature_names else 10

    for name, imp in zip(feature_names, importances):
        bar_len = int((max(imp, 0) / max_imp) * max_bar)
        bar = "\u2588" * bar_len
        print(f"  {name:<{name_width}}  {bar:<{max_bar}}  {imp:.3f}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze feature importance via permutation for precursor classifier."
    )
    parser.add_argument(
        "--model-dir",
        default=DEFAULT_MODEL_DIR,
        help="Directory containing precursor_classifier.tflite and config",
    )
    parser.add_argument(
        "--n-samples",
        type=int,
        default=200,
        metavar="N",
        help="Number of synthetic test samples to use (default: 200)",
    )
    args = parser.parse_args(argv)

    interpreter, config = load_model_files(args.model_dir)
    if interpreter is None:
        print("Model files not found")
        return 0

    feature_names = config.get("feature_names", FEATURE_NAMES_DEFAULT)
    n_features = len(feature_names)

    rng = np.random.default_rng(42)
    X, y = generate_synthetic_data(args.n_samples, n_features, rng)

    print(f"Running permutation importance on {args.n_samples} synthetic samples "
          f"({n_features} features)...")

    baseline_acc, importances = permutation_importance(interpreter, X, y, rng)
    print(f"Baseline accuracy: {baseline_acc:.4f}\n")

    # Sort features by importance (highest first)
    ranked = sorted(
        zip(feature_names, importances),
        key=lambda x: x[1],
        reverse=True,
    )
    ranked_names = [r[0] for r in ranked]
    ranked_imps = [r[1] for r in ranked]

    # Add "(most important)" marker to the top entry
    print("Feature Importance (permutation method):")
    print("-" * 55)

    name_width = max(len(n) for n in ranked_names) if ranked_names else 10
    max_imp = max(ranked_imps) if ranked_imps else 1.0
    if max_imp <= 0:
        max_imp = 1.0
    max_bar = 20

    for i, (name, imp) in enumerate(ranked):
        bar_len = int((max(imp, 0) / max_imp) * max_bar)
        bar = "\u2588" * bar_len
        suffix = " (most important)" if i == 0 else ""
        print(f"  {name:<{name_width}}  {bar:<{max_bar}}  {imp:.3f}{suffix}")

    print()
    print("Top 5 most important features:")
    for i, (name, imp) in enumerate(ranked[:5], start=1):
        print(f"  {i}. {name} ({imp:.3f})")

    print("\nBottom 3 least important features:")
    for i, (name, imp) in enumerate(ranked[-3:], start=1):
        print(f"  {i}. {name} ({imp:.3f})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
