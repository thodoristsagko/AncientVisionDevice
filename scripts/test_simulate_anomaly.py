"""Tests for scripts/simulate_anomaly.py"""
import importlib.util
import json
import random
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Dynamic import
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).parent
_MODULE_PATH = _SCRIPT_DIR / "simulate_anomaly.py"


def _load_simulate_anomaly():
    spec = importlib.util.spec_from_file_location("simulate_anomaly", _MODULE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


simulate_anomaly = _load_simulate_anomaly()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_DEVICE = "test-device"
_T0 = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
_TOTAL = 20


def _generate_all(pattern_fn, total=_TOTAL) -> list[dict]:
    """Generate `total` samples using the given pattern generator function."""
    return [
        pattern_fn(_DEVICE, _T0, i, total)
        for i in range(total)
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_soil_creep_pattern_has_expected_ppv_range():
    """soil_creep PPV values should be between 0.05 and 0.20."""
    samples = _generate_all(simulate_anomaly._soil_creep_sample)
    ppv_values = [s["ppv"] for s in samples]
    assert all(0.01 <= v <= 0.20 for v in ppv_values), (
        f"soil_creep PPV out of expected range [0.01, 0.20]: "
        f"min={min(ppv_values):.4f} max={max(ppv_values):.4f}"
    )
    # Most values should be in the 0.05-0.20 core band
    in_band = sum(1 for v in ppv_values if 0.04 <= v <= 0.20)
    assert in_band >= len(ppv_values) * 0.8, (
        f"Fewer than 80% of soil_creep PPV values are in [0.04, 0.20]: "
        f"{in_band}/{len(ppv_values)}"
    )


def test_crack_pattern_has_high_kurtosis():
    """crack pattern kurtosis should be > 6 for all samples."""
    random.seed(42)
    samples = _generate_all(simulate_anomaly._crack_sample)
    kurtosis_values = [s["kurtosis"] for s in samples]
    assert all(v > 6 for v in kurtosis_values), (
        f"crack kurtosis not always > 6: min={min(kurtosis_values):.2f}"
    )


def test_imminent_pattern_has_highest_ppv():
    """imminent pattern PPV should be higher on average than soil_creep and crack."""
    random.seed(42)
    total = 50

    soil_ppv_mean = sum(
        simulate_anomaly._soil_creep_sample(_DEVICE, _T0, i, total)["ppv"]
        for i in range(total)
    ) / total

    crack_ppv_mean = sum(
        simulate_anomaly._crack_sample(_DEVICE, _T0, i, total)["ppv"]
        for i in range(total)
    ) / total

    imminent_ppv_mean = sum(
        simulate_anomaly._imminent_sample(_DEVICE, _T0, i, total)["ppv"]
        for i in range(total)
    ) / total

    assert imminent_ppv_mean > soil_ppv_mean, (
        f"imminent mean PPV ({imminent_ppv_mean:.4f}) not higher than "
        f"soil_creep ({soil_ppv_mean:.4f})"
    )
    assert imminent_ppv_mean > crack_ppv_mean, (
        f"imminent mean PPV ({imminent_ppv_mean:.4f}) not higher than "
        f"crack ({crack_ppv_mean:.4f})"
    )


def test_dry_run_does_not_send_http():
    """--dry-run should print samples but make no HTTP requests."""
    with patch("urllib.request.urlopen") as mock_urlopen:
        rc = simulate_anomaly.main([
            "--count", "5",
            "--pattern", "soil_creep",
            "--dry-run",
        ])
    assert rc == 0
    mock_urlopen.assert_not_called(), \
        "urlopen was called during --dry-run"


def test_mixed_pattern_produces_variety():
    """mixed pattern should produce samples from at least 2 different patterns."""
    random.seed(0)
    total = 60
    samples = [
        simulate_anomaly._generate_sample("mixed", _DEVICE, _T0, i, total)
        for i in range(total)
    ]
    distinct_patterns = {s["pattern"] for s in samples}
    assert len(distinct_patterns) >= 2, (
        f"mixed pattern only produced {distinct_patterns}; expected at least 2 distinct patterns"
    )
