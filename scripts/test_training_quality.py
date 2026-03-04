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
