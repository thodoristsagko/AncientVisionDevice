"""Tests for evaluate_models.py.

Test strategy:
  - test_evaluate_models_imports:       script can be imported without error.
  - test_visualize_imports:             visualize_features can be imported without error.
  - test_visualize_with_empty_dir:      empty data dir prints 'No data found' without crashing.
  - test_build_feature_vector_fills_missing: missing CSV keys default to 0 / TREND_DEFAULTS.
"""

import importlib
import io
import os
import sys
import tempfile

import pytest

# Ensure the scripts directory is on the path for imports
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)


# ---------------------------------------------------------------------------
# test_evaluate_models_imports
# ---------------------------------------------------------------------------

def test_evaluate_models_imports():
    """evaluate_models can be imported without raising any exception."""
    import evaluate_models  # noqa: F401


def test_evaluate_models_has_expected_functions():
    """evaluate_models exposes the key public functions."""
    import evaluate_models
    assert callable(evaluate_models.build_feature_vector)
    assert callable(evaluate_models.apply_scaler)
    assert callable(evaluate_models.load_csv)


# ---------------------------------------------------------------------------
# test_visualize_imports
# ---------------------------------------------------------------------------

def test_visualize_imports():
    """visualize_features can be imported without raising any exception."""
    import visualize_features  # noqa: F401


def test_visualize_has_expected_functions():
    """visualize_features exposes the key public functions."""
    import visualize_features
    assert callable(visualize_features.build_histogram)
    assert callable(visualize_features.compute_stats)
    assert callable(visualize_features.per_class_stats)
    assert callable(visualize_features.render_histogram)


# ---------------------------------------------------------------------------
# test_visualize_with_empty_dir
# ---------------------------------------------------------------------------

def test_visualize_with_empty_dir(capsys):
    """main() with an empty (but existing) directory prints 'No data found'."""
    import visualize_features

    with tempfile.TemporaryDirectory() as tmpdir:
        # Patch sys.argv and call main()
        original_argv = sys.argv[:]
        sys.argv = ["visualize_features.py", "--data-dir", tmpdir]
        try:
            visualize_features.main()
        finally:
            sys.argv = original_argv

    captured = capsys.readouterr()
    assert "No data found" in captured.out


def test_visualize_with_nonexistent_dir(capsys):
    """main() with a non-existent directory also prints 'No data found'."""
    import visualize_features

    original_argv = sys.argv[:]
    sys.argv = ["visualize_features.py", "--data-dir", "/nonexistent/path/xyz"]
    try:
        visualize_features.main()
    finally:
        sys.argv = original_argv

    captured = capsys.readouterr()
    assert "No data found" in captured.out


# ---------------------------------------------------------------------------
# test_build_feature_vector_fills_missing
# ---------------------------------------------------------------------------

def test_build_feature_vector_fills_missing():
    """build_feature_vector uses 0.0 / TREND_DEFAULTS for missing keys."""
    from evaluate_models import build_feature_vector, TREND_DEFAULTS

    # Row that only has some fields
    row = {
        "rms": "0.5",
        "ppv": "1.2",
        # freq, crest, centroid, kurtosis, stalta, arias, cav all missing
        # temp, psdSlope missing
        # trend features missing
    }
    features = [
        "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
        "stalta", "arias", "cav", "temp", "psdSlope",
        "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
        "cusum_max", "autoencoder_score",
    ]
    vec = build_feature_vector(row, features)

    assert len(vec) == len(features)
    assert vec[0] == pytest.approx(0.5)    # rms parsed correctly
    assert vec[1] == pytest.approx(1.2)    # ppv parsed correctly
    assert vec[2] == pytest.approx(0.0)    # freq missing -> 0.0
    # Trend features should use TREND_DEFAULTS
    ppv_trend_idx = features.index("ppv_trend")
    assert vec[ppv_trend_idx] == pytest.approx(TREND_DEFAULTS["ppv_trend"])  # 1.0
    cusum_idx = features.index("cusum_max")
    assert vec[cusum_idx] == pytest.approx(TREND_DEFAULTS["cusum_max"])       # 0.0
    ae_idx = features.index("autoencoder_score")
    assert vec[ae_idx] == pytest.approx(TREND_DEFAULTS["autoencoder_score"])  # 0.0


def test_build_feature_vector_invalid_value_defaults():
    """build_feature_vector treats non-numeric strings as 0 / TREND_DEFAULTS."""
    from evaluate_models import build_feature_vector

    row = {"rms": "not_a_number", "ppv": "NaN_ish"}
    features = ["rms", "ppv", "freq"]
    vec = build_feature_vector(row, features)

    # rms "not_a_number" -> TREND_DEFAULTS.get("rms", 0.0) = 0.0
    assert vec[0] == pytest.approx(0.0)
    assert vec[1] == pytest.approx(0.0)
    assert vec[2] == pytest.approx(0.0)


def test_build_feature_vector_all_present():
    """build_feature_vector correctly parses a row with all features present."""
    from evaluate_models import build_feature_vector

    features = ["rms", "ppv", "freq"]
    row = {"rms": "0.1", "ppv": "0.5", "freq": "25.0"}
    vec = build_feature_vector(row, features)
    assert vec == pytest.approx([0.1, 0.5, 25.0])


# ---------------------------------------------------------------------------
# apply_scaler tests
# ---------------------------------------------------------------------------

def test_apply_scaler_normalizes():
    """apply_scaler produces expected z-score normalized values."""
    from evaluate_models import apply_scaler

    scaler = {"mean": [0.0, 10.0], "scale": [1.0, 5.0]}
    vec = [1.0, 15.0]
    result = apply_scaler(vec, scaler)
    assert result[0] == pytest.approx(1.0)    # (1-0)/1 = 1.0
    assert result[1] == pytest.approx(1.0)    # (15-10)/5 = 1.0


def test_apply_scaler_zero_scale_guard():
    """apply_scaler doesn't divide by zero when scale is 0."""
    from evaluate_models import apply_scaler

    scaler = {"mean": [0.0], "scale": [0.0]}
    result = apply_scaler([5.0], scaler)
    # scale clamped to 1e-10 -> (5 - 0) / 1e-10 = 5e10
    assert result[0] == pytest.approx(5.0 / 1e-10)


def test_apply_scaler_length_mismatch():
    """apply_scaler raises ValueError on length mismatch."""
    from evaluate_models import apply_scaler

    scaler = {"mean": [0.0, 1.0], "scale": [1.0, 1.0]}
    with pytest.raises(ValueError, match="length"):
        apply_scaler([1.0], scaler)


# ---------------------------------------------------------------------------
# load_csv tests
# ---------------------------------------------------------------------------

def test_load_csv_basic():
    """load_csv parses a simple CSV file correctly."""
    import evaluate_models
    import tempfile

    content = "device_id,timestamp,rms,ppv,label\ntest,2026-01-01,0.1,0.5,normal\n"
    with tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False) as f:
        f.write(content)
        tmppath = f.name

    try:
        rows = evaluate_models.load_csv(tmppath)
    finally:
        os.unlink(tmppath)

    assert len(rows) == 1
    assert rows[0]["rms"] == "0.1"
    assert rows[0]["label"] == "normal"


def test_label_to_index_known():
    """label_to_index maps known labels correctly."""
    from evaluate_models import label_to_index, CLASS_NAMES_PRECURSOR

    assert label_to_index("normal", CLASS_NAMES_PRECURSOR) == 0
    assert label_to_index("soil_creep", CLASS_NAMES_PRECURSOR) == 1
    assert label_to_index("crack_propagation", CLASS_NAMES_PRECURSOR) == 2
    assert label_to_index("imminent_failure", CLASS_NAMES_PRECURSOR) == 3


def test_label_to_index_unknown():
    """label_to_index returns -1 for an unrecognized label."""
    from evaluate_models import label_to_index, CLASS_NAMES_PRECURSOR

    assert label_to_index("unknown_class", CLASS_NAMES_PRECURSOR) == -1
    assert label_to_index("", CLASS_NAMES_PRECURSOR) == -1
