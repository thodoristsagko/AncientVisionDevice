#!/usr/bin/env python3
"""Post-training INT8 quantization for TFLite models.

Produces *_int8.tflite files alongside originals.
If a SavedModel directory is found next to the .tflite file, full INT8
quantization is performed. Otherwise the original .tflite is copied and a
note is printed explaining that full quantization requires the Keras SavedModel.

Usage:
    python scripts/quantize_models.py
    python scripts/quantize_models.py --assets-dir app/assets/ml
    python scripts/quantize_models.py --assets-dir app/assets/ml --n-calibration 200
"""

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

# Models to quantize: (tflite_name, scaler_name, config_name)
MODELS = [
    (
        "precursor_classifier.tflite",
        "precursor_classifier_scaler.json",
        "precursor_classifier_config.json",
    ),
    (
        "vibration_anomaly.tflite",
        "vibration_scaler.json",
        "vibration_model_config.json",
    ),
]


# ---------------------------------------------------------------------------
# Representative dataset generator
# ---------------------------------------------------------------------------

def representative_dataset_gen(scaler_path: str, n_samples: int = 200):
    """Generator yielding synthetic samples for INT8 calibration.

    Generates samples drawn from N(mean, std) per feature using the scaler
    parameters so the quantization range is representative of real inputs.

    Args:
        scaler_path: Path to scaler JSON with 'mean' and 'scale' (or 'std') keys.
        n_samples: Number of calibration samples to generate.

    Yields:
        List containing a single float32 array of shape (1, n_features).
    """
    with open(scaler_path) as f:
        scaler = json.load(f)

    means = np.array(scaler["mean"], dtype=np.float32)
    # Scaler JSON may use 'scale' or 'std' as the key name.
    stds = np.array(
        scaler.get("scale", scaler.get("std", [1.0] * len(means))),
        dtype=np.float32,
    )
    stds = np.where(stds < 1e-10, 1.0, stds)

    rng = np.random.default_rng(seed=42)
    for _ in range(n_samples):
        sample = (rng.standard_normal(len(means)).astype(np.float32) * stds + means)
        yield [sample.reshape(1, -1)]


# ---------------------------------------------------------------------------
# Quantization
# ---------------------------------------------------------------------------

def _stem(name: str) -> str:
    """Return filename without extension."""
    return name.rsplit(".", 1)[0]


def _find_saved_model(assets_dir: str, tflite_name: str) -> str | None:
    """Look for a SavedModel directory alongside the .tflite file.

    Checks for <stem>_saved_model/ and saved_model/<stem>/ conventions.
    Returns the directory path if found, else None.
    """
    stem = _stem(tflite_name)
    candidates = [
        os.path.join(assets_dir, f"{stem}_saved_model"),
        os.path.join(REPO_DIR, "data", "saved_models", stem),
        os.path.join(REPO_DIR, f"{stem}_saved_model"),
    ]
    for path in candidates:
        if os.path.isdir(path) and os.path.isfile(
            os.path.join(path, "saved_model.pb")
        ):
            return path
    return None


def quantize(
    assets_dir: str,
    tflite_name: str,
    scaler_name: str,
    n_calibration: int = 200,
) -> None:
    """Quantize a single model to INT8 TFLite.

    Steps:
    1. Try to locate a SavedModel directory for full INT8 quantization.
    2. If found: convert via TFLiteConverter from SavedModel + representative dataset.
    3. If not found: copy the float32 .tflite and log a note.

    Args:
        assets_dir: Directory containing .tflite and scaler JSON files.
        tflite_name: Filename of the float32 TFLite model.
        scaler_name: Filename of the scaler JSON.
        n_calibration: Number of calibration samples for representative dataset.
    """
    tflite_path = os.path.join(assets_dir, tflite_name)
    scaler_path = os.path.join(assets_dir, scaler_name)
    stem = _stem(tflite_name)
    output_name = f"{stem}_int8.tflite"
    output_path = os.path.join(assets_dir, output_name)

    print(f"\nQuantizing: {tflite_name}")

    if not os.path.isfile(tflite_path):
        print(f"  WARNING: {tflite_path} not found — skipping.")
        return

    if not os.path.isfile(scaler_path):
        print(f"  WARNING: {scaler_path} not found — using uniform calibration.")
        scaler_path = None

    orig_size = os.path.getsize(tflite_path)

    # --- Attempt full INT8 quantization via SavedModel ---
    saved_model_dir = _find_saved_model(assets_dir, tflite_name)

    if saved_model_dir is not None:
        print(f"  Found SavedModel at: {saved_model_dir}")
        try:
            import tensorflow as tf  # noqa: PLC0415

            converter = tf.lite.TFLiteConverter.from_saved_model(saved_model_dir)
            converter.optimizations = [tf.lite.Optimize.DEFAULT]
            converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
            converter.inference_input_type = tf.int8
            converter.inference_output_type = tf.int8

            if scaler_path:
                converter.representative_dataset = lambda: representative_dataset_gen(
                    scaler_path, n_samples=n_calibration
                )
            else:
                # Fallback: uniform calibration with zero-mean unit-variance samples
                def _uniform_gen():
                    rng = np.random.default_rng(seed=42)
                    for _ in range(n_calibration):
                        sample = rng.standard_normal((1, 17)).astype(np.float32)
                        yield [sample]
                converter.representative_dataset = _uniform_gen

            tflite_quant = converter.convert()
            Path(output_path).write_bytes(tflite_quant)
            quant_size = len(tflite_quant)
            reduction_pct = 100.0 * (1.0 - quant_size / orig_size)
            print(f"  Full INT8 quantization successful.")
            print(
                f"  Original: {orig_size / 1024:.1f} KB  ->  "
                f"INT8: {quant_size / 1024:.1f} KB  "
                f"({reduction_pct:.0f}% reduction)"
            )
            print(f"  Output: {output_path}")
            return

        except ImportError:
            print("  WARNING: TensorFlow not available. Falling back to copy mode.")
        except Exception as exc:
            print(f"  WARNING: Full INT8 quantization failed ({exc}). Falling back to copy mode.")

    # --- Fallback: copy original and report size ---
    print(
        "  NOTE: No SavedModel directory found alongside the .tflite file.\n"
        "  Full INT8 quantization requires the original Keras SavedModel.\n"
        "  To generate it, retrain with generate_precursor_data.py or\n"
        "  train_autoencoder.py — both export a SavedModel alongside the .tflite.\n"
        "  Copying float32 model as placeholder."
    )
    shutil.copy2(tflite_path, output_path)
    quant_size = os.path.getsize(output_path)
    # Float copy won't be smaller; report 0% reduction.
    print(
        f"  Original (float32): {orig_size / 1024:.1f} KB  ->  "
        f"Copy: {quant_size / 1024:.1f} KB  (0% reduction — float32 copy)"
    )
    print(f"  Output: {output_path}")


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def verify_tflite(path: str) -> bool:
    """Load the INT8 TFLite and allocate tensors to confirm it is valid.

    Args:
        path: Path to the .tflite file.

    Returns:
        True if the file loads and allocates tensors successfully, False otherwise.
    """
    try:
        try:
            from tflite_runtime.interpreter import Interpreter  # noqa: PLC0415
            interp = Interpreter(model_path=path)
        except ImportError:
            import tensorflow as tf  # noqa: PLC0415
            interp = tf.lite.Interpreter(model_path=path)
        interp.allocate_tensors()
        return True
    except Exception as exc:
        print(f"  Verification failed: {exc}")
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="INT8 post-training quantization for TFLite models."
    )
    parser.add_argument(
        "--assets-dir",
        default=DEFAULT_ASSETS_DIR,
        metavar="PATH",
        help=f"Directory containing .tflite and scaler JSON files (default: {DEFAULT_ASSETS_DIR}).",
    )
    parser.add_argument(
        "--n-calibration",
        type=int,
        default=200,
        metavar="N",
        help="Number of synthetic calibration samples (default: 200).",
    )
    args = parser.parse_args()

    assets_dir = os.path.abspath(args.assets_dir)
    if not os.path.isdir(assets_dir):
        print(f"ERROR: assets-dir not found: {assets_dir}", file=sys.stderr)
        sys.exit(1)

    print("=" * 60)
    print("INT8 Post-Training Quantization")
    print("=" * 60)
    print(f"Assets dir:           {assets_dir}")
    print(f"Calibration samples:  {args.n_calibration}")

    any_done = False
    for tflite_name, scaler_name, _ in MODELS:
        tflite_path = os.path.join(assets_dir, tflite_name)
        if not os.path.isfile(tflite_path):
            print(f"\nSkipping {tflite_name} (not found in {assets_dir})")
            continue
        quantize(assets_dir, tflite_name, scaler_name, n_calibration=args.n_calibration)
        any_done = True

    if not any_done:
        print("\nNo models found to quantize. Train models first.")
        sys.exit(0)

    print("\n" + "=" * 60)
    print("Verifying INT8 outputs...")
    print("=" * 60)
    all_ok = True
    for tflite_name, _, _ in MODELS:
        stem = _stem(tflite_name)
        out_path = os.path.join(assets_dir, f"{stem}_int8.tflite")
        if not os.path.isfile(out_path):
            continue
        ok = verify_tflite(out_path)
        status = "OK" if ok else "FAILED"
        print(f"  {os.path.basename(out_path)}: {status}")
        if not ok:
            all_ok = False

    if all_ok:
        print("\nAll INT8 models verified successfully.")
    else:
        print("\nWARNING: Some verifications failed.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
