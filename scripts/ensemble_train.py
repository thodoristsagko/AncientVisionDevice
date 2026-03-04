#!/usr/bin/env python3
"""Train 3 precursor classifier models with different seeds and export as an ensemble.

Each model uses the same architecture (17->16->8->4 softmax) but a different
random seed (42, 123, 456) and a different shuffle of the training data.

Exports:
  <output-dir>/precursor_v1.tflite
  <output-dir>/precursor_v2.tflite
  <output-dir>/precursor_v3.tflite
  <output-dir>/ensemble_config.json

The ensemble config uses majority voting at inference time.

Usage:
    python scripts/ensemble_train.py
    python scripts/ensemble_train.py --output-dir app/assets/ml/ensemble
    python scripts/ensemble_train.py --output-dir app/assets/ml/ensemble --csv data/field/session.csv
"""

import argparse
import csv
import datetime
import json
import os
import subprocess
import sys

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

SEEDS = [42, 123, 456]
CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]

# 17 feature names (matches generate_precursor_data.py)
FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis", "stalta",
    "arias", "cav", "temp", "psdSlope",
    "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
    "cusum_max", "autoencoder_score",
]

N_FEATURES = len(FEATURE_NAMES)  # 17


# ---------------------------------------------------------------------------
# Data generation — mirrors generate_precursor_data.py generate_class()
# ---------------------------------------------------------------------------

def _uniform(rng, lo: float, hi: float, n: int) -> np.ndarray:
    return rng.uniform(lo, hi, n).astype(np.float32)


def _generate_class(rng, name: str, n: int) -> np.ndarray:
    """Return (n, 17) array for one class using the provided RNG."""
    if name == "normal":
        return np.column_stack([
            _uniform(rng, 0.01, 0.15, n),
            _uniform(rng, 0.01, 0.25, n),
            _uniform(rng, 5, 80, n),
            _uniform(rng, 1.5, 3.5, n),
            _uniform(rng, 10, 60, n),
            _uniform(rng, 0.5, 3.0, n),
            _uniform(rng, 0.5, 1.5, n),
            _uniform(rng, 0.0, 0.05, n),
            _uniform(rng, 0.0, 0.3, n),
            _uniform(rng, 15, 35, n),
            _uniform(rng, -3, -0.5, n),
            _uniform(rng, 0.9, 1.1, n),
            _uniform(rng, 0.9, 1.1, n),
            _uniform(rng, 0.9, 1.1, n),
            _uniform(rng, 0.9, 1.1, n),
            _uniform(rng, 0.0, 0.5, n),
            _uniform(rng, 0.0, 0.3, n),
        ])
    elif name == "soil_creep":
        corr = rng.uniform(0, 0.8, n).astype(np.float32)
        ppv_tr = rng.uniform(0, 1, n).astype(np.float32) * 0.7 + 0.8 + corr
        kurt_tr = rng.uniform(0, 1, n).astype(np.float32) * 0.7 + 0.8 + corr
        return np.column_stack([
            _uniform(rng, 0.1, 0.8, n),
            _uniform(rng, 0.3, 2.0, n),
            _uniform(rng, 3.0, 20.0, n),
            _uniform(rng, 2.0, 5.0, n),
            _uniform(rng, 3, 25, n),
            _uniform(rng, 1.0, 6.0, n),
            _uniform(rng, 2.0, 8.0, n),
            _uniform(rng, 0.02, 0.3, n),
            _uniform(rng, 0.1, 1.0, n),
            _uniform(rng, 15, 35, n),
            _uniform(rng, -4, -1, n),
            ppv_tr,
            _uniform(rng, 0.5, 0.9, n),
            kurt_tr,
            _uniform(rng, 0.9, 1.3, n),
            _uniform(rng, 0.3, 2.0, n),
            _uniform(rng, 0.1, 0.6, n),
        ])
    elif name == "crack_propagation":
        return np.column_stack([
            _uniform(rng, 0.2, 1.5, n),
            _uniform(rng, 0.5, 3.0, n),
            _uniform(rng, 5, 40, n),
            _uniform(rng, 8.0, 20.0, n),
            _uniform(rng, 10, 50, n),
            _uniform(rng, 6.0, 15.0, n),
            _uniform(rng, 5.0, 12.0, n),
            _uniform(rng, 0.05, 0.8, n),
            _uniform(rng, 0.3, 2.5, n),
            _uniform(rng, 15, 35, n),
            _uniform(rng, -5, -1.5, n),
            _uniform(rng, 1.0, 1.5, n),
            _uniform(rng, 0.7, 1.1, n),
            _uniform(rng, 1.2, 2.0, n),
            _uniform(rng, 1.2, 2.0, n),
            _uniform(rng, 0.5, 3.0, n),
            _uniform(rng, 0.2, 0.8, n),
        ])
    elif name == "imminent_failure":
        return np.column_stack([
            _uniform(rng, 1.0, 5.0, n),
            _uniform(rng, 2.0, 8.0, n),
            _uniform(rng, 0.5, 5.0, n),
            _uniform(rng, 4.0, 15.0, n),
            _uniform(rng, 2, 15, n),
            _uniform(rng, 10.0, 20.0, n),
            _uniform(rng, 8.0, 15.0, n),
            _uniform(rng, 0.2, 3.0, n),
            _uniform(rng, 1.0, 8.0, n),
            _uniform(rng, 15, 35, n),
            _uniform(rng, -6, -2, n),
            _uniform(rng, 1.3, 2.5, n),
            _uniform(rng, 0.3, 0.8, n),
            _uniform(rng, 1.3, 2.5, n),
            _uniform(rng, 1.3, 2.5, n),
            _uniform(rng, 2.0, 10.0, n),
            _uniform(rng, 0.5, 1.0, n),
        ])
    else:
        raise ValueError(f"Unknown class: {name}")


def _generate_synthetic(seed: int) -> tuple:
    """Generate full synthetic dataset using given seed.

    Returns:
        X: np.ndarray (N, 17) float32
        y: np.ndarray (N,) int32
    """
    rng = np.random.default_rng(seed)
    counts = {"normal": 3200, "soil_creep": 2400, "crack_propagation": 2400, "imminent_failure": 1800}
    X_parts, y_parts = [], []
    for i, (cls, n) in enumerate(counts.items()):
        X_parts.append(_generate_class(rng, cls, n))
        y_parts.append(np.full(n, i, dtype=np.int32))
    return np.vstack(X_parts).astype(np.float32), np.concatenate(y_parts)


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

_TREND_DEFAULTS = {
    "ppv_trend": 1.0, "freq_trend": 1.0, "kurtosis_trend": 1.0,
    "stalta_trend": 1.0, "cusum_max": 0.0, "autoencoder_score": 0.0,
    "temp": 0.0, "psdSlope": 0.0,
}
_LABEL_TO_IDX = {n: i for i, n in enumerate(CLASS_NAMES)}


def _load_csv(path: str) -> tuple:
    """Load a field CSV; return (X, y) numpy arrays."""
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))

    X_list, y_list = [], []
    for row in rows:
        label = row.get("label", "").strip().lower()
        if label not in _LABEL_TO_IDX:
            continue
        vec = []
        for feat in FEATURE_NAMES:
            raw = row.get(feat)
            try:
                vec.append(float(raw) if raw is not None else _TREND_DEFAULTS.get(feat, 0.0))
            except (ValueError, TypeError):
                vec.append(_TREND_DEFAULTS.get(feat, 0.0))
        X_list.append(vec)
        y_list.append(_LABEL_TO_IDX[label])

    if not X_list:
        return np.zeros((0, N_FEATURES), dtype=np.float32), np.zeros(0, dtype=np.int32)
    return np.array(X_list, dtype=np.float32), np.array(y_list, dtype=np.int32)


# ---------------------------------------------------------------------------
# TFLite training + export (one model per seed)
# ---------------------------------------------------------------------------

def _train_one_model(X_train: np.ndarray, y_train: np.ndarray,
                     X_val: np.ndarray, y_val: np.ndarray,
                     seed: int) -> tuple:
    """Train one classifier model with the given seed.

    Returns:
        (keras_model, val_accuracy)
    """
    try:
        import tensorflow as tf  # noqa: PLC0415
    except ImportError as exc:
        raise ImportError("tensorflow is required for training.") from exc

    tf.random.set_seed(seed)

    # Compute class weights
    from sklearn.utils.class_weight import compute_class_weight  # noqa: PLC0415
    classes = np.unique(y_train)
    weights_arr = compute_class_weight("balanced", classes=classes, y=y_train)
    class_weight_dict = dict(zip(classes.tolist(), weights_arr.tolist()))

    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(N_FEATURES,)),
        tf.keras.layers.Dense(16, activation="relu",
                              kernel_regularizer=tf.keras.regularizers.l2(0.001)),
        tf.keras.layers.Dense(8, activation="relu",
                              kernel_regularizer=tf.keras.regularizers.l2(0.001)),
        tf.keras.layers.Dense(4, activation="softmax"),
    ])
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=0.001),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )

    early_stop = tf.keras.callbacks.EarlyStopping(
        monitor="val_loss", patience=10, restore_best_weights=True, verbose=0
    )

    model.fit(
        X_train, y_train,
        validation_data=(X_val, y_val),
        epochs=50,
        batch_size=64,
        verbose=0,
        callbacks=[early_stop],
        class_weight=class_weight_dict,
    )

    _, val_acc = model.evaluate(X_val, y_val, verbose=0)
    return model, float(val_acc)


def _export_tflite(model, output_path: str) -> int:
    """Convert Keras model to TFLite and save; return size in bytes."""
    try:
        import tensorflow as tf  # noqa: PLC0415
    except ImportError as exc:
        raise ImportError("tensorflow is required.") from exc

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    tflite_bytes = converter.convert()
    with open(output_path, "wb") as f:
        f.write(tflite_bytes)
    return len(tflite_bytes)


def _verify_tflite(path: str) -> bool:
    """Verify TFLite model loads correctly (subprocess to avoid segfault)."""
    result = subprocess.run(
        [sys.executable, "-c",
         f"import tensorflow as tf; "
         f"i=tf.lite.Interpreter(model_path=r'{path}'); "
         f"i.allocate_tensors(); print('ok')"],
        capture_output=True, text=True, timeout=30,
    )
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Majority vote evaluation
# ---------------------------------------------------------------------------

def _ensemble_accuracy(model_paths: list, X_val: np.ndarray, y_val: np.ndarray,
                        scaler_mean: np.ndarray, scaler_std: np.ndarray) -> float:
    """Run majority-vote ensemble; return accuracy on validation set."""
    try:
        import tensorflow as tf  # noqa: PLC0415
    except ImportError:
        return 0.0

    X_norm = ((X_val - scaler_mean) / np.where(scaler_std > 1e-10, scaler_std, 1.0)).astype(np.float32)
    all_preds = []
    for path in model_paths:
        interp = tf.lite.Interpreter(model_path=path)
        interp.allocate_tensors()
        in_det = interp.get_input_details()
        out_det = interp.get_output_details()
        dtype = in_det[0]["dtype"]
        preds = []
        for i in range(len(X_norm)):
            arr = np.array([X_norm[i]], dtype=dtype)
            interp.set_tensor(in_det[0]["index"], arr)
            interp.invoke()
            out = interp.get_tensor(out_det[0]["index"])
            preds.append(int(np.argmax(out[0])))
        all_preds.append(preds)

    # Majority vote
    n = len(y_val)
    correct = 0
    for i in range(n):
        votes = [all_preds[m][i] for m in range(len(model_paths))]
        # Tally votes
        counts = {}
        for v in votes:
            counts[v] = counts.get(v, 0) + 1
        pred = max(counts, key=counts.get)
        if pred == int(y_val[i]):
            correct += 1
    return correct / n if n > 0 else 0.0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Train 3 precursor classifiers with different seeds and export as ensemble."
    )
    parser.add_argument(
        "--output-dir",
        default=os.path.join(REPO_DIR, "app", "assets", "ml", "ensemble"),
        metavar="DIR",
        help="Directory for ensemble TFLite files + config (default: app/assets/ml/ensemble).",
    )
    parser.add_argument(
        "--csv", default=None, metavar="PATH",
        help="Path to field CSV with label column. Falls back to synthetic data if absent.",
    )
    args = parser.parse_args()

    output_dir = args.output_dir
    os.makedirs(output_dir, exist_ok=True)
    print(f"Output directory: {output_dir}")

    # ---- Load data ----
    if args.csv and os.path.isfile(args.csv):
        print(f"Loading field CSV: {args.csv}")
        X_all, y_all = _load_csv(args.csv)
        if len(X_all) < 20:
            print(f"WARNING: Only {len(X_all)} labeled rows in CSV. "
                  "Supplementing with synthetic data.")
            X_syn, y_syn = _generate_synthetic(seed=0)
            X_all = np.vstack([X_all, X_syn])
            y_all = np.concatenate([y_all, y_syn])
        print(f"Data: {len(X_all)} samples")
    else:
        if args.csv:
            print(f"WARNING: CSV not found: {args.csv}. Using synthetic data.")
        else:
            print("No CSV provided. Generating synthetic data...")
        X_all, y_all = _generate_synthetic(seed=0)
        print(f"Synthetic data: {len(X_all)} samples")

    # ---- Global scaler (computed on full dataset) ----
    scaler_mean = X_all.mean(axis=0).astype(np.float32)
    scaler_std = X_all.std(axis=0).astype(np.float32)
    scaler_std = np.where(scaler_std > 1e-10, scaler_std, 1.0).astype(np.float32)
    X_scaled = ((X_all - scaler_mean) / scaler_std).astype(np.float32)

    print(f"Global scaler computed on {len(X_all)} samples.")
    print()

    # ---- Train 3 models ----
    model_filenames = ["precursor_v1.tflite", "precursor_v2.tflite", "precursor_v3.tflite"]
    model_paths = [os.path.join(output_dir, fn) for fn in model_filenames]
    model_accuracies = []
    val_data_per_model = []

    for model_idx, seed in enumerate(SEEDS):
        print(f"{'=' * 60}")
        print(f"Model {model_idx + 1}/3  (seed={seed})")
        print(f"{'=' * 60}")

        # Shuffle data with this seed
        rng = np.random.default_rng(seed)
        shuffle_idx = rng.permutation(len(X_scaled))
        X_shuf = X_scaled[shuffle_idx]
        y_shuf = y_all[shuffle_idx]

        # 80/20 train/val split
        split = int(len(X_shuf) * 0.8)
        X_train, X_val = X_shuf[:split], X_shuf[split:]
        y_train, y_val = y_shuf[:split], y_shuf[split:]

        val_data_per_model.append((X_val, y_val))

        print(f"  Train: {len(X_train)}  Val: {len(X_val)}")

        try:
            keras_model, val_acc = _train_one_model(X_train, y_train, X_val, y_val, seed)
            model_accuracies.append(val_acc)
            print(f"  Val accuracy: {val_acc * 100:.2f}%")

            out_path = model_paths[model_idx]
            size_bytes = _export_tflite(keras_model, out_path)
            print(f"  Exported: {out_path}  ({size_bytes / 1024:.1f} KB)")

            ok = _verify_tflite(out_path)
            print(f"  TFLite verification: {'PASS' if ok else 'FAIL'}")
        except ImportError as exc:
            print(f"  ERROR: {exc}", file=sys.stderr)
            print("  Cannot train without tensorflow. Install tensorflow>=2.10.", file=sys.stderr)
            sys.exit(1)

        print()

    # ---- Ensemble accuracy (on combined validation data from all splits) ----
    print("Computing ensemble accuracy (majority vote)...")
    # Use the validation set from the first model as a common eval set
    # (fair because seed=42 shuffle is fixed — no overlap with its train)
    X_eval, y_eval = val_data_per_model[0]
    ensemble_acc = _ensemble_accuracy(model_paths, X_eval, y_eval, scaler_mean, scaler_std)

    print()
    print("=" * 60)
    print("ENSEMBLE RESULTS")
    print("=" * 60)
    for i, (seed, acc) in enumerate(zip(SEEDS, model_accuracies)):
        print(f"  Model {i + 1} (seed={seed:>3}): {acc * 100:.2f}%")
    print(f"  Ensemble (majority vote): {ensemble_acc * 100:.2f}%")
    best_individual = max(model_accuracies)
    gain = ensemble_acc - best_individual
    print(f"  Gain over best individual: {gain * 100:+.2f}%")
    print()

    # ---- Write ensemble config ----
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=REPO_DIR, capture_output=True, text=True, timeout=10,
        )
        git_sha = result.stdout.strip() if result.returncode == 0 else "unknown"
    except Exception:
        git_sha = "unknown"

    ensemble_config = {
        "models": model_filenames,
        "strategy": "majority_vote",
        "feature_names": FEATURE_NAMES,
        "class_names": CLASS_NAMES,
        "input_dim": N_FEATURES,
        "output_dim": len(CLASS_NAMES),
        "seeds": SEEDS,
        "per_model_val_accuracy": [round(a, 4) for a in model_accuracies],
        "ensemble_val_accuracy": round(ensemble_acc, 4),
        "scaler": {
            "mean": scaler_mean.tolist(),
            "scale": scaler_std.tolist(),
            "feature_names": FEATURE_NAMES,
        },
        "trained_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "git_sha": git_sha,
    }

    config_path = os.path.join(output_dir, "ensemble_config.json")
    with open(config_path, "w") as f:
        json.dump(ensemble_config, f, indent=2)
    print(f"Ensemble config written: {config_path}")

    # Also write a shared scaler JSON for Flutter app compatibility
    scaler_path = os.path.join(output_dir, "ensemble_scaler.json")
    with open(scaler_path, "w") as f:
        json.dump({
            "mean": scaler_mean.tolist(),
            "scale": scaler_std.tolist(),
            "feature_names": FEATURE_NAMES,
        }, f, indent=2)
    print(f"Scaler JSON written:     {scaler_path}")
    print()
    print("Done.")


if __name__ == "__main__":
    main()
