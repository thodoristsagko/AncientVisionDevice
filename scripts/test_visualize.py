"""Tests for visualize_features.py.

Test cases:
  - test_build_histogram_empty:    empty list -> empty histogram dict.
  - test_build_histogram_counts:   list of values -> correct bucket counts.
  - test_per_class_stats:          compute mean/std/max per class correctly.
"""

import math
import os
import sys

import pytest

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)


# ---------------------------------------------------------------------------
# test_build_histogram_empty
# ---------------------------------------------------------------------------

def test_build_histogram_empty():
    """build_histogram with an empty list returns an empty histogram structure."""
    from visualize_features import build_histogram

    result = build_histogram([])
    assert result["bins"] == []
    assert result["counts"] == []
    assert result["total"] == 0


def test_build_histogram_single_value():
    """build_histogram with a single value creates bins and puts it in bin 0."""
    from visualize_features import build_histogram

    result = build_histogram([5.0], num_bins=5)
    assert result["total"] == 1
    assert len(result["bins"]) == 5
    assert sum(result["counts"]) == 1
    # The single value always lands in first bin (or last due to clamp)
    assert result["counts"][0] == 1


# ---------------------------------------------------------------------------
# test_build_histogram_counts
# ---------------------------------------------------------------------------

def test_build_histogram_counts_simple():
    """build_histogram assigns values to correct bins for a uniform range."""
    from visualize_features import build_histogram

    # 10 values spread exactly over [0, 10) with num_bins=10
    # Each value falls into a distinct bin: 0->bin0, 1->bin1, ..., 9->bin9
    values = list(range(10))   # [0, 1, 2, ..., 9]
    result = build_histogram(values, num_bins=10)

    assert result["total"] == 10
    assert len(result["bins"]) == 10
    assert sum(result["counts"]) == 10
    # Each bin should have exactly 1 value
    assert all(c == 1 for c in result["counts"])


def test_build_histogram_counts_clustered():
    """build_histogram puts all values in the same bin when they are identical."""
    from visualize_features import build_histogram

    # All values are the same -> zero-width range guard triggers,
    # all land in bin 0
    values = [3.0, 3.0, 3.0, 3.0]
    result = build_histogram(values, num_bins=5)

    assert result["total"] == 4
    assert result["counts"][0] == 4
    assert sum(result["counts"]) == 4


def test_build_histogram_boundary_clamp():
    """build_histogram clamps the maximum value to the last bin index."""
    from visualize_features import build_histogram

    # Exactly 10 equal-spaced values from 0..9 with 5 bins:
    # bin_width = 9/5 = 1.8
    # bin boundaries: [0,1.8), [1.8,3.6), [3.6,5.4), [5.4,7.2), [7.2,9.0]
    values = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]
    result = build_histogram(values, num_bins=5)

    assert result["total"] == 10
    assert sum(result["counts"]) == 10  # nothing dropped
    assert len(result["bins"]) == 5


def test_build_histogram_min_max():
    """build_histogram correctly reports min and max of values."""
    from visualize_features import build_histogram

    values = [1.5, 7.2, 3.3, 0.1, 9.9]
    result = build_histogram(values)
    assert result["min"] == pytest.approx(0.1)
    assert result["max"] == pytest.approx(9.9)


# ---------------------------------------------------------------------------
# test_per_class_stats
# ---------------------------------------------------------------------------

def test_per_class_stats_basic():
    """per_class_stats computes correct mean/std/max for two classes."""
    from visualize_features import per_class_stats

    rows = [
        {"ppv": "1.0", "label": "normal"},
        {"ppv": "3.0", "label": "normal"},
        {"ppv": "2.0", "label": "normal"},
        {"ppv": "10.0", "label": "soil_creep"},
        {"ppv": "20.0", "label": "soil_creep"},
    ]
    stats = per_class_stats(rows, "ppv", ["normal", "soil_creep"])

    normal = stats["normal"]
    assert normal is not None
    assert normal["mean"] == pytest.approx(2.0)
    assert normal["max"] == pytest.approx(3.0)
    assert normal["min"] == pytest.approx(1.0)
    # std: variance = ((1-2)^2 + (3-2)^2 + (2-2)^2) / 3 = 2/3
    assert normal["std"] == pytest.approx(math.sqrt(2.0 / 3.0))

    soil = stats["soil_creep"]
    assert soil is not None
    assert soil["mean"] == pytest.approx(15.0)
    assert soil["max"] == pytest.approx(20.0)


def test_per_class_stats_empty_class():
    """per_class_stats returns None for classes with no samples."""
    from visualize_features import per_class_stats

    rows = [
        {"ppv": "1.0", "label": "normal"},
        {"ppv": "2.0", "label": "normal"},
    ]
    stats = per_class_stats(rows, "ppv", ["normal", "soil_creep", "crack_propagation"])

    assert stats["normal"] is not None
    assert stats["soil_creep"] is None
    assert stats["crack_propagation"] is None


def test_per_class_stats_missing_feature():
    """per_class_stats silently skips rows where the feature value is missing."""
    from visualize_features import per_class_stats

    rows = [
        {"ppv": "1.0", "label": "normal"},
        {"ppv": "",    "label": "normal"},       # empty string
        {"label": "normal"},                      # key absent
        {"ppv": "bad", "label": "normal"},        # non-numeric
        {"ppv": "5.0", "label": "normal"},
    ]
    stats = per_class_stats(rows, "ppv", ["normal"])

    # Only rows with ppv="1.0" and "5.0" are valid -> 2 samples
    normal = stats["normal"]
    assert normal is not None
    assert normal["count"] == 2
    assert normal["mean"] == pytest.approx(3.0)


def test_per_class_stats_single_sample():
    """per_class_stats handles a single-sample class (std=0)."""
    from visualize_features import per_class_stats

    rows = [{"ppv": "7.5", "label": "imminent_failure"}]
    stats = per_class_stats(rows, "ppv", ["imminent_failure"])

    st = stats["imminent_failure"]
    assert st is not None
    assert st["mean"] == pytest.approx(7.5)
    assert st["std"] == pytest.approx(0.0)
    assert st["max"] == pytest.approx(7.5)
    assert st["count"] == 1


# ---------------------------------------------------------------------------
# compute_stats tests
# ---------------------------------------------------------------------------

def test_compute_stats_empty():
    """compute_stats returns None for an empty list."""
    from visualize_features import compute_stats

    assert compute_stats([]) is None


def test_compute_stats_values():
    """compute_stats returns correct statistics."""
    from visualize_features import compute_stats

    values = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
    st = compute_stats(values)

    assert st is not None
    assert st["mean"] == pytest.approx(5.0)
    assert st["min"] == pytest.approx(2.0)
    assert st["max"] == pytest.approx(9.0)
    assert st["count"] == 8
    # population std: variance = sum((v-mean)^2)/n
    expected_var = sum((v - 5.0) ** 2 for v in values) / len(values)
    assert st["std"] == pytest.approx(math.sqrt(expected_var))


# ---------------------------------------------------------------------------
# render_histogram tests
# ---------------------------------------------------------------------------

def test_render_histogram_output_contains_title():
    """render_histogram output contains the feature name and sample count."""
    from visualize_features import build_histogram, per_class_stats, render_histogram

    values = [1.0, 2.0, 3.0]
    hist = build_histogram(values, num_bins=3)
    stats = per_class_stats(
        [{"ppv": str(v), "label": "normal"} for v in values],
        "ppv",
        ["normal"],
    )
    output = render_histogram("ppv", hist, stats)

    assert "PPV" in output
    assert "N=3" in output
    assert "Per-class:" in output


def test_render_histogram_empty_data():
    """render_histogram with zero samples shows '(no data)' message."""
    from visualize_features import build_histogram, render_histogram

    hist = build_histogram([])
    output = render_histogram("rms", hist, {})
    assert "no data" in output


# ---------------------------------------------------------------------------
# load_all_csv tests
# ---------------------------------------------------------------------------

def test_load_all_csv_empty_dir():
    """load_all_csv returns empty list for an empty directory."""
    import tempfile
    from visualize_features import load_all_csv

    with tempfile.TemporaryDirectory() as tmpdir:
        rows = load_all_csv(tmpdir)
    assert rows == []


def test_load_all_csv_nonexistent_dir():
    """load_all_csv returns empty list for a non-existent directory."""
    from visualize_features import load_all_csv

    rows = load_all_csv("/nonexistent/path/xyz")
    assert rows == []


def test_load_all_csv_reads_multiple_files():
    """load_all_csv concatenates rows from multiple CSV files."""
    import tempfile
    from visualize_features import load_all_csv

    csv1 = "device_id,ppv,label\ndev1,0.5,normal\ndev1,0.6,normal\n"
    csv2 = "device_id,ppv,label\ndev2,2.0,soil_creep\n"

    with tempfile.TemporaryDirectory() as tmpdir:
        with open(os.path.join(tmpdir, "a.csv"), "w") as f:
            f.write(csv1)
        with open(os.path.join(tmpdir, "b.csv"), "w") as f:
            f.write(csv2)
        rows = load_all_csv(tmpdir)

    assert len(rows) == 3
    labels = [r["label"] for r in rows]
    assert "normal" in labels
    assert "soil_creep" in labels
