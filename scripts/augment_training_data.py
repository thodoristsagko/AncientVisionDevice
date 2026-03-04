#!/usr/bin/env python3
"""
Data augmentation for minority classes via Gaussian noise injection.

Usage: python scripts/augment_training_data.py --data-dir ./data/field
       python scripts/augment_training_data.py --csv ./data/training_data.csv --output ./data/augmented.csv

Adds Gaussian noise (σ proportional to feature std) to minority class samples
until all classes have at least --min-samples samples.

Feature schema: rms, ppv, freq, crest, centroid, kurtosis, stalta,
                arias, cav, temp, psdSlope, ppv_trend, freq_trend,
                kurtosis_trend, stalta_trend, cusum_max, autoencoder_score, label
"""

import argparse
import json
import os
import sys

import numpy as np
import pandas as pd

# Default parameters
DEFAULT_NOISE_FACTOR = 0.05  # 5% of feature std
DEFAULT_SEED = 42

# Feature bounds: (feature_index, min_val, max_val or None)
FEATURE_BOUNDS = {
    0: (0.0, None),    # rms >= 0
    1: (0.0, None),    # ppv >= 0
    5: (1.0, None),    # kurtosis >= 1.0
}

FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis", "stalta",
    "arias", "cav", "temp", "psdSlope",
    "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
    "cusum_max", "autoencoder_score",
]

CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]


def load_dataset(csv_path: str) -> tuple:
    """Load CSV with schema: feature columns + 'label' column.

    Returns:
        (X, y) where X is (N, 17) float32, y is (N,) int32
    """
    df = pd.read_csv(csv_path)

    # Extract label column
    if "label" not in df.columns:
        raise ValueError("CSV must have a 'label' column")

    y = df["label"].values.astype(np.int32)

    # Extract features in order
    feature_cols = [c for c in FEATURE_NAMES if c in df.columns]
    if len(feature_cols) != len(FEATURE_NAMES):
        missing = set(FEATURE_NAMES) - set(feature_cols)
        raise ValueError(f"Missing feature columns: {missing}")

    X = df[FEATURE_NAMES].values.astype(np.float32)

    return X, y


def save_dataset(X: np.ndarray, y: np.ndarray, output_path: str):
    """Save augmented dataset to CSV."""
    df = pd.DataFrame(X, columns=FEATURE_NAMES)
    df["label"] = y
    df.to_csv(output_path, index=False)
    print(f"Saved augmented dataset to {output_path}")


def augment_data(
    X: np.ndarray,
    y: np.ndarray,
    noise_factor: float = DEFAULT_NOISE_FACTOR,
    min_samples: int = None,
    seed: int = DEFAULT_SEED,
) -> tuple:
    """
    Augment minority classes by adding Gaussian noise.

    Args:
        X: (N, 17) feature array
        y: (N,) label array
        noise_factor: std of noise as fraction of per-feature std
        min_samples: target count per class (default: majority class size)
        seed: random seed

    Returns:
        (X_augmented, y_augmented)
    """
    np.random.seed(seed)

    # Compute per-class counts
    class_counts = {i: int(np.sum(y == i)) for i in range(len(CLASS_NAMES))}
    print(f"\nClass distribution (before augmentation):")
    for i, name in enumerate(CLASS_NAMES):
        print(f"  {name}: {class_counts[i]}")

    # Determine target count
    majority_count = max(class_counts.values())
    if min_samples is None:
        target_count = majority_count
    else:
        target_count = max(min_samples, majority_count)

    print(f"\nAugmentation target: {target_count} samples per class")

    # Compute per-feature std (avoid division by zero)
    feature_std = X.std(axis=0)
    feature_std = np.where(feature_std > 1e-10, feature_std, 1e-10)

    # Augmentation
    X_aug_parts = [X]
    y_aug_parts = [y]
    total_augmented = 0

    for cls_idx in range(len(CLASS_NAMES)):
        current_count = class_counts[cls_idx]
        if current_count >= target_count:
            continue

        needed = target_count - current_count
        cls_mask = (y == cls_idx)
        cls_X = X[cls_mask]

        # Sample with replacement from existing class samples
        rng_indices = np.random.randint(0, len(cls_X), size=needed)
        base_samples = cls_X[rng_indices]

        # Add Gaussian noise scaled per feature
        noise = np.random.normal(
            0.0,
            noise_factor * feature_std,
            size=(needed, X.shape[1]),
        ).astype(np.float32)
        aug_X = base_samples + noise

        # Clamp physically implausible values
        for feat_idx, (lo, hi) in FEATURE_BOUNDS.items():
            if lo is not None:
                aug_X[:, feat_idx] = np.maximum(aug_X[:, feat_idx], lo)
            if hi is not None:
                aug_X[:, feat_idx] = np.minimum(aug_X[:, feat_idx], hi)

        X_aug_parts.append(aug_X)
        y_aug_parts.append(np.full(needed, cls_idx, dtype=np.int32))
        total_augmented += needed

        print(f"  {CLASS_NAMES[cls_idx]}: added {needed} samples "
              f"({current_count} -> {current_count + needed})")

    X_augmented = np.vstack(X_aug_parts).astype(np.float32)
    y_augmented = np.concatenate(y_aug_parts)

    # Shuffle
    shuffle_idx = np.random.permutation(len(X_augmented))
    X_augmented = X_augmented[shuffle_idx]
    y_augmented = y_augmented[shuffle_idx]

    print(f"\nTotal augmented samples: {total_augmented}")
    print(f"Final dataset: {X_augmented.shape[0]} samples")

    # Print final distribution
    final_counts = {i: int(np.sum(y_augmented == i)) for i in range(len(CLASS_NAMES))}
    print(f"\nClass distribution (after augmentation):")
    for i, name in enumerate(CLASS_NAMES):
        print(f"  {name}: {final_counts[i]}")

    return X_augmented, y_augmented


def main():
    parser = argparse.ArgumentParser(
        description="Data augmentation for minority classes via Gaussian noise injection."
    )
    parser.add_argument(
        "--csv",
        type=str,
        help="Path to input CSV (features + label column)",
    )
    parser.add_argument(
        "--data-dir",
        type=str,
        help="Path to data directory (searches for training_data.csv)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="augmented_training_data.csv",
        help="Output CSV path (default: augmented_training_data.csv)",
    )
    parser.add_argument(
        "--noise-factor",
        type=float,
        default=DEFAULT_NOISE_FACTOR,
        help="Noise std as fraction of feature std (default: 0.05)",
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=None,
        help="Target samples per class (default: majority class size)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help="Random seed (default: 42)",
    )

    args = parser.parse_args()

    # Determine input CSV path
    if args.csv:
        csv_path = args.csv
    elif args.data_dir:
        csv_path = os.path.join(args.data_dir, "training_data.csv")
    else:
        parser.error("Must specify either --csv or --data-dir")

    if not os.path.exists(csv_path):
        print(f"Error: {csv_path} not found", file=sys.stderr)
        sys.exit(1)

    print(f"Loading dataset from {csv_path}...")
    X, y = load_dataset(csv_path)
    print(f"Loaded {X.shape[0]} samples with {X.shape[1]} features")

    # Augment
    X_aug, y_aug = augment_data(
        X, y,
        noise_factor=args.noise_factor,
        min_samples=args.min_samples,
        seed=args.seed,
    )

    # Save
    save_dataset(X_aug, y_aug, args.output)
    print(f"\nDone. Augmented dataset saved to {args.output}")


if __name__ == "__main__":
    main()
