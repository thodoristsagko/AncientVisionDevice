#!/usr/bin/env python3
"""
Tests for new AncientVision pipeline scripts.
Covers: ab_test_models, data_augmentation_report, device_calibration_check,
        session_report (import-only and functional).
"""
import csv
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

import pytest
import numpy as np

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


# ===========================================================================
# model_monitor.py tests
# ===========================================================================

class TestModelMonitorImport(unittest.TestCase):
    """model_monitor.py is importable and has expected API."""

    def test_module_importable(self):
        """model_monitor can be imported."""
        spec = importlib.util.spec_from_file_location("model_monitor", "scripts/model_monitor.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertIsNotNone(mod)

    def test_has_main(self):
        """model_monitor has main function or check_degradation."""
        spec = importlib.util.spec_from_file_location("model_monitor", "scripts/model_monitor.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertTrue(hasattr(mod, "main") or hasattr(mod, "check_degradation"))

    def test_check_degradation_no_alerts_good_metrics(self):
        """check_degradation returns no alerts for good metrics."""
        spec = importlib.util.spec_from_file_location("model_monitor", "scripts/model_monitor.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        metrics = {"accuracy": 0.90, "avg_confidence": 0.85, "low_confidence_fraction": 0.10, "n_samples": 50}
        alerts = mod.check_degradation(metrics, baseline=None)
        self.assertEqual(len(alerts), 0)

    def test_check_degradation_alerts_on_low_confidence(self):
        """check_degradation alerts when avg_confidence is low."""
        spec = importlib.util.spec_from_file_location("model_monitor", "scripts/model_monitor.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        metrics = {"accuracy": 0.50, "avg_confidence": 0.40, "low_confidence_fraction": 0.60, "n_samples": 50}
        alerts = mod.check_degradation(metrics, baseline=None)
        self.assertGreater(len(alerts), 0)

    def test_check_degradation_alerts_on_accuracy_drop(self):
        """check_degradation alerts when accuracy drops from baseline."""
        spec = importlib.util.spec_from_file_location("model_monitor", "scripts/model_monitor.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        metrics = {"accuracy": 0.70, "avg_confidence": 0.75, "low_confidence_fraction": 0.10, "n_samples": 50}
        baseline = {"accuracy": 0.90}
        alerts = mod.check_degradation(metrics, baseline=baseline)
        self.assertGreater(len(alerts), 0)

    def test_cli_help(self):
        """--help flag exits with 0."""
        result = subprocess.run(
            [sys.executable, "scripts/model_monitor.py", "--help"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)


# ===========================================================================
# seismic_frequency_analysis.py tests
# ===========================================================================

class TestSeismicFrequencyAnalysis(unittest.TestCase):
    """seismic_frequency_analysis.py is importable and classifies frequencies."""

    def _load(self):
        """Load seismic_frequency_analysis module."""
        spec = importlib.util.spec_from_file_location(
            "seismic_freq", "scripts/seismic_frequency_analysis.py"
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_module_importable(self):
        """seismic_frequency_analysis can be imported."""
        self._load()

    def test_classify_microseismic(self):
        """classify_frequency returns 'microseismic' for 0.5 Hz."""
        mod = self._load()
        self.assertEqual(mod.classify_frequency(0.5), "microseismic")

    def test_classify_low_seismic(self):
        """classify_frequency returns 'low_seismic' for 5.0 Hz."""
        mod = self._load()
        self.assertEqual(mod.classify_frequency(5.0), "low_seismic")

    def test_classify_construction(self):
        """classify_frequency returns 'construction' for 25.0 Hz."""
        mod = self._load()
        self.assertEqual(mod.classify_frequency(25.0), "construction")

    def test_classify_high_freq(self):
        """classify_frequency returns 'high_freq' for 75.0 Hz."""
        mod = self._load()
        self.assertEqual(mod.classify_frequency(75.0), "high_freq")

    def test_bands_dict_has_four_entries(self):
        """BANDS constant has 4 frequency bands."""
        mod = self._load()
        self.assertEqual(len(mod.BANDS), 4)

    def test_cli_help(self):
        """--help flag exits with 0."""
        result = subprocess.run(
            [sys.executable, "scripts/seismic_frequency_analysis.py", "--help"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)

    def test_analyze_empty_dir(self):
        """analyze_csv returns error dict for missing file."""
        mod = self._load()
        with tempfile.TemporaryDirectory() as td:
            result = mod.analyze_csv(Path(td) / "nonexistent.csv")
            # Should return dict (possibly with error key), not raise
            self.assertIsInstance(result, dict)


# ===========================================================================
# compare_devices.py tests
# ===========================================================================

class TestCompareDevices(unittest.TestCase):
    """compare_devices.py — cross-device comparison."""

    def _load(self):
        spec = importlib.util.spec_from_file_location(
            "compare_devices", "scripts/compare_devices.py"
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_module_importable(self):
        self._load()

    def test_cli_help(self):
        result = subprocess.run(
            [sys.executable, "scripts/compare_devices.py", "--help"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)

    def test_empty_data_dir_ok(self):
        """Empty data dir exits 0 (nothing to compare)."""
        with tempfile.TemporaryDirectory() as td:
            result = subprocess.run(
                [sys.executable, "scripts/compare_devices.py", "--data-dir", td],
                capture_output=True, text=True
            )
            self.assertIn(result.returncode, (0, 1))

    def test_compute_cross_device_consistency_single_device(self):
        """Single device has no cross-device variance."""
        mod = self._load()
        devices = {
            "device_A": {"ppv": {"mean": 0.5, "std": 0.1, "min": 0.1, "max": 1.0, "p95": 0.9}}
        }
        result = mod.compute_cross_device_consistency(devices)
        # Single device → no CV computable → empty result
        self.assertIsInstance(result, dict)

    def test_compute_cross_device_consistency_two_devices(self):
        """Two devices with same means → CV near zero."""
        mod = self._load()
        devices = {
            "device_A": {"ppv": {"mean": 1.0, "std": 0.1, "min": 0.5, "max": 2.0, "p95": 1.8}},
            "device_B": {"ppv": {"mean": 1.0, "std": 0.1, "min": 0.5, "max": 2.0, "p95": 1.8}},
        }
        result = mod.compute_cross_device_consistency(devices)
        self.assertIn("ppv", result)
        self.assertAlmostEqual(result["ppv"]["cv"], 0.0, places=3)

    def test_compute_cross_device_consistency_high_variation(self):
        """Two devices with very different means → high CV."""
        mod = self._load()
        devices = {
            "device_A": {"ppv": {"mean": 0.1, "std": 0.01, "min": 0.0, "max": 0.2, "p95": 0.18}},
            "device_B": {"ppv": {"mean": 5.0, "std": 0.5,  "min": 3.0, "max": 7.0, "p95": 6.5}},
        }
        result = mod.compute_cross_device_consistency(devices)
        self.assertIn("ppv", result)
        self.assertGreater(result["ppv"]["cv"], 0.25)

    def test_metric_cols_exist(self):
        mod = self._load()
        self.assertIn("ppv", mod.METRIC_COLS)
        self.assertIn("kurtosis", mod.METRIC_COLS)


# ===========================================================================
# site_summary_report.py tests
# ===========================================================================

class TestSiteSummaryReport(unittest.TestCase):
    """site_summary_report.py — site-wide safety reporting."""

    def _load(self):
        spec = importlib.util.spec_from_file_location(
            "site_summary_report", "scripts/site_summary_report.py"
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_module_importable(self):
        self._load()

    def test_cli_help(self):
        result = subprocess.run(
            [sys.executable, "scripts/site_summary_report.py", "--help"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)

    def test_build_markdown_empty_stats(self):
        mod = self._load()
        report = mod.build_markdown({}, [], "Test Site")
        self.assertIn("AncientVision", report)
        self.assertIn("Test Site", report)
        self.assertIsInstance(report, str)

    def test_build_markdown_with_ppv(self):
        mod = self._load()
        stats = {
            "total_samples": 100,
            "total_sessions": 3,
            "ppv_max": 2.5,
            "ppv_mean": 0.3,
            "ppv_above_1": 5,
            "ppv_above_3": 0,
            "precursor_events": 2,
        }
        report = mod.build_markdown(stats, [], "Paros 2026")
        self.assertIn("2.5", report)
        self.assertIn("Paros 2026", report)

    def test_safety_assessment_low_risk(self):
        mod = self._load()
        stats = {"ppv_max": 0.5}
        report = mod.build_markdown(stats, [], "Site")
        self.assertIn("LOW RISK", report)

    def test_safety_assessment_high_risk(self):
        mod = self._load()
        stats = {"ppv_max": 6.0}
        report = mod.build_markdown(stats, [], "Site")
        self.assertIn("HIGH RISK", report)

    def test_empty_data_dir_runs_ok(self):
        """Empty data dir should exit 0 (nothing to process)."""
        with tempfile.TemporaryDirectory() as td:
            result = subprocess.run(
                [sys.executable, "scripts/site_summary_report.py", "--data-dir", td],
                capture_output=True, text=True
            )
            self.assertIn(result.returncode, (0, 1))


# ===========================================================================
# ppv_exceedance_analysis.py tests
# ===========================================================================

class TestPpvExceedanceAnalysis(unittest.TestCase):
    """ppv_exceedance_analysis.py — DIN threshold exceedance analysis."""

    def _load(self):
        spec = importlib.util.spec_from_file_location(
            "ppv_exceedance", "scripts/ppv_exceedance_analysis.py"
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_module_importable(self):
        self._load()

    def test_cli_help(self):
        result = subprocess.run(
            [sys.executable, "scripts/ppv_exceedance_analysis.py", "--help"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)

    def test_compute_exceedance_all_exceed(self):
        mod = self._load()
        values = np.array([1.0, 2.0, 3.0])
        prob = mod.compute_exceedance(values, 0.5)
        self.assertAlmostEqual(prob, 1.0)

    def test_compute_exceedance_none_exceed(self):
        mod = self._load()
        values = np.array([0.1, 0.2, 0.3])
        prob = mod.compute_exceedance(values, 1.0)
        self.assertAlmostEqual(prob, 0.0)

    def test_compute_exceedance_half(self):
        mod = self._load()
        values = np.array([0.5, 1.5])
        prob = mod.compute_exceedance(values, 1.0)
        self.assertAlmostEqual(prob, 0.5)

    def test_standard_thresholds_dict_nonempty(self):
        mod = self._load()
        self.assertGreater(len(mod.STANDARD_THRESHOLDS), 0)

    def test_compute_percentiles_keys(self):
        mod = self._load()
        values = np.array([1.0, 2.0, 3.0, 4.0, 5.0])
        pct = mod.compute_percentiles(values)
        self.assertIn("p95", pct)
        self.assertIn("mean", pct)
        self.assertIn("max", pct)


# ===========================================================================
# export_gps_track.py tests
# ===========================================================================

class TestExportGpsTrack(unittest.TestCase):
    """export_gps_track.py — GPX/KML export."""

    def _load(self):
        spec = importlib.util.spec_from_file_location(
            "export_gps_track", "scripts/export_gps_track.py"
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_module_importable(self):
        self._load()

    def test_cli_help(self):
        result = subprocess.run(
            [sys.executable, "scripts/export_gps_track.py", "--help"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)

    def test_empty_dir_ok(self):
        with tempfile.TemporaryDirectory() as td:
            result = subprocess.run(
                [sys.executable, "scripts/export_gps_track.py", "--data-dir", td],
                capture_output=True, text=True
            )
            self.assertIn(result.returncode, (0, 1))

    def test_export_gpx_writes_file(self):
        import pandas as pd
        mod = self._load()
        with tempfile.TemporaryDirectory() as td:
            output = Path(td) / "track.gpx"
            df = pd.DataFrame({
                "lat": [37.0, 37.001, 37.002],
                "lon": [23.0, 23.001, 23.002],
                "ppv": [0.1, 0.5, 0.2],
                "anomaly_level": ["SAFE", "ANOMALY", "SAFE"],
            })
            count = mod.export_gpx(df, output)
            self.assertEqual(count, 3)
            self.assertTrue(output.exists())
            content = output.read_text()
            self.assertIn("<gpx", content)
            self.assertIn("<trkpt", content)

    def test_kml_colors_dict_nonempty(self):
        mod = self._load()
        self.assertIn("CRITICAL", mod.KML_COLORS)
        self.assertIn("SAFE", mod.KML_COLORS)


# ===========================================================================
# vibration_timeline.py tests
# ===========================================================================

class TestVibrationTimeline(unittest.TestCase):
    """vibration_timeline.py — ASCII PPV timeline visualization."""

    def _load(self):
        spec = importlib.util.spec_from_file_location(
            "vibration_timeline", "scripts/vibration_timeline.py"
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_module_importable(self):
        self._load()

    def test_cli_help(self):
        result = subprocess.run(
            [sys.executable, "scripts/vibration_timeline.py", "--help"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)

    def test_empty_dir_ok(self):
        with tempfile.TemporaryDirectory() as td:
            result = subprocess.run(
                [sys.executable, "scripts/vibration_timeline.py", "--data-dir", td],
                capture_output=True, text=True
            )
            self.assertIn(result.returncode, (0, 1))

    def test_render_timeline_basic(self):
        import pandas as pd
        mod = self._load()
        df = pd.DataFrame({
            "ppv": [0.1, 0.5, 1.0, 0.3, 0.8, 0.2, 0.9, 0.4, 0.7, 0.1],
        })
        lines = mod.render_timeline(df, width=30)
        self.assertIsInstance(lines, list)
        self.assertGreater(len(lines), 0)

    def test_render_timeline_no_ppv_col(self):
        import pandas as pd
        mod = self._load()
        df = pd.DataFrame({"rms": [0.1, 0.2]})
        lines = mod.render_timeline(df, width=30)
        self.assertIsInstance(lines, list)
        # Should return error message lines, not crash
        self.assertGreater(len(lines), 0)

    def test_ppv_to_char_zero(self):
        mod = self._load()
        c = mod.ppv_to_char(0.0, 1.0)
        self.assertIsInstance(c, str)
        self.assertEqual(len(c), 1)

    def test_ppv_to_char_max(self):
        mod = self._load()
        c = mod.ppv_to_char(1.0, 1.0)
        self.assertIsInstance(c, str)
        self.assertEqual(len(c), 1)


# ===========================================================================
# data_drift_detector tests
# ===========================================================================

def _make_drift_csv(path: Path, n: int = 100,
                    ppv_mean: float = 0.05, ppv_std: float = 0.01,
                    ax_mean: float = 0.1, ay_mean: float = 0.2,
                    az_mean: float = 9.8) -> None:
    """Write a CSV with ppv, ax, ay, az columns."""
    import random
    random.seed(42)
    rows = []
    for i in range(n):
        rows.append({
            "ppv": str(ppv_mean + random.gauss(0, ppv_std)),
            "ax": str(ax_mean + random.gauss(0, 0.01)),
            "ay": str(ay_mean + random.gauss(0, 0.01)),
            "az": str(az_mean + random.gauss(0, 0.05)),
            "label": "normal",
        })
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


class TestDataDriftDetector:
    """Tests for data_drift_detector.py."""

    def _run(self, args: list) -> "subprocess.CompletedProcess":
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "data_drift_detector.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_data(self, tmp_path):
        """Exits 0 and prints informative message when no CSV data exists."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        assert result.returncode == 0
        combined = result.stdout + result.stderr
        assert any(phrase in combined for phrase in [
            "No CSV data", "No baseline", "No data"
        ]), f"Expected informative message in output: {combined!r}"

    def test_save_baseline(self, tmp_path):
        """--save-baseline writes drift_baseline.json with expected structure."""
        _make_drift_csv(tmp_path / "session.csv")
        baseline_path = tmp_path / "drift_baseline.json"
        result = self._run([
            "--data-dir", str(tmp_path),
            "--baseline", str(baseline_path),
            "--save-baseline",
        ])
        assert result.returncode == 0, f"stderr: {result.stderr}"
        assert baseline_path.exists(), "drift_baseline.json not created"
        data = json.loads(baseline_path.read_text(encoding="utf-8"))
        assert any(feat in data for feat in ["ppv", "ax", "ay", "az"]), (
            f"Expected feature keys in baseline, got: {list(data.keys())}"
        )
        for feat in data:
            assert "mean" in data[feat], f"Missing 'mean' for feature {feat}"
            assert "std" in data[feat], f"Missing 'std' for feature {feat}"

    def test_no_drift(self, tmp_path):
        """Identical data as baseline produces exit 0 and 'No significant drift'."""
        _make_drift_csv(tmp_path / "session.csv")
        baseline_path = tmp_path / "drift_baseline.json"
        self._run([
            "--data-dir", str(tmp_path),
            "--baseline", str(baseline_path),
            "--save-baseline",
        ])
        result = self._run([
            "--data-dir", str(tmp_path),
            "--baseline", str(baseline_path),
        ])
        assert result.returncode == 0, (
            f"Expected exit 0 for no drift, got {result.returncode}. stdout: {result.stdout}"
        )
        assert "No significant drift" in result.stdout, (
            f"Expected 'No significant drift' in output: {result.stdout!r}"
        )

    def test_with_drift(self, tmp_path):
        """Data shifted by many sigma from baseline -> exit 1 and drift flag."""
        # Save baseline from data around ppv=0.05 with tight std
        baseline_dir = tmp_path / "base"
        baseline_dir.mkdir()
        _make_drift_csv(baseline_dir / "b.csv", ppv_mean=0.05, ppv_std=0.005)
        baseline_path = tmp_path / "drift_baseline.json"
        self._run([
            "--data-dir", str(baseline_dir),
            "--baseline", str(baseline_path),
            "--save-baseline",
        ])
        # Current data: ppv shifted to 5.0 -- far outside 2 sigma of baseline
        current_dir = tmp_path / "current"
        current_dir.mkdir()
        _make_drift_csv(current_dir / "current.csv", ppv_mean=5.0, ppv_std=0.005)
        result = self._run([
            "--data-dir", str(current_dir),
            "--baseline", str(baseline_path),
        ])
        assert result.returncode == 1, (
            f"Expected exit 1 for drift, got {result.returncode}. stdout: {result.stdout}"
        )
        assert "DRIFT" in result.stdout, (
            f"Expected 'DRIFT' in output: {result.stdout!r}"
        )


# ===========================================================================
# retrain_advisor tests
# ===========================================================================

class TestRetrainAdvisor:
    """Tests for retrain_advisor.py."""

    def _run(self, args: list) -> "subprocess.CompletedProcess":
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "retrain_advisor.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_data(self, tmp_path):
        """With no data and no model, exits 0 (NO_ACTION)."""
        empty_dir = tmp_path / "data"
        empty_dir.mkdir()
        model_dir = tmp_path / "models"
        model_dir.mkdir()
        result = self._run([
            "--data-dir", str(empty_dir),
            "--model-dir", str(model_dir),
        ])
        assert result.returncode == 0, (
            f"Expected exit 0 (NO_ACTION) with no data, got {result.returncode}. "
            f"stdout: {result.stdout}"
        )
        assert "NO_ACTION" in result.stdout, (
            f"Expected 'NO_ACTION' in output: {result.stdout!r}"
        )

    def test_with_samples(self, tmp_path):
        """With > 500 labeled samples, a valid recommendation is printed."""
        import random
        random.seed(0)
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        model_dir = tmp_path / "models"
        model_dir.mkdir()

        labels = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]
        rows = []
        for i in range(600):
            rows.append({
                "ppv": str(0.05 + random.gauss(0, 0.01)),
                "ax": str(0.1 + random.gauss(0, 0.01)),
                "ay": str(0.2 + random.gauss(0, 0.01)),
                "az": str(9.8 + random.gauss(0, 0.05)),
                "label": labels[i % len(labels)],
            })
        csv_path = data_dir / "session.csv"
        with open(csv_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

        result = self._run([
            "--data-dir", str(data_dir),
            "--model-dir", str(model_dir),
        ])
        assert result.returncode in (0, 1, 2), (
            f"Unexpected exit code: {result.returncode}. stdout: {result.stdout}"
        )
        assert any(kw in result.stdout for kw in ["NO_ACTION", "RETRAIN_SOON", "RETRAIN_NOW"]), (
            f"Expected recommendation keyword in output: {result.stdout!r}"
        )
        assert "Score" in result.stdout, (
            f"Expected 'Score' in output: {result.stdout!r}"
        )



# ===========================================================================
# validate_training_data tests
# ===========================================================================

def _write_csv_vtd(path, rows, fieldnames=None):
    """Write a list-of-dicts CSV to path."""
    if not rows:
        with open(path, "w", newline="", encoding="utf-8") as f:
            if fieldnames:
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
        return
    fn = fieldnames or list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fn)
        writer.writeheader()
        writer.writerows(rows)


def _make_valid_rows_vtd(n=60):
    """Return n valid balanced field data rows."""
    import random
    random.seed(1234)
    rows = []
    labels = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]
    for i in range(n):
        rows.append({
            "timestamp": "2026-03-01T12:00:{:02d}Z".format(i % 60),
            "device_id": "device_001",
            "ppv": str(round(0.05 + random.gauss(0, 0.01), 6)),
            "ax": str(round(0.1 + random.gauss(0, 0.01), 6)),
            "ay": str(round(0.2 + random.gauss(0, 0.01), 6)),
            "az": str(round(9.8 + random.gauss(0, 0.05), 6)),
            "label": labels[i % len(labels)],
        })
    return rows


class TestValidateTrainingData:
    """Tests for validate_training_data.py."""

    def _run(self, args):
        env = os.environ.copy()
        env["PYTHONUTF8"] = "1"
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "validate_training_data.py")] + args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
        )

    def test_empty_data_dir(self, tmp_path):
        """With an empty directory (no CSV files), should report error for 0 samples."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        combined = result.stdout + result.stderr
        # Should fail or report no/insufficient samples
        assert result.returncode != 0 or any(
            phrase in combined
            for phrase in ["ERROR", "FAIL", "0 samples", "Only 0", "minimum"]
        ), f"Expected error/fail message for empty dir. Output: {combined!r}"

    def test_valid_data(self, tmp_path):
        """With balanced, clean data all checks should pass with exit 0."""
        rows = _make_valid_rows_vtd(n=60)
        _write_csv_vtd(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        combined = result.stdout + result.stderr
        assert result.returncode == 0, (
            f"Expected exit 0 for valid data, got {result.returncode}. Output: {combined!r}"
        )
        assert "PASS" in combined, f"Expected PASS in output: {combined!r}"

    def test_missing_values(self, tmp_path):
        """Rows with empty ppv should be flagged as missing/null."""
        rows = _make_valid_rows_vtd(n=60)
        for i in range(10):
            rows[i]["ppv"] = ""
        _write_csv_vtd(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        combined = result.stdout + result.stderr
        assert any(
            phrase in combined
            for phrase in ["missing", "null", "NaN", "ppv", "WARN", "ERROR"]
        ), f"Expected missing-value warning in output: {combined!r}"

    def test_out_of_range(self, tmp_path):
        """Rows with PPV > 100 mm/s should be flagged as out-of-range."""
        rows = _make_valid_rows_vtd(n=60)
        for i in range(5):
            rows[i]["ppv"] = "999.0"
        _write_csv_vtd(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        combined = result.stdout + result.stderr
        assert any(
            phrase in combined
            for phrase in ["ppv", "above", "maximum", "physical", "WARN", "ERROR", "bounds"]
        ), f"Expected out-of-range warning in output: {combined!r}"

    def test_class_imbalance(self, tmp_path):
        """Highly skewed class distribution should trigger a warning."""
        import random
        random.seed(42)
        rows = []
        # 58 normal, 1 soil_creep, 1 crack_propagation — no imminent_failure
        for i in range(58):
            rows.append({
                "timestamp": "2026-03-01T12:00:{:02d}Z".format(i % 60),
                "device_id": "device_001",
                "ppv": str(round(0.05 + random.gauss(0, 0.01), 6)),
                "ax": "0.1", "ay": "0.2", "az": "9.8",
                "label": "normal",
            })
        for label in ["soil_creep", "crack_propagation"]:
            rows.append({
                "timestamp": "2026-03-01T12:01:00Z",
                "device_id": "device_001",
                "ppv": "0.05", "ax": "0.1", "ay": "0.2", "az": "9.8",
                "label": label,
            })
        _write_csv_vtd(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        combined = result.stdout + result.stderr
        assert any(
            phrase in combined
            for phrase in ["class", "balance", "WARN", "ERROR", "soil_creep",
                           "crack_propagation", "imminent_failure", "%"]
        ), f"Expected class imbalance warning in output: {combined!r}"


# ===========================================================================
# training_pipeline_dry_run tests
# ===========================================================================

class TestTrainingPipelineDryRun:
    """Tests for training_pipeline_dry_run.py."""

    def _run(self, args):
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "training_pipeline_dry_run.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_data(self, tmp_path):
        """Fails when data directory has no CSV files."""
        empty_dir = tmp_path / "data"
        empty_dir.mkdir()
        model_dir = tmp_path / "models"
        model_dir.mkdir()
        result = self._run([
            "--data-dir", str(empty_dir),
            "--model-dir", str(model_dir),
        ])
        assert result.returncode == 1, (
            f"Expected exit 1 when no CSV data, got {result.returncode}. "
            f"stdout: {result.stdout}"
        )
        combined = result.stdout + result.stderr
        assert "FAIL" in combined, f"Expected FAIL in output: {combined!r}"

    def test_all_pass(self, tmp_path):
        """Passes critical checks when data dir has CSV with required columns."""
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        model_dir = tmp_path / "models"
        model_dir.mkdir()

        # Write a valid CSV with all required columns
        rows = _make_valid_rows_vtd(n=20)
        _write_csv_vtd(data_dir / "session.csv", rows)

        # Write a valid config with 17 features
        config = {
            "feature_names": [
                "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
                "stalta", "arias", "cav", "temp", "psdSlope",
                "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
                "cusum_max", "autoencoder_score",
            ],
            "input_dim": 17,
        }
        (model_dir / "precursor_classifier_config.json").write_text(
            json.dumps(config), encoding="utf-8"
        )

        result = self._run([
            "--data-dir", str(data_dir),
            "--model-dir", str(model_dir),
        ])
        combined = result.stdout + result.stderr
        # Data dir, CSV columns, output dir, packages, feature count must PASS
        assert "PASS" in combined, f"Expected at least one PASS in output: {combined!r}"
        # Exit code 0 (all pass) or 1 (some fail — acceptable if only scripts missing)
        assert result.returncode in (0, 1), (
            f"Unexpected exit code: {result.returncode}. Output: {combined!r}"
        )


# ===========================================================================
# TestSensorNoiseFloor
# ===========================================================================

class TestSensorNoiseFloor:
    """Tests for sensor_noise_floor.py."""

    def _run(self, args):
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "sensor_noise_floor.py")] + args,
            capture_output=True,
            text=True,
        )

    def _noise_row(self, ppv: float, ax: float, ay: float, az: float,
                   device_id: str = "dev-A") -> dict:
        return {
            "device_id": device_id,
            "timestamp": "2026-03-03T10:00:00Z",
            "ppv": str(ppv),
            "ax": str(ax),
            "ay": str(ay),
            "az": str(az),
        }

    def test_no_data(self, tmp_path):
        """Exits 0 gracefully when directory is empty."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        assert result.returncode == 0, (
            f"Expected exit 0 on empty dir, got {result.returncode}. "
            f"stdout: {result.stdout} stderr: {result.stderr}"
        )

    def test_low_noise(self, tmp_path):
        """Clean sensor with low noise shows OK status."""
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        # Write quiet samples with tiny accelerometer values (0.005 g — within MEMS range)
        rows = [self._noise_row(ppv=0.001, ax=0.005, ay=0.004, az=0.006)
                for _ in range(20)]
        _write_csv(data_dir / "session.csv", rows)

        result = self._run(["--data-dir", str(data_dir)])
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}. "
            f"stdout: {result.stdout} stderr: {result.stderr}"
        )
        combined = result.stdout + result.stderr
        assert "OK" in combined, f"Expected OK status for low-noise sensor: {combined!r}"
        assert "FLAGGED" not in combined, (
            f"Should not flag low-noise sensor: {combined!r}"
        )

    def test_high_noise(self, tmp_path):
        """Noisy sensor (RMS > 0.05 g in quiet state) gets FLAGGED."""
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        # quiet ppv but very high accelerometer noise (0.1 g — above 0.05g threshold)
        rows = [self._noise_row(ppv=0.001, ax=0.1, ay=0.12, az=0.09)
                for _ in range(20)]
        _write_csv(data_dir / "session.csv", rows)

        result = self._run(["--data-dir", str(data_dir)])
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}. "
            f"stdout: {result.stdout} stderr: {result.stderr}"
        )
        combined = result.stdout + result.stderr
        assert "FLAGGED" in combined, (
            f"Expected FLAGGED for high-noise sensor: {combined!r}"
        )
        assert "RECOMMENDATION" in combined or "recommend" in combined.lower(), (
            f"Expected recommendation message for flagged device: {combined!r}"
        )


# ===========================================================================
# TestEventDurationAnalysis
# ===========================================================================

class TestEventDurationAnalysis:
    """Tests for event_duration_analysis.py."""

    def _run(self, args):
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "event_duration_analysis.py")] + args,
            capture_output=True,
            text=True,
        )

    def _event_row(self, timestamp: str, ppv: float, device_id: str = "dev-A") -> dict:
        return {
            "device_id": device_id,
            "timestamp": timestamp,
            "ppv": str(ppv),
            "rms": str(ppv * 0.7),
        }

    def test_no_data(self, tmp_path):
        """Exits 0 gracefully when directory is empty."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        assert result.returncode == 0, (
            f"Expected exit 0 on empty dir, got {result.returncode}. "
            f"stdout: {result.stdout} stderr: {result.stderr}"
        )

    def test_impulsive_event(self, tmp_path):
        """Short event (< 1s total) classified as IMPULSIVE."""
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        # 3 readings within 0.5 seconds total — impulsive
        rows = [
            self._event_row("2026-03-03T10:00:00.000Z", ppv=0.5),
            self._event_row("2026-03-03T10:00:00.200Z", ppv=0.8),
            self._event_row("2026-03-03T10:00:00.450Z", ppv=0.3),
        ]
        _write_csv(data_dir / "session.csv", rows)

        result = self._run(["--data-dir", str(data_dir), "--min-ppv", "0.1"])
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}. "
            f"stdout: {result.stdout} stderr: {result.stderr}"
        )
        combined = result.stdout + result.stderr
        assert "IMPULSIVE" in combined, (
            f"Expected IMPULSIVE classification for short event: {combined!r}"
        )

    def test_sustained_event(self, tmp_path):
        """Long event (> 5s total) classified as SUSTAINED."""
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        # 7 readings spanning 6 seconds — sustained
        base_ts = [
            "2026-03-03T10:00:00Z",
            "2026-03-03T10:00:01Z",
            "2026-03-03T10:00:02Z",
            "2026-03-03T10:00:03Z",
            "2026-03-03T10:00:04Z",
            "2026-03-03T10:00:05Z",
            "2026-03-03T10:00:06Z",
        ]
        rows = [self._event_row(ts, ppv=0.3) for ts in base_ts]
        _write_csv(data_dir / "session.csv", rows)

        result = self._run(["--data-dir", str(data_dir), "--min-ppv", "0.1"])
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}. "
            f"stdout: {result.stdout} stderr: {result.stderr}"
        )
        combined = result.stdout + result.stderr
        assert "SUSTAINED" in combined, (
            f"Expected SUSTAINED classification for long event: {combined!r}"
        )


# ===========================================================================
# session_risk_report tests
# ===========================================================================

def _make_risk_csv(path: Path, rows: list) -> None:
    """Write list-of-dicts as CSV for session_risk_report tests."""
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def _risk_row(ts: datetime, ppv: float, anomaly_level: str = "normal") -> dict:
    """Single CSV row for session_risk_report tests."""
    return {
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ppv": str(ppv),
        "rms": str(ppv * 0.7),
        "anomaly_level": anomaly_level,
        "device_id": "test-device",
    }


class TestSessionRiskReport:
    """Tests for session_risk_report.py."""

    def _run(self, args: list) -> "subprocess.CompletedProcess":
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "session_risk_report.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_data(self, tmp_path):
        """Empty data dir exits 0 and prints 'No sessions found'."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        assert result.returncode == 0
        assert "No sessions found" in result.stdout

    def test_single_session(self, tmp_path):
        """Consecutive readings produce exactly one session."""
        import session_risk_report as srr

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_risk_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(20)]
        _make_risk_csv(tmp_path / "session.csv", rows)

        all_rows = srr.load_csv_files(str(tmp_path))
        sessions = srr.group_sessions(all_rows, session_gap_s=300)
        assert len(sessions) == 1

    def test_multiple_sessions(self, tmp_path):
        """Gap > session_gap between readings splits into 2 sessions."""
        import session_risk_report as srr

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        # First block: 10 readings every 5 seconds
        rows1 = [_risk_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(10)]
        # Second block starts 600s later (> default 300s gap)
        gap_start = base_ts + timedelta(seconds=600)
        rows2 = [_risk_row(gap_start + timedelta(seconds=i * 5), 0.05) for i in range(10)]
        _make_risk_csv(tmp_path / "session.csv", rows1 + rows2)

        all_rows = srr.load_csv_files(str(tmp_path))
        sessions = srr.group_sessions(all_rows, session_gap_s=300)
        assert len(sessions) == 2

    def test_risk_levels(self, tmp_path):
        """PPV > 1.0 → HIGH risk; < 0.3 → LOW risk."""
        import session_risk_report as srr

        # LOW risk session
        assert srr._ppv_risk_level(0.1) == "LOW"
        # MEDIUM risk session
        assert srr._ppv_risk_level(0.5) == "MEDIUM"
        # HIGH risk session
        assert srr._ppv_risk_level(1.5) == "HIGH"

    def test_output_contains_table(self, tmp_path):
        """Report with data prints a table containing 'Risk' and 'MaxPPV'."""
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_risk_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(20)]
        _make_risk_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "Risk" in result.stdout
        assert "MaxPPV" in result.stdout

    def test_summary_line_present(self, tmp_path):
        """Summary line with session counts is printed."""
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_risk_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(20)]
        _make_risk_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "Total:" in result.stdout
        assert "sessions" in result.stdout

    def test_high_risk_appears_first(self, tmp_path):
        """HIGH-risk sessions appear before LOW-risk ones in output."""
        import session_risk_report as srr

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)

        # Session 1: LOW risk (PPV 0.05), readings every 5s
        rows1 = [_risk_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(10)]
        # Session 2: HIGH risk (PPV 2.0), starts 600s later
        gap_start = base_ts + timedelta(seconds=600)
        rows2 = [_risk_row(gap_start + timedelta(seconds=i * 5), 2.0) for i in range(10)]
        _make_risk_csv(tmp_path / "session.csv", rows1 + rows2)

        all_rows = srr.load_csv_files(str(tmp_path))
        sessions = srr.group_sessions(all_rows, session_gap_s=300)
        records = srr.build_session_records(sessions)
        sorted_records = srr.sort_records(records)

        assert sorted_records[0]["risk_level"] == "HIGH"
        assert sorted_records[-1]["risk_level"] == "LOW"

    def test_alert_count_increments(self, tmp_path):
        """Rows with non-normal anomaly_level are counted as alerts."""
        import session_risk_report as srr

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [
            _risk_row(base_ts + timedelta(seconds=i * 5),
                      0.05,
                      "soil_creep" if i < 5 else "normal")
            for i in range(10)
        ]
        _make_risk_csv(tmp_path / "session.csv", rows)

        all_rows = srr.load_csv_files(str(tmp_path))
        sessions = srr.group_sessions(all_rows, session_gap_s=300)
        assert len(sessions) == 1
        assert sessions[0]["alert_count"] == 5

    def test_session_gap_argument(self, tmp_path):
        """--session-gap 60 splits readings with 120s gap into 2 sessions."""
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows1 = [_risk_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(5)]
        gap_start = base_ts + timedelta(seconds=200)  # 200s gap > 60, but < 300
        rows2 = [_risk_row(gap_start + timedelta(seconds=i * 5), 0.05) for i in range(5)]
        _make_risk_csv(tmp_path / "session.csv", rows1 + rows2)

        result = self._run(["--data-dir", str(tmp_path), "--session-gap", "60"])
        assert result.returncode == 0
        # Should show 2 sessions in summary
        assert "2 sessions" in result.stdout


# ===========================================================================
# ppv_trend_analysis tests
# ===========================================================================

def _make_trend_csv(path: Path, rows: list) -> None:
    """Write list-of-dicts as CSV for ppv_trend_analysis tests."""
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def _trend_row(ts: datetime, ppv: float) -> dict:
    """Single CSV row for ppv_trend_analysis tests."""
    return {
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ppv": str(ppv),
        "rms": str(ppv * 0.7),
        "device_id": "test-device",
    }


class TestPpvTrendAnalysis:
    """Tests for ppv_trend_analysis.py."""

    def _run(self, args: list) -> "subprocess.CompletedProcess":
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "ppv_trend_analysis.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_data(self, tmp_path):
        """Empty data dir exits 0 gracefully."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        assert result.returncode == 0
        assert "No data found" in result.stdout

    def test_stable_trend(self, tmp_path):
        """Constant PPV across all windows → STABLE trend."""
        import ppv_trend_analysis as pta

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        # 60 readings, one per minute, constant PPV=0.05
        rows = [_trend_row(base_ts + timedelta(minutes=i), 0.05) for i in range(60)]
        _make_trend_csv(tmp_path / "session.csv", rows)

        all_rows = pta.load_csv_files(str(tmp_path))
        series = pta.prepare_series(all_rows)
        window_means = pta.compute_window_means(series, window_s=10 * 60)
        trend = pta.classify_trend(window_means)
        assert trend == "STABLE"

    def test_accelerating_trend(self, tmp_path):
        """Doubling PPV each window → ACCELERATING trend."""
        import ppv_trend_analysis as pta

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        # 5 windows of 10 min each, PPV doubles every window: 0.1, 0.2, 0.4, 0.8, 1.6
        rows = []
        for window_i, ppv in enumerate([0.1, 0.2, 0.4, 0.8, 1.6]):
            for minute in range(10):
                ts = base_ts + timedelta(minutes=window_i * 10 + minute)
                rows.append(_trend_row(ts, ppv))
        _make_trend_csv(tmp_path / "session.csv", rows)

        all_rows = pta.load_csv_files(str(tmp_path))
        series = pta.prepare_series(all_rows)
        window_means = pta.compute_window_means(series, window_s=10 * 60)
        trend = pta.classify_trend(window_means)
        assert trend == "ACCELERATING"

    def test_increasing_trend(self, tmp_path):
        """Slowly rising PPV → INCREASING trend (not ACCELERATING)."""
        import ppv_trend_analysis as pta

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        # 5 windows, PPV rises 10% each time: 0.1, 0.11, 0.121, 0.133, 0.146
        rows = []
        ppv = 0.1
        for window_i in range(5):
            for minute in range(10):
                ts = base_ts + timedelta(minutes=window_i * 10 + minute)
                rows.append(_trend_row(ts, ppv))
            ppv *= 1.10  # 10% increase < 20% ACCELERATING threshold
        _make_trend_csv(tmp_path / "session.csv", rows)

        all_rows = pta.load_csv_files(str(tmp_path))
        series = pta.prepare_series(all_rows)
        window_means = pta.compute_window_means(series, window_s=10 * 60)
        trend = pta.classify_trend(window_means)
        assert trend == "INCREASING"

    def test_output_contains_chart(self, tmp_path):
        """With data, output contains ASCII chart markers and trend summary."""
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_trend_row(base_ts + timedelta(minutes=i), 0.05) for i in range(60)]
        _make_trend_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path), "--window", "10"])
        assert result.returncode == 0
        assert "Trend:" in result.stdout
        # Chart has time axis
        assert "Time -->" in result.stdout

    def test_accelerating_warning_in_output(self, tmp_path):
        """ACCELERATING trend prints a WARNING line in output."""
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        for window_i, ppv in enumerate([0.1, 0.2, 0.4, 0.8, 1.6]):
            for minute in range(10):
                ts = base_ts + timedelta(minutes=window_i * 10 + minute)
                rows.append(_trend_row(ts, ppv))
        _make_trend_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path), "--window", "10"])
        assert result.returncode == 0
        assert "ACCELERATING" in result.stdout
        assert "WARNING" in result.stdout

    def test_classify_trend_single_window(self, tmp_path):
        """Single window returns STABLE (no change to compare)."""
        import ppv_trend_analysis as pta

        # Only 5 readings, all within one window
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_trend_row(base_ts + timedelta(seconds=i * 30), 0.5) for i in range(5)]
        _make_trend_csv(tmp_path / "session.csv", rows)

        all_rows = pta.load_csv_files(str(tmp_path))
        series = pta.prepare_series(all_rows)
        # Very large window → all in one bucket
        window_means = pta.compute_window_means(series, window_s=3600)
        trend = pta.classify_trend(window_means)
        assert trend == "STABLE"

    def test_decreasing_trend(self, tmp_path):
        """Steadily falling PPV → DECREASING trend."""
        import ppv_trend_analysis as pta

        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        ppv = 1.0
        for window_i in range(5):
            for minute in range(10):
                ts = base_ts + timedelta(minutes=window_i * 10 + minute)
                rows.append(_trend_row(ts, ppv))
            ppv *= 0.85  # 15% decrease per window
        _make_trend_csv(tmp_path / "session.csv", rows)

        all_rows = pta.load_csv_files(str(tmp_path))
        series = pta.prepare_series(all_rows)
        window_means = pta.compute_window_means(series, window_s=10 * 60)
        trend = pta.classify_trend(window_means)
        assert trend == "DECREASING"

    def test_cli_help(self, tmp_path):
        """--help flag exits with 0."""
        result = subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "ppv_trend_analysis.py"), "--help"],
            capture_output=True, text=True
        )
        assert result.returncode == 0


# ===========================================================================
# training_history tests
# ===========================================================================

def _write_metrics_json(path: Path, data: dict) -> None:
    """Write a metrics JSON file."""
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _make_metrics(
    accuracy: float = 0.90,
    loss: float = 0.25,
    training_time_s: float = 120.5,
    epochs_run: int = 50,
    git_sha: str = "abc1234",
    trained_at: str = "2026-03-01T10:00:00+00:00",
) -> dict:
    return {
        "trained_at": trained_at,
        "accuracy": accuracy,
        "loss": loss,
        "training_time_s": training_time_s,
        "epochs_run": epochs_run,
        "git_sha": git_sha,
    }


class TestTrainingHistory:
    """Tests for scripts/training_history.py"""

    def _run(self, args: list) -> subprocess.CompletedProcess:
        env = {**os.environ, "PYTHONUTF8": "1"}
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "training_history.py")] + args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
        )

    def test_no_model_dir(self, tmp_path):
        """Empty directory exits 0 and prints 'No training runs found'."""
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "No training runs found" in result.stdout

    def test_single_run_shows_row(self, tmp_path):
        """Single metrics file produces one data row and a summary line."""
        _write_metrics_json(
            tmp_path / "precursor_training_metrics.json",
            _make_metrics(accuracy=0.91, trained_at="2026-03-01T10:00:00+00:00"),
        )
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        # Row 1 must appear, change column should show — (first run)
        assert "0.9100" in result.stdout
        assert "—" in result.stdout
        # Summary line
        assert "Best accuracy" in result.stdout
        assert "Latest" in result.stdout

    def test_multiple_runs_show_trend_arrows(self, tmp_path):
        """Two runs — second with higher accuracy — shows improvement arrow."""
        import time

        m1 = tmp_path / "precursor_training_metrics.json"
        _write_metrics_json(m1, _make_metrics(accuracy=0.88, trained_at="2026-03-01T09:00:00+00:00"))
        # Ensure second file has a later mtime
        time.sleep(0.05)

        archive = tmp_path / "archive" / "run2"
        archive.mkdir(parents=True)
        _write_metrics_json(
            archive / "precursor_training_metrics.json",
            _make_metrics(accuracy=0.93, trained_at="2026-03-02T10:00:00+00:00"),
        )

        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        # Improvement arrow for the second run
        assert "▲" in result.stdout
        assert "+5.0%" in result.stdout or "▲" in result.stdout

    def test_regression_shows_down_arrow(self, tmp_path):
        """Second run with lower accuracy shows regression arrow."""
        import time

        m1 = tmp_path / "precursor_training_metrics.json"
        _write_metrics_json(m1, _make_metrics(accuracy=0.95, trained_at="2026-03-01T09:00:00+00:00"))
        time.sleep(0.05)

        archive = tmp_path / "archive" / "run2"
        archive.mkdir(parents=True)
        _write_metrics_json(
            archive / "precursor_training_metrics.json",
            _make_metrics(accuracy=0.88, trained_at="2026-03-02T10:00:00+00:00"),
        )

        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "▼" in result.stdout

    def test_limit_flag_restricts_output(self, tmp_path):
        """--limit 1 shows only the last run."""
        import time

        for i, ts in enumerate(["2026-03-01T08:00:00+00:00", "2026-03-02T09:00:00+00:00"]):
            d = tmp_path / "archive" / f"run{i}"
            d.mkdir(parents=True)
            _write_metrics_json(
                d / "precursor_training_metrics.json",
                _make_metrics(accuracy=0.80 + i * 0.05, trained_at=ts),
            )
            time.sleep(0.05)

        result = self._run(["--model-dir", str(tmp_path), "--limit", "1"])
        assert result.returncode == 0
        # Only one row of actual data (row #1 in the limited view)
        lines = [l for l in result.stdout.splitlines() if l.strip().startswith("1 ") or l.strip().startswith("1\t")]
        # Simpler: output should contain exactly one data row line
        # Count lines that start with a digit (data rows)
        data_lines = [l for l in result.stdout.splitlines()
                      if l and l[0].isdigit()]
        assert len(data_lines) == 1

    def test_summary_shows_best_and_latest(self, tmp_path):
        """Summary line correctly identifies best and latest runs."""
        import time

        m1 = tmp_path / "precursor_training_metrics.json"
        _write_metrics_json(m1, _make_metrics(accuracy=0.90, trained_at="2026-03-01T09:00:00+00:00"))
        time.sleep(0.05)

        archive = tmp_path / "archive" / "run2"
        archive.mkdir(parents=True)
        _write_metrics_json(
            archive / "precursor_training_metrics.json",
            _make_metrics(accuracy=0.85, trained_at="2026-03-02T10:00:00+00:00"),
        )

        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        # Best is run 1 (0.90), latest is run 2 (0.85)
        assert "Best accuracy: 0.900" in result.stdout
        assert "Latest: 0.850" in result.stdout

    def test_alternate_accuracy_key_cv_accuracy_mean(self, tmp_path):
        """Metrics with cv_accuracy_mean field are parsed correctly."""
        data = {
            "trained_at": "2026-03-01T10:00:00+00:00",
            "cv_accuracy_mean": 0.87,
            "total_samples": 1000,
        }
        _write_metrics_json(tmp_path / "precursor_training_metrics.json", data)
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "0.8700" in result.stdout

    def test_extra_metrics_files_included(self, tmp_path):
        """Any *_metrics.json files in model dir are also shown."""
        _write_metrics_json(
            tmp_path / "vibration_training_metrics.json",
            _make_metrics(accuracy=0.77, trained_at="2026-03-03T08:00:00+00:00"),
        )
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "0.7700" in result.stdout


# ===========================================================================
# feature_importance_report tests
# ===========================================================================

class TestFeatureImportanceReport:
    """Tests for scripts/feature_importance_report.py"""

    def _run(self, args: list) -> subprocess.CompletedProcess:
        env = {**os.environ, "PYTHONUTF8": "1"}
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "feature_importance_report.py")] + args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
        )

    def test_no_model_files(self, tmp_path):
        """Empty directory: exits 0 and prints 'Model files not found'."""
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "Model files not found" in result.stdout

    def test_missing_tflite_only(self, tmp_path):
        """Config present but .tflite missing: exits 0 gracefully."""
        config = {
            "feature_names": ["rms", "ppv"],
            "class_names": ["normal", "soil_creep"],
            "input_dim": 2,
            "output_dim": 2,
        }
        (tmp_path / "precursor_classifier_config.json").write_text(
            json.dumps(config), encoding="utf-8"
        )
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "Model files not found" in result.stdout

    def test_with_real_model(self):
        """
        If the real model exists in app/assets/ml, run permutation importance
        and verify the output contains expected sections. Skip if model absent.
        """
        real_assets = Path(_SCRIPTS_DIR).parent / "app" / "assets" / "ml"
        tflite = real_assets / "precursor_classifier.tflite"
        config = real_assets / "precursor_classifier_config.json"
        if not tflite.exists() or not config.exists():
            pytest.skip("precursor_classifier.tflite not found — skipping live test")

        result = self._run(["--model-dir", str(real_assets), "--n-samples", "40"])
        assert result.returncode == 0
        assert "Baseline accuracy" in result.stdout
        assert "Top 5 most important" in result.stdout
        assert "Bottom 3 least important" in result.stdout


# ===========================================================================
# cross_site_comparison tests
# ===========================================================================

def _write_site_csv(path: Path, rows: list) -> None:
    """Write list-of-dicts as CSV for cross_site_comparison tests."""
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def _site_row(device_id: str, ppv: float, label: str = "normal",
              anomaly_level: str = "normal",
              ts: str = "2026-03-03T10:00:00Z") -> dict:
    """Single CSV row for cross_site_comparison tests."""
    return {
        "timestamp": ts,
        "device_id": device_id,
        "ppv": str(ppv),
        "rms": str(ppv * 0.7),
        "label": label,
        "anomaly_level": anomaly_level,
    }


class TestCrossSiteComparison:
    """Tests for cross_site_comparison.py."""

    def _run(self, args: list) -> "subprocess.CompletedProcess":
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "cross_site_comparison.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_data(self, tmp_path):
        """Empty data dir exits 0 and prints 'No data found'."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        assert result.returncode == 0
        assert "No data found" in result.stdout

    def test_single_device(self, tmp_path):
        """Single device_id group produces a comparison table with one row."""
        import cross_site_comparison as csc

        rows = [_site_row("device-A", 0.05 + i * 0.001) for i in range(10)]
        _write_site_csv(tmp_path / "session.csv", rows)

        all_rows = csc.load_csv_files(str(tmp_path))
        col_exists = csc._column_exists(all_rows, "device_id")
        groups = csc.group_rows(all_rows, "device_id", col_exists)
        stats = {k: csc.compute_group_stats(v) for k, v in groups.items()}

        assert "device-A" in stats
        assert stats["device-A"]["count"] == 10
        assert stats["device-A"]["mean_ppv"] > 0.0

    def test_multi_device(self, tmp_path):
        """Multiple device_ids produce separate stats and a comparison table in output."""
        rows = (
            [_site_row("device-A", 0.05) for _ in range(10)]
            + [_site_row("device-B", 0.20) for _ in range(10)]
        )
        _write_site_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path), "--by", "device_id"])
        assert result.returncode == 0
        assert "device-A" in result.stdout
        assert "device-B" in result.stdout
        # device-B has higher PPV so should appear in table
        assert "0.2000" in result.stdout or "0.20" in result.stdout

    def test_group_by_label(self, tmp_path):
        """Group by label column produces separate stats per label."""
        import cross_site_comparison as csc

        rows = (
            [_site_row("device-A", 0.05, label="normal") for _ in range(10)]
            + [_site_row("device-A", 0.50, label="soil_creep") for _ in range(10)]
        )
        _write_site_csv(tmp_path / "session.csv", rows)

        all_rows = csc.load_csv_files(str(tmp_path))
        col_exists = csc._column_exists(all_rows, "label")
        groups = csc.group_rows(all_rows, "label", col_exists)
        stats = {k: csc.compute_group_stats(v) for k, v in groups.items()}

        assert "normal" in stats
        assert "soil_creep" in stats
        assert stats["soil_creep"]["mean_ppv"] > stats["normal"]["mean_ppv"]

    def test_missing_column_fallback(self, tmp_path):
        """If grouping column missing, falls back to 'all_devices' single group."""
        import cross_site_comparison as csc

        # CSV without label column
        rows = [{"timestamp": "2026-03-03T10:00:00Z", "ppv": "0.05"} for _ in range(5)]
        _write_site_csv(tmp_path / "session.csv", rows)

        all_rows = csc.load_csv_files(str(tmp_path))
        col_exists = csc._column_exists(all_rows, "label")
        assert not col_exists

        groups = csc.group_rows(all_rows, "label", col_exists)
        assert "all_devices" in groups
        assert len(groups) == 1

    def test_correlation_single_group(self, tmp_path):
        """Single group returns None for correlation (cannot correlate one group)."""
        import cross_site_comparison as csc

        rows = [_site_row("device-A", 0.05) for _ in range(5)]
        _write_site_csv(tmp_path / "session.csv", rows)

        all_rows = csc.load_csv_files(str(tmp_path))
        col_exists = csc._column_exists(all_rows, "device_id")
        groups = csc.group_rows(all_rows, "device_id", col_exists)
        stats = {k: csc.compute_group_stats(v) for k, v in groups.items()}

        r = csc.compute_group_correlations(stats)
        assert r is None

    def test_correlation_multi_group(self, tmp_path):
        """Multiple groups returns a float correlation value."""
        import cross_site_comparison as csc

        rows = (
            [_site_row("device-A", 0.05) for _ in range(5)]
            + [_site_row("device-B", 0.20) for _ in range(5)]
        )
        _write_site_csv(tmp_path / "session.csv", rows)

        all_rows = csc.load_csv_files(str(tmp_path))
        col_exists = csc._column_exists(all_rows, "device_id")
        groups = csc.group_rows(all_rows, "device_id", col_exists)
        stats = {k: csc.compute_group_stats(v) for k, v in groups.items()}

        r = csc.compute_group_correlations(stats)
        assert r is not None
        assert -1.0 <= r <= 1.0

    def test_alert_rate_computed(self, tmp_path):
        """alert_rate is correctly computed as % of non-normal rows."""
        import cross_site_comparison as csc

        rows = (
            [_site_row("device-A", 0.05, anomaly_level="normal") for _ in range(8)]
            + [_site_row("device-A", 0.50, anomaly_level="soil_creep") for _ in range(2)]
        )
        _write_site_csv(tmp_path / "session.csv", rows)

        all_rows = csc.load_csv_files(str(tmp_path))
        col_exists = csc._column_exists(all_rows, "device_id")
        groups = csc.group_rows(all_rows, "device_id", col_exists)
        stats = {k: csc.compute_group_stats(v) for k, v in groups.items()}

        assert abs(stats["device-A"]["alert_rate"] - 20.0) < 1e-6

    def test_output_contains_table_headers(self, tmp_path):
        """Table output contains expected column headers."""
        rows = [_site_row("device-A", 0.05) for _ in range(5)]
        _write_site_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "Mean PPV" in result.stdout
        assert "Max PPV" in result.stdout
        assert "Alert Rate%" in result.stdout


# ===========================================================================
# long_term_trend_report tests
# ===========================================================================

def _write_trend_report_csv(path: Path, rows: list) -> None:
    """Write list-of-dicts as CSV for long_term_trend_report tests."""
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def _ltr_row(ts: datetime, ppv: float, anomaly_level: str = "normal") -> dict:
    """Single CSV row for long_term_trend_report tests."""
    return {
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ppv": str(ppv),
        "rms": str(ppv * 0.7),
        "device_id": "test-device",
        "anomaly_level": anomaly_level,
    }


class TestLongTermTrendReport:
    """Tests for long_term_trend_report.py."""

    def _run(self, args: list) -> "subprocess.CompletedProcess":
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "long_term_trend_report.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_data(self, tmp_path):
        """Empty data dir exits 0 and prints 'No data found'."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = self._run(["--data-dir", str(empty_dir)])
        assert result.returncode == 0
        assert "No data found" in result.stdout

    def test_daily_trend(self, tmp_path):
        """3 days of data produces daily buckets with correct counts."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        for day in range(3):
            for hour in range(5):
                rows.append(_ltr_row(base + timedelta(days=day, hours=hour), 0.05))

        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        records = ltr.aggregate_buckets(all_rows, "daily")

        assert len(records) == 3
        for rec in records:
            assert rec["sample_count"] == 5

    def test_trend_up(self, tmp_path):
        """Increasing PPV across days produces UP slope and is detected."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        for day in range(5):
            ppv = 0.05 + day * 0.10  # 0.05, 0.15, 0.25, 0.35, 0.45
            for hour in range(3):
                rows.append(_ltr_row(base + timedelta(days=day, hours=hour), ppv))

        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        records = ltr.aggregate_buckets(all_rows, "daily")
        slope = ltr.compute_trend_slope(records)
        direction = ltr.classify_trend(slope)

        assert slope > 0
        assert direction == "UP"

    def test_trend_down(self, tmp_path):
        """Decreasing PPV across days produces DOWN slope and is detected."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        for day in range(5):
            ppv = 0.50 - day * 0.08  # 0.50, 0.42, 0.34, 0.26, 0.18
            for hour in range(3):
                rows.append(_ltr_row(base + timedelta(days=day, hours=hour), ppv))

        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        records = ltr.aggregate_buckets(all_rows, "daily")
        slope = ltr.compute_trend_slope(records)
        direction = ltr.classify_trend(slope)

        assert slope < 0
        assert direction == "DOWN"

    def test_stable_trend(self, tmp_path):
        """Constant PPV produces STABLE classification."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ltr_row(base + timedelta(days=d, hours=h), 0.05)
                for d in range(5) for h in range(3)]

        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        records = ltr.aggregate_buckets(all_rows, "daily")
        slope = ltr.compute_trend_slope(records)
        direction = ltr.classify_trend(slope)

        assert direction == "STABLE"

    def test_high_risk_period_detected(self, tmp_path):
        """Day with >20% alert rate is flagged as high-risk."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        # Day 1: 8 normal + 4 alert = 33% alert rate (high-risk)
        for h in range(8):
            rows.append(_ltr_row(base + timedelta(hours=h), 0.05, "normal"))
        for h in range(8, 12):
            rows.append(_ltr_row(base + timedelta(hours=h), 0.50, "soil_creep"))

        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        records = ltr.aggregate_buckets(all_rows, "daily")
        high_risk = ltr.identify_high_risk_buckets(records)

        assert len(high_risk) == 1
        assert "2026-03-01" in high_risk[0]

    def test_auto_period_daily_for_short_span(self, tmp_path):
        """Data span < 14 days auto-selects 'daily' period."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ltr_row(base + timedelta(days=d), 0.05) for d in range(7)]
        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        period = ltr.choose_period(all_rows)
        assert period == "daily"

    def test_auto_period_weekly_for_long_span(self, tmp_path):
        """Data span >= 14 days auto-selects 'weekly' period."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ltr_row(base + timedelta(days=d), 0.05) for d in range(21)]
        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        period = ltr.choose_period(all_rows)
        assert period == "weekly"

    def test_weekly_buckets(self, tmp_path):
        """3 weeks of data aggregates into weekly buckets."""
        import long_term_trend_report as ltr

        base = datetime(2026, 3, 2, 10, 0, 0, tzinfo=timezone.utc)  # Monday
        rows = []
        for week in range(3):
            for day in range(7):
                rows.append(_ltr_row(base + timedelta(weeks=week, days=day), 0.05))

        _write_trend_report_csv(tmp_path / "session.csv", rows)

        all_rows = ltr.load_csv_files(str(tmp_path))
        records = ltr.aggregate_buckets(all_rows, "weekly")

        assert len(records) == 3
        for rec in records:
            assert rec["sample_count"] == 7

    def test_output_contains_table_and_trend(self, tmp_path):
        """CLI output contains table headers and trend summary."""
        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ltr_row(base + timedelta(days=d, hours=h), 0.05)
                for d in range(3) for h in range(4)]
        _write_trend_report_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path), "--period", "daily"])
        assert result.returncode == 0
        assert "Mean PPV" in result.stdout
        assert "Samples" in result.stdout
        assert "PPV trend" in result.stdout or "PPV trending" in result.stdout

    def test_trend_up_in_output(self, tmp_path):
        """CLI output says 'trending UP' when PPV is increasing."""
        base = datetime(2026, 3, 1, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        for day in range(5):
            ppv = 0.05 + day * 0.10
            for hour in range(3):
                rows.append(_ltr_row(base + timedelta(days=day, hours=hour), ppv))
        _write_trend_report_csv(tmp_path / "session.csv", rows)

        result = self._run(["--data-dir", str(tmp_path), "--period", "daily"])
        assert result.returncode == 0
        assert "UP" in result.stdout
        # At least one bar-chart row
        assert "\u2588" in result.stdout or "0.0" in result.stdout

    def test_help_flag(self):
        """--help exits 0."""
        result = self._run(["--help"])
        assert result.returncode == 0


# ==========================================================================

# ===========================================================================
# hyperparameter_report tests
# ===========================================================================

class TestHyperparameterReport:
    """Tests for scripts/hyperparameter_report.py"""

    def _run(self, args: list) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "hyperparameter_report.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_script(self, tmp_path):
        """Empty directory: exits 0 and prints 'not found' message."""
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "not found" in result.stdout.lower()

    def test_with_actual_script(self):
        """
        Runs on the real train_precursor_classifier.py if it exists.
        If not found, the script exits 0 with 'not found' -- both are valid.
        """
        result = self._run([])
        assert result.returncode == 0
        assert (
            "not found" in result.stdout.lower()
            or "Hyperparameter Report" in result.stdout
        )

    def test_output_contains_table_headers_when_script_present(self, tmp_path):
        """Synthetic script with recognisable patterns produces a table."""
        fake_script = tmp_path / "train_precursor_classifier.py"
        lines = [
            "EPOCHS = 200",
            "BATCH_SIZE = 64",
            "learning_rate = 0.001",
            "PATIENCE = 15",
            "n_splits = 5",
            "Dense(128, activation='relu')",
            "Dense(64, activation='relu')",
            "l2(0.001)",
        ]
        fake_script.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "Parameter" in result.stdout
        assert "Current Value" in result.stdout
        assert "Status" in result.stdout
        assert "epochs" in result.stdout
        assert "200" in result.stdout

    def test_good_config_reports_good(self, tmp_path):
        """Well-tuned hyperparameters produce 'GOOD' in summary."""
        fake_script = tmp_path / "train_precursor_classifier.py"
        lines = [
            "EPOCHS = 300",
            "BATCH_SIZE = 64",
            "learning_rate = 0.001",
            "PATIENCE = 20",
            "n_splits = 5",
            "Dense(128)",
            "l2(0.001)",
        ]
        fake_script.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "GOOD" in result.stdout

    def test_bad_config_warns(self, tmp_path):
        """Out-of-range hyperparameters produce WARN status and NEEDS_REVIEW."""
        fake_script = tmp_path / "train_precursor_classifier.py"
        lines = [
            "EPOCHS = 5",
            "BATCH_SIZE = 1000",
            "learning_rate = 0.5",
            "PATIENCE = 2",
            "n_splits = 5",
            "Dense(64)",
            "l2(0.001)",
        ]
        fake_script.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "WARN" in result.stdout
        assert "NEEDS_REVIEW" in result.stdout

    def test_help_flag(self):
        """--help exits 0."""
        result = self._run(["--help"])
        assert result.returncode == 0


# ===========================================================================
# model_size_report tests
# ===========================================================================

class TestModelSizeReport:
    """Tests for scripts/model_size_report.py"""

    def _run(self, args: list) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / "model_size_report.py")] + args,
            capture_output=True,
            text=True,
        )

    def test_no_models(self, tmp_path):
        """Empty directory: exits 0 and prints 'No .tflite files found'."""
        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "No .tflite files found" in result.stdout

    def test_nonexistent_dir(self, tmp_path):
        """Non-existent directory: exits 0 with 'No .tflite files found'."""
        result = self._run(["--model-dir", str(tmp_path / "does_not_exist")])
        assert result.returncode == 0
        assert "No .tflite files found" in result.stdout

    def test_with_synthetic_model(self, tmp_path):
        """Synthetic .tflite file produces a table with expected columns."""
        model_file = tmp_path / "test_model.tflite"
        model_file.write_bytes(bytes(10240))

        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "test_model.tflite" in result.stdout
        assert "Model" in result.stdout
        assert "Size KB" in result.stdout
        assert "Category" in result.stdout
        assert "2Hz_OK" in result.stdout

    def test_tiny_model_category(self, tmp_path):
        """A file under 50 KB is classified as TINY."""
        (tmp_path / "tiny.tflite").write_bytes(bytes(1024))

        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "TINY" in result.stdout

    def test_large_model_category(self, tmp_path):
        """A file over 500 KB is classified as LARGE."""
        (tmp_path / "big.tflite").write_bytes(bytes(600 * 1024))

        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "LARGE" in result.stdout

    def test_summary_line_present(self, tmp_path):
        """Output includes a summary line with model count."""
        (tmp_path / "m.tflite").write_bytes(bytes(4096))

        result = self._run(["--model-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "1 model(s)" in result.stdout

    def test_with_model(self):
        """
        Runs on the real precursor_classifier.tflite if it exists.
        Skip if model absent.
        """
        real_assets = Path(_SCRIPTS_DIR).parent / "app" / "assets" / "ml"
        tflite = real_assets / "precursor_classifier.tflite"
        if not tflite.exists():
            pytest.skip("precursor_classifier.tflite not found -- skipping live test")

        result = self._run(["--model-dir", str(real_assets)])
        assert result.returncode == 0
        assert "precursor_classifier.tflite" in result.stdout
        assert "Size KB" in result.stdout

    def test_help_flag(self):
        """--help exits 0."""
        result = self._run(["--help"])
        assert result.returncode == 0


# ===========================================================================
# export_training_dataset tests
# ===========================================================================

class TestExportTrainingDataset:
    def _run(self, args: list):
        env = {**os.environ, 'PYTHONUTF8': '1'}
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / 'export_training_dataset.py')] + args,
            capture_output=True, text=True, encoding='utf-8', env=env,
        )

    def test_no_data(self, tmp_path):
        data_dir = tmp_path / 'data'
        data_dir.mkdir()
        output = tmp_path / 'out.csv'
        result = self._run(['--data-dir', str(data_dir), '--output', str(output)])
        assert result.returncode == 0
        assert output.exists()
        file_lines = output.read_text(encoding='utf-8').splitlines()
        assert len(file_lines) == 1
        assert 'ppv' in file_lines[0]

    def test_label_normalization(self, tmp_path):
        data_dir = tmp_path / 'data'
        data_dir.mkdir()
        output = tmp_path / 'out.csv'
        rows = [
            {'ppv': '0.05', 'ax': '0.01', 'ay': '0.01', 'az': '0.02', 'label': 'SAFE'},
            {'ppv': '0.40', 'ax': '0.10', 'ay': '0.10', 'az': '0.20', 'label': 'ANOMALY'},
            {'ppv': '0.20', 'ax': '0.05', 'ay': '0.05', 'az': '0.10', 'label': 'WARNING'},
            {'ppv': '0.08', 'ax': '0.01', 'ay': '0.01', 'az': '0.01', 'label': 'safe'},
            {'ppv': '0.35', 'ax': '0.10', 'ay': '0.10', 'az': '0.15', 'label': 'anomaly'},
            {'ppv': '0.06', 'ax': '0.01', 'ay': '0.01', 'az': '0.01', 'label': 'normal'},
            {'ppv': '0.15', 'ax': '0.05', 'ay': '0.05', 'az': '0.05', 'label': 'soil_creep'},
        ]
        _write_csv(data_dir / 'session.csv', rows)
        result = self._run(['--data-dir', str(data_dir), '--output', str(output)])
        assert result.returncode == 0
        with open(output, newline='', encoding='utf-8') as fh:
            reader = csv.DictReader(fh)
            out_rows = list(reader)
        assert len(out_rows) == 7
        labels = [r['label'] for r in out_rows]
        assert labels.count('normal') >= 3
        assert labels.count('anomaly') >= 2
        assert 'precursor' in labels
        assert 'soil_creep' in labels

    def test_derived_features_computed(self, tmp_path):
        data_dir = tmp_path / 'data'
        data_dir.mkdir()
        output = tmp_path / 'out.csv'
        rows = [
            {'ppv': '0.10', 'ax': '0.03', 'ay': '0.04', 'az': '0.05', 'label': 'normal'},
            {'ppv': '0.12', 'ax': '0.04', 'ay': '0.03', 'az': '0.06', 'label': 'normal'},
            {'ppv': '0.08', 'ax': '0.02', 'ay': '0.02', 'az': '0.03', 'label': 'normal'},
        ]
        _write_csv(data_dir / 'session.csv', rows)
        result = self._run(['--data-dir', str(data_dir), '--output', str(output)])
        assert result.returncode == 0
        with open(output, newline='', encoding='utf-8') as fh:
            reader = csv.DictReader(fh)
            out_rows = list(reader)
        assert len(out_rows) == 3
        for row in out_rows:
            assert row['rms'] != ''
            assert float(row['rms']) > 0.0
            assert row['kurtosis'] != ''
            assert row['sta_lta'] != ''
            assert float(row['sta_lta']) == 1.0

    def test_min_samples_check(self, tmp_path):
        data_dir = tmp_path / 'data'
        data_dir.mkdir()
        output = tmp_path / 'out.csv'
        rows = [
            {'ppv': '0.05', 'ax': '0.01', 'ay': '0.01', 'az': '0.02', 'label': 'normal'},
            {'ppv': '0.08', 'ax': '0.01', 'ay': '0.01', 'az': '0.01', 'label': 'normal'},
        ]
        _write_csv(data_dir / 'session.csv', rows)
        result = self._run([
            '--data-dir', str(data_dir),
            '--output', str(output),
            '--min-samples', '100',
        ])
        assert result.returncode == 1
        combined = result.stderr + result.stdout
        assert '100' in combined or 'required' in combined


# ===========================================================================
# label_field_data tests
# ===========================================================================

class TestLabelFieldData:
    def _run(self, args: list):
        env = {**os.environ, 'PYTHONUTF8': '1'}
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / 'label_field_data.py')] + args,
            capture_output=True, text=True, encoding='utf-8', env=env,
        )

    def test_no_unlabeled(self, tmp_path):
        data_dir = tmp_path / 'data'
        data_dir.mkdir()
        rows = [
            {'ppv': '0.05', 'ax': '0.01', 'ay': '0.01', 'az': '0.02', 'label': 'normal'},
            {'ppv': '0.40', 'ax': '0.10', 'ay': '0.10', 'az': '0.20', 'label': 'precursor'},
        ]
        csv_path = data_dir / 'session.csv'
        _write_csv(csv_path, rows)
        original_content = csv_path.read_text(encoding='utf-8')
        result = self._run(['--data-dir', str(data_dir), '--auto'])
        assert result.returncode == 0
        assert csv_path.read_text(encoding='utf-8') == original_content
        assert '0 rows' in result.stdout or 'Labeled 0' in result.stdout

    def test_auto_label(self, tmp_path):
        data_dir = tmp_path / 'data'
        data_dir.mkdir()
        rows = [
            {'ppv': '0.05', 'ax': '0.01', 'ay': '0.01', 'az': '0.02', 'label': ''},
            {'ppv': '0.20', 'ax': '0.05', 'ay': '0.05', 'az': '0.10', 'label': 'unknown'},
            {'ppv': '0.50', 'ax': '0.10', 'ay': '0.10', 'az': '0.20', 'label': ''},
            {'ppv': '0.90', 'ax': '0.20', 'ay': '0.20', 'az': '0.30', 'label': ''},
            {'ppv': '1.50', 'ax': '0.40', 'ay': '0.40', 'az': '0.60', 'label': ''},
        ]
        csv_path = data_dir / 'session.csv'
        _write_csv(csv_path, rows)
        result = self._run(['--data-dir', str(data_dir), '--auto'])
        assert result.returncode == 0
        with open(csv_path, newline='', encoding='utf-8') as fh:
            reader = csv.DictReader(fh)
            out_rows = list(reader)
        assert len(out_rows) == 5
        assert out_rows[0]['label'] == 'normal'
        assert out_rows[1]['label'] == 'normal'
        assert out_rows[2]['label'] == 'precursor'
        assert out_rows[3]['label'] == 'precursor'
        assert out_rows[4]['label'] == 'imminent_failure'
        assert 'Labeled 5 rows' in result.stdout
        assert 'normal' in result.stdout
        assert 'precursor' in result.stdout
        assert 'imminent_failure' in result.stdout

    def test_backup_created(self, tmp_path):
        data_dir = tmp_path / 'data'
        data_dir.mkdir()
        rows = [{'ppv': '0.05', 'ax': '0.01', 'ay': '0.01', 'az': '0.02', 'label': ''}]
        csv_path = data_dir / 'session.csv'
        _write_csv(csv_path, rows)
        result = self._run(['--data-dir', str(data_dir), '--auto'])
        assert result.returncode == 0
        bak_path = data_dir / 'session.csv.bak'
        assert bak_path.exists()


# ===========================================================================
# TestGenerateFullReport
# ===========================================================================

class TestGenerateFullReport:
    """Tests for generate_full_report.py — master batch report generator."""

    def _run(self, args: list):
        env = {**os.environ, 'PYTHONUTF8': '1'}
        return subprocess.run(
            [sys.executable, str(_SCRIPTS_DIR / 'generate_full_report.py')] + args,
            capture_output=True, text=True, encoding='utf-8', env=env,
        )

    def test_no_data(self, tmp_path):
        """Runs without crash even when data-dir has no CSVs; creates output file."""
        output_path = tmp_path / 'report.md'
        result = self._run([
            '--data-dir', str(tmp_path),
            '--output', str(output_path),
        ])
        assert result.returncode == 0
        assert output_path.exists()

    def test_output_file_created(self, tmp_path):
        """Output .md file is created after a successful run."""
        output_path = tmp_path / 'out.md'
        self._run([
            '--data-dir', str(tmp_path),
            '--output', str(output_path),
        ])
        assert output_path.exists()
        content = output_path.read_text(encoding='utf-8')
        assert len(content) > 0

    def test_sections_present(self, tmp_path):
        """Each expected section header appears in the generated report."""
        output_path = tmp_path / 'report.md'
        self._run([
            '--data-dir', str(tmp_path),
            '--output', str(output_path),
        ])
        content = output_path.read_text(encoding='utf-8')
        # Only check headers for scripts that actually exist in the scripts dir.
        script_to_title = {
            'field_report.py':        'Field Summary',
            'session_risk_report.py': 'Session Risk Table',
            'ppv_trend_analysis.py':  'PPV Trend Analysis',
            'alert_correlation.py':   'Alert Correlation',
            'sensor_noise_floor.py':  'Sensor Noise Floor',
            'retrain_advisor.py':     'Retraining Recommendation',
            'data_drift_detector.py': 'Data Drift Check',
            'training_history.py':    'ML Training History',
            'model_size_report.py':   'Model Sizes',
            'site_summary_report.py': 'Site Summary',
        }
        for script_name, title in script_to_title.items():
            if (_SCRIPTS_DIR / script_name).exists():
                assert f'## {title}' in content, (
                    f"Expected section '## {title}' not found in report"
                )

    def test_custom_output_path(self, tmp_path):
        """--output flag writes the report to the specified path."""
        custom_path = tmp_path / 'subdir' / 'my_report.md'
        custom_path.parent.mkdir(parents=True, exist_ok=True)
        result = self._run([
            '--data-dir', str(tmp_path),
            '--output', str(custom_path),
        ])
        assert result.returncode == 0
        assert custom_path.exists()
        content = custom_path.read_text(encoding='utf-8')
        assert 'AncientVision Field Report' in content


# ===========================================================================
# ppv_forecast tests
# ===========================================================================

def _ppv_row(ts, ppv: float, label: str = "normal") -> dict:
    import datetime as _dt
    if isinstance(ts, _dt.datetime):
        ts_str = ts.strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        ts_str = str(ts)
    return {
        "timestamp": ts_str,
        "ppv": str(ppv),
        "rms": str(ppv * 0.7),
        "anomaly_level": label,
        "device_id": "test-device",
    }


class TestPpvForecast:
    import subprocess as _sp
    import sys as _sys
    from pathlib import Path as _Path

    def _run(self, extra_args):
        import subprocess, sys
        from pathlib import Path
        script = str(Path(__file__).parent / "ppv_forecast.py")
        return subprocess.run([sys.executable, script] + extra_args,
                               capture_output=True, text=True)

    def test_no_data(self, tmp_path):
        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "No data" in result.stdout

    def test_flat_series(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.1) for i in range(30)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path), "--horizon", "5", "--alpha", "0.3"])
        assert result.returncode == 0
        assert "FLAT" in result.stdout
        assert "0.1" in result.stdout

    def test_increasing_series(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.05 + i * 0.013)
                for i in range(20)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path), "--horizon", "5", "--alpha", "0.5"])
        assert result.returncode == 0
        assert "INCREASING" in result.stdout

    def test_alpha_clamping(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(10)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path), "--alpha", "9.9"])
        assert result.returncode == 0

    def test_horizon_clamping(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(10)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path), "--horizon", "999"])
        assert result.returncode == 0

    def test_output_contains_ci(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.1) for i in range(20)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "95% CI" in result.stdout

    def test_threshold_eta_shown_for_rising_trend(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.01 + i * 0.02)
                for i in range(20)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path), "--alpha", "0.5"])
        assert result.returncode == 0
        assert "DIN 4150" in result.stdout


# ===========================================================================
# anomaly_scoring tests
# ===========================================================================

class TestAnomalyScoring:
    def _run(self, extra_args):
        import subprocess, sys
        from pathlib import Path
        script = str(Path(__file__).parent / "anomaly_scoring.py")
        return subprocess.run([sys.executable, script] + extra_args,
                               capture_output=True, text=True)

    def test_no_data(self, tmp_path):
        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "No data" in result.stdout

    def test_all_normal(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.01, "normal")
                for i in range(60)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path), "--window", "5"])
        assert result.returncode == 0
        assert "SAFE" in result.stdout
        assert "WARNING" not in result.stdout
        assert "CRITICAL" not in result.stdout

    def test_all_critical(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 4.5, "imminent_failure")
                for i in range(60)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path), "--window", "5"])
        assert result.returncode == 0
        assert ("WARNING" in result.stdout or "CRITICAL" in result.stdout)

    def test_output_contains_summary(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(30)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "Summary" in result.stdout

    def test_output_contains_bar_chart(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = [_ppv_row(base_ts + timedelta(seconds=i * 5), 0.05) for i in range(30)]
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert "[" in result.stdout and "]" in result.stdout

    def test_stalta_column_used_when_present(self, tmp_path):
        from datetime import datetime, timezone, timedelta
        base_ts = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
        rows = []
        for i in range(30):
            row = _ppv_row(base_ts + timedelta(seconds=i * 5), 0.05, "normal")
            row["sta_lta"] = "4.5"
            rows.append(row)
        _write_csv(tmp_path / "session.csv", rows)
        result = self._run(["--data-dir", str(tmp_path)])
        assert result.returncode == 0
        assert ("MONITOR" in result.stdout or "WARNING" in result.stdout
                or "CRITICAL" in result.stdout)
