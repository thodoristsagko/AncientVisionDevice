#!/usr/bin/env python3
"""Find the minimal effective feature subset for the precursor classifier.

Usage:
    python scripts/feature_selection.py
    python scripts/feature_selection.py --n-features 10
    python scripts/feature_selection.py --n-features 10 --model precursor
    python scripts/feature_selection.py --test-csv data/field/test.csv

Algorithm (when TFLite is available):
1. Compute permutation importance on all 17 features (5-repeat, same as feature_importance.py).
2. Sort features from least important to most important.
3. Greedy backward elimination: iteratively remove the least important feature
   while leave-one-out accuracy stays within 1% of the all-features baseline.
4. Report the minimal effective subset.
5. If --n-features is given, also report the top-N feature subset.

Falls back to printing a ranked feature list when TFLite is unavailable.

Note: "CV accuracy" here is a proxy computed by permutation importance on a
held-out test set (no cross-fold split is possible without retraining the frozen
TFLite model). The criterion is: "does removing this feature cost more than 1%
of accuracy on the test set?".
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

# Tolerance: removing a feature is accepted if accuracy drop <= this value
ACCURACY_TOLERANCE = 0.01

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
# Synthetic data
# ---------------------------------------------------------------------------

def _make_synthetic(n: int = 300, feature_names: list = None) -> tuple:
    """Generate n synthetic rows with labels for accuracy estimation."""
    rng = np.random.default_rng(42)
    if feature_names is None:
        feature_names = [
            "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
            "stalta", "arias", "cav", "temp", "psdSlope",
            "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
            "cusum_max", "autoencoder_score",
        ]

    X_list, y_list = [], []
    class_names = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]
    for i in range(n):
        cls = i % 4
        base = rng.randn(len(feature_names)) * 0.3
        if cls == 0:
            base[0] = abs(base[0]) * 0.5  # low rms
            base[1] = abs(base[1]) * 0.1  # low ppv
        elif cls == 1:
            base[0] = abs(base[0]) + 0.5
            base[1] = abs(base[1]) + 0.4
        elif cls == 2:
            base[0] = abs(base[0]) + 1.0
            base[1] = abs(base[1]) + 0.9
            base[5] = abs(base[5]) + 2.0  # high kurtosis
        else:  # imminent_failure
            base[0] = abs(base[0]) + 2.0
            base[1] = abs(base[1]) + 2.0
            base[5] = abs(base[5]) + 4.0
            base[6] = abs(base[6]) + 3.0  # high stalta
        X_list.append(base.tolist())
        y_list.append(cls)

    X = np.array(X_list, dtype=np.float32)
    y = np.array(y_list)
    return X, y, feature_names


# ---------------------------------------------------------------------------
# Accuracy helper — evaluate using only a subset of features (zeroed others)
# ---------------------------------------------------------------------------

def _accuracy_with_subset(interp, X_norm: np.ndarray, y: np.ndarray,
                           active_indices: list, dtype) -> float:
    """Compute accuracy using only the features in active_indices.

    Features NOT in active_indices are replaced with their mean (0.0 in
    normalised space), simulating their absence.
    """
    preds = []
    for row in X_norm:
        masked = row.copy()
        for j in range(len(row)):
            if j not in active_indices:
                masked[j] = 0.0  # mean in normalised space
        arr = masked.astype(dtype).reshape(1, -1)
        out = _run_inference(interp, arr)
        preds.append(int(np.argmax(out[0])))
    preds = np.array(preds)
    return float(np.mean(preds == y))


# ---------------------------------------------------------------------------
# Permutation importance
# ---------------------------------------------------------------------------

def _permutation_importance(interp, X_norm: np.ndarray, y: np.ndarray,
                             n_repeats: int = 5, dtype=np.float32) -> tuple:
    """Return (baseline_acc, list_of_importance_per_feature)."""
    preds_base = []
    for row in X_norm:
        arr = row.astype(dtype).reshape(1, -1)
        out = _run_inference(interp, arr)
        preds_base.append(int(np.argmax(out[0])))
    baseline_acc = float(np.mean(np.array(preds_base) == y))

    rng = np.random.default_rng(0)
    importances = []
    for col in range(X_norm.shape[1]):
        drops = []
        for _ in range(n_repeats):
            X_perm = X_norm.copy()
            perm_idx = rng.permutation(len(X_perm))
            X_perm[:, col] = X_perm[perm_idx, col]
            perm_preds = []
            for row in X_perm:
                arr = row.astype(dtype).reshape(1, -1)
                out = _run_inference(interp, arr)
                perm_preds.append(int(np.argmax(out[0])))
            perm_acc = float(np.mean(np.array(perm_preds) == y))
            drops.append(baseline_acc - perm_acc)
        importances.append(float(np.mean(drops)))

    return baseline_acc, importances


# ---------------------------------------------------------------------------
# Greedy backward elimination
# ---------------------------------------------------------------------------

def _greedy_backward_elimination(interp, X_norm: np.ndarray, y: np.ndarray,
                                  feature_names: list, importances: list,
                                  baseline_acc: float, dtype) -> list:
    """Remove least important features one-by-one while accuracy stays within tolerance.

    Returns the minimal effective feature index list (indices into feature_names).
    """
    active = list(range(len(feature_names)))
    # Sort by ascending importance (least important first)
    sorted_by_importance = sorted(range(len(feature_names)),
                                  key=lambda i: importances[i])

    for col_idx in sorted_by_importance:
        if col_idx not in active:
            continue
        candidate_active = [i for i in active if i != col_idx]
        if not candidate_active:
            break  # never remove the last feature

        acc = _accuracy_with_subset(interp, X_norm, y, candidate_active, dtype)
        drop = baseline_acc - acc
        if drop <= ACCURACY_TOLERANCE:
            # Safe to remove
            active = candidate_active
        # else: keep the feature

    return active


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Find minimal effective feature subset via permutation importance + greedy elimination."
    )
    parser.add_argument("--n-features", type=int, default=None,
                        help="Also report the top-N feature subset (optional).")
    parser.add_argument("--model", choices=["precursor", "anomaly"], default="precursor",
                        help="Model to analyse (default: precursor).")
    parser.add_argument("--test-csv", default=None, metavar="PATH",
                        help="Optional path to labeled CSV for accuracy estimation.")
    args = parser.parse_args()

    if args.model == "precursor":
        tflite_path = PRECURSOR_TFLITE
        model_label = "Precursor Classifier"
        scaler_path = PRECURSOR_SCALER
        config_path = PRECURSOR_CONFIG
    else:
        tflite_path = ANOMALY_TFLITE
        model_label = "Anomaly Autoencoder"
        scaler_path = ANOMALY_SCALER
        config_path = ANOMALY_CONFIG

    # Load config / scaler for feature names
    if os.path.isfile(config_path):
        config = _load_json(config_path)
        if args.model == "precursor":
            feature_names = config.get("feature_names", [])
            class_names = config.get("class_names", [
                "normal", "soil_creep", "crack_propagation", "imminent_failure"
            ])
        else:
            feature_names = []  # will come from scaler
            class_names = ["normal", "elevated", "anomaly"]
    else:
        feature_names = []
        class_names = []

    if os.path.isfile(scaler_path):
        scaler = _load_json(scaler_path)
        if args.model == "anomaly" or not feature_names:
            feature_names = scaler.get("feature_names", feature_names)
    else:
        scaler = None

    if not feature_names:
        # Fallback default
        feature_names = [
            "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
            "stalta", "arias", "cav", "temp", "psdSlope",
            "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
            "cusum_max", "autoencoder_score",
        ]

    # Check TFLite availability
    if not os.path.isfile(tflite_path):
        print(f"TFLite model not found at {tflite_path}.")
        print("Falling back to displaying feature list (no importance ranking without model).")
        print()
        print(f"Features for {model_label} ({len(feature_names)} total):")
        for i, name in enumerate(feature_names):
            print(f"  {i+1:2d}. {name}")
        if args.n_features:
            n = min(args.n_features, len(feature_names))
            print()
            print(f"Top {n} features (by position, model unavailable for ranking):")
            print(f"  {', '.join(feature_names[:n])}")
        sys.exit(0)

    try:
        interp = _load_interpreter(tflite_path)
    except ImportError as exc:
        print(f"TFLite runtime unavailable: {exc}")
        print("Ranked feature list (no importance score without runtime):")
        for i, name in enumerate(feature_names):
            print(f"  {i+1:2d}. {name}")
        sys.exit(0)

    dtype = interp.get_input_details()[0]["dtype"]

    # Load or generate data
    if args.test_csv and os.path.isfile(args.test_csv):
        rows = _load_csv(args.test_csv)
        print(f"Using {len(rows)} rows from {args.test_csv}")
        X_raw_list, y_list = [], []
        label_map = {"normal": 0, "soil_creep": 1,
                     "crack_propagation": 2, "imminent_failure": 3,
                     "elevated": 1, "anomaly": 2}
        for row in rows:
            vec = _build_vec(row, feature_names)
            X_raw_list.append(vec)
            label = row.get("label", "").strip().lower()
            y_list.append(label_map.get(label, 0))
        X_raw = np.array(X_raw_list, dtype=np.float32)
        y = np.array(y_list)
        if scaler:
            mean = np.array(scaler["mean"], dtype=np.float32)
            scale = np.array(scaler["scale"], dtype=np.float32)
            X_norm = (X_raw - mean) / np.maximum(scale, 1e-10)
        else:
            X_norm = (X_raw - X_raw.mean(0)) / (X_raw.std(0) + 1e-10)
        X_norm = X_norm.astype(np.float32)
    else:
        if args.test_csv:
            print(f"CSV not found: {args.test_csv} - using synthetic data.")
        else:
            print("No test CSV provided - using synthetic data.")
        X_raw, y, feature_names_syn = _make_synthetic(300, feature_names)
        # Use provided feature_names list but synthetic X
        X_norm = (X_raw - X_raw.mean(0)) / (X_raw.std(0) + 1e-10)
        X_norm = X_norm.astype(np.float32)

    print(f"Running permutation importance on {len(X_norm)} samples, "
          f"{len(feature_names)} features...")

    baseline_acc, importances = _permutation_importance(
        interp, X_norm, y, n_repeats=5, dtype=dtype
    )
    print(f"Baseline accuracy (all features): {baseline_acc:.4f}")
    print()

    # Rank features
    ranked = sorted(zip(feature_names, importances, range(len(feature_names))),
                    key=lambda x: x[1], reverse=True)

    # Print ranked list
    print("=" * 65)
    print(f"PERMUTATION IMPORTANCE - {model_label}")
    print("=" * 65)
    max_imp = max(abs(imp) for _, imp, _ in ranked) or 1.0
    print(f"  {'Rank':<5}  {'Feature':<26}  {'Importance':>11}  Bar")
    print("  " + "-" * 60)
    for rank, (name, imp, _) in enumerate(ranked, 1):
        bar_w = int(abs(imp) / max_imp * 30)
        bar = "#" * bar_w if imp > 0 else ("-" * bar_w)
        sign = "+" if imp >= 0 else "-"
        print(f"  {rank:<5}  {name:<26}  {sign}{abs(imp):>10.4f}  {bar}")

    # Greedy backward elimination
    print()
    print("=" * 65)
    print("GREEDY BACKWARD ELIMINATION")
    print(f"  (removing features while accuracy drop <= {ACCURACY_TOLERANCE*100:.0f}%)")
    print("=" * 65)
    minimal_indices = _greedy_backward_elimination(
        interp, X_norm, y, feature_names, importances, baseline_acc, dtype
    )
    minimal_names = [feature_names[i] for i in minimal_indices]
    minimal_acc = _accuracy_with_subset(interp, X_norm, y, minimal_indices, dtype)

    print()
    print(f"  Full feature set ({len(feature_names)}):   accuracy = {baseline_acc:.4f}")
    print(f"  Minimal subset   ({len(minimal_names)}):   accuracy = {minimal_acc:.4f}  "
          f"(drop = {baseline_acc - minimal_acc:.4f})")
    print()
    print(f"Minimal effective features ({len(minimal_names)}): "
          f"{', '.join(minimal_names)}")

    # Optional top-N subset
    if args.n_features is not None:
        n = min(args.n_features, len(feature_names))
        top_n_names = [name for name, _, _ in ranked[:n]]
        top_n_indices = [idx for _, _, idx in ranked[:n]]
        top_n_acc = _accuracy_with_subset(interp, X_norm, y, top_n_indices, dtype)
        print()
        print(f"Top-{n} feature subset: accuracy = {top_n_acc:.4f}")
        print(f"  {', '.join(top_n_names)}")

    print()


if __name__ == "__main__":
    main()
