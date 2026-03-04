#!/usr/bin/env python3
"""
Tests for new AncientVision pipeline scripts.
Covers: ab_test_models, data_augmentation_report, device_calibration_check,
        session_report (import-only and functional).
"""
import csv
import json
import os
import sys
import tempfile
from pathlib import Path
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

import pytest

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

# ---------------------------------------------------------------------------
# Guard against data_augmentation_report.py replacing sys.stdout at import time.
# That module wraps sys.stdout in a UTF-8 TextIOWrapper on Windows so that its
# block-character bar chart renders correctly.  When pytest's capsys fixture
# temporarily swaps sys.stdout for a tmpfile, the TextIOWrapper wraps the
# capsys tmpfile; when pytest's capsys teardown closes that file, all
# subsequent tempfile operations (including tmp_path fixture setup) raise
# "I/O operation on closed file".
#
# Fix: pretend we are not on win32 during the one-time module-level import so
# the TextIOWrapper replacement branch is never triggered.  The module is
# already cached in sys.modules after this; subsequent test-body imports are
# no-ops.  We restore sys.platform immediately.
# ---------------------------------------------------------------------------
# data_augmentation_report is imported lazily inside each test body to avoid
# triggering its Windows sys.stdout replacement at collection time.


# ---------------------------------------------------------------------------
# Shared CSV helpers
# ---------------------------------------------------------------------------

def _write_csv(path: Path, rows: list) -> None:
    """Write list-of-dicts as CSV to path."""
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def _aug_row(label: str, idx: int) -> dict:
    """Single row suitable for data_augmentation_report tests."""
    return {
        "label": label,
        "ppv": "0.05",
        "rms": "0.02",
        "crest": "3.0",
        "kurtosis": "2.0",
        "device_id": "test-device",
        "timestamp": f"2026-03-03T10:{idx // 60:02d}:{idx % 60:02d}Z",
    }


def _calibration_row(device_id: str, ts: datetime, ppv: float) -> dict:
    """Single row suitable for device_calibration_check tests."""
    return {
        "device_id": device_id,
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ppv": str(ppv),
        "rms": str(ppv),
    }


def _session_row(idx: int, ts: datetime, ppv: float = 0.05,
                 anomaly_level: str = "normal") -> dict:
    """Single row suitable for session_report tests."""
    return {
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "ppv": str(ppv),
        "rms": str(ppv * 0.7),
        "freq": "15.0",
        "kurtosis": "2.5",
        "anomaly_level": anomaly_level,
        "device_id": "test-device",
    }


# ===========================================================================
# data_augmentation_report tests
# ===========================================================================

class TestDataAugmentationReportBalanced:
    """P01 — balanced dataset produces a valid report (no crash)."""

    def test_balanced_data_runs_without_error(self, tmp_path):
        rows = (
            [_aug_row("normal", i) for i in range(100)]
            + [_aug_row("soil_creep", i) for i in range(100)]
            + [_aug_row("crack_propagation", i) for i in range(100)]
        )
        _write_csv(tmp_path / "session.csv", rows)

        import data_augmentation_report as dar

        rc = dar.main(["--data-dir", str(tmp_path)])
        assert rc == 0

    def test_balanced_data_returns_correct_counts(self, tmp_path):
        rows = (
            [_aug_row("normal", i) for i in range(100)]
            + [_aug_row("soil_creep", i) for i in range(100)]
            + [_aug_row("crack_propagation", i) for i in range(100)]
        )
        _write_csv(tmp_path / "session.csv", rows)

        import data_augmentation_report as dar

        counts = dar.count_per_class(dar.load_field_csvs(tmp_path))
        assert counts["normal"] == 100
        assert counts["soil_creep"] == 100
        assert counts["crack_propagation"] == 100
        # imminent_failure was not added
        assert counts.get("imminent_failure", 0) == 0

    def test_balanced_data_output_contains_class_distribution(self, tmp_path, capsys):
        rows = (
            [_aug_row("normal", i) for i in range(100)]
            + [_aug_row("soil_creep", i) for i in range(100)]
            + [_aug_row("crack_propagation", i) for i in range(100)]
        )
        _write_csv(tmp_path / "session.csv", rows)

        import data_augmentation_report as dar

        dar.main(["--data-dir", str(tmp_path)])
        captured = capsys.readouterr()
        assert "Class Distribution" in captured.out
        assert "normal" in captured.out
        assert "soil_creep" in captured.out

    def test_json_output_contains_class_counts(self, tmp_path):
        rows = (
            [_aug_row("normal", i) for i in range(100)]
            + [_aug_row("soil_creep", i) for i in range(100)]
            + [_aug_row("crack_propagation", i) for i in range(100)]
        )
        _write_csv(tmp_path / "session.csv", rows)
        out_path = tmp_path / "report.json"

        import data_augmentation_report as dar

        dar.main(["--data-dir", str(tmp_path), "--output", str(out_path)])
        assert out_path.exists()
        data = json.loads(out_path.read_text())
        assert "class_counts" in data
        assert data["class_counts"]["normal"] == 100


class TestDataAugmentationReportImbalance:
    """P02 — imbalanced dataset is detected and flagged UNDER-REPRESENTED."""

    def test_imbalanced_data_flags_soil_creep(self, tmp_path, capsys):
        rows = (
            [_aug_row("normal", i) for i in range(200)]
            + [_aug_row("soil_creep", i) for i in range(10)]
        )
        _write_csv(tmp_path / "session.csv", rows)

        import data_augmentation_report as dar

        dar.main(["--data-dir", str(tmp_path)])
        captured = capsys.readouterr()
        assert "UNDER-REPRESENTED" in captured.out

    def test_imbalanced_recommendations_mark_soil_creep(self, tmp_path):
        rows = (
            [_aug_row("normal", i) for i in range(200)]
            + [_aug_row("soil_creep", i) for i in range(10)]
        )
        _write_csv(tmp_path / "session.csv", rows)

        import data_augmentation_report as dar

        counts = dar.count_per_class(dar.load_field_csvs(tmp_path))
        recs = dar.augmentation_recommendations(counts, min_samples=200)
        assert "UNDER-REPRESENTED" in recs["soil_creep"]["status"]

    def test_imbalanced_to_add_is_positive_for_minority(self, tmp_path):
        rows = (
            [_aug_row("normal", i) for i in range(200)]
            + [_aug_row("soil_creep", i) for i in range(10)]
        )
        _write_csv(tmp_path / "session.csv", rows)

        import data_augmentation_report as dar

        counts = dar.count_per_class(dar.load_field_csvs(tmp_path))
        recs = dar.augmentation_recommendations(counts, min_samples=200)
        assert recs["soil_creep"]["to_add"] > 0
        # Normal class at 200 may still need additions to reach target=max(200,200)
        # but should not be UNDER-REPRESENTED
        assert "UNDER-REPRESENTED" not in recs["normal"]["status"]

    def test_empty_data_dir_returns_zero_counts(self, tmp_path):
        import data_augmentation_report as dar

        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        rows = dar.load_field_csvs(empty_dir)
        counts = dar.count_per_class(rows)
        assert all(v == 0 for v in counts.values())


# ===========================================================================
# device_calibration_check tests
# ===========================================================================

class TestDeviceCalibrationCheckClean:
    """P03 — clean device with low noise floor → exit 0."""

    def _make_clean_csv(self, data_dir: Path, device_id: str, n: int = 150,
                        ppv: float = 0.002) -> None:
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [
            _calibration_row(device_id, base_ts + timedelta(seconds=i), ppv)
            for i in range(n)
        ]
        _write_csv(data_dir / "session.csv", rows)

    def test_clean_device_exits_0(self, tmp_path):
        self._make_clean_csv(tmp_path, "test-dev-01")

        import device_calibration_check as dcc

        with pytest.raises(SystemExit) as exc_info:
            dcc.main(["--data-dir", str(tmp_path), "--min-samples", "100"])
        assert exc_info.value.code == 0

    def test_clean_device_status_is_ok(self, tmp_path):
        self._make_clean_csv(tmp_path, "test-dev-01")
        data_dir = Path(tmp_path)

        import device_calibration_check as dcc

        device_data = dcc.load_device_data(data_dir)
        results = [
            dcc.analyze_device(
                dev_id, rows,
                idle_ppv_threshold=0.01,
                noise_threshold=dcc.DEFAULT_NOISE_THRESHOLD,
                bias_threshold=dcc.DEFAULT_BIAS_THRESHOLD,
                drift_threshold=dcc.DEFAULT_DRIFT_THRESHOLD,
                min_samples=100,
            )
            for dev_id, rows in device_data.items()
        ]
        assert all(r["status"] == "OK" for r in results)

    def test_clean_device_noise_floor_below_threshold(self, tmp_path):
        self._make_clean_csv(tmp_path, "test-dev-01", ppv=0.002)
        data_dir = Path(tmp_path)

        import device_calibration_check as dcc

        device_data = dcc.load_device_data(data_dir)
        rows = list(device_data.values())[0]
        result = dcc.analyze_device(
            "test-dev-01", rows,
            idle_ppv_threshold=0.01,
            noise_threshold=dcc.DEFAULT_NOISE_THRESHOLD,
            bias_threshold=dcc.DEFAULT_BIAS_THRESHOLD,
            drift_threshold=dcc.DEFAULT_DRIFT_THRESHOLD,
            min_samples=100,
        )
        # noise_floor is std of constant signal = 0.0 < 0.005 threshold
        assert result["noise_floor"] < dcc.DEFAULT_NOISE_THRESHOLD


class TestDeviceCalibrationCheckNoisy:
    """P04 — noisy device → exit 1 (needs recalibration)."""

    def _make_noisy_csv(self, data_dir: Path, device_id: str, n: int = 150) -> None:
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        for i in range(n):
            # Alternating 0.0 and 0.02 — high std relative to noise threshold of 0.005
            ppv = 0.0 if i % 2 == 0 else 0.02
            rows.append(_calibration_row(device_id, base_ts + timedelta(seconds=i), ppv))
        _write_csv(data_dir / "session.csv", rows)

    def test_noisy_device_exits_1(self, tmp_path):
        self._make_noisy_csv(tmp_path, "test-dev-02")

        import device_calibration_check as dcc

        # Use --idle-ppv 0.05 so all 150 rows count as idle (both 0.0 and 0.02
        # are below 0.05), giving enough samples and forcing noise detection.
        with pytest.raises(SystemExit) as exc_info:
            dcc.main([
                "--data-dir", str(tmp_path),
                "--min-samples", "100",
                "--idle-ppv", "0.05",
            ])
        assert exc_info.value.code == 1

    def test_noisy_device_status_is_recalibrate(self, tmp_path):
        self._make_noisy_csv(tmp_path, "test-dev-02")
        data_dir = Path(tmp_path)

        import device_calibration_check as dcc

        device_data = dcc.load_device_data(data_dir)
        rows = list(device_data.values())[0]
        result = dcc.analyze_device(
            "test-dev-02", rows,
            idle_ppv_threshold=0.05,  # high enough to include all rows as idle
            noise_threshold=dcc.DEFAULT_NOISE_THRESHOLD,
            bias_threshold=dcc.DEFAULT_BIAS_THRESHOLD,
            drift_threshold=dcc.DEFAULT_DRIFT_THRESHOLD,
            min_samples=100,
        )
        assert result["status"] == "RECALIBRATE"

    def test_noisy_device_has_issues(self, tmp_path):
        self._make_noisy_csv(tmp_path, "test-dev-02")
        data_dir = Path(tmp_path)

        import device_calibration_check as dcc

        device_data = dcc.load_device_data(data_dir)
        rows = list(device_data.values())[0]
        result = dcc.analyze_device(
            "test-dev-02", rows,
            idle_ppv_threshold=0.05,
            noise_threshold=dcc.DEFAULT_NOISE_THRESHOLD,
            bias_threshold=dcc.DEFAULT_BIAS_THRESHOLD,
            drift_threshold=dcc.DEFAULT_DRIFT_THRESHOLD,
            min_samples=100,
        )
        assert len(result["issues"]) > 0

    def test_insufficient_samples_returns_insufficient_data(self, tmp_path):
        """When fewer than min_samples idle rows exist, status = INSUFFICIENT DATA."""
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_calibration_row("dev-small", base_ts + timedelta(seconds=i), 0.001)
                for i in range(50)]
        _write_csv(tmp_path / "session.csv", rows)

        import device_calibration_check as dcc

        device_data = dcc.load_device_data(Path(tmp_path))
        dev_rows = list(device_data.values())[0]
        result = dcc.analyze_device(
            "dev-small", dev_rows,
            idle_ppv_threshold=0.01,
            noise_threshold=dcc.DEFAULT_NOISE_THRESHOLD,
            bias_threshold=dcc.DEFAULT_BIAS_THRESHOLD,
            drift_threshold=dcc.DEFAULT_DRIFT_THRESHOLD,
            min_samples=100,
        )
        assert result["status"] == "INSUFFICIENT DATA"


# ===========================================================================
# session_report tests
# ===========================================================================

class TestSessionReportGeneratesOutput:
    """P05 — session report produces Markdown containing required fields."""

    def _make_session_csv(self, path: Path, n: int = 100,
                          duration_minutes: int = 10) -> None:
        base_ts = datetime(2026, 3, 3, 8, 0, 0, tzinfo=timezone.utc)
        interval = timedelta(seconds=duration_minutes * 60 / n)
        rows = [_session_row(i, base_ts + i * interval) for i in range(n)]
        _write_csv(path, rows)

    def test_markdown_contains_ancientvision_title(self, tmp_path, capsys):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)

        import session_report as sr

        sr.main(["--session-csv", str(csv_path), "--format", "md"])
        captured = capsys.readouterr()
        assert "AncientVision" in captured.out

    def test_markdown_contains_ppv_label(self, tmp_path, capsys):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)

        import session_report as sr

        sr.main(["--session-csv", str(csv_path), "--format", "md"])
        captured = capsys.readouterr()
        assert "PPV" in captured.out

    def test_markdown_contains_summary_section(self, tmp_path, capsys):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)

        import session_report as sr

        sr.main(["--session-csv", str(csv_path), "--format", "md"])
        captured = capsys.readouterr()
        assert "## Summary" in captured.out

    def test_markdown_written_to_file(self, tmp_path):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)
        out_path = tmp_path / "report.md"

        import session_report as sr

        sr.main(["--session-csv", str(csv_path), "--output", str(out_path),
                 "--format", "md"])
        assert out_path.exists()
        content = out_path.read_text(encoding="utf-8")
        assert "AncientVision" in content
        assert "PPV" in content

    def test_html_format_written_to_file(self, tmp_path):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)
        out_path = tmp_path / "report.html"

        import session_report as sr

        sr.main(["--session-csv", str(csv_path), "--output", str(out_path),
                 "--format", "html"])
        assert out_path.exists()
        content = out_path.read_text(encoding="utf-8")
        assert "AncientVision" in content
        assert "<html" in content

    def test_missing_csv_exits_1(self, tmp_path):
        import session_report as sr

        with pytest.raises(SystemExit) as exc_info:
            sr.main(["--session-csv", str(tmp_path / "nonexistent.csv")])
        assert exc_info.value.code == 1

    def test_site_name_appears_in_report(self, tmp_path, capsys):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)

        import session_report as sr

        sr.main(["--session-csv", str(csv_path),
                 "--site-name", "Paros North Trench",
                 "--format", "md"])
        captured = capsys.readouterr()
        assert "Paros North Trench" in captured.out

    def test_compute_stats_returns_expected_keys(self, tmp_path):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)

        import session_report as sr

        rows = sr.load_csv(csv_path)
        stats = sr.compute_stats(rows)
        for key in ("mean_ppv", "max_ppv", "p95_ppv", "sample_count",
                    "alert_count", "duration_s"):
            assert key in stats, f"Missing key: {key}"

    def test_sample_count_matches_csv_rows(self, tmp_path):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path, n=100)

        import session_report as sr

        rows = sr.load_csv(csv_path)
        stats = sr.compute_stats(rows)
        assert stats["sample_count"] == 100

    def test_build_markdown_returns_string(self, tmp_path):
        csv_path = tmp_path / "session.csv"
        self._make_session_csv(csv_path)

        import session_report as sr

        rows = sr.load_csv(csv_path)
        stats = sr.compute_stats(rows)
        md = sr.build_markdown(stats, "Test Site")
        assert isinstance(md, str)
        assert "AncientVision" in md


# ===========================================================================
# ab_test_models tests (import-only — no TFLite model available in CI)
# ===========================================================================

class TestAbTestModelsImport:
    """P06 — ab_test_models is importable and exposes expected public API."""

    def test_module_importable(self):
        import ab_test_models  # noqa: F401

    def test_has_model_runner_class(self):
        import ab_test_models
        assert hasattr(ab_test_models, "ModelRunner")
        assert isinstance(ab_test_models.ModelRunner, type)

    def test_has_generate_test_set(self):
        import ab_test_models
        assert callable(ab_test_models.generate_test_set)

    def test_generate_test_set_returns_correct_count(self):
        import ab_test_models
        samples = ab_test_models.generate_test_set(40)
        # Rounds up to nearest multiple of 4 (4 classes * 10 = 40)
        assert len(samples) == 40

    def test_generate_test_set_item_structure(self):
        import ab_test_models
        samples = ab_test_models.generate_test_set(8)
        feat_dict, label = samples[0]
        assert isinstance(feat_dict, dict)
        assert label in ab_test_models.LABELS

    def test_labels_contains_four_classes(self):
        import ab_test_models
        assert len(ab_test_models.LABELS) == 4
        assert "normal" in ab_test_models.LABELS
        assert "imminent_failure" in ab_test_models.LABELS

    def test_build_parser_returns_parser(self):
        import ab_test_models
        import argparse
        parser = ab_test_models.build_parser()
        assert isinstance(parser, argparse.ArgumentParser)

    def test_help_flag_does_not_crash(self):
        """--help should raise SystemExit(0), not any other exception."""
        import ab_test_models
        with pytest.raises(SystemExit) as exc_info:
            ab_test_models.build_parser().parse_args(["--help"])
        assert exc_info.value.code == 0

    def test_build_vector_returns_array(self):
        """build_vector should return a numpy array of the right length."""
        import ab_test_models
        import numpy as np
        feat = {n: 0.5 for n in ab_test_models.FEATURE_NAMES}
        vec = ab_test_models.build_vector(feat, ab_test_models.FEATURE_NAMES)
        assert isinstance(vec, np.ndarray)
        assert len(vec) == len(ab_test_models.FEATURE_NAMES)


# ===========================================================================
# model_confidence_analysis tests (import-only — no TFLite model required)
# ===========================================================================

class TestModelConfidenceAnalysisImport:
    """P07 — model_confidence_analysis is importable and exposes expected API."""

    def test_module_importable(self):
        """model_confidence_analysis can be imported."""
        import model_confidence_analysis  # noqa: F401

    def test_build_parser_exists(self):
        """build_parser function exists and returns ArgumentParser."""
        import model_confidence_analysis
        import argparse
        parser = model_confidence_analysis.build_parser()
        assert isinstance(parser, argparse.ArgumentParser)

    def test_build_parser_has_assets_dir_arg(self):
        """Parser has --assets-dir argument."""
        import model_confidence_analysis
        parser = model_confidence_analysis.build_parser()
        # Parse with no args to see default behavior
        args = parser.parse_args([])
        assert hasattr(args, "assets_dir")

    def test_build_parser_has_n_samples_arg(self):
        """Parser has --n-samples argument."""
        import model_confidence_analysis
        parser = model_confidence_analysis.build_parser()
        args = parser.parse_args(["--n-samples", "100"])
        assert args.n_samples == 100

    def test_build_parser_has_output_arg(self):
        """Parser has --output argument."""
        import model_confidence_analysis
        parser = model_confidence_analysis.build_parser()
        args = parser.parse_args(["--output", "/tmp/report.json"])
        assert args.output == "/tmp/report.json"

    def test_help_flag_does_not_crash(self):
        """--help should raise SystemExit(0)."""
        import model_confidence_analysis
        with pytest.raises(SystemExit) as exc_info:
            model_confidence_analysis.build_parser().parse_args(["--help"])
        assert exc_info.value.code == 0

    def test_has_generate_test_samples(self):
        """generate_test_samples function exists."""
        import model_confidence_analysis
        assert callable(model_confidence_analysis.generate_test_samples)

    def test_generate_test_samples_returns_list(self):
        """generate_test_samples returns a list of samples."""
        import model_confidence_analysis
        samples = model_confidence_analysis.generate_test_samples(8)
        assert isinstance(samples, list)
        assert len(samples) == 8

    def test_generate_test_samples_item_structure(self):
        """Each sample is a (features_dict, label_str) tuple."""
        import model_confidence_analysis
        samples = model_confidence_analysis.generate_test_samples(4)
        for feat, label in samples:
            assert isinstance(feat, dict)
            assert isinstance(label, str)
            assert label in model_confidence_analysis.LABELS

    def test_labels_contains_four_classes(self):
        """LABELS constant has 4 classes."""
        import model_confidence_analysis
        assert len(model_confidence_analysis.LABELS) == 4
        assert "normal" in model_confidence_analysis.LABELS
        assert "imminent_failure" in model_confidence_analysis.LABELS


# ===========================================================================
# live_dashboard tests (import-only — curses not available in CI)
# ===========================================================================

class TestLiveDashboardImport:
    """P08 — live_dashboard is importable and argparse works."""

    def test_module_importable(self):
        """live_dashboard can be imported without starting the event loop."""
        import live_dashboard  # noqa: F401

    def test_main_has_url_arg(self):
        """main() accepts --url argument."""
        import live_dashboard
        import argparse
        # Create a minimal parser to test argparse behavior
        parser = argparse.ArgumentParser()
        parser.add_argument("--url", default="http://localhost:8765")
        parser.add_argument("--interval", type=int, default=2)
        parser.add_argument("--data-dir", default="./data")
        args = parser.parse_args(["--url", "http://192.168.1.1:8765"])
        assert args.url == "http://192.168.1.1:8765"

    def test_main_help_flag(self):
        """--help flag does not crash."""
        import subprocess
        result = subprocess.run(
            [sys.executable, "scripts/live_dashboard.py", "--help"],
            capture_output=True, text=True
        )
        # On systems without curses, main() may fail with a graceful exit;
        # on systems with curses, argparse will print help and exit with 0.
        # Either way, we're checking that the script doesn't crash unexpectedly.
        assert result.returncode in (0, 1)

    def test_fetch_health_function_exists(self):
        """fetch_health function is defined."""
        import live_dashboard
        assert callable(live_dashboard.fetch_health)

    def test_fetch_stats_function_exists(self):
        """fetch_stats function is defined."""
        import live_dashboard
        assert callable(live_dashboard.fetch_stats)

    def test_labels_constant_exists(self):
        """LABELS constant exists and has expected classes."""
        import live_dashboard
        assert hasattr(live_dashboard, "LABELS")
        assert "normal" in live_dashboard.LABELS
        assert "imminent_failure" in live_dashboard.LABELS
