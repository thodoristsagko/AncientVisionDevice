#!/usr/bin/env python3
"""Grid search for optimal hyperparameters of the precursor classifier.

Trains multiple model configurations via k-fold cross-validation on synthetic
data and reports the top-5 configurations sorted by CV accuracy.

Usage:
    python scripts/hyperparameter_search.py
    python scripts/hyperparameter_search.py --quick
    python scripts/hyperparameter_search.py --n-folds 5
    python scripts/hyperparameter_search.py --quick --n-folds 3 --n-samples 2000

Grid (full mode, 81 combinations):
    Learning rate:     [0.001, 0.0005, 0.0001]
    Hidden units:      [64, 128, 256]
    Dropout rate:      [0.2, 0.3, 0.5]
    L2 regularization: [0.0001, 0.001, 0.01]

Grid (--quick mode, 8 combinations):
    Learning rate:     [0.001, 0.0001]
    Hidden units:      [64, 128]
    Dropout rate:      [0.2, 0.3]
    L2 regularization: [0.0001, 0.001]

Results saved to data/hyperparameter_search_results.json.
"""

import argparse
import itertools
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DATA_DIR = os.path.join(REPO_DIR, "data")
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

DEFAULT_OUTPUT = os.path.join(DATA_DIR, "hyperparameter_search_results.json")

# ---------------------------------------------------------------------------
# Hyperparameter grids
# ---------------------------------------------------------------------------

FULL_GRID = {
    "lr":       [0.001, 0.0005, 0.0001],
    "units":    [64, 128, 256],
    "dropout":  [0.2, 0.3, 0.5],
    "l2":       [0.0001, 0.001, 0.01],
}

QUICK_GRID = {
    "lr":       [0.001, 0.0001],
    "units":    [64, 128],
    "dropout":  [0.2, 0.3],
    "l2":       [0.0001, 0.001],
}

# Feature and class constants matching the production model
N_FEATURES = 17
N_CLASSES = 4
CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]


# ---------------------------------------------------------------------------
# Synthetic data generation
# ---------------------------------------------------------------------------

def _generate_synthetic(n_samples: int, seed: int = 42) -> tuple:
    """Generate synthetic training data for hyperparameter search.

    Produces separable clusters per class with realistic feature ranges
    so that cross-validation scores reflect architecture differences.

    Args:
        n_samples: Total number of samples to generate.
        seed: Random seed for reproducibility.

    Returns:
        Tuple (X, y) where X has shape (n_samples, N_FEATURES) and
        y has shape (n_samples,) with integer class labels.
    """
    rng = np.random.default_rng(seed)
    n_per_class = n_samples // N_CLASSES

    # Class-specific means: progressively larger vibration signatures
    class_means = [
        # normal: low vibration
        np.array([0.1, 0.05, 25.0, 3.5, 24.0, 1.0, 1.2, 0.0001, 0.001,
                  25.0, -9.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.05]),
        # soil_creep: moderate vibration, slow trends
        np.array([0.5, 0.3, 20.0, 4.5, 20.0, 2.5, 2.5, 0.001, 0.01,
                  25.0, -7.0, 1.3, 1.2, 1.4, 1.3, 0.5, 0.2]),
        # crack_propagation: higher vibration, faster trends
        np.array([1.2, 0.8, 15.0, 6.0, 15.0, 5.0, 4.0, 0.005, 0.05,
                  25.0, -5.0, 1.7, 1.5, 1.8, 1.6, 1.5, 0.5]),
        # imminent_failure: very high vibration
        np.array([3.0, 2.5, 8.0, 9.0, 8.0, 10.0, 7.0, 0.05, 0.5,
                  25.0, -2.0, 2.5, 2.0, 3.0, 2.5, 4.0, 0.9]),
    ]
    # Trim/pad to N_FEATURES in case means are defined with different length
    class_means = [m[:N_FEATURES] if len(m) >= N_FEATURES
                   else np.pad(m, (0, N_FEATURES - len(m)))
                   for m in class_means]

    X_parts, y_parts = [], []
    for cls_idx, mean in enumerate(class_means):
        noise = rng.standard_normal((n_per_class, N_FEATURES)) * 0.3
        X_cls = mean + noise
        X_parts.append(X_cls.astype(np.float32))
        y_parts.append(np.full(n_per_class, cls_idx, dtype=np.int32))

    X = np.vstack(X_parts)
    y = np.concatenate(y_parts)

    # Shuffle
    perm = rng.permutation(len(X))
    return X[perm], y[perm]


# ---------------------------------------------------------------------------
# Normalize (simple StandardScaler)
# ---------------------------------------------------------------------------

def _normalize(X_train: np.ndarray, X_test: np.ndarray) -> tuple:
    mean = X_train.mean(axis=0)
    std = X_train.std(axis=0)
    std = np.where(std < 1e-10, 1.0, std)
    return (X_train - mean) / std, (X_test - mean) / std


# ---------------------------------------------------------------------------
# Model builder
# ---------------------------------------------------------------------------

def _build_model(units: int, dropout: float, l2: float, lr: float):
    """Build a two-hidden-layer classifier.

    Args:
        units: Number of units in the first hidden layer; second layer uses units // 2.
        dropout: Dropout rate after each hidden layer.
        l2: L2 regularization coefficient for Dense layers.
        lr: Learning rate for Adam optimizer.

    Returns:
        Compiled Keras model.
    """
    import tensorflow as tf  # noqa: PLC0415
    from tensorflow.keras import layers, regularizers  # noqa: PLC0415

    reg = regularizers.l2(l2)
    units2 = max(16, units // 2)

    model = tf.keras.Sequential([
        layers.Input(shape=(N_FEATURES,)),
        layers.Dense(units, activation="relu", kernel_regularizer=reg),
        layers.BatchNormalization(),
        layers.Dropout(dropout),
        layers.Dense(units2, activation="relu", kernel_regularizer=reg),
        layers.BatchNormalization(),
        layers.Dropout(dropout * 0.7),
        layers.Dense(N_CLASSES, activation="softmax"),
    ])

    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=lr),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


# ---------------------------------------------------------------------------
# Cross-validation evaluation
# ---------------------------------------------------------------------------

def _cv_accuracy(
    X: np.ndarray,
    y: np.ndarray,
    config: dict,
    n_folds: int,
    epochs: int = 15,
    batch_size: int = 64,
) -> dict:
    """Train with k-fold CV and return mean/std accuracy.

    Args:
        X: Feature matrix of shape (N, n_features).
        y: Integer class labels of shape (N,).
        config: Dict with keys 'lr', 'units', 'dropout', 'l2'.
        n_folds: Number of cross-validation folds.
        epochs: Training epochs per fold (kept small for speed).
        batch_size: Mini-batch size.

    Returns:
        Dict with 'mean_accuracy', 'std_accuracy', 'fold_accuracies'.
    """
    import tensorflow as tf  # noqa: PLC0415

    n = len(X)
    fold_size = n // n_folds
    fold_accs = []

    for fold in range(n_folds):
        val_start = fold * fold_size
        val_end = val_start + fold_size if fold < n_folds - 1 else n

        val_mask = np.zeros(n, dtype=bool)
        val_mask[val_start:val_end] = True
        train_mask = ~val_mask

        X_tr, X_va = X[train_mask], X[val_mask]
        y_tr, y_va = y[train_mask], y[val_mask]

        X_tr_n, X_va_n = _normalize(X_tr, X_va)

        # Build a fresh model for each fold
        tf.keras.backend.clear_session()
        model = _build_model(
            units=config["units"],
            dropout=config["dropout"],
            l2=config["l2"],
            lr=config["lr"],
        )

        model.fit(
            X_tr_n, y_tr,
            epochs=epochs,
            batch_size=min(batch_size, len(X_tr)),
            validation_data=(X_va_n, y_va),
            verbose=0,
        )

        _, acc = model.evaluate(X_va_n, y_va, verbose=0)
        fold_accs.append(float(acc))

    return {
        "mean_accuracy": float(np.mean(fold_accs)),
        "std_accuracy": float(np.std(fold_accs)),
        "fold_accuracies": [round(a, 4) for a in fold_accs],
    }


# ---------------------------------------------------------------------------
# Grid expansion
# ---------------------------------------------------------------------------

def _expand_grid(grid: dict) -> list:
    """Expand a grid dict into a list of config dicts.

    Args:
        grid: Dict mapping param name -> list of values.

    Returns:
        List of dicts, one per combination.
    """
    keys = list(grid.keys())
    combos = list(itertools.product(*[grid[k] for k in keys]))
    return [dict(zip(keys, combo)) for combo in combos]


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

def _print_progress(done: int, total: int, elapsed: float) -> None:
    pct = 100.0 * done / max(total, 1)
    eta = elapsed / max(done, 1) * (total - done)
    print(
        f"  [{done:3d}/{total}] {pct:5.1f}%  elapsed={elapsed:.0f}s  ETA={eta:.0f}s",
        flush=True,
    )


def _print_top_n(results: list, n: int = 5) -> None:
    print(f"\n  Top-{min(n, len(results))} configurations by CV accuracy:")
    header = (
        f"  {'Rank':>4}  {'lr':>8}  {'units':>6}  {'dropout':>8}  "
        f"{'l2':>8}  {'CV acc':>7}  {'std':>6}"
    )
    print(header)
    print("  " + "-" * (len(header) - 2))
    for rank, r in enumerate(results[:n], start=1):
        cfg = r["config"]
        print(
            f"  {rank:>4}  {cfg['lr']:>8.5f}  {cfg['units']:>6}  "
            f"{cfg['dropout']:>8.3f}  {cfg['l2']:>8.5f}  "
            f"{r['mean_accuracy']:>7.4f}  {r['std_accuracy']:>6.4f}"
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Grid search for optimal precursor classifier hyperparameters."
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Use reduced grid (8 combinations) for faster search.",
    )
    parser.add_argument(
        "--n-folds",
        type=int,
        default=3,
        metavar="K",
        help="Number of cross-validation folds (default: 3).",
    )
    parser.add_argument(
        "--n-samples",
        type=int,
        default=4000,
        metavar="N",
        help="Number of synthetic training samples (default: 4000).",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        metavar="PATH",
        help=f"Output JSON path (default: {DEFAULT_OUTPUT}).",
    )
    args = parser.parse_args()

    print("=" * 60)
    print("Hyperparameter Grid Search — Precursor Classifier")
    print("=" * 60)

    # --- Check TF ---
    try:
        import tensorflow as tf  # noqa: PLC0415
        print(f"TensorFlow version: {tf.__version__}")
    except ImportError:
        print("ERROR: TensorFlow is required for hyperparameter search.", file=sys.stderr)
        print("Install it with: pip install tensorflow==2.15.1")
        sys.exit(1)

    grid = QUICK_GRID if args.quick else FULL_GRID
    configs = _expand_grid(grid)
    mode = "quick" if args.quick else "full"
    print(f"Mode:       {mode} ({len(configs)} combinations)")
    print(f"Folds:      {args.n_folds}")
    print(f"Samples:    {args.n_samples}")
    print(f"Output:     {args.output}")
    print()

    # --- Generate data ---
    print("Generating synthetic training data...")
    X, y = _generate_synthetic(args.n_samples)
    print(f"  Generated {len(X)} samples, {N_FEATURES} features, {N_CLASSES} classes")
    print()

    # --- Run grid search ---
    print(f"Running {len(configs)}-combination grid search with {args.n_folds}-fold CV...")
    results = []
    start_time = time.time()

    for i, config in enumerate(configs):
        t0 = time.time()
        cv_result = _cv_accuracy(X, y, config, n_folds=args.n_folds)
        elapsed_combo = time.time() - t0
        elapsed_total = time.time() - start_time

        entry = {
            "config": config,
            "mean_accuracy": cv_result["mean_accuracy"],
            "std_accuracy": cv_result["std_accuracy"],
            "fold_accuracies": cv_result["fold_accuracies"],
            "combo_elapsed_s": round(elapsed_combo, 2),
        }
        results.append(entry)

        _print_progress(i + 1, len(configs), elapsed_total)

    total_elapsed = time.time() - start_time

    # --- Sort by CV accuracy ---
    results.sort(key=lambda r: r["mean_accuracy"], reverse=True)

    # --- Print top 5 ---
    print()
    print("=" * 60)
    print("RESULTS")
    print("=" * 60)
    _print_top_n(results, n=5)

    best = results[0]
    print()
    print("Best configuration:")
    for k, v in best["config"].items():
        print(f"  {k}: {v}")
    print(f"  CV accuracy: {best['mean_accuracy']:.4f} +/- {best['std_accuracy']:.4f}")
    print()
    print(f"Total elapsed: {total_elapsed:.1f}s")

    # --- Save results ---
    output_data = {
        "search_mode": mode,
        "n_folds": args.n_folds,
        "n_samples": args.n_samples,
        "n_combinations": len(configs),
        "total_elapsed_s": round(total_elapsed, 2),
        "searched_at": datetime.now(timezone.utc).isoformat(),
        "results": results,
    }

    output_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    Path(output_path).write_text(json.dumps(output_data, indent=2))
    print(f"Results saved to: {output_path}")
    print()


if __name__ == "__main__":
    main()
