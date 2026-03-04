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


# ---------------------------------------------------------------------------
# --dry-run flag
# ---------------------------------------------------------------------------

class TestDryRun:
    """dry_run() validates prerequisites and returns 0 on success, 1 on failure."""

    def _setup_valid_state(self, rp, tmp_path) -> Path:
        """Create a minimal valid state: trigger + field CSV. Returns field_dir."""
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.TRIGGER_FILE.touch()
        field_dir = rp.DATA_DIR / "field"
        field_dir.mkdir(parents=True, exist_ok=True)
        (field_dir / "session.csv").write_text("t,ppv\n0.0,0.1\n0.005,0.2\n")
        return field_dir

    def test_dry_run_returns_1_when_no_trigger(self, tmp_path, monkeypatch):
        """dry_run() returns 1 when trigger file is absent (pipeline is a no-op)."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        # Trigger file deliberately NOT created.
        field_dir = rp.DATA_DIR / "field"
        field_dir.mkdir(parents=True, exist_ok=True)
        (field_dir / "session.csv").write_text("t,ppv\n0.0,0.1\n")

        result = rp.dry_run()
        assert result == 1, "dry_run() should return 1 when trigger is missing"

    def test_dry_run_returns_1_when_no_field_data(self, tmp_path, monkeypatch):
        """dry_run() returns 1 when field data directory is absent."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.TRIGGER_FILE.touch()
        # field/ dir deliberately NOT created

        result = rp.dry_run()
        assert result == 1, "dry_run() should return 1 when field dir is missing"

    def test_dry_run_returns_1_when_field_data_empty(self, tmp_path, monkeypatch):
        """dry_run() returns 1 when field data directory has no valid samples."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.TRIGGER_FILE.touch()
        field_dir = rp.DATA_DIR / "field"
        field_dir.mkdir(parents=True, exist_ok=True)
        # CSV with header only — no data rows
        (field_dir / "session.csv").write_text("t,ppv\n")

        result = rp.dry_run()
        assert result == 1, "dry_run() should return 1 when field data is empty"

    def test_dry_run_returns_0_with_valid_data_and_trigger(self, tmp_path, monkeypatch):
        """dry_run() returns 0 when trigger exists and field data is valid."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        self._setup_valid_state(rp, tmp_path)
        # Point ASSETS_DIR at a writable temp location (will not exist — parent is writable)
        rp.ASSETS_DIR = tmp_path / "assets_output"

        result = rp.dry_run()
        assert result == 0, "dry_run() should return 0 when all prerequisites are met"

    def test_dry_run_does_not_run_training(self, tmp_path, monkeypatch):
        """dry_run() must not invoke any subprocess (no actual training)."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        self._setup_valid_state(rp, tmp_path)
        rp.ASSETS_DIR = tmp_path / "assets_output"

        with patch("subprocess.run") as mock_run:
            rp.dry_run()
            mock_run.assert_not_called()

    def test_dry_run_writes_to_pipeline_log(self, tmp_path, monkeypatch):
        """dry_run() writes at least one JSON entry to pipeline.log."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        self._setup_valid_state(rp, tmp_path)
        rp.ASSETS_DIR = tmp_path / "assets_output"

        rp.dry_run()

        log_path = rp.DATA_DIR / "pipeline.log"
        assert log_path.exists(), "pipeline.log must be created by dry_run()"
        lines = [l for l in log_path.read_text(encoding="utf-8").splitlines() if l.strip()]
        assert lines, "pipeline.log must contain at least one JSON entry"
        # Each line must be valid JSON
        for line in lines:
            parsed = __import__("json").loads(line)
            assert "ts" in parsed and "msg" in parsed


# ---------------------------------------------------------------------------
# --status flag
# ---------------------------------------------------------------------------

class TestStatus:
    """status() prints pipeline state and returns 0."""

    def test_status_returns_0_with_no_data(self, tmp_path, monkeypatch, capsys):
        """status() returns 0 even when no pipeline_metrics.json exists."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.ASSETS_DIR = tmp_path / "assets"

        result = rp.status()
        assert result == 0

    def test_status_prints_last_training_time(self, tmp_path, monkeypatch, capsys):
        """status() displays 'pipeline_run_at' from pipeline_metrics.json."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.ASSETS_DIR = tmp_path / "assets"

        metrics = {
            "pipeline_run_at": "2026-03-04T10:00:00+00:00",
            "training_duration_seconds": 42.5,
            "samples_processed": 7,
            "model_sizes": {},
        }
        (rp.DATA_DIR / "pipeline_metrics.json").write_text(
            __import__("json").dumps(metrics)
        )

        rp.status()
        out = capsys.readouterr().out
        assert "2026-03-04T10:00:00" in out, "status() must print the last training timestamp"
        assert "42.5" in out, "status() must print the training duration"

    def test_status_prints_model_version(self, tmp_path, monkeypatch, capsys):
        """status() displays model version from precursor_classifier_config.json."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.ASSETS_DIR = tmp_path / "assets"
        rp.ASSETS_DIR.mkdir(parents=True, exist_ok=True)

        config = {
            "model_version": "2.3.1",
            "trained_at": "2026-03-04T09:00:00+00:00",
        }
        (rp.ASSETS_DIR / "precursor_classifier_config.json").write_text(
            __import__("json").dumps(config)
        )

        rp.status()
        out = capsys.readouterr().out
        assert "2.3.1" in out, "status() must print the model version"

    def test_status_prints_sample_count(self, tmp_path, monkeypatch, capsys):
        """status() prints the number of samples in field data CSVs."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.ASSETS_DIR = tmp_path / "assets"

        field_dir = rp.DATA_DIR / "field"
        field_dir.mkdir(parents=True, exist_ok=True)
        (field_dir / "s1.csv").write_text("t,ppv\n0.0,0.1\n0.005,0.2\n0.010,0.3\n")
        (field_dir / "s2.csv").write_text("t,ppv\n0.0,0.1\n0.005,0.2\n")

        rp.status()
        out = capsys.readouterr().out
        # 3 rows in s1 + 2 rows in s2 = 5 total samples
        assert "5" in out, "status() must print the total sample count (5)"

    def test_status_reports_healthy_when_models_present(self, tmp_path, monkeypatch, capsys):
        """status() reports HEALTHY when both .tflite models exist."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.ASSETS_DIR = tmp_path / "assets"
        rp.ASSETS_DIR.mkdir(parents=True, exist_ok=True)

        (rp.ASSETS_DIR / "vibration_anomaly.tflite").write_bytes(b"fake_tflite")
        (rp.ASSETS_DIR / "precursor_classifier.tflite").write_bytes(b"fake_tflite")

        rp.status()
        out = capsys.readouterr().out
        assert "HEALTHY" in out, "status() should report HEALTHY when all models are present"

    def test_status_reports_needs_attention_when_model_missing(self, tmp_path, monkeypatch, capsys):
        """status() reports NEEDS ATTENTION when a .tflite model is absent."""
        rp = _load_pipeline(tmp_path, monkeypatch)
        rp.DATA_DIR.mkdir(parents=True, exist_ok=True)
        rp.ASSETS_DIR = tmp_path / "assets"
        rp.ASSETS_DIR.mkdir(parents=True, exist_ok=True)
        # Only one model present — precursor_classifier is missing

        (rp.ASSETS_DIR / "vibration_anomaly.tflite").write_bytes(b"fake_tflite")

        rp.status()
        out = capsys.readouterr().out
        assert "NEEDS ATTENTION" in out, (
            "status() should report NEEDS ATTENTION when a model is missing"
        )
