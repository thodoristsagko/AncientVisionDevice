#!/usr/bin/env python3
"""Incremental model update (online learning) for the precursor classifier.

Loads the existing Keras SavedModel, fine-tunes on new labeled field data,
evaluates accuracy, and if >= 70% exports an updated TFLite to assets.

Usage:
    python scripts/online_learning.py --labeled-csv data/field/new_labels.csv
    python scripts/online_learning.py --labeled-csv data/field/new_labels.csv --epochs 5 --lr 0.0001
    python scripts/online_learning.py --labeled-csv data/field/new_labels.csv --dry-run

Algorithm:
1. Load existing precursor classifier (Keras SavedModel if available, else trains
   from scratch on existing data + new data).
2. Load new labeled CSV (requires 'label' column).
3. Map labels to class indices.
4. Freeze all layers except the last 2, fine-tune with low learning rate.
5. Evaluate on a 20% holdout of the new data.
6. If accuracy >= 70%: export updated TFLite and backup old model.

Falls back gracefully if TensorFlow is not available.
"""

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")
DATA_DIR = os.path.join(REPO_DIR, "data")

PRECURSOR_TFLITE = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
PRECURSOR_CONFIG = os.path.join(ASSETS_DIR, "precursor_classifier_config.json")
PRECURSOR_SCALER = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")

# SavedModel directories searched in order
SAVED_MODEL_CANDIDATES = [
    os.path.join(ASSETS_DIR, "precursor_classifier_saved_model"),
    os.path.join(DATA_DIR, "saved_models", "precursor_classifier"),
    os.path.join(REPO_DIR, "precursor_classifier_saved_model"),
]

ARCHIVE_DIR = os.path.join(DATA_DIR, "model_archive")

CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]
CLASS_INDEX = {name: i for i, name in enumerate(CLASS_NAMES)}

MIN_ACCURACY_THRESHOLD = 0.70
HOLDOUT_FRACTION = 0.20

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
# CSV / feature helpers
# ---------------------------------------------------------------------------

def _load_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _load_csv(path: str) -> list:
    """Load a labeled CSV into a list of row dicts."""
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))
    return rows


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


def _apply_scaler(vec: list, scaler: dict) -> list:
    mean = scaler["mean"]
    scale = scaler.get("scale", scaler.get("std", [1.0] * len(mean)))
    return [(v - m) / max(s, 1e-10) for v, m, s in zip(vec, mean, scale)]


def _prepare_dataset(rows: list, feature_names: list, scaler: dict):
    """Convert labeled rows into (X, y) numpy arrays.

    Rows without a recognizable label are skipped.

    Returns:
        Tuple (X, y) where X has shape (N, n_features) and y has shape (N,).
        Returns (None, None) if no valid rows are found.
    """
    X, y = [], []
    skipped = 0
    for row in rows:
        label = row.get("label", "").strip().lower()
        if label not in CLASS_INDEX:
            skipped += 1
            continue
        vec = _build_vec(row, feature_names)
        norm_vec = _apply_scaler(vec, scaler)
        X.append(norm_vec)
        y.append(CLASS_INDEX[label])

    if skipped > 0:
        print(f"  Skipped {skipped} rows with unrecognized labels.")
    if not X:
        return None, None
    return np.array(X, dtype=np.float32), np.array(y, dtype=np.int32)


# ---------------------------------------------------------------------------
# Saved model search
# ---------------------------------------------------------------------------

def _find_saved_model() -> str | None:
    for path in SAVED_MODEL_CANDIDATES:
        if os.path.isdir(path) and os.path.isfile(os.path.join(path, "saved_model.pb")):
            return path
    return None


# ---------------------------------------------------------------------------
# TFLite fallback: get current accuracy via inference
# ---------------------------------------------------------------------------

def _tflite_accuracy(X: np.ndarray, y: np.ndarray) -> float:
    """Run float32 TFLite inference and compute accuracy.

    Args:
        X: Normalized feature matrix of shape (N, n_features).
        y: True class indices of shape (N,).

    Returns:
        Accuracy in [0, 1], or 0.0 on failure.
    """
    try:
        try:
            from tflite_runtime.interpreter import Interpreter  # noqa: PLC0415
            interp = Interpreter(model_path=PRECURSOR_TFLITE)
        except ImportError:
            import tensorflow as tf  # noqa: PLC0415
            interp = tf.lite.Interpreter(model_path=PRECURSOR_TFLITE)
        interp.allocate_tensors()
        in_det = interp.get_input_details()
        out_det = interp.get_output_details()
        dtype = in_det[0]["dtype"]

        preds = []
        for sample in X:
            arr = sample.reshape(1, -1).astype(dtype)
            interp.set_tensor(in_det[0]["index"], arr)
            interp.invoke()
            out = interp.get_tensor(out_det[0]["index"])[0]
            preds.append(int(np.argmax(out)))

        correct = sum(p == int(t) for p, t in zip(preds, y))
        return correct / len(y)

    except Exception as exc:
        print(f"  WARNING: TFLite accuracy check failed: {exc}")
        return 0.0


# ---------------------------------------------------------------------------
# Train-from-scratch fallback
# ---------------------------------------------------------------------------

def _build_model(input_dim: int, n_classes: int, lr: float):
    """Build a fresh precursor classifier matching the production architecture.

    Args:
        input_dim: Number of input features.
        n_classes: Number of output classes.
        lr: Learning rate for Adam optimizer.

    Returns:
        Compiled Keras model.
    """
    import tensorflow as tf  # noqa: PLC0415
    from tensorflow.keras import layers, regularizers  # noqa: PLC0415

    reg = regularizers.l2(0.001)
    model = tf.keras.Sequential([
        layers.Input(shape=(input_dim,)),
        layers.Dense(128, activation="relu", kernel_regularizer=reg),
        layers.BatchNormalization(),
        layers.Dropout(0.3),
        layers.Dense(64, activation="relu", kernel_regularizer=reg),
        layers.BatchNormalization(),
        layers.Dropout(0.2),
        layers.Dense(n_classes, activation="softmax"),
    ], name="precursor_classifier")

    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=lr),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

def _export_tflite(model, output_path: str) -> None:
    """Convert Keras model to TFLite and write to output_path.

    Uses a subprocess to avoid in-process TFLiteConverter segfaults.

    Args:
        model: Trained Keras model.
        output_path: Destination path for the .tflite file.
    """
    import tempfile
    import tensorflow as tf  # noqa: PLC0415

    with tempfile.TemporaryDirectory() as tmp_dir:
        saved_model_path = os.path.join(tmp_dir, "saved_model")
        model.save(saved_model_path)

        # Convert in subprocess to avoid MLIR/TFLite segfaults
        script = (
            f"import tensorflow as tf; "
            f"c=tf.lite.TFLiteConverter.from_saved_model(r'{saved_model_path}'); "
            f"c.optimizations=[tf.lite.Optimize.DEFAULT]; "
            f"data=c.convert(); "
            f"open(r'{output_path}','wb').write(data); "
            f"print('OK')"
        )
        result = subprocess.run(
            [sys.executable, "-c", script],
            capture_output=True,
            timeout=120,
        )
        if result.returncode != 0 or b"OK" not in result.stdout:
            stderr = result.stderr.decode(errors="replace")
            raise RuntimeError(f"TFLite conversion failed: {stderr}")


def _backup_old_model() -> None:
    """Copy current .tflite and config files to ARCHIVE_DIR with timestamp."""
    if not os.path.isfile(PRECURSOR_TFLITE):
        return
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    archive_path = os.path.join(ARCHIVE_DIR, ts)
    os.makedirs(archive_path, exist_ok=True)
    for src in [PRECURSOR_TFLITE, PRECURSOR_CONFIG, PRECURSOR_SCALER]:
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(archive_path, os.path.basename(src)))
    print(f"  Old model backed up to: {archive_path}")


# ---------------------------------------------------------------------------
# Main fine-tuning logic
# ---------------------------------------------------------------------------

def online_update(
    labeled_csv: str,
    epochs: int = 5,
    lr: float = 1e-4,
    dry_run: bool = False,
) -> None:
    """Run online learning update.

    Args:
        labeled_csv: Path to CSV with a 'label' column.
        epochs: Fine-tuning epochs.
        lr: Learning rate for fine-tuning.
        dry_run: If True, skip model export / backup.
    """
    # --- Load config and scaler ---
    if not os.path.isfile(PRECURSOR_CONFIG):
        print(f"ERROR: Config not found: {PRECURSOR_CONFIG}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(PRECURSOR_SCALER):
        print(f"ERROR: Scaler not found: {PRECURSOR_SCALER}", file=sys.stderr)
        sys.exit(1)

    config = _load_json(PRECURSOR_CONFIG)
    scaler = _load_json(PRECURSOR_SCALER)
    feature_names = config["feature_names"]
    n_classes = config.get("output_dim", 4)
    input_dim = config.get("input_dim", len(feature_names))

    # --- Load new data ---
    if not os.path.isfile(labeled_csv):
        print(f"ERROR: Labeled CSV not found: {labeled_csv}", file=sys.stderr)
        sys.exit(1)

    rows = _load_csv(labeled_csv)
    print(f"Loaded {len(rows)} rows from {labeled_csv}")

    X, y = _prepare_dataset(rows, feature_names, scaler)
    if X is None or len(X) == 0:
        print("ERROR: No valid labeled samples found in CSV.", file=sys.stderr)
        sys.exit(1)

    n_new = len(X)
    print(f"  Valid labeled samples: {n_new}")

    # --- Holdout split ---
    rng = np.random.default_rng(seed=0)
    indices = rng.permutation(n_new)
    holdout_n = max(1, int(n_new * HOLDOUT_FRACTION))
    holdout_idx = indices[:holdout_n]
    train_idx = indices[holdout_n:]

    X_train, y_train = X[train_idx], y[train_idx]
    X_val, y_val = X[holdout_idx], y[holdout_idx]

    print(f"  Train: {len(X_train)}  Holdout: {len(X_val)}")

    # --- Get baseline accuracy on holdout ---
    baseline_acc = 0.0
    if os.path.isfile(PRECURSOR_TFLITE):
        baseline_acc = _tflite_accuracy(X_val, y_val)
        print(f"  Baseline accuracy (current model on holdout): {baseline_acc * 100:.1f}%")

    # --- Check TF availability ---
    try:
        import tensorflow as tf  # noqa: PLC0415
    except ImportError:
        print("WARNING: TensorFlow not available. Cannot perform fine-tuning.", file=sys.stderr)
        print("Install TensorFlow to use online learning.")
        sys.exit(0)

    # --- Load or build model ---
    saved_model_dir = _find_saved_model()

    if saved_model_dir is not None:
        print(f"  Loading SavedModel from: {saved_model_dir}")
        try:
            model = tf.keras.models.load_model(saved_model_dir)
        except Exception as exc:
            print(f"  WARNING: Could not load SavedModel ({exc}). Building fresh model.")
            model = _build_model(input_dim, n_classes, lr)
    else:
        print(
            "  WARNING: No SavedModel found. Building fresh model from scratch.\n"
            "  Tip: retrain with generate_precursor_data.py to export a SavedModel."
        )
        model = _build_model(input_dim, n_classes, lr)

    # --- Freeze all layers except last 2 ---
    total_layers = len(model.layers)
    freeze_up_to = max(0, total_layers - 2)
    for layer in model.layers[:freeze_up_to]:
        layer.trainable = False
    trainable_count = sum(1 for l in model.layers if l.trainable)
    print(f"  Frozen {freeze_up_to} of {total_layers} layers. Trainable: {trainable_count}")

    # Recompile with fine-tuning learning rate
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=lr),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )

    # --- Fine-tune ---
    print(f"  Fine-tuning for {epochs} epoch(s) at lr={lr}...")
    history = model.fit(
        X_train,
        y_train,
        epochs=epochs,
        batch_size=min(32, max(1, len(X_train))),
        validation_data=(X_val, y_val),
        verbose=0,
    )

    val_acc = float(history.history.get("val_accuracy", [0.0])[-1])
    train_acc = float(history.history.get("accuracy", [0.0])[-1])
    print(f"  Training accuracy: {train_acc * 100:.1f}%")
    print(f"  Holdout accuracy:  {val_acc * 100:.1f}%")

    # --- Evaluate decision ---
    print()
    if val_acc >= MIN_ACCURACY_THRESHOLD:
        print(
            f"Online update: {n_new} new samples, "
            f"accuracy {val_acc * 100:.1f}% (was {baseline_acc * 100:.1f}%), "
            f"model updated"
        )

        if dry_run:
            print("  [dry-run] Skipping model export and backup.")
            return

        # Backup old model
        _backup_old_model()

        # Export updated TFLite
        print(f"  Exporting updated TFLite to: {PRECURSOR_TFLITE}")
        try:
            _export_tflite(model, PRECURSOR_TFLITE)
            print("  Export successful.")
        except Exception as exc:
            print(f"  ERROR: TFLite export failed: {exc}", file=sys.stderr)
            sys.exit(1)

    else:
        print(
            f"Online update: {n_new} new samples, "
            f"accuracy {val_acc * 100:.1f}% < {MIN_ACCURACY_THRESHOLD * 100:.0f}% threshold — "
            f"model NOT updated"
        )
        print(
            "  Recommendation: collect more labeled data or retrain from scratch."
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Incremental fine-tuning update for the precursor classifier."
    )
    parser.add_argument(
        "--labeled-csv",
        required=True,
        metavar="PATH",
        help="Path to labeled CSV file (requires 'label' column).",
    )
    parser.add_argument(
        "--epochs",
        type=int,
        default=5,
        metavar="N",
        help="Number of fine-tuning epochs (default: 5).",
    )
    parser.add_argument(
        "--lr",
        type=float,
        default=1e-4,
        metavar="RATE",
        help="Learning rate for fine-tuning (default: 0.0001).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Evaluate but do not export or backup the model.",
    )
    args = parser.parse_args()

    print("=" * 60)
    print("Online Learning — Precursor Classifier Fine-tuning")
    print("=" * 60)
    print(f"Labeled CSV:  {args.labeled_csv}")
    print(f"Epochs:       {args.epochs}")
    print(f"Learning rate:{args.lr}")
    print(f"Dry run:      {args.dry_run}")
    print()

    online_update(
        labeled_csv=args.labeled_csv,
        epochs=args.epochs,
        lr=args.lr,
        dry_run=args.dry_run,
    )


if __name__ == "__main__":
    main()
