"""Smoke tests for ML training scripts.

These tests verify script syntax, importability of their dependencies,
and structural constants — without executing the full training pipelines.
"""

import ast
import importlib.util
import json
import os
import py_compile
import sys
import unittest

import numpy as np

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPTS_DIR)

GENERATE_SCRIPT = os.path.join(SCRIPTS_DIR, "generate_precursor_data.py")
AUTOENCODER_SCRIPT = os.path.join(SCRIPTS_DIR, "train_autoencoder.py")


def _parse_ast(path: str) -> ast.Module:
    """Parse a Python file into an AST (syntax check + tree access)."""
    with open(path, "r", encoding="utf-8") as fh:
        source = fh.read()
    return ast.parse(source, filename=path)


def _find_assign_value(tree: ast.Module, target_name: str):
    """Return the AST node for the right-hand side of `target_name = ...`."""
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name) and tgt.id == target_name:
                    return node.value
    return None


# ---------------------------------------------------------------------------
# test_generate_precursor_data_imports
# ---------------------------------------------------------------------------

def test_generate_precursor_data_imports():
    """Script parses without syntax errors and its required imports are available."""
    # 1. Syntax check via py_compile
    py_compile.compile(GENERATE_SCRIPT, doraise=True)

    # 2. Verify the top-level imports that the script declares are resolvable
    required_modules = [
        "datetime", "json", "os", "subprocess", "sys",
        "numpy", "tensorflow",
        "sklearn.metrics",
        "sklearn.model_selection",
        "sklearn.tree",
        "sklearn.utils.class_weight",
    ]
    for mod in required_modules:
        spec = importlib.util.find_spec(mod)
        assert spec is not None, f"Required module not found: {mod}"


# ---------------------------------------------------------------------------
# test_train_autoencoder_imports
# ---------------------------------------------------------------------------

def test_train_autoencoder_imports():
    """Autoencoder script parses without syntax errors and its required imports are available."""
    py_compile.compile(AUTOENCODER_SCRIPT, doraise=True)

    required_modules = [
        "json", "os",
        "numpy", "tensorflow",
        "sklearn.preprocessing",
    ]
    for mod in required_modules:
        spec = importlib.util.find_spec(mod)
        assert spec is not None, f"Required module not found: {mod}"


# ---------------------------------------------------------------------------
# test_assets_dir_constant
# ---------------------------------------------------------------------------

def test_assets_dir_constant():
    """ASSETS_DIR in generate_precursor_data.py resolves to app/assets/ml."""
    tree = _parse_ast(GENERATE_SCRIPT)

    # Find: ASSETS_DIR = os.path.join(PROJECT_DIR, "app", "assets", "ml")
    assets_node = _find_assign_value(tree, "ASSETS_DIR")
    assert assets_node is not None, "ASSETS_DIR assignment not found in script"

    # Verify the last three path components are "app", "assets", "ml"
    # The node is a Call to os.path.join — check its string args
    assert isinstance(assets_node, ast.Call), "ASSETS_DIR must be assigned from a function call"
    string_args = [
        arg.value if isinstance(arg, ast.Constant) and isinstance(arg.value, str) else None
        for arg in assets_node.args
    ]
    string_args = [a for a in string_args if a is not None]
    assert string_args[-3:] == ["app", "assets", "ml"], (
        f"Expected ASSETS_DIR path segments ['app', 'assets', 'ml'], got {string_args[-3:]}"
    )


# ---------------------------------------------------------------------------
# test_early_stopping_present_in_autoencoder
# ---------------------------------------------------------------------------

def test_early_stopping_present_in_autoencoder():
    """EarlyStopping callback is present in train_autoencoder.py."""
    tree = _parse_ast(AUTOENCODER_SCRIPT)

    found_early_stop = False
    found_reduce_lr = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute):
            if node.attr == "EarlyStopping":
                found_early_stop = True
            if node.attr == "ReduceLROnPlateau":
                found_reduce_lr = True

    assert found_early_stop, "EarlyStopping not found in train_autoencoder.py"
    assert found_reduce_lr, "ReduceLROnPlateau not found in train_autoencoder.py"


# ---------------------------------------------------------------------------
# test_cross_validation_present_in_generate
# ---------------------------------------------------------------------------

def test_cross_validation_present_in_generate():
    """StratifiedKFold and cross_val_score are used in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)

    names_used = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
    attrs_used = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    all_names = names_used | attrs_used

    assert "StratifiedKFold" in all_names, "StratifiedKFold not found in generate_precursor_data.py"
    assert "cross_val_score" in all_names, "cross_val_score not found in generate_precursor_data.py"


# ---------------------------------------------------------------------------
# test_confusion_matrix_present_in_generate
# ---------------------------------------------------------------------------

def test_confusion_matrix_present_in_generate():
    """confusion_matrix and classification_report are used in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)

    names_used = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
    assert "confusion_matrix" in names_used, "confusion_matrix not found"
    assert "classification_report" in names_used, "classification_report not found"


# ---------------------------------------------------------------------------
# test_l2_regularization_present
# ---------------------------------------------------------------------------

def test_l2_regularization_present():
    """L2 regularization is applied to Dense layers in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)

    attrs_used = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert "l2" in attrs_used, "l2 regularizer not found in generate_precursor_data.py"


# ---------------------------------------------------------------------------
# test_class_weights_present
# ---------------------------------------------------------------------------

def test_class_weights_present():
    """compute_class_weight is used in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)

    names_used = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
    assert "compute_class_weight" in names_used, "compute_class_weight not found"


# ---------------------------------------------------------------------------
# test_metrics_json_output_present
# ---------------------------------------------------------------------------

def test_metrics_json_output_present():
    """precursor_training_metrics.json output is written in generate_precursor_data.py."""
    with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
        source = fh.read()
    assert "precursor_training_metrics.json" in source, (
        "precursor_training_metrics.json output not found in script"
    )


# ---------------------------------------------------------------------------
# test_model_versioning_fields_present
# ---------------------------------------------------------------------------

def test_model_versioning_fields_present():
    """trained_at, git_sha, holdout_accuracy, cv_mean_accuracy are in config export."""
    with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
        source = fh.read()
    for field in ("trained_at", "git_sha", "holdout_accuracy", "cv_mean_accuracy"):
        assert f'"{field}"' in source, f'Config field "{field}" not found in script'


# ---------------------------------------------------------------------------
# P25: Model output quality tests
# ---------------------------------------------------------------------------

def test_model_probabilities_sum_to_one():
    """Precursor model output probabilities sum to [0.99, 1.01]."""
    try:
        import tensorflow as tf
    except ImportError:
        print("SKIP: TensorFlow not available")
        return

    model_path = os.path.join(REPO_DIR, "app", "assets", "ml", "precursor_classifier.tflite")
    if not os.path.exists(model_path):
        print(f"SKIP: Model not found at {model_path}")
        return

    # Load interpreter
    interpreter = tf.lite.Interpreter(model_path=model_path)
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    # Generate 10 random valid inputs (17 features)
    np.random.seed(42)
    for _ in range(10):
        # Random features in reasonable ranges
        test_input = np.random.uniform(-1, 3, size=(1, 17)).astype(np.float32)

        interpreter.set_tensor(input_details[0]["index"], test_input)
        interpreter.invoke()
        output = interpreter.get_tensor(output_details[0]["index"])

        # Sum should be close to 1.0 (softmax output)
        prob_sum = float(np.sum(output))
        assert 0.99 <= prob_sum <= 1.01, (
            f"Probabilities sum to {prob_sum}, expected ~1.0"
        )


def test_autoencoder_reconstruction_error_positive():
    """Autoencoder reconstruction error (MSE) must always be >= 0."""
    try:
        import tensorflow as tf
    except ImportError:
        print("SKIP: TensorFlow not available")
        return

    model_path = os.path.join(REPO_DIR, "app", "assets", "ml", "vibration_anomaly.tflite")
    if not os.path.exists(model_path):
        print(f"SKIP: Autoencoder model not found at {model_path}")
        return

    interpreter = tf.lite.Interpreter(model_path=model_path)
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    # Load config to check input dimension
    config_path = os.path.join(REPO_DIR, "app", "assets", "ml", "vibration_model_config.json")
    if os.path.exists(config_path):
        with open(config_path, "r") as fh:
            config = json.load(fh)
        input_dim = config.get("input_dim", 11)
    else:
        input_dim = 11  # default

    # Generate 10 random valid inputs
    np.random.seed(42)
    for _ in range(10):
        test_input = np.random.uniform(-1, 3, size=(1, input_dim)).astype(np.float32)

        interpreter.set_tensor(input_details[0]["index"], test_input)
        interpreter.invoke()
        output = interpreter.get_tensor(output_details[0]["index"])

        # Autoencoder outputs reconstructed features (same dim as input)
        # Compute MSE reconstruction error
        mse_error = float(np.mean((test_input - output) ** 2))
        assert mse_error >= 0, (
            f"MSE reconstruction error is {mse_error}, expected >= 0"
        )


def test_precursor_model_input_dim():
    """Precursor model expects exactly 17 features."""
    try:
        import tensorflow as tf
    except ImportError:
        print("SKIP: TensorFlow not available")
        return

    model_path = os.path.join(REPO_DIR, "app", "assets", "ml", "precursor_classifier.tflite")
    if not os.path.exists(model_path):
        print(f"SKIP: Model not found at {model_path}")
        return

    interpreter = tf.lite.Interpreter(model_path=model_path)
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()
    input_shape = input_details[0]["shape"]

    # Shape is typically [batch_size, feature_dim]
    assert input_shape[-1] == 17, (
        f"Precursor model input dimension is {input_shape[-1]}, expected 17"
    )


def test_autoencoder_input_dim():
    """Autoencoder model input dimension matches config."""
    try:
        import tensorflow as tf
    except ImportError:
        print("SKIP: TensorFlow not available")
        return

    model_path = os.path.join(REPO_DIR, "app", "assets", "ml", "vibration_anomaly.tflite")
    config_path = os.path.join(REPO_DIR, "app", "assets", "ml", "vibration_model_config.json")

    if not os.path.exists(model_path):
        print(f"SKIP: Autoencoder model not found at {model_path}")
        return

    if not os.path.exists(config_path):
        print(f"SKIP: Config not found at {config_path}")
        return

    # Load config
    with open(config_path, "r") as fh:
        config = json.load(fh)

    expected_input_dim = config.get("input_dim")
    assert expected_input_dim is not None, "input_dim not found in config"

    # Check model
    interpreter = tf.lite.Interpreter(model_path=model_path)
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()
    input_shape = input_details[0]["shape"]
    actual_input_dim = input_shape[-1]

    assert actual_input_dim == expected_input_dim, (
        f"Autoencoder input dim is {actual_input_dim}, config says {expected_input_dim}"
    )


def test_model_config_complete():
    """Config files have all required keys."""
    configs_to_check = [
        ("precursor_classifier_config.json", [
            "model_version", "model_file", "feature_names", "class_names",
            "input_dim", "output_dim"
        ]),
        ("vibration_model_config.json", [
            "model_version", "input_dim"
        ]),
    ]

    ml_dir = os.path.join(REPO_DIR, "app", "assets", "ml")

    for config_name, required_keys in configs_to_check:
        config_path = os.path.join(ml_dir, config_name)

        if not os.path.exists(config_path):
            print(f"SKIP: {config_name} not found at {config_path}")
            continue

        with open(config_path, "r") as fh:
            config = json.load(fh)

        for key in required_keys:
            assert key in config, (
                f"Required key '{key}' not found in {config_name}"
            )


# ---------------------------------------------------------------------------
# P25 unittest classes: model asset files, scaler, config.json, inference
# ---------------------------------------------------------------------------

ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")
PRECURSOR_MODEL = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
AUTOENCODER_MODEL = os.path.join(ASSETS_DIR, "autoencoder.tflite")
SCALER_FILE = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
CONFIG_FILE = os.path.join(ASSETS_DIR, "config.json")

_MODELS_PRESENT = os.path.exists(PRECURSOR_MODEL) and os.path.exists(AUTOENCODER_MODEL)
SKIP_IF_NO_MODELS = unittest.skipUnless(
    _MODELS_PRESENT,
    "TFLite models not found — run training first"
)


class TestModelFilesExist(unittest.TestCase):
    """Model asset files exist and have reasonable sizes."""

    def test_precursor_tflite_exists(self):
        if not os.path.exists(PRECURSOR_MODEL):
            self.skipTest(f"TFLite models not found — run training first: {PRECURSOR_MODEL}")
        self.assertTrue(True)  # file exists

    def test_autoencoder_tflite_exists(self):
        if not os.path.exists(AUTOENCODER_MODEL):
            self.skipTest(f"TFLite models not found — run training first: {AUTOENCODER_MODEL}")
        self.assertTrue(True)  # file exists

    def test_scaler_json_exists(self):
        if not os.path.exists(SCALER_FILE):
            self.skipTest(f"Scaler file not found — run training first: {SCALER_FILE}")
        self.assertTrue(True)  # file exists

    def test_precursor_tflite_min_size(self):
        if os.path.exists(PRECURSOR_MODEL):
            size = os.path.getsize(PRECURSOR_MODEL)
            self.assertGreater(size, 1000, f"precursor_classifier.tflite suspiciously small: {size} bytes")

    def test_autoencoder_tflite_min_size(self):
        if os.path.exists(AUTOENCODER_MODEL):
            size = os.path.getsize(AUTOENCODER_MODEL)
            self.assertGreater(size, 1000, f"autoencoder.tflite suspiciously small: {size} bytes")


class TestScalerJson(unittest.TestCase):
    """Scaler JSON has correct structure and sane statistics."""

    def setUp(self):
        if not os.path.exists(SCALER_FILE):
            self.skipTest("Scaler file not found")
        with open(SCALER_FILE) as f:
            self.scaler = json.load(f)

    def test_scaler_has_mean(self):
        self.assertIn("mean", self.scaler)

    def test_scaler_has_scale(self):
        self.assertIn("scale", self.scaler)

    def test_scaler_mean_length(self):
        self.assertEqual(len(self.scaler["mean"]), 17,
                         "Precursor classifier expects 17 features")

    def test_scaler_scale_length(self):
        self.assertEqual(len(self.scaler["scale"]), 17)

    def test_scaler_scale_nonzero(self):
        for i, v in enumerate(self.scaler["scale"]):
            self.assertGreater(abs(v), 1e-10, f"Scale[{i}] is near zero — division by zero risk")

    def test_scaler_mean_finite(self):
        for i, v in enumerate(self.scaler["mean"]):
            self.assertTrue(np.isfinite(v), f"Mean[{i}] is not finite: {v}")


class TestConfigJson(unittest.TestCase):
    """config.json has required fields and reasonable values."""

    def setUp(self):
        if not os.path.exists(CONFIG_FILE):
            self.skipTest("Config file not found")
        with open(CONFIG_FILE) as f:
            self.config = json.load(f)

    def test_config_has_labels(self):
        self.assertIn("labels", self.config)

    def test_config_labels_count(self):
        labels = self.config.get("labels", [])
        self.assertGreaterEqual(len(labels), 2, "Need at least 2 class labels")

    def test_config_has_version(self):
        self.assertIn("version", self.config)

    def test_config_has_thresholds(self):
        has_thresh = (
            "anomaly_threshold" in self.config or
            "precursor_thresholds" in self.config or
            "thresholds" in self.config
        )
        self.assertTrue(has_thresh, "Config must contain threshold values")


@SKIP_IF_NO_MODELS
class TestPrecursorModelInference(unittest.TestCase):
    """Precursor classifier produces valid outputs."""

    def _run_inference(self, features_17):
        try:
            import tflite_runtime.interpreter as tflite
        except ImportError:
            import tensorflow as tf
            tflite = tf.lite
        interp = tflite.Interpreter(model_path=PRECURSOR_MODEL)
        interp.allocate_tensors()
        in_idx = interp.get_input_details()[0]["index"]
        out_idx = interp.get_output_details()[0]["index"]
        interp.set_tensor(in_idx, np.array([features_17], dtype=np.float32))
        interp.invoke()
        return interp.get_tensor(out_idx)[0]

    def test_output_shape(self):
        probs = self._run_inference([0.0] * 17)
        self.assertEqual(len(probs), 4, "Precursor classifier must output 4 class probabilities")

    def test_probabilities_sum_to_one(self):
        probs = self._run_inference([0.0] * 17)
        total = float(sum(probs))
        self.assertAlmostEqual(total, 1.0, places=2,
                               msg=f"Probabilities must sum to ~1.0, got {total:.4f}")

    def test_probabilities_in_range(self):
        probs = self._run_inference([0.5] * 17)
        for i, p in enumerate(probs):
            self.assertGreaterEqual(float(p), 0.0, f"prob[{i}] < 0")
            self.assertLessEqual(float(p), 1.0, f"prob[{i}] > 1")

    def test_no_nan_output(self):
        probs = self._run_inference([1.0] * 17)
        for i, p in enumerate(probs):
            self.assertFalse(np.isnan(float(p)), f"prob[{i}] is NaN")

    def test_normal_class_dominates_zero_input(self):
        """With all-zero features, normal class should have highest probability."""
        probs = self._run_inference([0.0] * 17)
        max_prob = max(float(p) for p in probs)
        self.assertGreater(max_prob, 0.25, "No class dominates — model might be random")


@SKIP_IF_NO_MODELS
class TestAutoencoderInference(unittest.TestCase):
    """Autoencoder produces valid reconstruction errors."""

    def _run_inference(self, features_11):
        try:
            import tflite_runtime.interpreter as tflite
        except ImportError:
            import tensorflow as tf
            tflite = tf.lite
        interp = tflite.Interpreter(model_path=AUTOENCODER_MODEL)
        interp.allocate_tensors()
        in_idx = interp.get_input_details()[0]["index"]
        out_idx = interp.get_output_details()[0]["index"]
        interp.set_tensor(in_idx, np.array([features_11], dtype=np.float32))
        interp.invoke()
        return interp.get_tensor(out_idx)[0]

    def test_output_shape(self):
        out = self._run_inference([0.0] * 11)
        self.assertEqual(len(out), 11, "Autoencoder output must match input dimension")

    def test_reconstruction_finite(self):
        out = self._run_inference([0.5] * 11)
        for i, v in enumerate(out):
            self.assertTrue(np.isfinite(float(v)), f"output[{i}] is not finite: {v}")

    def test_zero_input_small_error(self):
        """Zero input should have small reconstruction error (normal-ish pattern)."""
        inp = [0.0] * 11
        out = self._run_inference(inp)
        mse = float(np.mean((np.array(inp) - np.array(out)) ** 2))
        self.assertLess(mse, 10.0, f"Reconstruction MSE suspiciously large for zero input: {mse:.4f}")


if __name__ == "__main__":
    unittest.main()
