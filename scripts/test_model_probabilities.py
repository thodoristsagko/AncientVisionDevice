"""Test that TFLite model output probabilities sum to approximately 1.0."""
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# P90: Precursor classifier softmax output must sum to ~1.0
# ---------------------------------------------------------------------------

REPO_DIR = Path(__file__).parent.parent
ASSETS = REPO_DIR / "app" / "assets" / "ml"


def _get_tflite():
    """Return a tflite module (tflite_runtime or tf.lite) or skip if unavailable."""
    try:
        import tflite_runtime.interpreter as tflite
        return tflite
    except ImportError:
        pass
    try:
        import tensorflow as tf
        return tf.lite
    except ImportError:
        pytest.skip("TFLite not available (no tflite_runtime or tensorflow installed)")


def test_precursor_probs_sum_to_one():
    """Precursor classifier softmax output should sum to ~1.0."""
    tflite = _get_tflite()
    import numpy as np

    model_path = ASSETS / "precursor_classifier.tflite"
    if not model_path.exists():
        pytest.skip(f"Model not found: {model_path}")

    interp = tflite.Interpreter(str(model_path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    # Run with random inputs (shape from model metadata)
    data = np.random.randn(*inp["shape"]).astype(np.float32)
    interp.set_tensor(inp["index"], data)
    interp.invoke()
    probs = interp.get_tensor(out["index"])[0]

    assert abs(probs.sum() - 1.0) < 0.01, (
        f"Probabilities sum to {probs.sum():.6f}, expected ~1.0"
    )
    assert all(p >= 0 for p in probs), "All probabilities should be non-negative"
    assert len(probs) == 4, (
        f"Expected 4 output classes (normal/soil_creep/crack_propagation/imminent_failure), "
        f"got {len(probs)}"
    )


def test_precursor_probs_argmax_is_valid_class():
    """The predicted class index must be in range [0, num_classes)."""
    tflite = _get_tflite()
    import numpy as np

    model_path = ASSETS / "precursor_classifier.tflite"
    if not model_path.exists():
        pytest.skip(f"Model not found: {model_path}")

    interp = tflite.Interpreter(str(model_path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    # Run 5 random inputs — all should produce a valid class index
    for _ in range(5):
        data = np.random.randn(*inp["shape"]).astype(np.float32)
        interp.set_tensor(inp["index"], data)
        interp.invoke()
        probs = interp.get_tensor(out["index"])[0]
        best = int(np.argmax(probs))
        assert 0 <= best < len(probs), f"argmax class index {best} out of range"


def test_vibration_anomaly_model_produces_output():
    """Vibration anomaly autoencoder should produce a reconstruction output."""
    tflite = _get_tflite()
    import numpy as np

    model_path = ASSETS / "vibration_anomaly.tflite"
    if not model_path.exists():
        pytest.skip(f"Model not found: {model_path}")

    interp = tflite.Interpreter(str(model_path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    data = np.random.randn(*inp["shape"]).astype(np.float32)
    interp.set_tensor(inp["index"], data)
    interp.invoke()
    output = interp.get_tensor(out["index"])

    assert output is not None
    assert tuple(output.shape) == tuple(inp["shape"]), (
        f"Autoencoder input shape {inp['shape']} != output shape {output.shape}"
    )
    # Reconstruction error should be finite
    mse = float(np.mean((output - data) ** 2))
    assert mse == mse, "MSE is NaN"  # NaN != NaN
    assert mse >= 0.0, f"MSE should be non-negative, got {mse}"
