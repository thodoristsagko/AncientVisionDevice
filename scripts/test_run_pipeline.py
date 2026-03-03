"""
Tests for scripts/run_pipeline.py error-recovery logic.

All subprocess calls are mocked — no training scripts are actually executed.
"""
import importlib
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_pipeline(tmp_path: Path, monkeypatch):
    """
    Import run_pipeline with DATA_DIR and ASSETS_DIR pointed at tmp_path.
    Re-imports every time so each test gets a clean module state.
    """
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "data"))

    # Remove cached module so constants are re-evaluated on import
    sys.modules.pop("run_pipeline", None)

    # Temporarily add scripts/ to sys.path
    scripts_dir = Path(__file__).parent
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))

    import run_pipeline as rp

    # Override module-level constants to point at tmp_path
    rp.DATA_DIR = tmp_path / "data"
    rp.TRIGGER_FILE = rp.DATA_DIR / ".retrain_trigger"
    rp.ASSETS_DIR = tmp_path / "assets"

    return rp


def _make_trigger(rp) -> Path:
    """Create DATA_DIR and .retrain_trigger; return path."""
    rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
    trigger = rp.TRIGGER_FILE
    trigger.touch()
    return trigger


def _make_assets(rp, names: list[str]) -> None:
    """Create fake asset files so output-verification passes."""
    rp.ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    for name in names:
        (rp.ASSETS_DIR / name).write_text("fake")


ALL_EXPECTED = [
    "vibration_anomaly.tflite",
    "vibration_scaler.json",
    "vibration_model_config.json",
    "precursor_classifier.tflite",
    "precursor_classifier_scaler.json",
    "precursor_classifier_config.json",
]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestNoTrigger:
    """Pipeline exits cleanly when trigger file does not exist."""

    def test_no_trigger_returns_without_error(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        # Trigger file deliberately NOT created.
        # main() should return normally (no sys.exit).
        rp.main()  # must not raise


class TestTrainingFailure:
    """Trigger is deleted and sys.exit(1) raised when a training script fails."""

    def test_trigger_deleted_when_train_autoencoder_fails(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)
        trigger = _make_trigger(rp)

        failing_result = MagicMock()
        failing_result.returncode = 1

        with patch("subprocess.run", return_value=failing_result):
            with pytest.raises(SystemExit) as exc_info:
                rp.main()

        assert exc_info.value.code == 1
        assert not trigger.exists(), "Trigger must be deleted after training failure"

    def test_trigger_deleted_when_generate_precursor_fails(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)
        trigger = _make_trigger(rp)

        success = MagicMock(returncode=0)
        failure = MagicMock(returncode=2)

        # First call (train_autoencoder) succeeds; second (generate_precursor) fails.
        with patch("subprocess.run", side_effect=[success, failure]):
            with pytest.raises(SystemExit) as exc_info:
                rp.main()

        assert exc_info.value.code == 1
        assert not trigger.exists(), "Trigger must be deleted after precursor script failure"


class TestOutputVerificationFailure:
    """Trigger is deleted and sys.exit(1) raised when an expected output is missing."""

    def test_trigger_deleted_when_output_missing(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)
        trigger = _make_trigger(rp)

        # Both training scripts succeed but we put NO asset files in ASSETS_DIR.
        rp.ASSETS_DIR.mkdir(parents=True, exist_ok=True)
        success = MagicMock(returncode=0)

        with patch("subprocess.run", return_value=success):
            with pytest.raises(SystemExit) as exc_info:
                rp.main()

        assert exc_info.value.code == 1
        assert not trigger.exists(), "Trigger must be deleted when output verification fails"

    def test_trigger_deleted_when_partial_outputs_missing(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)
        trigger = _make_trigger(rp)

        # Create only some of the expected files — last one is missing.
        _make_assets(rp, ALL_EXPECTED[:-1])
        success = MagicMock(returncode=0)

        with patch("subprocess.run", return_value=success):
            with pytest.raises(SystemExit) as exc_info:
                rp.main()

        assert exc_info.value.code == 1
        assert not trigger.exists(), "Trigger must be deleted when a subset of outputs is missing"


class TestSuccessfulRun:
    """On a successful run baseline_count is reset and trigger is removed."""

    def _run_success(self, rp, field_dir):
        """
        Run main() with subprocess mocked to succeed, model verification bypassed,
        and docker branch disabled (shutil.which returns None so the DinD block is
        skipped).
        """
        success = MagicMock(returncode=0)
        with patch("subprocess.run", return_value=success), \
             patch("shutil.which", return_value=None), \
             patch.object(rp, "_verify_new_models", return_value=True):
            rp.main()

    def test_baseline_count_reset_after_success(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)
        trigger = _make_trigger(rp)
        _make_assets(rp, ALL_EXPECTED)

        field_dir = rp.DATA_DIR / "field"
        field_dir.mkdir(parents=True, exist_ok=True)
        (field_dir / ".sample_count").write_text("42")
        (field_dir / "session_001.csv").write_text("t,x,y,z\n0.0,0.1,0.2,0.3\n")

        self._run_success(rp, field_dir)

        baseline = (rp.DATA_DIR / ".baseline_count").read_text().strip()
        assert baseline == "42", f"Expected baseline_count=42, got {baseline!r}"
        assert not trigger.exists(), "Trigger must be removed on success"

    def test_trigger_removed_after_success(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)
        trigger = _make_trigger(rp)
        _make_assets(rp, ALL_EXPECTED)

        field_dir = rp.DATA_DIR / "field"
        field_dir.mkdir(parents=True, exist_ok=True)
        (field_dir / "session_001.csv").write_text("t,x,y,z\n0.0,0.1,0.2,0.3\n")

        self._run_success(rp, field_dir)

        assert not trigger.exists()

    def test_baseline_count_defaults_to_zero_when_sample_count_missing(
        self, tmp_path, monkeypatch
    ):
        rp = _load_pipeline(tmp_path, monkeypatch)
        trigger = _make_trigger(rp)
        _make_assets(rp, ALL_EXPECTED)

        # field dir exists but .sample_count does NOT.
        field_dir = rp.DATA_DIR / "field"
        field_dir.mkdir(parents=True, exist_ok=True)
        (field_dir / "session_001.csv").write_text("t,x,y,z\n0.0,0.1,0.2,0.3\n")

        self._run_success(rp, field_dir)

        baseline = (rp.DATA_DIR / ".baseline_count").read_text().strip()
        assert baseline == "0"


# ---------------------------------------------------------------------------
# P28: Model backup and restore
# ---------------------------------------------------------------------------

class TestBackupAndRestoreModels:
    """_backup_models / _restore_models correctly copy and restore .tflite/.json files."""

    def test_backup_and_restore_models(self, tmp_path, monkeypatch):
        rp = _load_pipeline(tmp_path, monkeypatch)

        assets_dir = tmp_path / "assets"
        assets_dir.mkdir(parents=True)
        backup_dir = tmp_path / "backup"

        # Create original model files
        (assets_dir / "vibration_anomaly.tflite").write_bytes(b"original_tflite")
        (assets_dir / "vibration_scaler.json").write_text('{"original": true}')

        # Backup
        rp._backup_models(assets_dir, backup_dir)

        # Overwrite originals with new content
        (assets_dir / "vibration_anomaly.tflite").write_bytes(b"new_tflite")
        (assets_dir / "vibration_scaler.json").write_text('{"new": true}')

        # Verify the overwritten files differ
        assert (assets_dir / "vibration_anomaly.tflite").read_bytes() == b"new_tflite"

        # Restore from backup
        rp._restore_models(backup_dir, assets_dir)

        # Verify originals are back
        assert (assets_dir / "vibration_anomaly.tflite").read_bytes() == b"original_tflite"
        assert (assets_dir / "vibration_scaler.json").read_text() == '{"original": true}'


# ---------------------------------------------------------------------------
# P30: Pre-training data validation
# ---------------------------------------------------------------------------

class TestValidateTrainingData:
    """_validate_training_data raises or returns correct sample counts."""

    def test_validate_training_data_empty(self, tmp_path, monkeypatch):
        """Empty field_dir (no CSV files at all) raises RuntimeError."""
        rp = _load_pipeline(tmp_path, monkeypatch)

        field_dir = tmp_path / "field"
        field_dir.mkdir(parents=True)
        # No CSV files created

        with pytest.raises(RuntimeError, match="No valid training samples found"):
            rp._validate_training_data(field_dir)

    def test_validate_training_data_corrupt(self, tmp_path, monkeypatch):
        """A CSV containing only a header line (no data rows) counts as 0 samples
        and results in a RuntimeError when it is the only file present."""
        rp = _load_pipeline(tmp_path, monkeypatch)

        field_dir = tmp_path / "field"
        field_dir.mkdir(parents=True)
        # Write a CSV with only a header — no data rows
        (field_dir / "session_001.csv").write_text("t,x,y,z\n")

        with pytest.raises(RuntimeError, match="No valid training samples found"):
            rp._validate_training_data(field_dir)

    def test_validate_training_data_counts_rows(self, tmp_path, monkeypatch):
        """A CSV with a header plus 3 data rows returns a sample count of 3."""
        rp = _load_pipeline(tmp_path, monkeypatch)

        field_dir = tmp_path / "field"
        field_dir.mkdir(parents=True)
        (field_dir / "session_001.csv").write_text(
            "t,x,y,z\n"
            "0.0,0.1,0.2,0.3\n"
            "0.005,0.4,0.5,0.6\n"
            "0.010,0.7,0.8,0.9\n"
        )

        count = rp._validate_training_data(field_dir)
        assert count == 3, f"Expected 3 samples, got {count}"
