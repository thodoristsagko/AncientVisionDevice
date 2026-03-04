#!/usr/bin/env python3
"""
Lightweight HTTP server that serves TFLite model inference.
Useful for testing models without the full Flutter app.

Usage:
    python scripts/model_serve.py [--port 8766] [--assets-dir app/assets/ml]

    curl http://localhost:8766/health
    curl http://localhost:8766/features
    curl -X POST http://localhost:8766/predict \\
         -H "Content-Type: application/json" \\
         -d '{"rms": 0.5, "ppv": 0.12, "freq": 15.2, "crest": 3.1, "centroid": 20.0,
              "kurtosis": 3.0, "stalta": 1.5, "arias": 0.3, "cav": 1.2, "temp": 25.0,
              "psdSlope": -2.0, "ppv_trend": 0.01, "freq_trend": 0.0, "kurtosis_trend": 0.1,
              "stalta_trend": 0.05, "cusum_max": 0.5, "autoencoder_score": 0.02}'
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")
DEFAULT_PORT = 8766

CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]

# ---------------------------------------------------------------------------
# Model state — loaded once before the server starts
# ---------------------------------------------------------------------------

_state: dict = {
    "interpreter": None,
    "input_details": None,
    "output_details": None,
    "scaler_mean": None,
    "scaler_scale": None,
    "feature_names": None,
    "model_loaded": False,
    "load_error": None,
}


def _load_tflite(model_path: str):
    """Load a TFLite interpreter.  Prefers tflite_runtime, falls back to tensorflow."""
    try:
        from tflite_runtime.interpreter import Interpreter  # type: ignore
        interp = Interpreter(model_path=model_path, num_threads=1)
    except ImportError:
        import tensorflow as tf  # type: ignore  # noqa: PLC0415
        interp = tf.lite.Interpreter(model_path=model_path, num_threads=1)
    interp.allocate_tensors()
    return interp


def load_model(assets_dir: str) -> None:
    """Load TFLite model and scaler JSON from assets_dir into _state."""
    assets = Path(assets_dir)

    # Locate model file
    model_path = assets / "precursor_classifier.tflite"
    scaler_path = assets / "precursor_classifier_scaler.json"
    config_path = assets / "precursor_classifier_config.json"

    if not model_path.exists():
        _state["load_error"] = f"Model not found: {model_path}"
        print(f"[WARN] {_state['load_error']}", file=sys.stderr)
        return

    # Load scaler
    try:
        with open(scaler_path, encoding="utf-8") as f:
            scaler = json.load(f)
        _state["scaler_mean"] = scaler["mean"]
        _state["scaler_scale"] = scaler["scale"]
        _state["feature_names"] = scaler["feature_names"]
    except Exception as exc:
        _state["load_error"] = f"Failed to load scaler: {exc}"
        print(f"[WARN] {_state['load_error']}", file=sys.stderr)
        # Fallback: try config for feature_names
        if config_path.exists():
            try:
                with open(config_path, encoding="utf-8") as f:
                    cfg = json.load(f)
                _state["feature_names"] = cfg.get("feature_names", [])
            except Exception:
                pass
        return

    # Load TFLite interpreter
    try:
        interp = _load_tflite(str(model_path))
        _state["interpreter"] = interp
        _state["input_details"] = interp.get_input_details()
        _state["output_details"] = interp.get_output_details()
        _state["model_loaded"] = True
        print(f"[INFO] Model loaded: {model_path}", file=sys.stderr)
        print(f"[INFO] Features ({len(_state['feature_names'])}): {_state['feature_names']}", file=sys.stderr)
    except Exception as exc:
        _state["load_error"] = f"Failed to load TFLite interpreter: {exc}"
        print(f"[WARN] {_state['load_error']}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Inference helper
# ---------------------------------------------------------------------------

def _run_inference(features: list) -> tuple:
    """
    Normalize features with scaler and run TFLite inference.

    Returns (class_name: str, probabilities: dict, inference_ms: float)
    """
    import numpy as np  # type: ignore

    interp = _state["interpreter"]
    mean = _state["scaler_mean"]
    scale = _state["scaler_scale"]
    feature_names = _state["feature_names"]

    # Normalize
    normalized = [(v - m) / s for v, m, s in zip(features, mean, scale)]
    input_data = np.array([normalized], dtype=np.float32)

    # Inference
    t0 = time.perf_counter()
    input_details = _state["input_details"]
    output_details = _state["output_details"]
    interp.set_tensor(input_details[0]["index"], input_data)
    interp.invoke()
    output = interp.get_tensor(output_details[0]["index"])[0]
    elapsed_ms = (time.perf_counter() - t0) * 1000.0

    probs = {name: float(p) for name, p in zip(CLASS_NAMES, output)}
    predicted_class = CLASS_NAMES[int(output.argmax())]
    return predicted_class, probs, elapsed_ms


# ---------------------------------------------------------------------------
# Flask app factory
# ---------------------------------------------------------------------------

def create_app():
    try:
        from flask import Flask, jsonify, request  # type: ignore
    except ImportError:
        print("[ERROR] Flask is not installed. Run: pip install flask", file=sys.stderr)
        sys.exit(1)

    app = Flask(__name__)

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({
            "status": "ok",
            "model_loaded": _state["model_loaded"],
            "load_error": _state["load_error"],
        })

    @app.route("/features", methods=["GET"])
    def features():
        names = _state.get("feature_names") or []
        return jsonify({
            "feature_names": names,
            "count": len(names),
        })

    @app.route("/predict", methods=["POST"])
    def predict():
        if not _state["model_loaded"]:
            return jsonify({
                "error": "Model not loaded",
                "detail": _state["load_error"] or "Unknown error",
            }), 503

        feature_names = _state["feature_names"]

        # Parse JSON body
        body = request.get_json(silent=True)
        if body is None:
            return jsonify({"error": "Invalid JSON body"}), 400

        # Validate all required features are present
        missing = [f for f in feature_names if f not in body]
        if missing:
            return jsonify({
                "error": "Missing features",
                "missing": missing,
                "required": feature_names,
            }), 400

        # Extract feature vector in correct order
        try:
            feature_vector = [float(body[f]) for f in feature_names]
        except (ValueError, TypeError) as exc:
            return jsonify({"error": f"Invalid feature value: {exc}"}), 400

        # Run inference
        try:
            class_name, probabilities, inference_ms = _run_inference(feature_vector)
        except Exception as exc:
            return jsonify({"error": f"Inference failed: {exc}"}), 500

        return jsonify({
            "class": class_name,
            "probabilities": probabilities,
            "inference_ms": round(inference_ms, 3),
        })

    return app


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Lightweight HTTP model inference server for AncientVision precursor classifier."
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"HTTP port to listen on (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--assets-dir",
        default=DEFAULT_ASSETS_DIR,
        help=f"Directory containing TFLite model and scaler JSON (default: {DEFAULT_ASSETS_DIR})",
    )
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="Host to bind to (default: 0.0.0.0)",
    )
    args = parser.parse_args(argv)

    # Load model before starting server (fails gracefully — /health reports degraded)
    load_model(args.assets_dir)

    app = create_app()

    print(f"[INFO] Starting model inference server on {args.host}:{args.port}", file=sys.stderr)
    print(f"[INFO] POST /predict  — run inference", file=sys.stderr)
    print(f"[INFO] GET  /health   — server + model status", file=sys.stderr)
    print(f"[INFO] GET  /features — list expected feature names", file=sys.stderr)

    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
