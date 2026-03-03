"""Tests for scripts/validate_config.py

P134 — covers:
  - Valid config/scaler/metrics JSON files → all PASS, exit 0
  - Invalid JSON → FAIL row, exit 1
  - Mismatched feature_names / scaler lengths → cross-check error, exit 1
  - Missing required keys → FAIL row, exit 1
  - Empty assets directory → exit 0 (no files to validate)
"""
import json
import os
import sys
from pathlib import Path

import pytest

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from validate_config import (
    validate_config,
    validate_scaler,
    validate_training_metrics,
    cross_check_config_scaler,
    validate_directory,
    STATUS_PASS,
    STATUS_FAIL,
    STATUS_SKIP,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_json(path: Path, data) -> None:
    path.write_text(json.dumps(data), encoding="utf-8")


def _valid_config() -> dict:
    return {
        "version": "1.0.0",
        "feature_names": ["rms", "ppv", "freq"],
        "class_names": ["normal", "anomaly"],
        "input_dim": 3,
        "output_dim": 2,
    }


def _valid_scaler(n: int = 3) -> dict:
    return {
        "mean": [0.0] * n,
        "std": [1.0] * n,
    }


def _valid_metrics() -> dict:
    return {
        "trained_at": "2026-03-01T00:00:00Z",
        "total_samples": 1000,
        "holdout_accuracy": 0.95,
    }


# ---------------------------------------------------------------------------
# P134a: validate_config() unit tests
# ---------------------------------------------------------------------------

class TestValidateConfig:

    def test_valid_config_returns_no_errors(self):
        errors = validate_config(_valid_config())
        assert errors == []

    def test_missing_feature_names(self):
        data = {"version": "1.0"}
        errors = validate_config(data)
        assert any("feature_names" in e for e in errors)

    def test_missing_version(self):
        data = {"feature_names": ["rms", "ppv"]}
        errors = validate_config(data)
        assert any("version" in e for e in errors)

    def test_feature_names_not_a_list(self):
        data = {"version": "1.0", "feature_names": "rms,ppv"}
        errors = validate_config(data)
        assert any("feature_names" in e for e in errors)

    def test_both_keys_missing(self):
        errors = validate_config({})
        assert len(errors) == 2


# ---------------------------------------------------------------------------
# P134b: validate_scaler() unit tests
# ---------------------------------------------------------------------------

class TestValidateScaler:

    def test_valid_scaler_returns_no_errors(self):
        errors = validate_scaler(_valid_scaler(5))
        assert errors == []

    def test_missing_mean(self):
        data = {"std": [1.0, 1.0]}
        errors = validate_scaler(data)
        assert any("mean" in e for e in errors)

    def test_missing_std(self):
        data = {"mean": [0.0, 0.0]}
        errors = validate_scaler(data)
        assert any("std" in e for e in errors)

    def test_mismatched_mean_std_lengths(self):
        data = {"mean": [0.0, 0.0, 0.0], "std": [1.0, 1.0]}
        errors = validate_scaler(data)
        assert any("mean" in e or "std" in e or "length" in e for e in errors)

    def test_both_keys_missing(self):
        errors = validate_scaler({})
        assert len(errors) == 2


# ---------------------------------------------------------------------------
# P134c: validate_training_metrics() unit tests
# ---------------------------------------------------------------------------

class TestValidateTrainingMetrics:

    def test_valid_metrics_returns_no_errors(self):
        errors = validate_training_metrics(_valid_metrics())
        assert errors == []

    def test_missing_trained_at(self):
        data = {"total_samples": 500, "holdout_accuracy": 0.9}
        errors = validate_training_metrics(data)
        assert any("trained_at" in e for e in errors)

    def test_missing_total_samples(self):
        data = {"trained_at": "2026-03-01", "holdout_accuracy": 0.9}
        errors = validate_training_metrics(data)
        assert any("total_samples" in e for e in errors)

    def test_missing_holdout_accuracy(self):
        data = {"trained_at": "2026-03-01", "total_samples": 100}
        errors = validate_training_metrics(data)
        assert any("holdout_accuracy" in e for e in errors)

    def test_all_keys_missing(self):
        errors = validate_training_metrics({})
        assert len(errors) == 3


# ---------------------------------------------------------------------------
# P134d: cross_check_config_scaler() unit tests
# ---------------------------------------------------------------------------

class TestCrossCheckConfigScaler:

    def test_matching_lengths_no_errors(self):
        config = _valid_config()        # feature_names has 3 entries
        scaler = _valid_scaler(3)       # mean and std both have 3 entries
        errors = cross_check_config_scaler(config, scaler, "test_config.json", "test_scaler.json")
        assert errors == []

    def test_mismatched_mean_length(self):
        config = _valid_config()        # 3 features
        scaler = {"mean": [0.0, 0.0], "std": [1.0, 1.0, 1.0]}   # mean=2, std=3
        errors = cross_check_config_scaler(config, scaler, "cfg.json", "scl.json")
        # mean length (2) != feature_names length (3)
        assert len(errors) >= 1
        assert any("mean" in e or "feature_names" in e for e in errors)

    def test_mismatched_std_length(self):
        config = _valid_config()        # 3 features
        scaler = {"mean": [0.0, 0.0, 0.0], "std": [1.0, 1.0]}  # std=2, mean=3
        errors = cross_check_config_scaler(config, scaler, "cfg.json", "scl.json")
        assert len(errors) >= 1
        assert any("std" in e or "feature_names" in e for e in errors)


# ---------------------------------------------------------------------------
# P134e: validate_directory() integration tests (using tmp_path)
# ---------------------------------------------------------------------------

class TestValidateDirectory:

    def test_empty_directory_exits_0(self, tmp_path):
        """An assets directory with no JSON files should return 0 (no failures)."""
        result = validate_directory(str(tmp_path))
        assert result == 0

    def test_nonexistent_directory_exits_1(self, tmp_path):
        missing = str(tmp_path / "does_not_exist")
        result = validate_directory(missing)
        assert result == 1

    def test_valid_config_and_scaler_pass(self, tmp_path):
        """A valid *_config.json and paired *_scaler.json should both PASS."""
        _write_json(tmp_path / "model_config.json", _valid_config())
        _write_json(tmp_path / "model_scaler.json", _valid_scaler(3))
        result = validate_directory(str(tmp_path))
        assert result == 0

    def test_invalid_json_causes_fail(self, tmp_path):
        """A file containing invalid JSON must produce a FAIL and exit 1."""
        (tmp_path / "bad_config.json").write_text("{ not valid json }", encoding="utf-8")
        result = validate_directory(str(tmp_path))
        assert result == 1

    def test_missing_version_in_config_causes_fail(self, tmp_path):
        """A *_config.json missing the 'version' key must FAIL."""
        data = {"feature_names": ["rms", "ppv"]}  # no 'version'
        _write_json(tmp_path / "model_config.json", data)
        result = validate_directory(str(tmp_path))
        assert result == 1

    def test_missing_mean_in_scaler_causes_fail(self, tmp_path):
        """A *_scaler.json missing the 'mean' key must FAIL."""
        data = {"std": [1.0, 1.0, 1.0]}  # no 'mean'
        _write_json(tmp_path / "model_scaler.json", data)
        result = validate_directory(str(tmp_path))
        assert result == 1

    def test_valid_training_metrics_passes(self, tmp_path):
        """A valid *_training_metrics.json must PASS."""
        _write_json(tmp_path / "model_training_metrics.json", _valid_metrics())
        result = validate_directory(str(tmp_path))
        assert result == 0

    def test_missing_trained_at_causes_fail(self, tmp_path):
        """A *_training_metrics.json missing 'trained_at' must FAIL."""
        data = {"total_samples": 500, "holdout_accuracy": 0.9}
        _write_json(tmp_path / "model_training_metrics.json", data)
        result = validate_directory(str(tmp_path))
        assert result == 1

    def test_cross_check_mismatch_causes_fail(self, tmp_path):
        """Config with 3 features but scaler with 5 mean values must cross-check FAIL."""
        config = _valid_config()          # feature_names has 3 entries
        scaler = _valid_scaler(5)         # mean/std have 5 entries (mismatch)
        _write_json(tmp_path / "model_config.json", config)
        _write_json(tmp_path / "model_scaler.json", scaler)
        result = validate_directory(str(tmp_path))
        assert result == 1

    def test_unrecognised_json_is_skipped(self, tmp_path):
        """A JSON file with no recognised name pattern is SKIPped, not failed."""
        # A filename that doesn't contain _config.json, _scaler.json, or _training_metrics.json
        _write_json(tmp_path / "summary.json", {"whatever": 1})
        result = validate_directory(str(tmp_path))
        assert result == 0  # SKIP does not cause failure

    def test_lightglue_config_treated_as_config_file(self, tmp_path):
        """lightglue_config.json matches the _config.json pattern and is validated as a config."""
        # It contains '_config.json', so it goes through validate_config() which
        # requires 'feature_names' (list) and 'version'. Without them it fails.
        _write_json(tmp_path / "lightglue_config.json", {"whatever": 1})
        result = validate_directory(str(tmp_path))
        assert result == 1  # missing feature_names and version -> FAIL
