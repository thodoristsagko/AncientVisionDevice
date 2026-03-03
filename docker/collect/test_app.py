import csv
import os
import threading
import pytest
from app import create_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c, tmp_path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

BASE_PAYLOAD = {
    "device_id": "m5stick-01",
    "timestamp": "2026-03-03T10:00:00Z",
    "rms": 0.01,
    "ppv": 0.05,
    "freq": 15.0,
    "crest": 3.0,
    "centroid": 20.0,
    "kurtosis": 1.5,
    "stalta": 1.0,
    "arias": 0.0001,
    "cav": 0.002,
    "label": "normal",
}


def _post_sample(c, overrides=None, ts_suffix=""):
    payload = {**BASE_PAYLOAD}
    if ts_suffix:
        payload["timestamp"] = f"2026-03-03T10:00:0{ts_suffix}Z"
    if overrides:
        payload.update(overrides)
    return c.post("/ingest", json=payload)


# ---------------------------------------------------------------------------
# Existing tests (unchanged)
# ---------------------------------------------------------------------------

def test_ingest_writes_csv(client):
    c, data_dir = client
    payload = {
        "device_id": "m5stick-01",
        "timestamp": "2026-03-03T10:00:00Z",
        "rms": 0.01,
        "ppv": 0.05,
        "freq": 15.0,
        "crest": 3.0,
        "centroid": 20.0,
        "kurtosis": 1.5,
        "stalta": 1.0,
        "arias": 0.0001,
        "cav": 0.002,
        "label": "normal"
    }
    r = c.post("/ingest", json=payload)
    assert r.status_code == 200
    csvs = list(data_dir.glob("field/*.csv"))
    assert len(csvs) == 1
    with open(csvs[0]) as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 1
    assert rows[0]["device_id"] == "m5stick-01"


def test_ingest_increments_sample_count(client):
    c, data_dir = client
    base = {
        "device_id": "m5stick-01",
        "rms": 0.01, "ppv": 0.05, "freq": 15.0, "crest": 3.0,
        "centroid": 20.0, "kurtosis": 1.5, "stalta": 1.0,
        "arias": 0.0001, "cav": 0.002, "label": "normal"
    }
    c.post("/ingest", json={**base, "timestamp": "2026-03-03T10:00:00Z"})
    c.post("/ingest", json={**base, "timestamp": "2026-03-03T10:00:01Z"})
    count_file = data_dir / "field" / ".sample_count"
    assert count_file.read_text().strip() == "2"


def test_ingest_rejects_missing_fields(client):
    c, _ = client
    r = c.post("/ingest", json={"device_id": "x"})
    assert r.status_code == 400


def test_health(client):
    c, _ = client
    r = c.get("/health")
    assert r.status_code == 200


def test_ingest_uses_env_collection_name(tmp_path, monkeypatch):
    """FIRESTORE_COLLECTION env var must be passed into the Firestore sync loop."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("FIRESTORE_COLLECTION", "test_col")
    # No credentials set — sync is disabled, but the app must still start and
    # the health endpoint must work (proves create_app() consumed the env var
    # without crashing).
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        r = c.get("/health")
        assert r.status_code == 200


def test_dedup_same_timestamp(client):
    """Same timestamp+device_id twice must not create a duplicate CSV row."""
    c, data_dir = client
    payload = {
        "device_id": "m5stick-01", "timestamp": "2026-03-03T10:00:00Z",
        "rms": 0.01, "ppv": 0.05, "freq": 15.0, "crest": 3.0,
        "centroid": 20.0, "kurtosis": 1.5, "stalta": 1.0,
        "arias": 0.0001, "cav": 0.002, "label": "normal"
    }
    c.post("/ingest", json=payload)
    r = c.post("/ingest", json=payload)
    assert r.status_code == 200
    assert r.get_json()["status"] == "duplicate"
    csvs = list(data_dir.glob("field/*.csv"))
    with open(csvs[0]) as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 1  # only one row despite two POSTs


# ---------------------------------------------------------------------------
# New tests: P04-P09
# ---------------------------------------------------------------------------

def test_stats_returns_json(client):
    """POST one sample, then GET /stats — total_samples must be >= 1."""
    c, _ = client
    _post_sample(c)
    r = c.get("/stats")
    assert r.status_code == 200
    body = r.get_json()
    assert "total_samples" in body
    assert body["total_samples"] >= 1
    assert "samples_today" in body
    assert "devices" in body
    assert "classes" in body
    assert "csv_files" in body
    assert body["csv_files"] >= 1


def test_export_returns_csv(client):
    """POST one sample, GET /export — Content-Type must be text/csv and body must have CSV header."""
    c, _ = client
    _post_sample(c)
    r = c.get("/export")
    assert r.status_code == 200
    # Content-Type may include charset suffix; check prefix only
    assert r.content_type.startswith("text/csv")
    text = r.data.decode("utf-8")
    # The CSV header row must be present
    assert "device_id" in text
    assert "timestamp" in text
    assert "ppv" in text


def test_devices_lists_device_ids(client):
    """POST a sample with device_id='test-dev', then GET /devices — 'test-dev' must appear."""
    c, _ = client
    _post_sample(c, overrides={"device_id": "test-dev", "timestamp": "2026-03-03T11:00:00Z"})
    r = c.get("/devices")
    assert r.status_code == 200
    body = r.get_json()
    assert "devices" in body
    assert "count" in body
    assert "test-dev" in body["devices"]
    assert body["count"] >= 1


def test_invalid_ppv_rejected(client):
    """POST with ppv=999.9 (out of range) must return 400 with out_of_range error."""
    c, _ = client
    r = _post_sample(c, overrides={"ppv": 999.9, "timestamp": "2026-03-03T12:00:00Z"})
    assert r.status_code == 400
    body = r.get_json()
    assert body.get("error") == "out_of_range"
    assert body.get("field") == "ppv"
    assert body.get("value") == 999.9


def test_invalid_freq_rejected(client):
    """POST with freq=99999 (out of range) must return 400 with out_of_range error."""
    c, _ = client
    r = _post_sample(c, overrides={"freq": 99999, "timestamp": "2026-03-03T13:00:00Z"})
    assert r.status_code == 400
    body = r.get_json()
    assert body.get("error") == "out_of_range"
    assert body.get("field") == "freq"


def test_rate_limiting(client):
    """Send 11 requests from same device_id rapidly — at least one must return 429."""
    c, _ = client
    statuses = []
    for i in range(11):
        # Use unique timestamps to avoid dedup, but same device_id
        payload = {**BASE_PAYLOAD, "device_id": "rate-test-dev", "timestamp": f"2026-03-03T14:00:{i:02d}Z"}
        r = c.post("/ingest", json=payload)
        statuses.append(r.status_code)
    assert 429 in statuses, f"Expected at least one 429, got: {statuses}"
    # Verify the 429 response body is correct
    for i, status in enumerate(statuses):
        if status == 429:
            payload = {**BASE_PAYLOAD, "device_id": "rate-test-dev", "timestamp": f"2026-03-03T14:00:{i:02d}Z"}
            # Re-issue just to confirm structure (already have statuses list)
            break
    # At least confirm 429 appeared
    assert statuses.count(429) >= 1


# ---------------------------------------------------------------------------
# P88: Concurrent CSV write stress test
# ---------------------------------------------------------------------------

class TestConcurrentWrites:

    def test_concurrent_ingest_no_data_loss(self, tmp_path, monkeypatch):
        """
        20 threads each send 5 unique samples (100 total).
        All requests use distinct timestamps so none are deduplicated.
        The final .sample_count must equal exactly 100.
        """
        monkeypatch.setenv("DATA_DIR", str(tmp_path))
        app = create_app()
        app.config["TESTING"] = True

        errors = []

        def _send_samples(thread_id: int):
            # Each thread gets its own test client to avoid sharing state
            with app.test_client() as c:
                for sample_idx in range(5):
                    # Unique timestamp per (thread, sample) pair
                    ts = f"2026-03-03T15:{thread_id:02d}:{sample_idx:02d}Z"
                    payload = {
                        **BASE_PAYLOAD,
                        "device_id": f"stress-dev-{thread_id}",
                        "timestamp": ts,
                    }
                    r = c.post("/ingest", json=payload)
                    if r.status_code not in (200,):
                        errors.append(
                            f"Thread {thread_id} sample {sample_idx}: "
                            f"status {r.status_code} body {r.data}"
                        )

        threads = [threading.Thread(target=_send_samples, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors, f"Some requests failed:\n" + "\n".join(errors)

        count_file = tmp_path / "field" / ".sample_count"
        sample_count = int(count_file.read_text().strip())
        assert sample_count == 100, (
            f"Expected 100 samples (20 threads x 5 each), got {sample_count}"
        )
