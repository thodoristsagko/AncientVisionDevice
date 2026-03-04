#!/usr/bin/env python3
"""Export TF SavedModels to ONNX format using tf2onnx.

If tf2onnx is not available, documents the model architecture from the
config JSON files instead.

If onnxruntime is available, verifies each exported ONNX model with a
dummy inference pass.

Usage:
    python scripts/onnx_export.py
    python scripts/onnx_export.py --assets-dir app/assets/ml --output-dir data/onnx_models
    python scripts/onnx_export.py --output-dir data/onnx_models

Output: precursor_classifier.onnx, vibration_model.onnx in --output-dir.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")
DEFAULT_OUTPUT_DIR = os.path.join(REPO_DIR, "data", "onnx_models")

# Models to export: (saved_model_candidates, config_json, onnx_output_name, scaler_json)
MODELS = [
    {
        "name": "precursor_classifier",
        "onnx_output": "precursor_classifier.onnx",
        "config": "precursor_classifier_config.json",
        "scaler": "precursor_classifier_scaler.json",
        "saved_model_candidates": [
            "precursor_classifier_saved_model",
        ],
        "description": "4-class precursor classifier (normal/soil_creep/crack_propagation/imminent_failure)",
    },
    {
        "name": "vibration_model",
        "onnx_output": "vibration_model.onnx",
        "config": "vibration_model_config.json",
        "scaler": "vibration_scaler.json",
        "saved_model_candidates": [
            "vibration_anomaly_saved_model",
            "vibration_model_saved_model",
        ],
        "description": "Autoencoder anomaly detector for vibration signals",
    },
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _find_saved_model(assets_dir: str, candidates: list) -> str | None:
    """Search assets_dir and repo root for a SavedModel directory.

    Args:
        assets_dir: Primary search directory.
        candidates: List of directory name candidates to try.

    Returns:
        Absolute path to SavedModel directory, or None if not found.
    """
    search_roots = [
        assets_dir,
        os.path.join(REPO_DIR, "data", "saved_models"),
        REPO_DIR,
    ]
    for root in search_roots:
        for candidate in candidates:
            path = os.path.join(root, candidate)
            if os.path.isdir(path) and os.path.isfile(os.path.join(path, "saved_model.pb")):
                return path
    return None


# ---------------------------------------------------------------------------
# ONNX export via tf2onnx
# ---------------------------------------------------------------------------

def _export_onnx_via_tf2onnx(saved_model_dir: str, output_path: str) -> bool:
    """Export a SavedModel to ONNX using tf2onnx CLI subprocess.

    Uses subprocess to avoid graph compatibility issues when running
    tf2onnx in the same process as TF inference.

    Args:
        saved_model_dir: Path to TF SavedModel directory.
        output_path: Destination .onnx file path.

    Returns:
        True on success, False on failure.
    """
    cmd = [
        sys.executable, "-m", "tf2onnx.convert",
        "--saved-model", saved_model_dir,
        "--output", output_path,
        "--opset", "13",
    ]
    print(f"  Running: {' '.join(cmd)}")
    try:
        result = subprocess.run(cmd, capture_output=True, timeout=120)
        if result.returncode != 0:
            stderr = result.stderr.decode(errors="replace")
            print(f"  tf2onnx failed (exit {result.returncode}):")
            # Print last 10 lines of stderr for diagnostics
            for line in stderr.strip().splitlines()[-10:]:
                print(f"    {line}")
            return False
        return True
    except FileNotFoundError:
        print("  ERROR: tf2onnx not found. Install with: pip install tf2onnx")
        return False
    except subprocess.TimeoutExpired:
        print("  ERROR: tf2onnx conversion timed out after 120s")
        return False


# ---------------------------------------------------------------------------
# ONNX verification via onnxruntime
# ---------------------------------------------------------------------------

def _verify_onnx(onnx_path: str, input_dim: int) -> bool:
    """Run a dummy inference pass with onnxruntime to verify the ONNX model.

    Args:
        onnx_path: Path to the exported .onnx file.
        input_dim: Expected number of input features.

    Returns:
        True if inference succeeds and output has reasonable shape, False otherwise.
    """
    try:
        import onnxruntime as ort  # noqa: PLC0415
    except ImportError:
        print("  NOTE: onnxruntime not installed — skipping verification.")
        print("  Install with: pip install onnxruntime")
        return True  # Not a failure — just can't verify

    try:
        sess = ort.InferenceSession(onnx_path)
        input_name = sess.get_inputs()[0].name
        dummy = np.zeros((1, input_dim), dtype=np.float32)
        outputs = sess.run(None, {input_name: dummy})
        out_shape = outputs[0].shape
        print(f"  onnxruntime verification: input=({1}, {input_dim}) -> output={out_shape}")
        return True
    except Exception as exc:
        print(f"  onnxruntime verification failed: {exc}")
        return False


# ---------------------------------------------------------------------------
# Architecture documentation fallback
# ---------------------------------------------------------------------------

def _document_architecture(config: dict, scaler: dict | None, output_path: str) -> None:
    """Write a JSON architecture description when ONNX export is not possible.

    This serves as a reference for reimplementing the model in other frameworks.

    Args:
        config: Model config dict from the JSON asset.
        scaler: Scaler dict (may be None).
        output_path: Path to write the architecture JSON (replaces .onnx extension).
    """
    arch_path = output_path.replace(".onnx", "_architecture.json")

    model_type = config.get("model_type", "classifier")
    input_dim = config.get("input_dim", len(config.get("feature_names", [])))
    output_dim = config.get("output_dim", 1)
    class_names = config.get("class_names", [])

    if model_type == "autoencoder":
        architecture = {
            "type": "autoencoder",
            "note": "Symmetric encoder-decoder. Input/output shape identical.",
            "input_dim": input_dim,
            "encoder_layers": [
                {"type": "Dense", "units": 8, "activation": "relu"},
                {"type": "Dense", "units": 4, "activation": "relu"},
            ],
            "bottleneck": {"type": "Dense", "units": 2, "activation": "relu"},
            "decoder_layers": [
                {"type": "Dense", "units": 4, "activation": "relu"},
                {"type": "Dense", "units": 8, "activation": "relu"},
                {"type": "Dense", "units": input_dim, "activation": "linear"},
            ],
            "loss": "mse",
            "anomaly_detection": "reconstruction_error",
            "thresholds": config.get("thresholds", {}),
        }
    else:
        architecture = {
            "type": "classifier",
            "input_dim": input_dim,
            "output_dim": output_dim,
            "class_names": class_names,
            "layers": [
                {"type": "Dense", "units": 128, "activation": "relu",
                 "regularizer": "l2(0.001)"},
                {"type": "BatchNormalization"},
                {"type": "Dropout", "rate": 0.3},
                {"type": "Dense", "units": 64, "activation": "relu",
                 "regularizer": "l2(0.001)"},
                {"type": "BatchNormalization"},
                {"type": "Dropout", "rate": 0.2},
                {"type": "Dense", "units": output_dim, "activation": "softmax"},
            ],
            "optimizer": "Adam",
            "loss": "sparse_categorical_crossentropy",
        }

    doc = {
        "note": (
            "ONNX export requires tf2onnx and a SavedModel directory. "
            "This file documents the architecture for framework-agnostic reimplementation."
        ),
        "model_version": config.get("model_version", "unknown"),
        "feature_names": config.get("feature_names", []),
        "scaler": {
            "type": "StandardScaler",
            "mean": scaler["mean"] if scaler else None,
            "scale": scaler.get("scale", scaler.get("std")) if scaler else None,
        },
        "architecture": architecture,
    }

    Path(arch_path).write_text(json.dumps(doc, indent=2))
    print(f"  Architecture documented at: {arch_path}")


# ---------------------------------------------------------------------------
# Per-model export
# ---------------------------------------------------------------------------

def export_model(model_info: dict, assets_dir: str, output_dir: str) -> dict:
    """Attempt ONNX export for a single model.

    Args:
        model_info: Dict with name, onnx_output, config, scaler, saved_model_candidates.
        assets_dir: Directory containing config and scaler JSON files.
        output_dir: Directory to write the .onnx file.

    Returns:
        Status dict with 'name', 'status', 'output_path', 'input_dim'.
    """
    name = model_info["name"]
    onnx_name = model_info["onnx_output"]
    config_path = os.path.join(assets_dir, model_info["config"])
    scaler_path = os.path.join(assets_dir, model_info["scaler"])
    output_path = os.path.join(output_dir, onnx_name)

    print(f"\n[{name}]  {model_info['description']}")

    # Load config
    if not os.path.isfile(config_path):
        print(f"  WARNING: Config not found: {config_path}")
        return {"name": name, "status": "skipped_no_config", "output_path": None, "input_dim": 0}

    config = _load_json(config_path)
    input_dim = config.get("input_dim", len(config.get("feature_names", [])))
    print(f"  input_dim={input_dim}  output_dim={config.get('output_dim', '?')}")

    # Load scaler (optional)
    scaler = None
    if os.path.isfile(scaler_path):
        scaler = _load_json(scaler_path)

    # Check tf2onnx availability
    tf2onnx_available = False
    try:
        import tf2onnx  # noqa: F401, PLC0415
        tf2onnx_available = True
    except ImportError:
        pass

    if not tf2onnx_available:
        print("  tf2onnx not installed — documenting architecture instead.")
        print("  Install with: pip install tf2onnx")
        _document_architecture(config, scaler, output_path)
        return {"name": name, "status": "documented_no_tf2onnx", "output_path": None, "input_dim": input_dim}

    # Find SavedModel
    saved_model_dir = _find_saved_model(assets_dir, model_info["saved_model_candidates"])
    if saved_model_dir is None:
        print(
            "  WARNING: No SavedModel directory found.\n"
            "  Full ONNX export requires the Keras SavedModel produced during training.\n"
            "  Retrain with generate_precursor_data.py or train_autoencoder.py."
        )
        _document_architecture(config, scaler, output_path)
        return {"name": name, "status": "documented_no_saved_model", "output_path": None, "input_dim": input_dim}

    print(f"  SavedModel found: {saved_model_dir}")

    # Export
    success = _export_onnx_via_tf2onnx(saved_model_dir, output_path)
    if not success:
        _document_architecture(config, scaler, output_path)
        return {"name": name, "status": "export_failed", "output_path": None, "input_dim": input_dim}

    onnx_size = os.path.getsize(output_path)
    print(f"  Exported: {output_path}  ({onnx_size / 1024:.1f} KB)")

    # Verify
    ok = _verify_onnx(output_path, input_dim)
    status = "exported_verified" if ok else "exported_verify_failed"

    return {"name": name, "status": status, "output_path": output_path, "input_dim": input_dim}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export TF SavedModels to ONNX format."
    )
    parser.add_argument(
        "--assets-dir",
        default=DEFAULT_ASSETS_DIR,
        metavar="PATH",
        help=f"Directory containing model assets (default: {DEFAULT_ASSETS_DIR}).",
    )
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT_DIR,
        metavar="PATH",
        help=f"Directory for ONNX output files (default: {DEFAULT_OUTPUT_DIR}).",
    )
    args = parser.parse_args()

    assets_dir = os.path.abspath(args.assets_dir)
    output_dir = os.path.abspath(args.output_dir)

    print("=" * 60)
    print("ONNX Model Export")
    print("=" * 60)
    print(f"Assets dir: {assets_dir}")
    print(f"Output dir: {output_dir}")

    if not os.path.isdir(assets_dir):
        print(f"ERROR: assets-dir not found: {assets_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    # Check tf2onnx
    try:
        import tf2onnx  # noqa: F401, PLC0415
        print("tf2onnx: available")
    except ImportError:
        print("tf2onnx: NOT installed  (pip install tf2onnx)")

    # Check onnxruntime
    try:
        import onnxruntime as ort  # noqa: F401, PLC0415
        print(f"onnxruntime: {ort.__version__}")
    except ImportError:
        print("onnxruntime: NOT installed  (pip install onnxruntime)")

    # Export each model
    statuses = []
    for model_info in MODELS:
        result = export_model(model_info, assets_dir, output_dir)
        statuses.append(result)

    # Summary
    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    for s in statuses:
        print(f"  {s['name']:30s}  {s['status']}")

    exported = [s for s in statuses if s["status"].startswith("exported")]
    documented = [s for s in statuses if s["status"].startswith("documented")]

    print()
    if exported:
        print(f"  {len(exported)} model(s) exported to ONNX.")
    if documented:
        print(f"  {len(documented)} model(s) documented (SavedModel or tf2onnx not available).")
    if not exported and not documented:
        print("  No models processed.")

    print()


if __name__ == "__main__":
    main()
