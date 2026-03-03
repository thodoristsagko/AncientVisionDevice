"""
Tests for scripts/reset_pipeline.py
"""
import sys
from pathlib import Path

import pytest

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from reset_pipeline import reset_pipeline


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _setup_data_dir(tmp_path: Path, sample_count: int = 0,
                    baseline_count: int = 0,
                    create_trigger: bool = False) -> Path:
    """
    Create a minimal data directory layout inside tmp_path and return it.
    """
    data_dir = tmp_path / "data"
    field_dir = data_dir / "field"
    field_dir.mkdir(parents=True)

    (field_dir / ".sample_count").write_text(str(sample_count))
    (data_dir / ".baseline_count").write_text(str(baseline_count))

    if create_trigger:
        (data_dir / ".retrain_trigger").touch()

    return data_dir


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestResetPipeline:

    def test_dry_run_does_nothing(self, tmp_path):
        """
        --dry-run must not modify any files on disk.
        """
        data_dir = _setup_data_dir(
            tmp_path, sample_count=200, baseline_count=50, create_trigger=True
        )
        trigger_file = data_dir / ".retrain_trigger"
        baseline_file = data_dir / ".baseline_count"

        # Record state before
        assert trigger_file.exists()
        baseline_before = baseline_file.read_text().strip()

        result = reset_pipeline(data_dir, dry_run=True)

        # Files must be unchanged
        assert trigger_file.exists(), "Dry run must NOT delete the trigger file"
        assert baseline_file.read_text().strip() == baseline_before, (
            "Dry run must NOT change the baseline count"
        )

        # Return dict must still report what would have happened
        assert result["dry_run"] is True
        assert result["trigger_deleted"] is True
        assert result["baseline_set_to"] == 200

    def test_resets_trigger(self, tmp_path):
        """
        reset_pipeline() must delete .retrain_trigger if it exists.
        """
        data_dir = _setup_data_dir(
            tmp_path, sample_count=100, create_trigger=True
        )
        trigger_file = data_dir / ".retrain_trigger"
        assert trigger_file.exists()

        result = reset_pipeline(data_dir, dry_run=False)

        assert not trigger_file.exists(), ".retrain_trigger must be deleted"
        assert result["trigger_deleted"] is True

    def test_no_trigger_file_is_safe(self, tmp_path):
        """
        Calling reset_pipeline when no trigger file exists must not raise.
        """
        data_dir = _setup_data_dir(tmp_path, sample_count=42, create_trigger=False)

        result = reset_pipeline(data_dir, dry_run=False)

        assert result["trigger_deleted"] is False
        # Baseline should still be updated
        baseline = int((data_dir / ".baseline_count").read_text().strip())
        assert baseline == 42

    def test_baseline_set_to_current_count(self, tmp_path):
        """
        After reset_pipeline(), .baseline_count must equal .sample_count.
        """
        data_dir = _setup_data_dir(
            tmp_path, sample_count=350, baseline_count=100, create_trigger=True
        )

        result = reset_pipeline(data_dir, dry_run=False)

        baseline = int((data_dir / ".baseline_count").read_text().strip())
        assert baseline == 350, f"Expected baseline=350, got {baseline}"
        assert result["baseline_set_to"] == 350
        assert result["baseline_was"] == 100

    def test_baseline_defaults_to_zero_when_sample_count_missing(self, tmp_path):
        """
        If .sample_count does not exist, baseline must be set to 0.
        """
        data_dir = tmp_path / "data"
        field_dir = data_dir / "field"
        field_dir.mkdir(parents=True)
        # Deliberately omit .sample_count

        result = reset_pipeline(data_dir, dry_run=False)

        assert result["baseline_set_to"] == 0
        baseline = int((data_dir / ".baseline_count").read_text().strip())
        assert baseline == 0
