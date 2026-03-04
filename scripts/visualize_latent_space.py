#!/usr/bin/env python3
"""Visualize autoencoder latent space via PCA on extracted encoder output.

Loads the vibration autoencoder (11-feature, 11->8->4->8->11), extracts the
bottleneck (latent) representations for synthetic samples across 4 classes,
projects them to 2D via manual PCA, and renders an ASCII scatter plot.

Usage:
    python scripts/visualize_latent_space.py
    python scripts/visualize_latent_space.py --csv path/to/data.csv
    python scripts/visualize_latent_space.py --n-samples 200

If the encoder sub-model cannot be extracted from the TFLite graph (single
flat model without intermediate outputs), reconstruction error is used as a
1D proxy and PCA is skipped.
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

AUTOENCODER_TFLITE = os.path.join(ASSETS_DIR, "vibration_anomaly.tflite")
ANOMALY_SCALER = os.path.join(ASSETS_DIR, "vibration_scaler.json")

# Autoencoder features (11) — matches train_autoencoder.py
AE_FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid",
    "kurtosis", "stalta", "arias", "cav", "temp", "psdSlope",
]

CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]
CLASS_MARKERS = {"normal": "n", "soil_creep": "s", "crack_propagation": "c", "imminent_failure": "i"}
CLASS_COLORS = {
    "normal": "n",
    "soil_creep": "s",
    "crack_propagation": "c",
    "imminent_failure": "i",
}

# Physical ranges per class for synthetic generation (AE features only, 11 features)
_CLASS_RANGES = {
    "normal": [
        (0.001, 0.05),    # rms
        (0.01, 0.3),      # ppv
        (5.0, 50.0),      # freq
        (2.0, 6.0),       # crest
        (10.0, 40.0),     # centroid
        (-1.0, 3.0),      # kurtosis
        (0.5, 2.0),       # stalta
        (0.0, 0.001),     # arias
        (0.0, 0.01),      # cav
        (15.0, 35.0),     # temp
        (-12.0, -6.0),    # psdSlope
    ],
    "soil_creep": [
        (0.1, 0.8),       # rms
        (0.3, 2.0),       # ppv
        (3.0, 20.0),      # freq
        (2.0, 5.0),       # crest
        (3.0, 25.0),      # centroid
        (1.0, 6.0),       # kurtosis
        (2.0, 8.0),       # stalta
        (0.02, 0.3),      # arias
        (0.1, 1.0),       # cav
        (15.0, 35.0),     # temp
        (-4.0, -1.0),     # psdSlope
    ],
    "crack_propagation": [
        (0.2, 1.5),       # rms
        (0.5, 3.0),       # ppv
        (5.0, 40.0),      # freq
        (8.0, 20.0),      # crest
        (10.0, 50.0),     # centroid
        (6.0, 15.0),      # kurtosis
        (5.0, 12.0),      # stalta
        (0.05, 0.8),      # arias
        (0.3, 2.5),       # cav
        (15.0, 35.0),     # temp
        (-5.0, -1.5),     # psdSlope
    ],
    "imminent_failure": [
        (1.0, 5.0),       # rms
        (2.0, 8.0),       # ppv
        (0.5, 5.0),       # freq
        (4.0, 15.0),      # crest
        (2.0, 15.0),      # centroid
        (10.0, 20.0),     # kurtosis
        (8.0, 15.0),      # stalta
        (0.2, 3.0),       # arias
        (1.0, 8.0),       # cav
        (15.0, 35.0),     # temp
        (-6.0, -2.0),     # psdSlope
    ],
}


# ---------------------------------------------------------------------------
# Synthetic data
# ---------------------------------------------------------------------------

def _generate_synthetic(n_per_class: int) -> tuple:
    """Generate synthetic samples for all 4 classes.

    Returns:
        X: np.ndarray shape (n_total, 11), raw (unscaled)
        y: np.ndarray shape (n_total,) int class indices
        class_labels: list of class name strings per sample
    """
    rng = np.random.default_rng(42)
    parts_X = []
    parts_y = []
    parts_labels = []
    for cls_idx, cls_name in enumerate(CLASS_NAMES):
        ranges = _CLASS_RANGES[cls_name]
        rows = np.zeros((n_per_class, len(ranges)), dtype=np.float32)
        for fi, (lo, hi) in enumerate(ranges):
            rows[:, fi] = rng.uniform(lo, hi, n_per_class).astype(np.float32)
        parts_X.append(rows)
        parts_y.append(np.full(n_per_class, cls_idx, dtype=np.int32))
        parts_labels.extend([cls_name] * n_per_class)
    return np.vstack(parts_X), np.concatenate(parts_y), parts_labels


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _load_csv(path: str) -> tuple:
    """Load feature CSV and return (X, y, class_labels)."""
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))

    label_to_idx = {n: i for i, n in enumerate(CLASS_NAMES)}
    X_list = []
    y_list = []
    labels_list = []
    for row in rows:
        label = row.get("label", "").strip().lower()
        if label not in label_to_idx:
            continue
        vec = []
        for feat in AE_FEATURE_NAMES:
            try:
                vec.append(float(row.get(feat, 0.0) or 0.0))
            except (ValueError, TypeError):
                vec.append(0.0)
        X_list.append(vec)
        y_list.append(label_to_idx[label])
        labels_list.append(label)
    if not X_list:
        return np.zeros((0, 11), dtype=np.float32), np.zeros(0, dtype=np.int32), []
    return (
        np.array(X_list, dtype=np.float32),
        np.array(y_list, dtype=np.int32),
        labels_list,
    )


# ---------------------------------------------------------------------------
# TFLite helpers
# ---------------------------------------------------------------------------

def _load_interpreter(path: str):
    """Load TFLite model, falling back gracefully."""
    try:
        try:
            from tflite_runtime.interpreter import Interpreter  # noqa: PLC0415
            interp = Interpreter(model_path=path)
        except ImportError:
            import tensorflow as tf  # noqa: PLC0415
            interp = tf.lite.Interpreter(model_path=path)
        interp.allocate_tensors()
        return interp
    except Exception as exc:
        print(f"WARNING: Could not load TFLite interpreter: {exc}", file=sys.stderr)
        return None


def _run_autoencoder(interp, X_scaled: np.ndarray) -> np.ndarray:
    """Run full autoencoder inference; return reconstructed output."""
    in_det = interp.get_input_details()
    out_det = interp.get_output_details()
    dtype = in_det[0]["dtype"]
    results = []
    for i in range(len(X_scaled)):
        arr = np.array([X_scaled[i]], dtype=dtype)
        interp.set_tensor(in_det[0]["index"], arr)
        interp.invoke()
        out = interp.get_tensor(out_det[0]["index"])
        results.append(out[0])
    return np.array(results, dtype=np.float32)


def _extract_latent_via_subgraph(interp, X_scaled: np.ndarray) -> np.ndarray | None:
    """Attempt to extract the bottleneck (latent) tensor from the TFLite graph.

    The autoencoder is 11->8->4->8->11.  The bottleneck is the tensor with
    shape (1, 4) produced by the second Dense layer.  We look for an
    intermediate output tensor of that shape.

    Returns:
        Latent representations shape (N, bottleneck_dim), or None if the
        bottleneck tensor cannot be identified.
    """
    try:
        tensor_details = interp.get_tensor_details()
        in_det = interp.get_input_details()
        out_det = interp.get_output_details()
        dtype = in_det[0]["dtype"]
        bottleneck_idx = None
        # Find a variable tensor with shape (1, 4) that is not input or output
        input_idx = in_det[0]["index"]
        output_idx = out_det[0]["index"]
        for td in tensor_details:
            shape = td.get("shape", [])
            if (
                len(shape) == 2
                and shape[0] == 1
                and shape[1] == 4
                and td["index"] != input_idx
                and td["index"] != output_idx
            ):
                bottleneck_idx = td["index"]
                break

        if bottleneck_idx is None:
            return None

        latents = []
        for i in range(len(X_scaled)):
            arr = np.array([X_scaled[i]], dtype=dtype)
            interp.set_tensor(input_idx, arr)
            interp.invoke()
            latent = interp.get_tensor(bottleneck_idx)
            latents.append(latent[0].copy())
        return np.array(latents, dtype=np.float32)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Scaler helpers
# ---------------------------------------------------------------------------

def _apply_scaler(X: np.ndarray, scaler: dict) -> np.ndarray:
    mean = np.array(scaler["mean"], dtype=np.float32)
    scale = np.array(scaler["scale"], dtype=np.float32)
    scale = np.where(scale > 1e-10, scale, 1.0)
    return ((X - mean) / scale).astype(np.float32)


# ---------------------------------------------------------------------------
# Manual PCA (numpy only)
# ---------------------------------------------------------------------------

def _pca_2d(Z: np.ndarray) -> tuple:
    """Project Z (N, D) to 2D via PCA using numpy eigenvectors.

    Returns:
        Z2: np.ndarray (N, 2) — 2D projections
        explained_variance: tuple (var_pc1, var_pc2) as fractions
    """
    # Center
    Z_mean = Z.mean(axis=0)
    Z_c = Z - Z_mean

    # Covariance matrix
    cov = np.cov(Z_c.T)  # shape (D, D)

    # Eigendecomposition
    eigenvalues, eigenvectors = np.linalg.eigh(cov)

    # Sort descending
    order = np.argsort(eigenvalues)[::-1]
    eigenvalues = eigenvalues[order]
    eigenvectors = eigenvectors[:, order]

    # Project to 2D
    W = eigenvectors[:, :2]  # (D, 2)
    Z2 = Z_c @ W             # (N, 2)

    total_var = eigenvalues.sum()
    ev1 = float(eigenvalues[0] / total_var) if total_var > 0 else 0.0
    ev2 = float(eigenvalues[1] / total_var) if total_var > 0 else 0.0

    return Z2, (ev1, ev2)


# ---------------------------------------------------------------------------
# Cluster separation metric
# ---------------------------------------------------------------------------

def _cluster_separation(Z2: np.ndarray, y: np.ndarray) -> float:
    """Compute inter-class / intra-class distance ratio.

    inter = mean pairwise distance between class centroids
    intra = mean within-class std (average over all classes and both axes)

    Higher ratio => better separation.
    """
    class_centroids = []
    intra_stds = []
    for cls_idx in range(len(CLASS_NAMES)):
        mask = y == cls_idx
        if mask.sum() == 0:
            continue
        pts = Z2[mask]
        centroid = pts.mean(axis=0)
        class_centroids.append(centroid)
        intra_stds.append(pts.std(axis=0).mean())

    if len(class_centroids) < 2:
        return 0.0

    # Inter: mean pairwise distance between centroids
    centroids = np.array(class_centroids)
    inter_dists = []
    for i in range(len(centroids)):
        for j in range(i + 1, len(centroids)):
            d = float(np.linalg.norm(centroids[i] - centroids[j]))
            inter_dists.append(d)
    inter_mean = float(np.mean(inter_dists)) if inter_dists else 0.0

    intra_mean = float(np.mean(intra_stds)) if intra_stds else 1e-10
    intra_mean = max(intra_mean, 1e-10)

    return inter_mean / intra_mean


# ---------------------------------------------------------------------------
# ASCII scatter plot
# ---------------------------------------------------------------------------

def _ascii_scatter(Z2: np.ndarray, y: np.ndarray, class_labels: list,
                   width: int = 70, height: int = 30) -> str:
    """Render a 2D ASCII scatter plot.

    Args:
        Z2: (N, 2) 2D projections
        y: (N,) int class indices
        class_labels: list of class name strings per sample
        width: plot character width (excluding axis)
        height: plot character height

    Returns:
        Multi-line string ready to print.
    """
    if len(Z2) == 0:
        return "(no data to plot)"

    x_vals = Z2[:, 0]
    y_vals = Z2[:, 1]

    x_min, x_max = float(x_vals.min()), float(x_vals.max())
    y_min, y_max = float(y_vals.min()), float(y_vals.max())

    # Add 5% padding
    x_pad = max((x_max - x_min) * 0.05, 1e-6)
    y_pad = max((y_max - y_min) * 0.05, 1e-6)
    x_min -= x_pad; x_max += x_pad
    y_min -= y_pad; y_max += y_pad

    x_range = x_max - x_min
    y_range = y_max - y_min

    # Build grid (row=0 is top)
    grid = [["." for _ in range(width)] for _ in range(height)]

    for i in range(len(Z2)):
        col = int((x_vals[i] - x_min) / x_range * (width - 1))
        row = int((1.0 - (y_vals[i] - y_min) / y_range) * (height - 1))
        col = max(0, min(width - 1, col))
        row = max(0, min(height - 1, row))
        cls_name = class_labels[i]
        marker = CLASS_MARKERS.get(cls_name, "?")
        grid[row][col] = marker

    lines = []
    lines.append(f"  PC2 ^")
    for row_idx, row in enumerate(grid):
        prefix = "  |  " if row_idx < height - 1 else "  |  "
        lines.append(prefix + "".join(row))
    lines.append("  +" + "-" * width + "> PC1")
    lines.append(f"  x=[{x_min:.3f}, {x_max:.3f}]  y=[{y_min:.3f}, {y_max:.3f}]")

    # Legend
    lines.append("")
    lines.append("  Legend:")
    for cls_name in CLASS_NAMES:
        marker = CLASS_MARKERS.get(cls_name, "?")
        lines.append(f"    [{marker}] {cls_name}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 1D proxy via reconstruction error
# ---------------------------------------------------------------------------

def _reconstruction_error_proxy(X_scaled: np.ndarray, reconstructed: np.ndarray,
                                 y: np.ndarray, class_labels: list) -> None:
    """Print 1D reconstruction error distribution per class as ASCII histogram."""
    errors = np.mean((X_scaled - reconstructed) ** 2, axis=1)

    print("  [PROXY MODE] Using reconstruction error as 1D proxy (encoder not extractable)")
    print()
    print(f"  Reconstruction error per class (MSE):")
    for cls_idx, cls_name in enumerate(CLASS_NAMES):
        mask = y == cls_idx
        if mask.sum() == 0:
            continue
        cls_errors = errors[mask]
        mean_e = float(cls_errors.mean())
        std_e = float(cls_errors.std())
        min_e = float(cls_errors.min())
        max_e = float(cls_errors.max())
        bar_width = int(mean_e / max(errors.max(), 1e-10) * 40)
        bar = "#" * bar_width
        marker = CLASS_MARKERS.get(cls_name, "?")
        print(f"    [{marker}] {cls_name:<22}  mean={mean_e:.4f}  "
              f"std={std_e:.4f}  [{min_e:.4f}, {max_e:.4f}]  {bar}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Visualize autoencoder latent space via PCA (ASCII scatter plot)."
    )
    parser.add_argument(
        "--csv", default=None, metavar="PATH",
        help="CSV file with features + label column. Uses synthetic data if not provided.",
    )
    parser.add_argument(
        "--n-samples", type=int, default=200, metavar="N",
        help="Samples per class when using synthetic data (default: 200).",
    )
    args = parser.parse_args()

    n_samples = max(1, args.n_samples)

    # ---- Load data ----
    if args.csv:
        if not os.path.isfile(args.csv):
            print(f"ERROR: CSV file not found: {args.csv}", file=sys.stderr)
            sys.exit(1)
        X_raw, y, class_labels = _load_csv(args.csv)
        if len(X_raw) == 0:
            print("ERROR: No labeled rows found in CSV.", file=sys.stderr)
            sys.exit(1)
        print(f"Loaded {len(X_raw)} samples from {args.csv}")
    else:
        print(f"Generating {n_samples} synthetic samples per class...")
        X_raw, y, class_labels = _generate_synthetic(n_samples)
        print(f"Total: {len(X_raw)} samples across {len(CLASS_NAMES)} classes")

    # ---- Load scaler ----
    scaler = None
    if os.path.isfile(ANOMALY_SCALER):
        with open(ANOMALY_SCALER) as f:
            scaler = json.load(f)
        print(f"Loaded scaler from {ANOMALY_SCALER}")
    else:
        print(f"WARNING: Scaler not found at {ANOMALY_SCALER}. Using per-data normalization.")

    if scaler is not None:
        # Only use the AE feature subset
        scaler_names = scaler.get("feature_names", AE_FEATURE_NAMES)
        # Re-order X_raw columns to match scaler feature order
        name_to_idx = {n: i for i, n in enumerate(AE_FEATURE_NAMES)}
        reordered = np.zeros((len(X_raw), len(scaler_names)), dtype=np.float32)
        for si, sname in enumerate(scaler_names):
            src_idx = name_to_idx.get(sname)
            if src_idx is not None and src_idx < X_raw.shape[1]:
                reordered[:, si] = X_raw[:, src_idx]
        X_scaled = _apply_scaler(reordered, scaler)
    else:
        # Normalize per feature using data statistics
        mean = X_raw.mean(axis=0)
        std = np.where(X_raw.std(axis=0) > 1e-10, X_raw.std(axis=0), 1.0)
        X_scaled = ((X_raw - mean) / std).astype(np.float32)

    print()
    print("=" * 72)
    print("AUTOENCODER LATENT SPACE VISUALIZATION")
    print("=" * 72)

    # ---- Load autoencoder ----
    interp = None
    if os.path.isfile(AUTOENCODER_TFLITE):
        print(f"Loading model: {AUTOENCODER_TFLITE}")
        interp = _load_interpreter(AUTOENCODER_TFLITE)
    else:
        print(f"WARNING: Autoencoder not found at {AUTOENCODER_TFLITE}")
        print("Run scripts/train_autoencoder.py first.")

    latent_extracted = False
    use_proxy = False

    if interp is not None:
        # Attempt to extract latent representations
        print("Attempting to extract encoder bottleneck from TFLite graph...")
        latent = _extract_latent_via_subgraph(interp, X_scaled)
        if latent is not None:
            print(f"Encoder bottleneck extracted. Shape: {latent.shape}")
            latent_extracted = True
        else:
            print("Could not extract encoder sub-model — falling back to reconstruction error proxy.")
            use_proxy = True

        # Run full autoencoder for reconstruction errors (needed for proxy or separation metric)
        print("Running full autoencoder inference...")
        reconstructed = _run_autoencoder(interp, X_scaled)
    else:
        # No model — synthesize latent space from normalized features as stand-in
        print("No model available. Using normalized features as latent space approximation.")
        latent = X_scaled
        latent_extracted = True
        reconstructed = X_scaled  # no reconstruction possible
        use_proxy = False

    print()

    if use_proxy and interp is not None:
        # 1D proxy mode
        _reconstruction_error_proxy(X_scaled, reconstructed, y, class_labels)
        print()
        print("NOTE: To enable full PCA visualization, the autoencoder must be saved")
        print("      with named intermediate outputs or as a Keras SavedModel.")
    else:
        # PCA mode
        Z = latent if latent_extracted else X_scaled
        print(f"Input to PCA: shape={Z.shape}")

        if Z.shape[1] < 2:
            print("ERROR: Latent dimension < 2; PCA cannot project to 2D.", file=sys.stderr)
            sys.exit(1)

        Z2, (ev1, ev2) = _pca_2d(Z)
        explained = (ev1 + ev2) * 100

        print(f"PCA explained variance: PC1={ev1 * 100:.1f}%  PC2={ev2 * 100:.1f}%  "
              f"total={explained:.1f}%")
        print()
        print("ASCII Scatter Plot (PCA 2D projection):")
        print()
        plot = _ascii_scatter(Z2, y, class_labels)
        print(plot)

    # ---- Cluster separation ----
    print()
    print("Cluster Separation Metric:")
    if latent_extracted and not use_proxy:
        Z_for_sep = Z2 if latent_extracted else X_scaled[:, :2]
        sep = _cluster_separation(Z_for_sep, y)
        print(f"  inter-class distance / intra-class std = {sep:.3f}")
        if sep >= 3.0:
            print("  Interpretation: GOOD separation (clusters are well-defined)")
        elif sep >= 1.5:
            print("  Interpretation: MODERATE separation (some overlap between classes)")
        else:
            print("  Interpretation: POOR separation (classes overlap heavily in latent space)")
    elif use_proxy and interp is not None:
        errors = np.mean((X_scaled - reconstructed) ** 2, axis=1)
        # Use reconstruction errors as 1D; inter = mean |centroid_i - centroid_j|
        centroids = []
        intra = []
        for cls_idx in range(len(CLASS_NAMES)):
            mask = y == cls_idx
            if mask.sum() == 0:
                continue
            cls_e = errors[mask]
            centroids.append(float(cls_e.mean()))
            intra.append(float(cls_e.std()))
        if len(centroids) > 1:
            inter_dists = [abs(centroids[i] - centroids[j])
                           for i in range(len(centroids))
                           for j in range(i + 1, len(centroids))]
            inter_mean = float(np.mean(inter_dists))
            intra_mean = max(float(np.mean(intra)), 1e-10)
            sep = inter_mean / intra_mean
            print(f"  (1D proxy) inter-class / intra-class = {sep:.3f}")
        else:
            print("  (1D proxy) Not enough classes to compute separation.")
    else:
        print("  (no model) Computed on normalized feature PCA:")
        Z2_feat, _ = _pca_2d(X_scaled)
        sep = _cluster_separation(Z2_feat, y)
        print(f"  feature-space inter/intra = {sep:.3f}")

    print()
    print("Done.")


if __name__ == "__main__":
    main()
