#!/usr/bin/env python3
"""Compute feature importance for the precursor classifier via permutation.

Usage:
    python scripts/feature_importance.py --test-csv data/field/test.csv
    python scripts/feature_importance.py  # uses synthetic test data if no CSV
"""
import argparse, json, os, random, sys
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

def load_config_and_scaler():
    config_path = os.path.join(ASSETS_DIR, "precursor_classifier_config.json")
    scaler_path = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
    if not os.path.isfile(config_path) or not os.path.isfile(scaler_path):
        return None, None
    with open(config_path) as f: config = json.load(f)
    with open(scaler_path) as f: scaler = json.load(f)
    return config, scaler

def make_synthetic_data(n=200):
    """Create simple synthetic test data with 17 features."""
    np.random.seed(42)
    feature_names = [
        "ppv", "rms", "freq", "crest", "kurtosis", "stalta",
        "arias", "cav", "centroid", "psdSlope", "temp",
        "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
        "cusum_max", "autoencoder_score"
    ]
    # normal class: low ppv, low kurtosis
    X_normal = np.random.randn(n//2, 17) * 0.3
    X_normal[:, 0] = np.abs(X_normal[:, 0]) * 0.1  # ppv low
    # anomaly class: high ppv, high kurtosis
    X_anom = np.random.randn(n//2, 17) * 0.5 + 1.0
    X_anom[:, 0] = np.abs(X_anom[:, 0]) + 1.5  # ppv high
    X = np.vstack([X_normal, X_anom])
    y = np.array([0]*(n//2) + [2]*(n//2))
    return X, y, feature_names

def run_permutation_importance(X, y, interpreter, n_repeats=5):
    """Compute permutation importance for each feature."""
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()
    dtype = input_details[0]["dtype"]

    def predict(X_arr):
        preds = []
        for row in X_arr:
            interpreter.set_tensor(input_details[0]["index"], row.astype(dtype).reshape(1, -1))
            interpreter.invoke()
            out = interpreter.get_tensor(output_details[0]["index"])[0]
            preds.append(int(np.argmax(out)))
        return np.array(preds)

    baseline_preds = predict(X)
    baseline_acc = np.mean(baseline_preds == y)

    importances = []
    for col in range(X.shape[1]):
        drops = []
        for _ in range(n_repeats):
            X_perm = X.copy()
            np.random.shuffle(X_perm[:, col])
            perm_preds = predict(X_perm)
            perm_acc = np.mean(perm_preds == y)
            drops.append(baseline_acc - perm_acc)
        importances.append(np.mean(drops))

    return baseline_acc, importances

def main():
    parser = argparse.ArgumentParser(description="Feature importance via permutation")
    parser.add_argument("--test-csv", default=None)
    args = parser.parse_args()

    config, scaler = load_config_and_scaler()
    tflite_path = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")

    if not os.path.isfile(tflite_path):
        print("No TFLite model found — using synthetic data only for feature ranking")
        _, _, feature_names = make_synthetic_data()
        print("\nFeature names (model not available for ranking):")
        for i, name in enumerate(feature_names):
            print(f"  {i+1:2d}. {name}")
        return

    try:
        import tensorflow as tf
        interpreter = tf.lite.Interpreter(model_path=tflite_path)
        interpreter.allocate_tensors()
    except ImportError:
        print("tensorflow not installed — skipping TFLite evaluation")
        return

    if args.test_csv and os.path.isfile(args.test_csv):
        import csv
        rows = []
        with open(args.test_csv) as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(row)
        feature_names = config.get("feature_names", []) if config else []
        mean = scaler["mean"] if scaler else [0]*17
        scale = scaler["scale"] if scaler else [1]*17
        X_list, y_list = [], []
        for row in rows:
            vec = [float(row.get(f, 0) or 0) for f in feature_names]
            norm = [(v-m)/max(s,1e-10) for v,m,s in zip(vec, mean, scale)]
            X_list.append(norm)
            label_map = {"normal":0,"soil_creep":1,"crack_propagation":2,"imminent_failure":3}
            y_list.append(label_map.get(row.get("label",""),0))
        X = np.array(X_list, dtype=np.float32)
        y = np.array(y_list)
    else:
        print("Using synthetic test data...")
        X_raw, y, feature_names = make_synthetic_data()
        mean = X_raw.mean(axis=0).tolist()
        scale = X_raw.std(axis=0).tolist()
        X = ((X_raw - X_raw.mean(axis=0)) / (X_raw.std(axis=0) + 1e-10)).astype(np.float32)

    print(f"\nRunning permutation importance on {len(X)} samples...")
    baseline_acc, importances = run_permutation_importance(X, y, interpreter)
    print(f"Baseline accuracy: {baseline_acc:.4f}")

    ranked = sorted(zip(feature_names, importances), key=lambda x: x[1], reverse=True)
    print("\nFeature Importance (accuracy drop when shuffled):")
    print(f"  {'Feature':<26} {'Importance':>12}  {'Bar'}")
    print("  " + "-"*60)
    max_imp = max(abs(i) for i in importances) or 1.0
    for name, imp in ranked:
        bar_w = int(abs(imp) / max_imp * 30)
        bar = "█" * bar_w
        sign = "+" if imp >= 0 else "-"
        print(f"  {name:<26} {sign}{abs(imp):>10.4f}  {bar}")
    print()

if __name__ == "__main__":
    main()
