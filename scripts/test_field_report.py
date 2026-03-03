"""
Tests for scripts/field_report.py
"""
import csv
import sys
from pathlib import Path

import pytest

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from field_report import _collect_stats

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CSV_HEADER = [
    "device_id", "timestamp", "rms", "ppv", "freq", "crest",
    "centroid", "kurtosis", "stalta", "arias", "cav", "label",
]


def _write_csv(path: Path, rows: list) -> None:
    """Write rows (list of dicts) to path as a CSV with the standard header."""
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_HEADER, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def _row(**kwargs) -> dict:
    """Build a minimal valid sample row, overriding any fields via kwargs."""
    base = {
        "device_id": "m5stick-01",
        "timestamp": "2026-03-03T10:00:00Z",
        "rms": "0.01",
        "ppv": "0.05",
        "freq": "15.0",
        "crest": "3.0",
        "centroid": "20.0",
        "kurtosis": "1.5",
        "stalta": "1.0",
        "arias": "0.0001",
        "cav": "0.002",
        "label": "normal",
    }
    base.update(kwargs)
    return base


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestFieldReport:

    def test_report_empty_dir(self, tmp_path):
        """No CSVs in field_dir -> all counts are zero / empty."""
        field_dir = tmp_path / "field"
        field_dir.mkdir()

        stats = _collect_stats(field_dir)

        assert stats["total_samples"] == 0
        assert stats["csv_files"] == 0
        assert stats["samples_per_day"] == {}
        assert stats["samples_per_device"] == {}
        assert stats["samples_per_label"] == {}

    def test_report_counts_rows(self, tmp_path):
        """A CSV with 3 data rows must produce total_samples=3."""
        field_dir = tmp_path / "field"
        field_dir.mkdir()

        _write_csv(field_dir / "2026-03-03.csv", [
            _row(timestamp="2026-03-03T10:00:00Z"),
            _row(timestamp="2026-03-03T10:00:01Z"),
            _row(timestamp="2026-03-03T10:00:02Z"),
        ])

        stats = _collect_stats(field_dir)

        assert stats["total_samples"] == 3
        assert stats["csv_files"] == 1

    def test_report_groups_by_label(self, tmp_path):
        """Mix of labels -> per-class counts must be correct."""
        field_dir = tmp_path / "field"
        field_dir.mkdir()

        _write_csv(field_dir / "2026-03-03.csv", [
            _row(label="normal",             timestamp="2026-03-03T10:00:00Z"),
            _row(label="normal",             timestamp="2026-03-03T10:00:01Z"),
            _row(label="soil_creep",         timestamp="2026-03-03T10:00:02Z"),
            _row(label="crack_propagation",  timestamp="2026-03-03T10:00:03Z"),
            _row(label="crack_propagation",  timestamp="2026-03-03T10:00:04Z"),
            _row(label="crack_propagation",  timestamp="2026-03-03T10:00:05Z"),
        ])

        stats = _collect_stats(field_dir)

        assert stats["total_samples"] == 6
        assert stats["samples_per_label"]["normal"] == 2
        assert stats["samples_per_label"]["soil_creep"] == 1
        assert stats["samples_per_label"]["crack_propagation"] == 3

    def test_report_groups_by_day(self, tmp_path):
        """Multiple CSV files -> samples_per_day keyed by filename stem."""
        field_dir = tmp_path / "field"
        field_dir.mkdir()

        _write_csv(field_dir / "2026-03-01.csv", [
            _row(timestamp="2026-03-01T10:00:00Z"),
        ])
        _write_csv(field_dir / "2026-03-02.csv", [
            _row(timestamp="2026-03-02T10:00:00Z"),
            _row(timestamp="2026-03-02T10:00:01Z"),
        ])

        stats = _collect_stats(field_dir)

        assert stats["total_samples"] == 3
        assert stats["csv_files"] == 2
        assert stats["samples_per_day"]["2026-03-01"] == 1
        assert stats["samples_per_day"]["2026-03-02"] == 2

    def test_report_groups_by_device(self, tmp_path):
        """Samples from multiple devices are counted separately."""
        field_dir = tmp_path / "field"
        field_dir.mkdir()

        _write_csv(field_dir / "2026-03-03.csv", [
            _row(device_id="dev-a", timestamp="2026-03-03T10:00:00Z"),
            _row(device_id="dev-a", timestamp="2026-03-03T10:00:01Z"),
            _row(device_id="dev-b", timestamp="2026-03-03T10:00:02Z"),
        ])

        stats = _collect_stats(field_dir)

        assert stats["samples_per_device"]["dev-a"] == 2
        assert stats["samples_per_device"]["dev-b"] == 1
