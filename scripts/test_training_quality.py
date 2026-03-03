"""Smoke tests for ML training scripts.

These tests verify script syntax, importability of their dependencies,
and structural constants — without executing the full training pipelines.
"""

import ast
import importlib.util
import os
import py_compile
import sys

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
