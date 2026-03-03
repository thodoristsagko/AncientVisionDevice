"""
Integration tests: collect -> watcher trigger pipeline.

Verifies that the file-based signalling between the collect service
and the watcher service works correctly end-to-end.
"""
import sys
from pathlib import Path

import pytest

# Ensure the watcher module is importable
_WATCHER_DIR = Path(__file__).parent.parent / "docker" / "watcher"
if str(_WATCHER_DIR) not in sys.path:
    sys.path.insert(0, str(_WATCHER_DIR))

from watch import should_trigger, reset_baseline, TRIGGER_THRESHOLD


class TestCollectToWatcher:

    def test_watcher_triggers_after_enough_samples(self, tmp_path):
        """
        When sample_count - baseline_count >= TRIGGER_THRESHOLD the watcher
        should signal a retrain and reset_baseline() must update the baseline.
        """
        field_dir = tmp_path / "field"
        field_dir.mkdir()
        (field_dir / ".sample_count").write_text("105")
        (tmp_path / ".baseline_count").write_text("0")

        # Verify should_trigger() returns True (105 - 0 = 105 >= 100)
        assert should_trigger(tmp_path) is True

        # Simulate the watcher writing the trigger file
        trigger_file = tmp_path / ".retrain_trigger"
        trigger_file.touch()
        assert trigger_file.exists()

        # reset_baseline() must set baseline to current sample count
        reset_baseline(tmp_path)
        baseline = int((tmp_path / ".baseline_count").read_text().strip())
        assert baseline == 105

    def test_watcher_does_not_trigger_below_threshold(self, tmp_path):
        """
        When new samples (sample_count - baseline_count) < TRIGGER_THRESHOLD
        should_trigger() must return False.
        """
        field_dir = tmp_path / "field"
        field_dir.mkdir()
        (field_dir / ".sample_count").write_text("50")
        (tmp_path / ".baseline_count").write_text("0")

        # 50 - 0 = 50, which is below the default threshold of 100
        assert should_trigger(tmp_path) is False

    def test_full_cycle_via_files(self, tmp_path):
        """
        Full cycle: 150 total samples, 30 baseline (120 new) should trigger.
        After reset_baseline(), baseline must equal 150.
        """
        field_dir = tmp_path / "field"
        field_dir.mkdir()
        (field_dir / ".sample_count").write_text("150")
        (tmp_path / ".baseline_count").write_text("30")

        # 150 - 30 = 120 >= TRIGGER_THRESHOLD (100)
        assert should_trigger(tmp_path) is True

        # Simulate what the watcher main loop does on trigger
        trigger_file = tmp_path / ".retrain_trigger"
        trigger_file.touch()
        reset_baseline(tmp_path)

        # Baseline must now equal current sample count
        baseline = int((tmp_path / ".baseline_count").read_text().strip())
        assert baseline == 150
