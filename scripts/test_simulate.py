"""
Tests for scripts/simulate_field_data.py sample-generation logic.

No HTTP requests are made — only the generate_sample() function and helpers
are exercised.
"""
import sys
from pathlib import Path
from datetime import datetime, timezone

import pytest

# ---------------------------------------------------------------------------
# Import the module under test
# ---------------------------------------------------------------------------

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from simulate_field_data import generate_sample, LABELS

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

REQUIRED_FIELDS = [
    "device_id", "timestamp", "rms", "ppv", "freq", "crest",
    "centroid", "kurtosis", "stalta", "arias", "cav", "label",
]

_T0 = datetime(2026, 3, 3, 12, 0, 0, tzinfo=timezone.utc)


def _sample(mode: str, index: int = 0, total: int = 1) -> dict:
    return generate_sample("test-dev", _T0, mode, index=index, total=total)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestNormalSample:
    def test_generate_normal_sample_has_required_fields(self):
        """A normal sample must contain every one of the 12 required fields."""
        s = _sample("normal")
        for field in REQUIRED_FIELDS:
            assert field in s, f"Missing required field: {field!r}"

    def test_normal_sample_label(self):
        s = _sample("normal")
        assert s["label"] == "normal"

    def test_normal_ppv_in_range(self):
        for _ in range(20):
            s = _sample("normal")
            assert 0.01 <= s["ppv"] <= 0.3, f"ppv out of range: {s['ppv']}"

    def test_normal_kurtosis_in_range(self):
        for _ in range(20):
            s = _sample("normal")
            assert -1.0 <= s["kurtosis"] <= 3.0, f"kurtosis out of range: {s['kurtosis']}"

    def test_normal_stalta_in_range(self):
        for _ in range(20):
            s = _sample("normal")
            assert 0.5 <= s["stalta"] <= 2.0, f"stalta out of range: {s['stalta']}"


class TestSoilCreepSample:
    def test_generate_soil_creep_has_higher_ppv(self):
        """
        Soil creep samples must have ppv > 0.3 (above normal baseline).
        Tested at multiple positions along the ramp.
        """
        for i in range(10):
            s = _sample("soil_creep", index=i, total=10)
            assert s["ppv"] > 0.3, (
                f"soil_creep ppv should be > 0.3, got {s['ppv']} at index {i}"
            )

    def test_soil_creep_ppv_ramp_increases(self):
        """
        The mean PPV at the end of a long sequence should be higher than
        the mean PPV at the beginning.
        """
        total = 100
        early_ppvs = [_sample("soil_creep", index=i, total=total)["ppv"] for i in range(5)]
        late_ppvs  = [_sample("soil_creep", index=i, total=total)["ppv"] for i in range(95, 100)]
        assert sum(late_ppvs) / len(late_ppvs) > sum(early_ppvs) / len(early_ppvs), (
            "Late soil_creep PPV should exceed early PPV (ramp not working)"
        )

    def test_soil_creep_has_required_fields(self):
        s = _sample("soil_creep")
        for field in REQUIRED_FIELDS:
            assert field in s, f"Missing required field: {field!r}"

    def test_soil_creep_label(self):
        s = _sample("soil_creep")
        assert s["label"] == "soil_creep"


class TestCrackPropagationSample:
    def test_crack_propagation_has_high_crest(self):
        for _ in range(20):
            s = _sample("crack_propagation")
            assert s["crest"] >= 8.0, f"crest should be >= 8.0, got {s['crest']}"

    def test_crack_propagation_has_high_kurtosis(self):
        for _ in range(20):
            s = _sample("crack_propagation")
            assert s["kurtosis"] >= 8.0, f"kurtosis should be >= 8.0, got {s['kurtosis']}"

    def test_crack_propagation_has_required_fields(self):
        s = _sample("crack_propagation")
        for field in REQUIRED_FIELDS:
            assert field in s

    def test_crack_propagation_label(self):
        s = _sample("crack_propagation")
        assert s["label"] == "crack_propagation"


class TestImminentFailureSample:
    def test_imminent_failure_has_required_fields(self):
        s = _sample("imminent_failure")
        for field in REQUIRED_FIELDS:
            assert field in s

    def test_imminent_failure_extreme_ppv(self):
        for _ in range(10):
            s = _sample("imminent_failure")
            assert s["ppv"] >= 2.0, f"imminent_failure ppv should be >= 2.0, got {s['ppv']}"

    def test_imminent_failure_extreme_kurtosis(self):
        for _ in range(10):
            s = _sample("imminent_failure")
            assert s["kurtosis"] >= 12.0, (
                f"imminent_failure kurtosis should be >= 12.0, got {s['kurtosis']}"
            )

    def test_imminent_failure_label(self):
        s = _sample("imminent_failure")
        assert s["label"] == "imminent_failure"


class TestMixedMode:
    def test_generate_mixed_samples_has_variety(self):
        """
        100 mixed samples must include all 4 labels.
        The probability of any single label being absent from 100 draws
        is vanishingly small given the weights used (min weight = 0.10).
        """
        labels_seen: set[str] = set()
        for i in range(100):
            from datetime import timedelta
            ts = _T0 + timedelta(seconds=i)
            s = generate_sample("test-dev", ts, "mixed", index=i, total=100)
            labels_seen.add(s["label"])

        assert labels_seen == set(LABELS), (
            f"Expected all 4 labels; got {labels_seen}"
        )

    def test_mixed_samples_have_required_fields(self):
        for i in range(20):
            s = _sample("mixed", index=i, total=20)
            for field in REQUIRED_FIELDS:
                assert field in s, f"Mixed sample missing field: {field!r}"


class TestTimestamps:
    def test_timestamps_are_unique(self):
        """
        50 samples generated with 1-second increments must have 50
        distinct ISO-8601 timestamps.
        """
        from datetime import timedelta
        timestamps = []
        for i in range(50):
            ts = _T0 + timedelta(seconds=i)
            s = generate_sample("test-dev", ts, "normal", index=i, total=50)
            timestamps.append(s["timestamp"])

        assert len(set(timestamps)) == 50, (
            f"Expected 50 unique timestamps; got {len(set(timestamps))}"
        )

    def test_timestamp_is_iso8601_utc(self):
        """Timestamp must be parseable as UTC ISO-8601 (ends with Z)."""
        s = _sample("normal")
        ts_str = s["timestamp"]
        assert ts_str.endswith("Z"), f"Timestamp must end with Z: {ts_str!r}"
        # Must parse without raising
        datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
