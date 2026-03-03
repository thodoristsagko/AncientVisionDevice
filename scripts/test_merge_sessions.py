"""Tests for scripts/merge_sessions.py"""
import csv
import importlib.util
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Dynamic import
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).parent
_MODULE_PATH = _SCRIPT_DIR / "merge_sessions.py"


def _load_merge_sessions():
    spec = importlib.util.spec_from_file_location("merge_sessions", _MODULE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


merge_sessions = _load_merge_sessions()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def _read_csv(path: Path) -> tuple[list[str], list[dict]]:
    """Return (fieldnames, rows) from a CSV file."""
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fieldnames = list(reader.fieldnames or [])
        rows = list(reader)
    return fieldnames, rows


def _run_merge(data_dir: Path, output: Path, **kwargs) -> int:
    """Call merge_sessions.merge() with the given data_dir and output path."""
    sort_by = kwargs.get("sort_by", None)
    dedup = kwargs.get("dedup", False)
    return merge_sessions.merge(str(data_dir), str(output), sort_by, dedup)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_merges_two_csvs_into_one(tmp_path):
    """Two CSVs with the same columns should be merged; output has all rows."""
    fields = ["timestamp", "device_id", "ppv"]

    _write_csv(tmp_path / "a.csv", fields, [
        {"timestamp": "2026-01-01T00:00:00Z", "device_id": "dev1", "ppv": "0.1"},
        {"timestamp": "2026-01-01T00:00:01Z", "device_id": "dev1", "ppv": "0.2"},
    ])
    _write_csv(tmp_path / "b.csv", fields, [
        {"timestamp": "2026-01-01T00:00:02Z", "device_id": "dev2", "ppv": "0.3"},
    ])

    output = tmp_path / "merged.csv"
    rc = _run_merge(tmp_path, output)
    assert rc == 0
    assert output.exists()

    _, rows = _read_csv(output)
    assert len(rows) == 3, f"Expected 3 rows, got {len(rows)}"


def test_adds_source_file_column(tmp_path):
    """Merged CSV should have a source_file column with the originating filename."""
    fields = ["timestamp", "device_id", "ppv"]

    _write_csv(tmp_path / "session1.csv", fields, [
        {"timestamp": "2026-01-01T00:00:00Z", "device_id": "dev1", "ppv": "0.1"},
    ])

    output = tmp_path / "merged.csv"
    rc = _run_merge(tmp_path, output)
    assert rc == 0

    fieldnames, rows = _read_csv(output)
    assert "source_file" in fieldnames, \
        f"source_file column missing; got columns: {fieldnames}"
    assert rows[0]["source_file"] == "session1.csv", \
        f"Unexpected source_file value: '{rows[0]['source_file']}'"


def test_dedup_removes_duplicate_rows(tmp_path):
    """With dedup=True, rows with same (timestamp, device_id) are deduplicated."""
    fields = ["timestamp", "device_id", "ppv"]
    duplicate_row = {"timestamp": "2026-01-01T00:00:00Z", "device_id": "dev1", "ppv": "0.1"}

    # Both files contain the same row
    _write_csv(tmp_path / "a.csv", fields, [duplicate_row])
    _write_csv(tmp_path / "b.csv", fields, [duplicate_row])

    output = tmp_path / "merged.csv"
    rc = _run_merge(tmp_path, output, dedup=True)
    assert rc == 0

    _, rows = _read_csv(output)
    assert len(rows) == 1, \
        f"Expected 1 row after dedup, got {len(rows)}"


def test_union_of_columns_from_mismatched_csvs(tmp_path):
    """CSVs with different columns produce output with all columns; missing values empty."""
    _write_csv(tmp_path / "a.csv", ["timestamp", "ppv"], [
        {"timestamp": "2026-01-01T00:00:00Z", "ppv": "0.1"},
    ])
    _write_csv(tmp_path / "b.csv", ["timestamp", "kurtosis"], [
        {"timestamp": "2026-01-01T00:00:01Z", "kurtosis": "3.5"},
    ])

    output = tmp_path / "merged.csv"
    rc = _run_merge(tmp_path, output)
    assert rc == 0

    fieldnames, rows = _read_csv(output)
    assert "ppv" in fieldnames, "Expected 'ppv' in merged columns"
    assert "kurtosis" in fieldnames, "Expected 'kurtosis' in merged columns"
    assert len(rows) == 2, f"Expected 2 rows, got {len(rows)}"

    # Row from a.csv has no kurtosis — should be empty string
    row_a = next(r for r in rows if r.get("ppv") == "0.1")
    assert row_a.get("kurtosis", "") == "", \
        f"Expected empty kurtosis for row from a.csv, got '{row_a.get('kurtosis')}'"

    # Row from b.csv has no ppv — should be empty string
    row_b = next(r for r in rows if r.get("kurtosis") == "3.5")
    assert row_b.get("ppv", "") == "", \
        f"Expected empty ppv for row from b.csv, got '{row_b.get('ppv')}'"


def test_empty_data_dir(tmp_path):
    """Empty data dir (no CSV files) should return 0 without creating output."""
    output = tmp_path / "merged.csv"
    rc = _run_merge(tmp_path, output)
    # Should exit gracefully with code 0
    assert rc == 0
    # Output file should not be created when there is nothing to merge
    assert not output.exists(), \
        "merge wrote output file for an empty data directory"
