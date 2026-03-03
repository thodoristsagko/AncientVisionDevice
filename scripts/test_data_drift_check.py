"""Tests for scripts/data_drift_check.py

P135 — covers:
  - No field data → exits 0 with "no data" message
  - Field data matching training distribution → exits 0, no alerts
  - Severely drifted field data (z-score >> 3) → exits 1 with ALERT
  - Missing scaler file → exits 1 with error message
"""
import csv
import io
import json
import os
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from data_drift_check import load_field_data, field_stats, main


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

FEATURE_NAMES = ["rms", "ppv", "freq", "crest", "centroid"]

def _make_scaler(tmp_path: Path, feature_names=None, mean=None, scale=None) -> Path:
    """Write a fake precursor_classifier_scaler.json and return its path."""
    if feature_names is None:
        feature_names = FEATURE_NAMES
    n = len(feature_names)
    if mean is None:
        mean = [0.0] * n
    if scale is None:
        scale = [1.0] * n
    data = {"feature_names": feature_names, "mean": mean, "scale": scale}
    path = tmp_path / "precursor_classifier_scaler.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def _make_csv(field_dir: Path, name: str, rows: list) -> None:
    """Write rows (list of dicts) as a CSV in field_dir."""
    field_dir.mkdir(parents=True, exist_ok=True)
    path = field_dir / name
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fieldnames = list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _normal_rows(n: int = 10, mean_val: float = 0.05) -> list:
    """Return n CSV rows where all FEATURE_NAMES are close to mean_val."""
    return [
        {
            "device_id": "dev-01",
            "timestamp": f"2026-03-03T10:00:{i:02d}Z",
            "rms": str(mean_val),
            "ppv": str(mean_val),
            "freq": str(mean_val),
            "crest": str(mean_val),
            "centroid": str(mean_val),
        }
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# Unit tests for load_field_data
# ---------------------------------------------------------------------------

class TestLoadFieldData:

    def test_no_directory_returns_empty(self, tmp_path):
        rows = load_field_data(str(tmp_path / "nonexistent"))
        assert rows == []

    def test_empty_directory_returns_empty(self, tmp_path):
        rows = load_field_data(str(tmp_path))
        assert rows == []

    def test_loads_csv_files(self, tmp_path):
        _make_csv(tmp_path, "session.csv", _normal_rows(5))
        rows = load_field_data(str(tmp_path))
        assert len(rows) == 5

    def test_loads_multiple_csvs(self, tmp_path):
        _make_csv(tmp_path, "a.csv", _normal_rows(3))
        _make_csv(tmp_path, "b.csv", _normal_rows(4))
        rows = load_field_data(str(tmp_path))
        assert len(rows) == 7


# ---------------------------------------------------------------------------
# Unit tests for field_stats
# ---------------------------------------------------------------------------

class TestFieldStats:

    def test_returns_stats_per_feature(self):
        rows = _normal_rows(10, mean_val=0.1)
        stats = field_stats(rows, FEATURE_NAMES)
        assert "rms" in stats
        assert "ppv" in stats
        assert stats["rms"]["n"] == 10
        assert abs(stats["rms"]["mean"] - 0.1) < 1e-9

    def test_empty_rows_returns_empty_stats(self):
        stats = field_stats([], FEATURE_NAMES)
        assert stats == {}

    def test_ignores_non_numeric_values(self):
        rows = [
            {"rms": "0.1", "ppv": "bad", "freq": "0.2", "crest": "0.3", "centroid": "0.4"},
            {"rms": "0.2", "ppv": "0.05", "freq": "0.3", "crest": "0.4", "centroid": "0.5"},
        ]
        stats = field_stats(rows, FEATURE_NAMES)
        # rms has 2 valid values, ppv has 1 valid value
        assert stats["rms"]["n"] == 2
        assert stats["ppv"]["n"] == 1


# ---------------------------------------------------------------------------
# P135: main() integration tests (patching ASSETS_DIR and argparse)
# ---------------------------------------------------------------------------

class TestMainNoData:

    def test_no_field_data_exits_0(self, tmp_path, capsys):
        """main() must exit 0 (not crash) when no CSV files are present."""
        assets_dir = tmp_path / "ml"
        assets_dir.mkdir()
        _make_scaler(assets_dir)

        field_dir = tmp_path / "field"
        field_dir.mkdir()

        import data_drift_check as ddc
        original_assets = ddc.ASSETS_DIR
        ddc.ASSETS_DIR = str(assets_dir)
        try:
            with patch("sys.argv", ["data_drift_check.py", "--data-dir", str(field_dir)]):
                main()  # must return without calling sys.exit(1)
        finally:
            ddc.ASSETS_DIR = original_assets

        captured = capsys.readouterr()
        # Should print a "no data" style message
        assert "No field data" in captured.out or "no" in captured.out.lower()


class TestMainNoDrift:

    def test_data_matching_distribution_exits_0(self, tmp_path):
        """Field data close to training mean → no drift alert, return without exit(1)."""
        assets_dir = tmp_path / "ml"
        assets_dir.mkdir()
        # Training mean=0.1, std=1.0 for all features
        _make_scaler(assets_dir, mean=[0.1] * 5, scale=[1.0] * 5)

        field_dir = tmp_path / "field"
        # Field mean ~ 0.1 too → z-score ~ 0
        _make_csv(field_dir, "session.csv", _normal_rows(20, mean_val=0.1))

        import data_drift_check as ddc
        original_assets = ddc.ASSETS_DIR
        ddc.ASSETS_DIR = str(assets_dir)
        try:
            with patch("sys.argv", ["data_drift_check.py", "--data-dir", str(field_dir)]):
                main()  # should NOT raise SystemExit
        finally:
            ddc.ASSETS_DIR = original_assets


class TestMainDrift:

    def test_drifted_data_exits_1(self, tmp_path):
        """Field data far from training mean → z-score >> 3 → SystemExit(1) + ALERT."""
        assets_dir = tmp_path / "ml"
        assets_dir.mkdir()
        # Training mean=0.0, std=0.01 → even field_mean=1.0 gives z=100
        _make_scaler(assets_dir, mean=[0.0] * 5, scale=[0.01] * 5)

        field_dir = tmp_path / "field"
        _make_csv(field_dir, "session.csv", _normal_rows(20, mean_val=1.0))

        import data_drift_check as ddc
        original_assets = ddc.ASSETS_DIR
        ddc.ASSETS_DIR = str(assets_dir)
        try:
            with patch("sys.argv", ["data_drift_check.py", "--data-dir", str(field_dir)]):
                with pytest.raises(SystemExit) as exc_info:
                    main()
        finally:
            ddc.ASSETS_DIR = original_assets

        assert exc_info.value.code == 1

    def test_drifted_output_contains_alert(self, tmp_path, capsys):
        """The ALERT word must appear in output when drift is detected."""
        assets_dir = tmp_path / "ml"
        assets_dir.mkdir()
        _make_scaler(assets_dir, mean=[0.0] * 5, scale=[0.01] * 5)

        field_dir = tmp_path / "field"
        _make_csv(field_dir, "session.csv", _normal_rows(20, mean_val=1.0))

        import data_drift_check as ddc
        original_assets = ddc.ASSETS_DIR
        ddc.ASSETS_DIR = str(assets_dir)
        try:
            with patch("sys.argv", ["data_drift_check.py", "--data-dir", str(field_dir)]):
                with pytest.raises(SystemExit):
                    main()
        finally:
            ddc.ASSETS_DIR = original_assets

        captured = capsys.readouterr()
        assert "ALERT" in captured.out


class TestMainMissingScaler:

    def test_missing_scaler_exits_1(self, tmp_path):
        """When scaler JSON does not exist, main() must print error and exit 1."""
        assets_dir = tmp_path / "ml"
        assets_dir.mkdir()
        # Intentionally do NOT write the scaler file

        import data_drift_check as ddc
        original_assets = ddc.ASSETS_DIR
        ddc.ASSETS_DIR = str(assets_dir)
        try:
            with patch("sys.argv", ["data_drift_check.py"]):
                with pytest.raises(SystemExit) as exc_info:
                    main()
        finally:
            ddc.ASSETS_DIR = original_assets

        assert exc_info.value.code == 1

    def test_custom_threshold_accepted(self, tmp_path, capsys):
        """--threshold argument is accepted without error."""
        assets_dir = tmp_path / "ml"
        assets_dir.mkdir()
        _make_scaler(assets_dir, mean=[0.1] * 5, scale=[1.0] * 5)

        field_dir = tmp_path / "field"
        _make_csv(field_dir, "session.csv", _normal_rows(5, mean_val=0.1))

        import data_drift_check as ddc
        original_assets = ddc.ASSETS_DIR
        ddc.ASSETS_DIR = str(assets_dir)
        try:
            with patch("sys.argv", [
                "data_drift_check.py",
                "--data-dir", str(field_dir),
                "--threshold", "5.0",
            ]):
                main()  # should not raise
        finally:
            ddc.ASSETS_DIR = original_assets
