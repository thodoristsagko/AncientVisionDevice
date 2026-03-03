"""Tests for scripts/plot_session.py

P137 — covers:
  - Small CSV (10 rows) → produces output with chart characters
  - --feature flag → uses specified column
  - Non-existent file → error message, non-zero exit
  - Output contains axis labels and summary stats
"""
import csv
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from plot_session import (
    load_data,
    extract_series,
    compute_stats,
    render_chart,
    main,
    DATA_CHAR,
    Y_AXIS_CHAR,
    CORNER_CHAR,
    X_AXIS_CHAR,
)


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


def _make_rows(n: int, ppv_start: float = 0.01, ppv_step: float = 0.05) -> list:
    rows = []
    for i in range(n):
        rows.append({
            "device_id": "dev-01",
            "timestamp": f"2026-03-03T10:00:{i:02d}Z",
            "rms": "0.01",
            "ppv": str(round(ppv_start + i * ppv_step, 4)),
            "freq": "15.0",
            "crest": "3.0",
            "centroid": "20.0",
            "kurtosis": "1.5",
            "stalta": "1.0",
            "arias": "0.0001",
            "cav": "0.002",
            "label": "normal",
        })
    return rows


# ---------------------------------------------------------------------------
# Unit tests for compute_stats
# ---------------------------------------------------------------------------

class TestComputeStats:

    def test_empty_values(self):
        s = compute_stats([])
        assert s["count"] == 0
        assert s["min"] == 0.0
        assert s["max"] == 0.0
        assert s["mean"] == 0.0
        assert s["std"] == 0.0

    def test_single_value(self):
        s = compute_stats([5.0])
        assert s["count"] == 1
        assert s["min"] == pytest.approx(5.0)
        assert s["max"] == pytest.approx(5.0)
        assert s["mean"] == pytest.approx(5.0)
        assert s["std"] == pytest.approx(0.0)

    def test_multiple_values(self):
        values = [1.0, 2.0, 3.0, 4.0, 5.0]
        s = compute_stats(values)
        assert s["count"] == 5
        assert s["min"] == pytest.approx(1.0)
        assert s["max"] == pytest.approx(5.0)
        assert s["mean"] == pytest.approx(3.0)
        assert s["std"] > 0


# ---------------------------------------------------------------------------
# Unit tests for extract_series
# ---------------------------------------------------------------------------

class TestExtractSeries:

    def test_extracts_ppv_values(self):
        rows = _make_rows(5)
        timestamps, values = extract_series(rows, "ppv")
        assert len(values) == 5
        assert len(timestamps) == 5
        assert all(isinstance(v, float) for v in values)

    def test_skips_non_numeric_values(self):
        rows = [
            {"ppv": "0.1", "timestamp": "t1"},
            {"ppv": "bad", "timestamp": "t2"},
            {"ppv": "",    "timestamp": "t3"},
            {"ppv": "0.3", "timestamp": "t4"},
        ]
        _, values = extract_series(rows, "ppv")
        assert len(values) == 2
        assert values[0] == pytest.approx(0.1)
        assert values[1] == pytest.approx(0.3)

    def test_missing_feature_returns_empty(self):
        rows = _make_rows(5)
        _, values = extract_series(rows, "nonexistent_column")
        assert values == []

    def test_detects_timestamp_column(self):
        rows = [{"timestamp": "2026-03-01T10:00:00Z", "ppv": "0.5"}]
        timestamps, _ = extract_series(rows, "ppv")
        assert timestamps[0] == "2026-03-01T10:00:00Z"


# ---------------------------------------------------------------------------
# Unit tests for render_chart
# ---------------------------------------------------------------------------

class TestRenderChart:

    def test_empty_values_shows_no_data(self):
        chart = render_chart([], [], "ppv")
        assert "no data" in chart.lower() or "(no data)" in chart.lower()

    def test_chart_contains_title(self):
        values = [0.1, 0.2, 0.3, 0.4, 0.5]
        timestamps = [f"t{i}" for i in range(5)]
        chart = render_chart(timestamps, values, "ppv")
        assert "PPV" in chart
        assert "N=5" in chart

    def test_chart_contains_axis_characters(self):
        values = list(range(1, 11))  # 10 values
        timestamps = [f"t{i}" for i in range(10)]
        chart = render_chart(timestamps, values, "ppv")
        assert Y_AXIS_CHAR in chart   # vertical bar
        assert CORNER_CHAR in chart   # bottom-left corner
        assert X_AXIS_CHAR in chart   # horizontal line

    def test_chart_contains_data_characters(self):
        """The full-block character must appear when there are data points."""
        values = [0.5, 1.0, 0.3, 0.8, 0.6] * 4  # 20 values
        timestamps = [f"t{i}" for i in range(20)]
        chart = render_chart(timestamps, values, "ppv")
        assert DATA_CHAR in chart

    def test_chart_contains_summary_stats(self):
        values = [0.1, 0.2, 0.3]
        timestamps = ["t0", "t1", "t2"]
        chart = render_chart(timestamps, values, "ppv")
        assert "count=" in chart
        assert "min=" in chart
        assert "max=" in chart
        assert "mean=" in chart
        assert "std=" in chart

    def test_y_axis_labels_are_numeric(self):
        """Y-axis tick labels must contain numeric values (top=max, mid=mean, bottom=min)."""
        values = [0.0, 0.5, 1.0]
        timestamps = ["t0", "t1", "t2"]
        chart = render_chart(timestamps, values, "ppv")
        # max=1.0, min=0.0, mean=0.5 should appear as formatted floats
        assert "1.000" in chart
        assert "0.000" in chart
        assert "0.500" in chart


# ---------------------------------------------------------------------------
# Unit tests for load_data
# ---------------------------------------------------------------------------

class TestLoadData:

    def test_load_specific_csv(self, tmp_path):
        csv_path = tmp_path / "session.csv"
        _write_csv(csv_path, _make_rows(10))
        rows = load_data(str(csv_path))
        assert len(rows) == 10

    def test_nonexistent_file_exits_1(self, tmp_path):
        missing = str(tmp_path / "missing.csv")
        with pytest.raises(SystemExit) as exc_info:
            load_data(missing)
        assert exc_info.value.code == 1

    def test_load_all_from_dir(self, tmp_path):
        _write_csv(tmp_path / "a.csv", _make_rows(5))
        _write_csv(tmp_path / "b.csv", _make_rows(3))
        rows = load_data(None, data_dir=str(tmp_path))
        assert len(rows) == 8

    def test_missing_dir_exits_1(self, tmp_path):
        missing_dir = str(tmp_path / "no_such_dir")
        with pytest.raises(SystemExit) as exc_info:
            load_data(None, data_dir=missing_dir)
        assert exc_info.value.code == 1


# ---------------------------------------------------------------------------
# P137: main() integration tests
# ---------------------------------------------------------------------------

class TestMainWithSmallCSV:

    def test_10_row_csv_produces_chart_output(self, tmp_path, capsys):
        """A 10-row CSV must produce output containing chart and summary statistics."""
        csv_path = tmp_path / "session.csv"
        _write_csv(csv_path, _make_rows(10))

        with patch("sys.argv", ["plot_session.py", "--csv", str(csv_path)]):
            main()

        captured = capsys.readouterr()
        assert "PPV" in captured.out
        assert "count=10" in captured.out
        assert Y_AXIS_CHAR in captured.out

    def test_feature_flag_uses_specified_column(self, tmp_path, capsys):
        """--feature rms must plot the rms column instead of ppv."""
        csv_path = tmp_path / "session.csv"
        _write_csv(csv_path, _make_rows(10))

        with patch("sys.argv", ["plot_session.py", "--csv", str(csv_path), "--feature", "rms"]):
            main()

        captured = capsys.readouterr()
        assert "RMS" in captured.out
        assert "count=10" in captured.out

    def test_nonexistent_file_exits_nonzero(self, tmp_path):
        """--csv pointing at a non-existent file must exit with non-zero code."""
        missing = str(tmp_path / "does_not_exist.csv")
        with patch("sys.argv", ["plot_session.py", "--csv", missing]):
            with pytest.raises(SystemExit) as exc_info:
                main()
        assert exc_info.value.code != 0

    def test_output_contains_axis_labels(self, tmp_path, capsys):
        """Chart output must contain both the first and last timestamps as x-axis labels."""
        rows = _make_rows(10)
        csv_path = tmp_path / "session.csv"
        _write_csv(csv_path, rows)

        with patch("sys.argv", ["plot_session.py", "--csv", str(csv_path)]):
            main()

        captured = capsys.readouterr()
        first_ts = rows[0]["timestamp"][:38]  # truncated to max_ts_len
        assert first_ts[:10] in captured.out  # at minimum the date portion

    def test_unknown_feature_exits_nonzero(self, tmp_path):
        """--feature pointing at a non-existent column must exit with non-zero code."""
        csv_path = tmp_path / "session.csv"
        _write_csv(csv_path, _make_rows(5))

        with patch("sys.argv", ["plot_session.py", "--csv", str(csv_path), "--feature", "nonexistent"]):
            with pytest.raises(SystemExit) as exc_info:
                main()
        assert exc_info.value.code != 0

    def test_default_feature_is_ppv(self, tmp_path, capsys):
        """Without --feature flag, default feature is ppv."""
        csv_path = tmp_path / "session.csv"
        _write_csv(csv_path, _make_rows(5))

        with patch("sys.argv", ["plot_session.py", "--csv", str(csv_path)]):
            main()

        captured = capsys.readouterr()
        assert "PPV" in captured.out
