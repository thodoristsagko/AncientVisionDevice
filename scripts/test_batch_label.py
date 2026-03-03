"""Tests for scripts/batch_label.py"""
import csv
import importlib.util
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Dynamic import so the test file works regardless of working directory
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).parent
_MODULE_PATH = _SCRIPT_DIR / "batch_label.py"


def _load_batch_label():
    spec = importlib.util.spec_from_file_location("batch_label", _MODULE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


batch_label = _load_batch_label()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_FIELDNAMES = ["timestamp", "device_id", "ppv", "sta_lta", "kurtosis"]


def _write_csv(path: Path, rows: list[dict]) -> None:
    """Write a CSV file with _FIELDNAMES columns."""
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=_FIELDNAMES, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def _read_csv(path: Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _run_label(data_dir: Path, **kwargs) -> int:
    """Call batch_label.main() pointing at data_dir, return exit code."""
    argv = ["--data-dir", str(data_dir)]
    for k, v in kwargs.items():
        argv += [f"--{k.replace('_', '-')}", str(v)]
    return batch_label.main(argv)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_labels_normal_rows(tmp_path):
    """Rows with low ppv and low kurtosis should be labeled 'normal'."""
    csv_file = tmp_path / "session.csv"
    _write_csv(csv_file, [
        {"timestamp": "2026-01-01T00:00:00Z", "device_id": "dev1",
         "ppv": "0.01", "sta_lta": "1.0", "kurtosis": "2.0"},
        {"timestamp": "2026-01-01T00:00:01Z", "device_id": "dev1",
         "ppv": "0.05", "sta_lta": "0.5", "kurtosis": "1.5"},
    ])

    rc = _run_label(tmp_path)
    assert rc == 0

    rows = _read_csv(csv_file)
    assert all(r["label"] == "normal" for r in rows), \
        f"Expected all 'normal', got: {[r['label'] for r in rows]}"


def test_labels_anomaly_rows(tmp_path):
    """Rows with ppv >= 0.3 should be labeled 'anomaly'."""
    csv_file = tmp_path / "session.csv"
    _write_csv(csv_file, [
        {"timestamp": "2026-01-01T00:00:00Z", "device_id": "dev1",
         "ppv": "0.3", "sta_lta": "0.0", "kurtosis": "2.0"},
        {"timestamp": "2026-01-01T00:00:01Z", "device_id": "dev1",
         "ppv": "1.5", "sta_lta": "0.0", "kurtosis": "2.0"},
    ])

    rc = _run_label(tmp_path)
    assert rc == 0

    rows = _read_csv(csv_file)
    assert all(r["label"] == "anomaly" for r in rows), \
        f"Expected all 'anomaly', got: {[r['label'] for r in rows]}"


def test_labels_precursor_rows(tmp_path):
    """Rows with 0.1 <= ppv < 0.3 and kurtosis >= 4.0 should be 'precursor'."""
    csv_file = tmp_path / "session.csv"
    _write_csv(csv_file, [
        {"timestamp": "2026-01-01T00:00:00Z", "device_id": "dev1",
         "ppv": "0.1", "sta_lta": "0.5", "kurtosis": "4.0"},
        {"timestamp": "2026-01-01T00:00:01Z", "device_id": "dev1",
         "ppv": "0.2", "sta_lta": "1.0", "kurtosis": "8.0"},
    ])

    rc = _run_label(tmp_path, ppv_precursor=0.1, ppv_anomaly=0.3,
                    kurtosis_precursor=4.0)
    assert rc == 0

    rows = _read_csv(csv_file)
    assert all(r["label"] == "precursor" for r in rows), \
        f"Expected all 'precursor', got: {[r['label'] for r in rows]}"


def test_skips_already_labeled_rows(tmp_path):
    """Rows with existing labels should not be relabeled."""
    # Write a CSV that already has a label column
    csv_file = tmp_path / "session.csv"
    with open(csv_file, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=["timestamp", "device_id", "ppv", "sta_lta", "kurtosis", "label"],
        )
        writer.writeheader()
        # This row would be 'anomaly' by threshold but is pre-labeled 'normal'
        writer.writerow({
            "timestamp": "2026-01-01T00:00:00Z",
            "device_id": "dev1",
            "ppv": "0.5",
            "sta_lta": "0.0",
            "kurtosis": "2.0",
            "label": "normal",
        })

    rc = _run_label(tmp_path)
    assert rc == 0

    rows = _read_csv(csv_file)
    assert len(rows) == 1
    # Label must remain 'normal' (was not relabeled to 'anomaly')
    assert rows[0]["label"] == "normal", \
        f"Pre-labeled row was overwritten; got '{rows[0]['label']}'"


def test_dry_run_does_not_modify_file(tmp_path):
    """--dry-run should not write any changes to the CSV file."""
    csv_file = tmp_path / "session.csv"
    _write_csv(csv_file, [
        {"timestamp": "2026-01-01T00:00:00Z", "device_id": "dev1",
         "ppv": "0.5", "sta_lta": "0.0", "kurtosis": "2.0"},
    ])

    original_text = csv_file.read_text()

    # Run with --dry-run
    argv = ["--data-dir", str(tmp_path), "--dry-run"]
    rc = batch_label.main(argv)
    assert rc == 0

    # File must be byte-for-byte unchanged
    assert csv_file.read_text() == original_text, \
        "--dry-run modified the CSV file"
