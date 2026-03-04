#!/usr/bin/env python3
"""
Direct function tests for pipeline_status.py (no subprocess calls)

Usage:
    python -m pytest scripts/test_pipeline_status_direct.py -v
"""

import json
import os
import tempfile
from io import StringIO
from pathlib import Path
from unittest import mock

# Import functions from pipeline_status
import sys
sys.path.insert(0, "scripts")
from pipeline_status import (
    _load_json_safe,
    _format_bytes,
    _get_file_age_days,
    _count_samples_in_csv,
    _build_bar_chart,
)


class TestHelperFunctions:
    """Test helper functions directly."""

    def test_load_json_safe_valid_file(self):
        """Test loading a valid JSON file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            json_file = Path(tmpdir) / "test.json"
            json_file.write_text('{"key": "value"}')

            result = _load_json_safe(str(json_file))
            assert result == {"key": "value"}

    def test_load_json_safe_missing_file(self):
        """Test loading a missing JSON file returns empty dict."""
        result = _load_json_safe("/nonexistent/path/file.json")
        assert result == {}

    def test_load_json_safe_invalid_json(self):
        """Test loading invalid JSON returns empty dict."""
        with tempfile.TemporaryDirectory() as tmpdir:
            json_file = Path(tmpdir) / "bad.json"
            json_file.write_text("this is not json {}")

            result = _load_json_safe(str(json_file))
            assert result == {}

    def test_format_bytes(self):
        """Test byte formatting."""
        assert _format_bytes(512) == "512.0 B"
        assert _format_bytes(1024) == "1.0 KB"
        assert _format_bytes(1024 * 1024) == "1.0 MB"
        assert _format_bytes(1024 * 1024 * 1024) == "1.0 GB"

    def test_count_samples_in_csv_valid(self):
        """Test counting samples in valid CSV."""
        with tempfile.TemporaryDirectory() as tmpdir:
            csv_file = Path(tmpdir) / "test.csv"
            csv_file.write_text(
                "timestamp,label\n"
                "2026-03-03T10:00:00,normal\n"
                "2026-03-03T10:01:00,normal\n"
                "2026-03-03T10:02:00,soil_creep\n"
            )

            result = _count_samples_in_csv(str(csv_file))
            assert result == {"normal": 2, "soil_creep": 1}

    def test_count_samples_in_csv_missing_file(self):
        """Test counting samples with missing file."""
        result = _count_samples_in_csv("/nonexistent/file.csv")
        assert result == {}

    def test_count_samples_in_csv_unlabeled(self):
        """Test counting unlabeled samples."""
        with tempfile.TemporaryDirectory() as tmpdir:
            csv_file = Path(tmpdir) / "test.csv"
            csv_file.write_text(
                "timestamp,label\n"
                "2026-03-03T10:00:00,normal\n"
                "2026-03-03T10:01:00,\n"
                "2026-03-03T10:02:00,normal\n"
            )

            result = _count_samples_in_csv(str(csv_file))
            assert result == {"normal": 2, "(unlabeled)": 1}

    def test_build_bar_chart(self):
        """Test bar chart building."""
        data = {"normal": 100, "anomaly": 10}
        result = _build_bar_chart(data)

        assert len(result) == 2
        # Check that anomaly comes first alphabetically, then normal
        assert "anomaly" in result[0]
        assert "normal" in result[1]
        assert "█" in result[0]  # Has bar characters

    def test_build_bar_chart_empty(self):
        """Test bar chart with empty data."""
        result = _build_bar_chart({})
        assert len(result) == 1
        assert "(no data)" in result[0]


class TestSectionLogic:
    """Test logic of report sections."""

    def test_ml_models_section_with_configs(self):
        """Test ML models section with config files."""
        with tempfile.TemporaryDirectory() as tmpdir:
            assets_dir = Path(tmpdir)

            # Create config file
            config = {
                "model_version": "1.0.0",
                "input_dim": 17,
                "class_names": ["normal", "anomaly"]
            }
            config_file = assets_dir / "precursor_classifier_config.json"
            config_file.write_text(json.dumps(config))

            # Create TFLite file
            tflite_file = assets_dir / "precursor_classifier.tflite"
            tflite_file.write_bytes(b"dummy tflite data")

            # Verify files exist
            assert config_file.exists()
            assert tflite_file.exists()

            # Check config loading
            loaded_config = _load_json_safe(str(config_file))
            assert loaded_config["model_version"] == "1.0.0"

    def test_training_data_counting(self):
        """Test training data aggregation."""
        with tempfile.TemporaryDirectory() as tmpdir:
            field_dir = Path(tmpdir) / "field"
            field_dir.mkdir()

            # Create multiple CSV files
            for day in range(1, 4):
                csv_file = field_dir / f"2026-03-0{day}.csv"
                csv_file.write_text(
                    "timestamp,label\n"
                    "2026-03-0{}T10:00:00,normal\n"
                    "2026-03-0{}T10:01:00,soil_creep\n".format(day, day)
                )

            # Count all samples
            total = 0
            for csv_file in field_dir.glob("*.csv"):
                counts = _count_samples_in_csv(str(csv_file))
                total += sum(counts.values())

            assert total == 6  # 2 samples per day × 3 days

    def test_class_imbalance_calculation(self):
        """Test class imbalance ratio calculation."""
        from collections import defaultdict

        label_counts = defaultdict(int)
        label_counts["normal"] = 100
        label_counts["rare"] = 10

        counts_vals = list(label_counts.values())
        imbalance = max(counts_vals) / min(counts_vals) if min(counts_vals) > 0 else 0

        assert imbalance == 10.0


if __name__ == "__main__":
    import pytest
    pytest.main([__file__, "-v"])
