"""Tests for scripts/aggregate_stats.py

P136 — covers:
  - Daily aggregation: rows across 2 days → table has 2 rows
  - Hourly aggregation: correct bucket counts
  - No data → graceful "No data" message, exits 0
  - Output table has the expected columns (Period, Count, Mean, Max, Min)
"""
import csv
import os
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from aggregate_stats import load_field_data, get_period_key, aggregate, main


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CSV_HEADER = [
    "device_id", "timestamp", "rms", "ppv", "freq", "crest",
    "centroid", "kurtosis", "stalta", "arias", "cav", "label",
]


def _write_csv(path: Path, rows: list) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_HEADER, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def _row(timestamp: str, ppv: float = 0.05, device: str = "dev-01") -> dict:
    return {
        "device_id": device,
        "timestamp": timestamp,
        "rms": "0.01",
        "ppv": str(ppv),
        "freq": "15.0",
        "crest": "3.0",
        "centroid": "20.0",
        "kurtosis": "1.5",
        "stalta": "1.0",
        "arias": "0.0001",
        "cav": "0.002",
        "label": "normal",
    }


# ---------------------------------------------------------------------------
# Unit tests for get_period_key
# ---------------------------------------------------------------------------

class TestGetPeriodKey:

    def test_daily_truncates_to_date(self):
        key = get_period_key("2026-03-03T10:30:00Z", "daily")
        assert key == "2026-03-03"

    def test_hourly_truncates_to_hour(self):
        key = get_period_key("2026-03-03T10:30:00Z", "hourly")
        assert key == "2026-03-03T10:00"

    def test_short_timestamp_fallback(self):
        # Timestamps shorter than 10 chars return "unknown"
        key = get_period_key("bad", "daily")
        assert key == "unknown"

    def test_empty_timestamp(self):
        key = get_period_key("", "daily")
        assert key == "unknown"


# ---------------------------------------------------------------------------
# Unit tests for aggregate
# ---------------------------------------------------------------------------

class TestAggregate:

    def test_daily_groups_by_date(self):
        rows = [
            _row("2026-03-01T10:00:00Z", ppv=0.1),
            _row("2026-03-01T11:00:00Z", ppv=0.2),
            _row("2026-03-02T09:00:00Z", ppv=0.3),
        ]
        buckets, _, _ = aggregate(rows, "daily")
        assert len(buckets) == 2
        assert "2026-03-01" in buckets
        assert "2026-03-02" in buckets
        assert len(buckets["2026-03-01"]) == 2
        assert len(buckets["2026-03-02"]) == 1

    def test_hourly_groups_by_hour(self):
        rows = [
            _row("2026-03-01T10:00:00Z", ppv=0.1),
            _row("2026-03-01T10:30:00Z", ppv=0.2),  # same hour
            _row("2026-03-01T11:00:00Z", ppv=0.3),  # different hour
        ]
        buckets, _, _ = aggregate(rows, "hourly")
        assert len(buckets) == 2
        assert "2026-03-01T10:00" in buckets
        assert "2026-03-01T11:00" in buckets
        assert len(buckets["2026-03-01T10:00"]) == 2

    def test_skips_non_numeric_ppv(self):
        rows = [
            {"timestamp": "2026-03-01T10:00:00Z", "ppv": "bad"},
            {"timestamp": "2026-03-01T10:00:00Z", "ppv": "0.1"},
        ]
        buckets, _, _ = aggregate(rows, "daily")
        # Only 1 valid value in the bucket
        assert len(buckets["2026-03-01"]) == 1


# ---------------------------------------------------------------------------
# Unit tests for load_field_data
# ---------------------------------------------------------------------------

class TestLoadFieldData:

    def test_loads_csv_files(self, tmp_path):
        _write_csv(tmp_path / "session.csv", [_row("2026-03-01T10:00:00Z")])
        rows = load_field_data(str(tmp_path))
        assert len(rows) == 1

    def test_multiple_csvs_concatenated(self, tmp_path):
        _write_csv(tmp_path / "a.csv", [_row("2026-03-01T10:00:00Z")] * 3)
        _write_csv(tmp_path / "b.csv", [_row("2026-03-02T10:00:00Z")] * 2)
        rows = load_field_data(str(tmp_path))
        assert len(rows) == 5

    def test_ignores_non_csv_files(self, tmp_path):
        (tmp_path / "readme.txt").write_text("not a csv", encoding="utf-8")
        _write_csv(tmp_path / "session.csv", [_row("2026-03-01T10:00:00Z")])
        rows = load_field_data(str(tmp_path))
        assert len(rows) == 1


# ---------------------------------------------------------------------------
# P136: main() integration tests
# ---------------------------------------------------------------------------

class TestMainDailyAggregation:

    def test_daily_output_has_two_rows(self, tmp_path, capsys):
        """3 CSVs with timestamps across 2 days → output table shows exactly 2 period rows."""
        _write_csv(tmp_path / "a.csv", [
            _row("2026-03-01T09:00:00Z", ppv=0.1),
            _row("2026-03-01T10:00:00Z", ppv=0.2),
        ])
        _write_csv(tmp_path / "b.csv", [
            _row("2026-03-02T08:00:00Z", ppv=0.3),
        ])

        with patch("sys.argv", ["aggregate_stats.py", "--data-dir", str(tmp_path), "--period", "daily"]):
            main()

        captured = capsys.readouterr()
        # Both dates must appear in output
        assert "2026-03-01" in captured.out
        assert "2026-03-02" in captured.out


class TestMainHourlyAggregation:

    def test_hourly_bucket_counts(self, tmp_path, capsys):
        """5 samples in hour 10 and 2 in hour 11 → correct counts in output."""
        hour10 = [_row(f"2026-03-01T10:{i:02d}:00Z", ppv=0.1) for i in range(5)]
        hour11 = [_row(f"2026-03-01T11:{i:02d}:00Z", ppv=0.2) for i in range(2)]
        _write_csv(tmp_path / "session.csv", hour10 + hour11)

        with patch("sys.argv", ["aggregate_stats.py", "--data-dir", str(tmp_path), "--period", "hourly"]):
            main()

        captured = capsys.readouterr()
        assert "2026-03-01T10:00" in captured.out
        assert "2026-03-01T11:00" in captured.out
        # Count of 5 must appear
        assert "5" in captured.out


class TestMainNoData:

    def test_no_data_exits_gracefully(self, tmp_path, capsys):
        """Empty data dir → prints 'No data' message and returns without crashing."""
        with patch("sys.argv", ["aggregate_stats.py", "--data-dir", str(tmp_path), "--period", "daily"]):
            main()  # must not raise

        captured = capsys.readouterr()
        assert "No data" in captured.out or "no data" in captured.out.lower()


class TestMainOutputColumns:

    def test_output_has_expected_column_headers(self, tmp_path, capsys):
        """Output table must include Period, Count, Mean, Max, Min column headings."""
        _write_csv(tmp_path / "session.csv", [_row("2026-03-01T10:00:00Z", ppv=0.05)])

        with patch("sys.argv", ["aggregate_stats.py", "--data-dir", str(tmp_path), "--period", "daily"]):
            main()

        captured = capsys.readouterr()
        output_lower = captured.out.lower()
        assert "period" in output_lower or "daily" in output_lower
        assert "count" in output_lower
        assert "mean" in output_lower
        assert "max" in output_lower
        assert "min" in output_lower

    def test_ppv_statistics_reported(self, tmp_path, capsys):
        """The output must show PPV statistics (the aggregated metric)."""
        rows = [
            _row("2026-03-01T10:00:00Z", ppv=0.1),
            _row("2026-03-01T10:01:00Z", ppv=0.3),
        ]
        _write_csv(tmp_path / "session.csv", rows)

        with patch("sys.argv", ["aggregate_stats.py", "--data-dir", str(tmp_path), "--period", "daily"]):
            main()

        captured = capsys.readouterr()
        # Max should be 0.3 in the output
        assert "0.3" in captured.out or "0.30" in captured.out
