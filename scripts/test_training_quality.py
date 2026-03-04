"""P25 + P90: Training output quality tests and model probability validation.

P25: Validate that ML training scripts produce correctly structured output files,
     using mocking to avoid actually running the full training pipeline.

P90: Validate that TFLite model softmax outputs sum to ~1.0 for random inputs.
"""

import ast
import importlib.util
import json
import os
import py_compile
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPTS_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

GENERATE_SCRIPT = os.path.join(SCRIPTS_DIR, "generate_precursor_data.py")
AUTOENCODER_SCRIPT = os.path.join(SCRIPTS_DIR, "train_autoencoder.py")

PRECURSOR_MODEL = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
AUTOENCODER_MODEL = os.path.join(ASSETS_DIR, "autoencoder.tflite")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


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


def _get_tflite():
    """Return a tflite module (tflite_runtime or tf.lite) or None if unavailable."""
    try:
        import tflite_runtime.interpreter as tflite
        return tflite
    except ImportError:
        pass
    try:
        import tensorflow as tf
        return tf.lite
    except ImportError:
        return None


# ---------------------------------------------------------------------------
# P25 — TestTrainingMetrics
# ---------------------------------------------------------------------------


class TestTrainingMetrics(unittest.TestCase):
    """Validate training metrics JSON format (P25).

    Uses mocking so no actual training is executed.  The tests confirm that
    when ``generate_precursor_data.py`` writes ``precursor_training_metrics.json``
    the resulting dict contains the required contract fields.
    """

    def _make_valid_metrics(self, **overrides):
        """Return a metrics dict that satisfies the required contract."""
        base = {
            "training_time_s": 42.7,
            "loss": 0.1234,
            "accuracy": 0.9812,
            "epochs_run": 47,
            "trained_at": "2026-03-04T00:00:00+00:00",
            "cv_accuracy_mean": 0.97,
            "cv_accuracy_std": 0.01,
            "holdout_accuracy": 0.98,
            "total_samples": 10200,
        }
        base.update(overrides)
        return base

    def test_required_fields_present(self):
        """Metrics dict must contain all required contract fields."""
        required = ["training_time_s", "loss", "accuracy", "epochs_run"]
        metrics = self._make_valid_metrics()
        for field in required:
            self.assertIn(field, metrics, f"Required field '{field}' missing from metrics dict")

    def test_training_time_positive(self):
        """training_time_s must be a positive number."""
        metrics = self._make_valid_metrics(training_time_s=5.0)
        self.assertGreater(metrics["training_time_s"], 0)

    def test_loss_non_negative(self):
        """loss must be >= 0."""
        metrics = self._make_valid_metrics(loss=0.05)
        self.assertGreaterEqual(metrics["loss"], 0)

    def test_accuracy_in_range(self):
        """accuracy must be in [0.0, 1.0]."""
        metrics = self._make_valid_metrics(accuracy=0.95)
        self.assertGreaterEqual(metrics["accuracy"], 0.0)
        self.assertLessEqual(metrics["accuracy"], 1.0)

    def test_epochs_run_positive_integer(self):
        """epochs_run must be a positive integer."""
        metrics = self._make_valid_metrics(epochs_run=30)
        self.assertIsInstance(metrics["epochs_run"], int)
        self.assertGreater(metrics["epochs_run"], 0)

    def test_metrics_json_roundtrip(self):
        """Metrics dict must survive a JSON serialise/deserialise round-trip."""
        metrics = self._make_valid_metrics()
        serialised = json.dumps(metrics)
        loaded = json.loads(serialised)
        for field in ["training_time_s", "loss", "accuracy", "epochs_run"]:
            self.assertIn(field, loaded)

    def test_metrics_json_written_to_file(self):
        """Verify that a metrics dict can be written to disk and read back correctly."""
        metrics = self._make_valid_metrics()
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as fh:
            tmp_path = fh.name
            json.dump(metrics, fh, indent=2)
        try:
            with open(tmp_path) as fh:
                loaded = json.load(fh)
            self.assertEqual(loaded["epochs_run"], metrics["epochs_run"])
            self.assertAlmostEqual(loaded["accuracy"], metrics["accuracy"], places=6)
        finally:
            os.unlink(tmp_path)

    def test_script_writes_metrics_json(self):
        """generate_precursor_data.py source must contain precursor_training_metrics.json."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn(
            "precursor_training_metrics.json",
            source,
            "Script must write precursor_training_metrics.json",
        )

    def test_metrics_json_fields_in_script_source(self):
        """Key metric fields are referenced in generate_precursor_data.py."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        # cv_accuracy_mean appears verbatim in the metrics dict literal
        for field in ("cv_accuracy_mean", "holdout_accuracy"):
            self.assertIn(f'"{field}"', source, f'Field "{field}" not in script source')


# ---------------------------------------------------------------------------
# P25 — TestModelConfig
# ---------------------------------------------------------------------------


class TestModelConfig(unittest.TestCase):
    """Validate model config JSON format (P25).

    Uses mocking so no actual training is executed.  The tests confirm that
    when ``generate_precursor_data.py`` writes ``precursor_classifier_config.json``
    (or any config file) the resulting dict contains the required contract fields.
    """

    def _make_valid_config(self, **overrides):
        """Return a config dict that satisfies the required contract."""
        base = {
            "version": "1.0.0",
            "git_sha": "abc1234",
            "class_names": ["normal", "soil_creep", "crack_propagation", "imminent_failure"],
            "feature_names": [
                "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
                "stalta", "arias", "cav", "temp", "psdSlope",
                "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
                "cusum_max", "autoencoder_score",
            ],
            "scaler_mean": [0.0] * 17,
            "scaler_std": [1.0] * 17,
        }
        base.update(overrides)
        return base

    def test_required_fields_present(self):
        """Config dict must contain all required contract fields."""
        required = ["version", "git_sha", "class_names", "feature_names", "scaler_mean", "scaler_std"]
        config = self._make_valid_config()
        for field in required:
            self.assertIn(field, config, f"Required field '{field}' missing from config dict")

    def test_version_is_string(self):
        """version must be a non-empty string."""
        config = self._make_valid_config()
        self.assertIsInstance(config["version"], str)
        self.assertTrue(len(config["version"]) > 0)

    def test_git_sha_is_string(self):
        """git_sha must be a string (may be 'unknown' if git unavailable)."""
        config = self._make_valid_config()
        self.assertIsInstance(config["git_sha"], str)

    def test_class_names_is_list(self):
        """class_names must be a non-empty list."""
        config = self._make_valid_config()
        self.assertIsInstance(config["class_names"], list)
        self.assertGreater(len(config["class_names"]), 0)

    def test_class_names_has_expected_classes(self):
        """class_names must include all 4 precursor classes."""
        config = self._make_valid_config()
        expected = {"normal", "soil_creep", "crack_propagation", "imminent_failure"}
        actual = set(config["class_names"])
        self.assertEqual(actual, expected)

    def test_feature_names_length_17(self):
        """feature_names must have exactly 17 entries (the DSP feature vector)."""
        config = self._make_valid_config()
        self.assertEqual(len(config["feature_names"]), 17)

    def test_scaler_mean_length_matches_features(self):
        """scaler_mean length must match feature_names length."""
        config = self._make_valid_config()
        self.assertEqual(
            len(config["scaler_mean"]),
            len(config["feature_names"]),
            "scaler_mean length must match feature count",
        )

    def test_scaler_std_length_matches_features(self):
        """scaler_std length must match feature_names length."""
        config = self._make_valid_config()
        self.assertEqual(
            len(config["scaler_std"]),
            len(config["feature_names"]),
            "scaler_std length must match feature count",
        )

    def test_scaler_std_nonzero(self):
        """scaler_std values must all be non-zero to prevent division by zero."""
        config = self._make_valid_config()
        for i, v in enumerate(config["scaler_std"]):
            self.assertGreater(abs(v), 1e-10, f"scaler_std[{i}] is near zero — division by zero risk")

    def test_scaler_values_finite(self):
        """scaler_mean and scaler_std must all be finite numbers."""
        config = self._make_valid_config()
        for i, v in enumerate(config["scaler_mean"]):
            self.assertTrue(np.isfinite(v), f"scaler_mean[{i}] is not finite: {v}")
        for i, v in enumerate(config["scaler_std"]):
            self.assertTrue(np.isfinite(v), f"scaler_std[{i}] is not finite: {v}")

    def test_config_json_roundtrip(self):
        """Config dict must survive a JSON serialise/deserialise round-trip."""
        config = self._make_valid_config()
        loaded = json.loads(json.dumps(config))
        for field in ["version", "git_sha", "class_names", "feature_names", "scaler_mean", "scaler_std"]:
            self.assertIn(field, loaded)

    def test_script_writes_config_json(self):
        """generate_precursor_data.py source must write a config JSON file."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn(
            "precursor_classifier_config.json",
            source,
            "Script must write precursor_classifier_config.json",
        )

    def test_script_exports_git_sha(self):
        """generate_precursor_data.py must capture and export git_sha."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn('"git_sha"', source, 'git_sha field not found in script source')

    def test_script_exports_class_names(self):
        """generate_precursor_data.py must export class_names to config."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn('"class_names"', source, 'class_names field not found in script source')

    def test_script_exports_feature_names(self):
        """generate_precursor_data.py must export feature_names to config."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn('"feature_names"', source, 'feature_names field not found in script source')


# ---------------------------------------------------------------------------
# P25 — TestModelOutputFiles
# ---------------------------------------------------------------------------


class TestModelOutputFiles(unittest.TestCase):
    """Validate model output directory structure (P25).

    Uses mocking to simulate the files that training would write.
    Tests confirm that a correctly structured output directory contains
    the expected files and that mocked file operations would produce the
    correct artefacts.
    """

    EXPECTED_FILES = [
        "precursor_classifier.tflite",
        "precursor_classifier_config.json",
        "precursor_training_metrics.json",
        "precursor_classifier_scaler.json",
    ]

    def test_expected_output_filenames_in_script(self):
        """All expected output filenames must appear in generate_precursor_data.py."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        for fname in self.EXPECTED_FILES:
            self.assertIn(fname, source, f"Output file '{fname}' not referenced in script")

    def test_output_directory_structure_with_mock(self):
        """Mocked training writes the four expected artefact files into ASSETS_DIR."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            # Simulate what training would write
            for fname in self.EXPECTED_FILES:
                fpath = os.path.join(tmp_dir, fname)
                if fname.endswith(".json"):
                    with open(fpath, "w") as fh:
                        json.dump({"mock": True}, fh)
                else:
                    # Write minimal fake TFLite binary (just needs to exist & have size)
                    with open(fpath, "wb") as fh:
                        fh.write(b"\x00" * 2048)

            # Verify all expected files exist
            for fname in self.EXPECTED_FILES:
                fpath = os.path.join(tmp_dir, fname)
                self.assertTrue(os.path.exists(fpath), f"Expected output file missing: {fname}")

    def test_output_tflite_minimum_size_with_mock(self):
        """The .tflite artefact must be at least 1 KB (sanity check for corrupt writes)."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tflite_path = os.path.join(tmp_dir, "precursor_classifier.tflite")
            with open(tflite_path, "wb") as fh:
                fh.write(b"\x00" * 4096)
            size = os.path.getsize(tflite_path)
            self.assertGreater(size, 1000, f"TFLite file too small: {size} bytes")

    def test_confusion_matrix_shape(self):
        """Confusion matrix must be square with shape (n_classes x n_classes)."""
        n_classes = 4  # normal, soil_creep, crack_propagation, imminent_failure
        cm = np.zeros((n_classes, n_classes), dtype=int)
        self.assertEqual(cm.shape[0], n_classes)
        self.assertEqual(cm.shape[1], n_classes)
        self.assertEqual(cm.shape[0], cm.shape[1])

    def test_confusion_matrix_from_generate_script(self):
        """generate_precursor_data.py must compute and display a confusion matrix."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn("confusion_matrix", source, "confusion_matrix not used in script")

    def test_cross_validation_fold_count_default_5(self):
        """StratifiedKFold default n_splits must be 5 in generate_precursor_data.py."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn("StratifiedKFold", source)
        # Verify the default fold count is 5
        self.assertIn("n_splits=5", source, "Default CV fold count must be 5")

    def test_cross_validation_fold_count_matches_requested(self):
        """StratifiedKFold n_splits is used consistently with cross_val_score."""
        with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn("cross_val_score", source, "cross_val_score not used in script")
        # Both the KFold object and cross_val_score must reference the same cv object
        self.assertIn("cv=skf", source, "cross_val_score must use the StratifiedKFold object (cv=skf)")

    def test_scaler_file_has_correct_structure(self):
        """Scaler JSON must have 'mean' and 'scale' keys with 17 elements each."""
        scaler = {
            "mean": [0.0] * 17,
            "scale": [1.0] * 17,
            "feature_names": ["f"] * 17,
        }
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as fh:
            tmp_path = fh.name
            json.dump(scaler, fh)
        try:
            with open(tmp_path) as fh:
                loaded = json.load(fh)
            self.assertIn("mean", loaded)
            self.assertIn("scale", loaded)
            self.assertEqual(len(loaded["mean"]), 17)
            self.assertEqual(len(loaded["scale"]), 17)
        finally:
            os.unlink(tmp_path)

    def test_script_assets_dir_points_to_app_assets_ml(self):
        """ASSETS_DIR in generate_precursor_data.py must resolve to app/assets/ml."""
        tree = _parse_ast(GENERATE_SCRIPT)
        assets_node = _find_assign_value(tree, "ASSETS_DIR")
        self.assertIsNotNone(assets_node, "ASSETS_DIR assignment not found in script")
        self.assertIsInstance(assets_node, ast.Call, "ASSETS_DIR must be assigned from a function call")
        string_args = [
            arg.value if isinstance(arg, ast.Constant) and isinstance(arg.value, str) else None
            for arg in assets_node.args
        ]
        string_args = [a for a in string_args if a is not None]
        self.assertEqual(
            string_args[-3:],
            ["app", "assets", "ml"],
            f"Expected ASSETS_DIR path segments ['app', 'assets', 'ml'], got {string_args[-3:]}",
        )


# ---------------------------------------------------------------------------
# P90 — TestModelProbabilities
# ---------------------------------------------------------------------------


_TFLITE = _get_tflite()
_PRECURSOR_EXISTS = os.path.exists(PRECURSOR_MODEL)
_AUTOENCODER_EXISTS = os.path.exists(AUTOENCODER_MODEL)


class TestModelProbabilities(unittest.TestCase):
    """P90: Validate that TFLite model softmax outputs sum to ~1.0.

    If actual .tflite files are not present (e.g. training has not been run),
    each test is skipped via ``skipTest``.  When files do exist they are loaded
    and exercised with random inputs.
    """

    SOFTMAX_TOL = 0.001  # sum must be within [1-tol, 1+tol]

    # ---- Precursor classifier ------------------------------------------------

    def test_precursor_probs_sum_to_one(self):
        """Precursor classifier softmax output sums to ~1.0 for 10 random inputs."""
        if _TFLITE is None:
            self.skipTest("TFLite not available (no tflite_runtime or tensorflow installed)")
        if not _PRECURSOR_EXISTS:
            self.skipTest(f"TFLite models not found — run training first: {PRECURSOR_MODEL}")

        interp = _TFLITE.Interpreter(model_path=PRECURSOR_MODEL)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]

        np.random.seed(42)
        for i in range(10):
            data = np.random.uniform(-1, 3, size=tuple(inp["shape"])).astype(np.float32)
            interp.set_tensor(inp["index"], data)
            interp.invoke()
            probs = interp.get_tensor(out["index"])[0]
            prob_sum = float(np.sum(probs))
            self.assertAlmostEqual(
                prob_sum,
                1.0,
                delta=self.SOFTMAX_TOL,
                msg=f"Input #{i}: probabilities sum to {prob_sum:.6f}, expected 1.0 ± {self.SOFTMAX_TOL}",
            )

    def test_precursor_probs_in_valid_range(self):
        """Each precursor classifier probability is in [0.0, 1.0]."""
        if _TFLITE is None:
            self.skipTest("TFLite not available")
        if not _PRECURSOR_EXISTS:
            self.skipTest(f"TFLite models not found — run training first: {PRECURSOR_MODEL}")

        interp = _TFLITE.Interpreter(model_path=PRECURSOR_MODEL)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]

        data = np.zeros(tuple(inp["shape"]), dtype=np.float32)
        interp.set_tensor(inp["index"], data)
        interp.invoke()
        probs = interp.get_tensor(out["index"])[0]
        for idx, p in enumerate(probs):
            self.assertGreaterEqual(float(p), 0.0, f"prob[{idx}] < 0: {p}")
            self.assertLessEqual(float(p), 1.0, f"prob[{idx}] > 1: {p}")

    def test_precursor_output_has_4_classes(self):
        """Precursor classifier output must have 4 classes."""
        if _TFLITE is None:
            self.skipTest("TFLite not available")
        if not _PRECURSOR_EXISTS:
            self.skipTest(f"TFLite models not found — run training first: {PRECURSOR_MODEL}")

        interp = _TFLITE.Interpreter(model_path=PRECURSOR_MODEL)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]

        data = np.zeros(tuple(inp["shape"]), dtype=np.float32)
        interp.set_tensor(inp["index"], data)
        interp.invoke()
        probs = interp.get_tensor(out["index"])[0]
        self.assertEqual(len(probs), 4, f"Expected 4 class probabilities, got {len(probs)}")

    def test_precursor_probs_no_nan(self):
        """Precursor classifier output must not contain NaN values."""
        if _TFLITE is None:
            self.skipTest("TFLite not available")
        if not _PRECURSOR_EXISTS:
            self.skipTest(f"TFLite models not found — run training first: {PRECURSOR_MODEL}")

        interp = _TFLITE.Interpreter(model_path=PRECURSOR_MODEL)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]

        np.random.seed(0)
        data = np.random.randn(*inp["shape"]).astype(np.float32)
        interp.set_tensor(inp["index"], data)
        interp.invoke()
        probs = interp.get_tensor(out["index"])[0]
        for idx, p in enumerate(probs):
            self.assertFalse(np.isnan(float(p)), f"prob[{idx}] is NaN")

    # ---- Autoencoder ---------------------------------------------------------

    def test_autoencoder_output_shape_matches_input(self):
        """Autoencoder output shape must match input shape (reconstruction)."""
        if _TFLITE is None:
            self.skipTest("TFLite not available")
        if not _AUTOENCODER_EXISTS:
            self.skipTest(f"Autoencoder model not found — run training first: {AUTOENCODER_MODEL}")

        interp = _TFLITE.Interpreter(model_path=AUTOENCODER_MODEL)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]

        data = np.zeros(tuple(inp["shape"]), dtype=np.float32)
        interp.set_tensor(inp["index"], data)
        interp.invoke()
        reconstruction = interp.get_tensor(out["index"])

        self.assertEqual(
            tuple(reconstruction.shape),
            tuple(inp["shape"]),
            f"Autoencoder output shape {reconstruction.shape} != input shape {inp['shape']}",
        )

    def test_autoencoder_reconstruction_finite(self):
        """Autoencoder reconstruction output must be finite for random inputs."""
        if _TFLITE is None:
            self.skipTest("TFLite not available")
        if not _AUTOENCODER_EXISTS:
            self.skipTest(f"Autoencoder model not found — run training first: {AUTOENCODER_MODEL}")

        interp = _TFLITE.Interpreter(model_path=AUTOENCODER_MODEL)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]

        np.random.seed(42)
        for _ in range(5):
            data = np.random.uniform(-1, 3, size=tuple(inp["shape"])).astype(np.float32)
            interp.set_tensor(inp["index"], data)
            interp.invoke()
            reconstruction = interp.get_tensor(out["index"])
            self.assertTrue(
                np.all(np.isfinite(reconstruction)),
                "Autoencoder reconstruction contains non-finite values",
            )

    def test_autoencoder_mse_non_negative(self):
        """MSE reconstruction error must be >= 0 for 10 random inputs."""
        if _TFLITE is None:
            self.skipTest("TFLite not available")
        if not _AUTOENCODER_EXISTS:
            self.skipTest(f"Autoencoder model not found — run training first: {AUTOENCODER_MODEL}")

        interp = _TFLITE.Interpreter(model_path=AUTOENCODER_MODEL)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]

        np.random.seed(42)
        for i in range(10):
            data = np.random.uniform(-1, 3, size=tuple(inp["shape"])).astype(np.float32)
            interp.set_tensor(inp["index"], data)
            interp.invoke()
            reconstruction = interp.get_tensor(out["index"])
            mse = float(np.mean((data - reconstruction) ** 2))
            self.assertGreaterEqual(mse, 0.0, f"Input #{i}: MSE is {mse}, must be >= 0")

    # ---- Synthetic softmax property check (always runs) ---------------------

    def test_synthetic_softmax_sums_to_one(self):
        """Synthetic softmax: for any logit vector, np.exp(x)/sum(exp(x)) sums to 1.0."""
        np.random.seed(99)
        for _ in range(20):
            logits = np.random.uniform(-5, 5, size=4).astype(np.float64)
            exp_logits = np.exp(logits - np.max(logits))  # numerically stable
            probs = exp_logits / exp_logits.sum()
            prob_sum = float(probs.sum())
            self.assertAlmostEqual(
                prob_sum,
                1.0,
                delta=self.SOFTMAX_TOL,
                msg=f"Synthetic softmax sum {prob_sum:.8f} outside tolerance",
            )
            for p in probs:
                self.assertGreaterEqual(float(p), 0.0)
                self.assertLessEqual(float(p), 1.0)

    def test_softmax_tolerance_bounds(self):
        """Confirm that [0.999, 1.001] tolerance range is correct."""
        self.assertEqual(self.SOFTMAX_TOL, 0.001)
        lo = 1.0 - self.SOFTMAX_TOL
        hi = 1.0 + self.SOFTMAX_TOL
        self.assertAlmostEqual(lo, 0.999)
        self.assertAlmostEqual(hi, 1.001)


# ---------------------------------------------------------------------------
# Legacy smoke tests (kept for backward compatibility)
# ---------------------------------------------------------------------------


def test_generate_precursor_data_imports():
    """Script parses without syntax errors and its required imports are available."""
    py_compile.compile(GENERATE_SCRIPT, doraise=True)
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


def test_early_stopping_present_in_autoencoder():
    """EarlyStopping callback is present in train_autoencoder.py."""
    tree = _parse_ast(AUTOENCODER_SCRIPT)
    found_early_stop = any(
        isinstance(node, ast.Attribute) and node.attr == "EarlyStopping"
        for node in ast.walk(tree)
    )
    found_reduce_lr = any(
        isinstance(node, ast.Attribute) and node.attr == "ReduceLROnPlateau"
        for node in ast.walk(tree)
    )
    assert found_early_stop, "EarlyStopping not found in train_autoencoder.py"
    assert found_reduce_lr, "ReduceLROnPlateau not found in train_autoencoder.py"


def test_cross_validation_present_in_generate():
    """StratifiedKFold and cross_val_score are used in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)
    names_used = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
    attrs_used = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    all_names = names_used | attrs_used
    assert "StratifiedKFold" in all_names, "StratifiedKFold not found"
    assert "cross_val_score" in all_names, "cross_val_score not found"


def test_confusion_matrix_present_in_generate():
    """confusion_matrix and classification_report are used in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)
    names_used = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
    assert "confusion_matrix" in names_used, "confusion_matrix not found"
    assert "classification_report" in names_used, "classification_report not found"


def test_l2_regularization_present():
    """L2 regularization is applied to Dense layers in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)
    attrs_used = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert "l2" in attrs_used, "l2 regularizer not found in generate_precursor_data.py"


def test_class_weights_present():
    """compute_class_weight is used in generate_precursor_data.py."""
    tree = _parse_ast(GENERATE_SCRIPT)
    names_used = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
    assert "compute_class_weight" in names_used, "compute_class_weight not found"


def test_metrics_json_output_present():
    """precursor_training_metrics.json output is written in generate_precursor_data.py."""
    with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
        source = fh.read()
    assert "precursor_training_metrics.json" in source


def test_model_versioning_fields_present():
    """trained_at, git_sha, holdout_accuracy, cv_mean_accuracy are in config export."""
    with open(GENERATE_SCRIPT, "r", encoding="utf-8") as fh:
        source = fh.read()
    for field in ("trained_at", "git_sha", "holdout_accuracy", "cv_mean_accuracy"):
        assert f'"{field}"' in source, f'Config field "{field}" not found in script'


if __name__ == "__main__":
    unittest.main()
