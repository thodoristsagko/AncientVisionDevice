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

# Ensure the collect app is importable
_COLLECT_DIR = Path(__file__).parent.parent / "docker" / "collect"
if str(_COLLECT_DIR) not in sys.path:
    sys.path.insert(0, str(_COLLECT_DIR))

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


# ---------------------------------------------------------------------------
# P138: /stats count matches posted samples
# ---------------------------------------------------------------------------

BASE_PAYLOAD = {
    "device_id": "m5stick-01",
    "timestamp": "2026-03-03T10:00:00Z",
    "rms": 0.01,
    "ppv": 0.05,
    "freq": 15.0,
    "crest": 3.0,
    "centroid": 20.0,
    "kurtosis": 1.5,
    "stalta": 1.0,
    "arias": 0.0001,
    "cav": 0.002,
    "label": "normal",
}


class TestStatsCountMatchesPostedSamples:

    def test_stats_count_matches_5_posted_samples(self, tmp_path, monkeypatch):
        """After posting 5 samples to /ingest, /stats must report total_samples == 5."""
        from app import create_app

        monkeypatch.setenv("DATA_DIR", str(tmp_path))
        app = create_app()
        app.config["TESTING"] = True

        with app.test_client() as c:
            # Post 5 samples with distinct timestamps to avoid deduplication
            for i in range(5):
                payload = {**BASE_PAYLOAD, "timestamp": f"2026-03-03T10:00:{i:02d}Z"}
                r = c.post("/ingest", json=payload)
                assert r.status_code == 200, (
                    f"Sample {i} ingest failed with status {r.status_code}: {r.data}"
                )

            # /stats must report exactly 5 total samples
            resp = c.get("/stats")
            assert resp.status_code == 200
            data = resp.get_json()
            assert "total_samples" in data, f"/stats response missing 'total_samples': {data}"
            assert data["total_samples"] == 5, (
                f"Expected total_samples=5, got {data['total_samples']}"
            )

    def test_stats_count_after_zero_posts(self, tmp_path, monkeypatch):
        """Before any ingest calls, /stats must report total_samples == 0."""
        from app import create_app

        monkeypatch.setenv("DATA_DIR", str(tmp_path))
        app = create_app()
        app.config["TESTING"] = True

        with app.test_client() as c:
            resp = c.get("/stats")
            assert resp.status_code == 200
            data = resp.get_json()
            assert data["total_samples"] == 0

    def test_stats_count_increments_per_sample(self, tmp_path, monkeypatch):
        """total_samples increments by 1 after each successful ingest."""
        from app import create_app

        monkeypatch.setenv("DATA_DIR", str(tmp_path))
        app = create_app()
        app.config["TESTING"] = True

        with app.test_client() as c:
            for i in range(3):
                payload = {**BASE_PAYLOAD, "timestamp": f"2026-03-03T11:00:{i:02d}Z"}
                c.post("/ingest", json=payload)

                resp = c.get("/stats")
                data = resp.get_json()
                assert data["total_samples"] == i + 1, (
                    f"After {i+1} ingests, expected total_samples={i+1}, "
                    f"got {data['total_samples']}"
                )
