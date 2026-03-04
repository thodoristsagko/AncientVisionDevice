"""End-to-end pipeline test: simulate → collect → verify flow.

Tests the complete pipeline: POST samples to /ingest, verify they're collected,
check stats endpoint shows correct counts, verify data can be exported.
Uses Flask test client (no real server needed).
"""
import csv
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Import the modules under test
# ---------------------------------------------------------------------------

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

_DOCKER_COLLECT = _SCRIPTS_DIR.parent / "docker" / "collect"
if str(_DOCKER_COLLECT) not in sys.path:
    sys.path.insert(0, str(_DOCKER_COLLECT))

from simulate_field_data import generate_sample
from app import create_app


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def app_and_data_dir(tmp_path, monkeypatch):
    """Create Flask test app with isolated data directory."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    app = create_app()
    app.config["TESTING"] = True
    return app, tmp_path


@pytest.fixture
def client(app_and_data_dir):
    """Flask test client."""
    app, data_dir = app_and_data_dir
    with app.test_client() as c:
        yield c, data_dir


# ---------------------------------------------------------------------------
# Test: Full pipeline smoke test
# ---------------------------------------------------------------------------


def test_full_pipeline_smoke(client):
    """
    End-to-end smoke test:
    1. POST samples above threshold using different device IDs
    2. Verify /stats shows correct count
    3. Verify /export returns CSV with all rows
    4. Verify data integrity: all required fields present
    """
    c, data_dir = client

    # POST 60 samples (arbitrary mix of modes)
    # Use different device IDs to avoid rate limiting (10 req/s per device)
    base_time = datetime(2026, 3, 3, 10, 0, 0, tzinfo=timezone.utc)
    count = 60
    success_count = 0

    for i in range(count):
        mode = ["normal", "soil_creep", "crack_propagation", "imminent_failure"][
            i % 4
        ]
        device_id = f"smoke-test-device-{i % 20}"  # Spread across 20 devices
        timestamp = base_time.replace(second=(base_time.second + i) % 60)
        sample = generate_sample(device_id, timestamp, mode, index=i, total=count)
        r = c.post("/ingest", json=sample)
        assert r.status_code == 200, f"Request {i} failed with status {r.status_code}: {r.get_json()}"
        resp = r.get_json()
        if resp.get("accepted", 0) > 0:
            success_count += 1

    # Verify /stats endpoint returns correct count
    r = c.get("/stats")
    assert r.status_code == 200
    stats = r.get_json()
    assert stats["total_samples"] >= success_count, (
        f"Expected >={success_count} total_samples, got {stats['total_samples']}"
    )
    assert stats["samples_today"] >= success_count

    # Verify /export returns CSV with all samples
    r = c.get("/export")
    assert r.status_code == 200
    assert r.content_type == "text/csv; charset=utf-8"

    # Parse exported CSV
    csv_lines = r.data.decode("utf-8").split("\n")
    reader = csv.DictReader(csv_lines)
    exported_rows = list(reader)

    # Should have at least success_count rows
    assert len(exported_rows) >= success_count, f"Expected >={success_count} exported rows, got {len(exported_rows)}"

    # Verify data integrity: all required fields present in first row
    required_fields = [
        "device_id",
        "timestamp",
        "rms",
        "ppv",
        "freq",
        "crest",
        "centroid",
        "kurtosis",
        "stalta",
        "arias",
        "cav",
        "label",
    ]
    if exported_rows:
        first_row = exported_rows[0]
        for field in required_fields:
            assert field in first_row, f"Missing field in CSV: {field}"
            assert first_row[field], f"Empty field in CSV: {field}"


def test_data_flows_end_to_end(client):
    """
    Integration test: simulate_field_data → /ingest → /stats → /export → verify CSV readable.
    """
    c, data_dir = client

    # Generate 50 samples (mixed modes)
    base_time = datetime(2026, 3, 3, 12, 0, 0, tzinfo=timezone.utc)
    device_id = "e2e-flow-test"
    sent_count = 0

    for i in range(50):
        mode = "mixed"  # Use mixed mode like real deployment
        timestamp = base_time.replace(second=(base_time.second + i) % 60)
        sample = generate_sample(device_id, timestamp, mode, index=i, total=50)

        # POST sample
        r = c.post("/ingest", json=sample)
        resp = r.get_json() or {}
        if r.status_code == 200 and resp.get("accepted", 0) > 0:
            sent_count += 1

    assert sent_count > 0, "No samples were accepted by /ingest"

    # Check /stats endpoint
    r = c.get("/stats")
    assert r.status_code == 200
    stats = r.get_json()
    assert stats["total_samples"] >= sent_count
    assert device_id in stats["devices"]

    # Export data
    r = c.get("/export")
    assert r.status_code == 200

    # Verify CSV is readable and well-formed
    csv_lines = r.data.decode("utf-8").split("\n")
    reader = csv.DictReader(csv_lines)
    rows = list(reader)

    assert len(rows) >= sent_count, (
        f"Expected >= {sent_count} rows in export, got {len(rows)}"
    )

    # Spot-check numeric fields are valid floats
    for row in rows[:5]:  # Check first 5 rows
        if not row.get("ppv"):
            continue
        try:
            ppv = float(row["ppv"])
            assert 0.0 <= ppv <= 100.0
            rms = float(row["rms"])
            assert 0.0 <= rms <= 1000.0
        except (ValueError, KeyError) as e:
            pytest.fail(f"Invalid numeric field in row: {e}")


def test_pipeline_deduplication(client):
    """
    Verify that posting the same timestamp+device_id twice does not create
    duplicate CSV rows.
    """
    c, data_dir = client

    # Create a sample
    base_time = datetime(2026, 3, 3, 13, 0, 0, tzinfo=timezone.utc)
    sample = generate_sample("dup-test-device", base_time, "normal")

    # POST it twice
    r1 = c.post("/ingest", json=sample)
    r2 = c.post("/ingest", json=sample)

    assert r1.status_code == 200
    assert r1.get_json().get("accepted", 0) >= 1
    assert r2.status_code == 200
    # Second post: duplicate is accepted (not rejected) but nothing written to CSV
    assert r2.get_json().get("accepted", 0) >= 1

    # Verify stats shows only 1 sample (duplicate was not written to CSV)
    r = c.get("/stats")
    assert r.status_code == 200
    assert r.get_json()["total_samples"] == 1


def test_pipeline_stats_cache(client):
    """
    Verify /stats caching works (should return cached data for 10s).
    """
    c, data_dir = client

    # POST one sample
    sample = generate_sample("cache-test", datetime.now(timezone.utc), "normal")
    c.post("/ingest", json=sample)

    # Get stats (should compute and cache)
    r1 = c.get("/stats")
    stats1 = r1.get_json()
    assert stats1["total_samples"] == 1

    # Get stats again (should return cached version)
    r2 = c.get("/stats")
    stats2 = r2.get_json()
    assert stats2["total_samples"] == 1
    assert stats2 == stats1  # Exact same response


def test_pipeline_quality_endpoint(client):
    """
    Verify /quality endpoint returns valid quality metrics.
    """
    c, data_dir = client

    # POST 10 samples
    base_time = datetime(2026, 3, 3, 14, 0, 0, tzinfo=timezone.utc)
    for i in range(10):
        ts = base_time.replace(second=(base_time.second + i) % 60)
        sample = generate_sample("quality-test", ts, "normal")
        c.post("/ingest", json=sample)

    # Get quality metrics
    r = c.get("/quality")
    assert r.status_code == 200
    quality = r.get_json()

    # Verify expected fields
    assert "total_samples" in quality
    assert quality["total_samples"] == 10
    assert "quality_score" in quality
    assert 0.0 <= quality["quality_score"] <= 1.0
    assert "status" in quality
    assert quality["status"] in ("good", "degraded", "poor")
    assert "duplicate_records" in quality
    assert quality["duplicate_records"] == 0


def test_pipeline_devices_endpoint(client):
    """
    Verify /devices endpoint returns list of unique device IDs.
    """
    c, data_dir = client

    base_time = datetime(2026, 3, 3, 15, 0, 0, tzinfo=timezone.utc)

    # POST samples from multiple devices
    devices = ["device-a", "device-b", "device-c"]
    for dev in devices:
        ts = base_time
        sample = generate_sample(dev, ts, "normal")
        c.post("/ingest", json=sample)

    # Get devices list
    r = c.get("/devices")
    assert r.status_code == 200
    result = r.get_json()

    assert "devices" in result
    assert len(result["devices"]) == 3
    assert set(result["devices"]) == set(devices)
    assert result["count"] == 3


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
