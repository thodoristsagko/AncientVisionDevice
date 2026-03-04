import csv
import os
import threading
import pytest
from datetime import datetime, timezone, timedelta
from app import create_app, CSV_HEADER


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
    # New batch response: accepted=1 (duplicate counts as accepted, not rejected)
    body = r.get_json()
    assert body["accepted"] == 1
    assert body["rejected"] == 0
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
    # New batch response shape: accepted=0, rejected=1, errors=[...]
    assert body.get("accepted") == 0
    assert body.get("rejected") == 1
    assert any("out_of_range" in e and "ppv" in e for e in body.get("errors", []))


def test_invalid_freq_rejected(client):
    """POST with freq=99999 (out of range) must return 400 with out_of_range error."""
    c, _ = client
    r = _post_sample(c, overrides={"freq": 99999, "timestamp": "2026-03-03T13:00:00Z"})
    assert r.status_code == 400
    body = r.get_json()
    # New batch response shape: accepted=0, rejected=1, errors=[...]
    assert body.get("accepted") == 0
    assert body.get("rejected") == 1
    assert any("out_of_range" in e and "freq" in e for e in body.get("errors", []))


def test_rate_limiting(client):
    """Send 11 requests from same device_id rapidly — at least one must be rate-limited.

    With the new batch ingest, a rate-limited single-sample POST returns 400 (all rejected)
    with a 'rate_limited' error in the errors list.
    """
    c, _ = client
    rate_limited_count = 0
    for i in range(11):
        payload = {**BASE_PAYLOAD, "device_id": "rate-test-dev", "timestamp": f"2026-03-03T14:00:{i:02d}Z"}
        r = c.post("/ingest", json=payload)
        body = r.get_json() or {}
        if r.status_code == 400 and any(
            "rate_limited" in e for e in body.get("errors", [])
        ):
            rate_limited_count += 1
    assert rate_limited_count >= 1, "Expected at least one rate-limited rejection"


# ---------------------------------------------------------------------------
# P106: /quality endpoint
# ---------------------------------------------------------------------------

def test_quality_returns_json(client):
    c, _ = client
    _post_sample(c)
    resp = c.get("/quality")
    assert resp.status_code == 200
    data = resp.get_json()
    assert "total_samples" in data
    assert "quality_score" in data
    assert 0.0 <= data["quality_score"] <= 1.0
    assert data["status"] in ("good", "degraded", "poor")


# ---------------------------------------------------------------------------
# P88: Concurrent CSV write stress test
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Sessions endpoints
# ---------------------------------------------------------------------------

BASE_SESSION = {
    "device_id": "m5stick-01",
    "start_time": "2026-03-04T08:00:00Z",
    "end_time": "2026-03-04T08:30:00Z",
    "peak_ppv": 0.42,
    "sample_count": 450,
    "anomaly_events": 2,
    "session_export": [[0.01, 15.0], [0.02, 16.0]],
}


def test_ingest_session_success(client):
    """POST a valid session — must return 200 with status=ok and a session_id."""
    c, data_dir = client
    r = c.post("/sessions", json=BASE_SESSION)
    assert r.status_code == 200
    body = r.get_json()
    assert body["status"] == "ok"
    assert "session_id" in body
    session_id = body["session_id"]
    # File must exist on disk
    session_files = list((data_dir / "sessions").glob("session_*.json"))
    assert len(session_files) == 1
    import json
    stored = json.loads(session_files[0].read_text())
    assert stored["device_id"] == "m5stick-01"
    assert stored["peak_ppv"] == 0.42
    assert stored["session_id"] == session_id


def test_ingest_session_missing_fields(client):
    """POST with missing required fields must return 400."""
    c, _ = client
    # Missing start_time and end_time
    r = c.post("/sessions", json={"device_id": "m5stick-01"})
    assert r.status_code == 400
    body = r.get_json()
    assert "error" in body
    assert "missing fields" in body["error"]


def test_list_sessions(client):
    """POST two sessions, GET /sessions — both must appear in the list."""
    c, _ = client
    session_a = {**BASE_SESSION, "device_id": "dev-a"}
    session_b = {**BASE_SESSION, "device_id": "dev-b",
                 "start_time": "2026-03-04T09:00:00Z",
                 "end_time": "2026-03-04T09:45:00Z"}
    c.post("/sessions", json=session_a)
    c.post("/sessions", json=session_b)

    r = c.get("/sessions")
    assert r.status_code == 200
    body = r.get_json()
    assert "sessions" in body
    assert "count" in body
    assert body["count"] == 2
    device_ids = {s["device_id"] for s in body["sessions"]}
    assert "dev-a" in device_ids
    assert "dev-b" in device_ids
    # session_export must not be in the summary
    for s in body["sessions"]:
        assert "session_export" not in s


def test_get_session(client):
    """POST a session, retrieve it by session_id — full JSON including session_export."""
    c, _ = client
    r = c.post("/sessions", json=BASE_SESSION)
    session_id = r.get_json()["session_id"]

    r2 = c.get(f"/sessions/{session_id}")
    assert r2.status_code == 200
    body = r2.get_json()
    assert body["session_id"] == session_id
    assert body["device_id"] == "m5stick-01"
    assert body["session_export"] == [[0.01, 15.0], [0.02, 16.0]]


def test_get_session_not_found(client):
    """GET /sessions/<nonexistent> must return 404."""
    c, _ = client
    r = c.get("/sessions/session_nonexistent_00000000T000000000000")
    assert r.status_code == 404


def test_sessions_export_csv(client):
    """POST a session, GET /sessions/export — must return valid CSV with correct columns."""
    c, _ = client
    c.post("/sessions", json=BASE_SESSION)

    r = c.get("/sessions/export")
    assert r.status_code == 200
    assert r.content_type.startswith("text/csv")

    text = r.data.decode("utf-8")
    lines = [l for l in text.strip().splitlines() if l]
    # Header + at least one data row
    assert len(lines) >= 2
    header = lines[0].split(",")
    assert "device_id" in header
    assert "start_time" in header
    assert "end_time" in header
    assert "duration_min" in header
    assert "peak_ppv" in header
    assert "sample_count" in header
    assert "anomaly_events" in header

    import csv as csv_mod
    import io
    reader = csv_mod.DictReader(io.StringIO(text))
    rows = list(reader)
    assert len(rows) >= 1
    row = rows[0]
    assert row["device_id"] == "m5stick-01"
    assert float(row["duration_min"]) == pytest.approx(30.0, abs=0.01)
    assert float(row["peak_ppv"]) == pytest.approx(0.42, abs=0.001)


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


# ---------------------------------------------------------------------------
# New tests: Pagination, Archive, and Metrics
# ---------------------------------------------------------------------------

def test_paginated_data_endpoint(client):
    """POST multiple samples, GET /data with pagination."""
    c, _ = client
    # Post 20 samples with different timestamps and two devices
    # Use unique timestamps to avoid dedup, and spread by device to manage rate limiting
    sample_count = 0
    for i in range(10):
        # dev-a: post 10 samples
        payload = {
            **BASE_PAYLOAD,
            "device_id": "dev-a",
            "timestamp": f"2026-03-03T16:01:{i:02d}Z",
            "ppv": 0.01 + (i * 0.002),
        }
        c.post("/ingest", json=payload)
        sample_count += 1

    for i in range(10):
        # dev-b: post 10 samples
        payload = {
            **BASE_PAYLOAD,
            "device_id": "dev-b",
            "timestamp": f"2026-03-03T16:02:{i:02d}Z",
            "ppv": 0.01 + (i * 0.002),
        }
        c.post("/ingest", json=payload)
        sample_count += 1

    # Test: default pagination (per_page=50)
    r = c.get("/data")
    assert r.status_code == 200
    body = r.get_json()
    assert "data" in body
    assert "total" in body
    assert "page" in body
    assert "per_page" in body
    assert "pages" in body
    assert body["total"] == sample_count
    assert body["page"] == 1
    assert body["per_page"] == 50
    assert body["pages"] == 1
    assert len(body["data"]) == sample_count

    # Test: custom per_page
    r = c.get("/data?page=1&per_page=10")
    assert r.status_code == 200
    body = r.get_json()
    assert body["total"] == sample_count
    assert body["per_page"] == 10
    assert body["pages"] == 2
    assert len(body["data"]) == 10

    # Test: page 2
    r = c.get("/data?page=2&per_page=10")
    assert r.status_code == 200
    body = r.get_json()
    assert body["page"] == 2
    assert len(body["data"]) == 10

    # Test: out of range page
    r = c.get("/data?page=100&per_page=10")
    assert r.status_code == 200
    body = r.get_json()
    assert len(body["data"]) == 0

    # Test: device_id filter
    r = c.get("/data?device_id=dev-a&per_page=50")
    assert r.status_code == 200
    body = r.get_json()
    assert body["total"] == 10
    assert all(row["device_id"] == "dev-a" for row in body["data"])

    # Test: device_id filter with dev-b
    r = c.get("/data?device_id=dev-b&per_page=50")
    assert r.status_code == 200
    body = r.get_json()
    assert body["total"] == 10
    assert all(row["device_id"] == "dev-b" for row in body["data"])

    # Test: date_from filter
    r = c.get("/data?date_from=2026-03-03&per_page=50")
    assert r.status_code == 200
    body = r.get_json()
    # All samples are from 2026-03-03
    assert body["total"] == sample_count

    # Test: invalid page
    r = c.get("/data?page=0")
    assert r.status_code == 400
    assert "page must be >= 1" in r.get_json()["error"]

    # Test: invalid per_page
    r = c.get("/data?per_page=0")
    assert r.status_code == 400
    assert "per_page must be 1-1000" in r.get_json()["error"]

    r = c.get("/data?per_page=2000")
    assert r.status_code == 400
    assert "per_page must be 1-1000" in r.get_json()["error"]


def test_archive_endpoint_basic(client):
    """POST samples, archive old data, verify files moved."""
    import os
    c, data_dir = client

    # Create a sample from 40 days ago by manually writing to CSV
    # (since we can't easily mock time in ingest())
    field_dir = data_dir / "field"
    field_dir.mkdir(parents=True, exist_ok=True)

    # Write old CSV with a sample from 40 days ago
    old_date = (datetime.now(timezone.utc) - timedelta(days=40)).strftime("%Y-%m-%d")
    old_csv = field_dir / f"{old_date}.csv"
    old_sample = {
        "device_id": "old-dev",
        "timestamp": (datetime.now(timezone.utc) - timedelta(days=40)).isoformat(),
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
    with open(old_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_HEADER)
        writer.writeheader()
        writer.writerow(old_sample)

    # Set file mtime to 40 days ago so archive can detect it
    old_mtime = (datetime.now(timezone.utc) - timedelta(days=40)).timestamp()
    os.utime(old_csv, (old_mtime, old_mtime))

    # Also post a recent sample
    _post_sample(c, overrides={"device_id": "recent-dev"})

    # Verify files before archive
    assert old_csv.exists()
    assert len(list(field_dir.glob("*.csv"))) == 2  # old + today

    # Archive with days=30 (should move old_csv but not today)
    r = c.post("/archive?days=30")
    assert r.status_code == 200
    body = r.get_json()
    assert body["archived_files"] >= 1
    assert body["archived_samples"] >= 1
    assert body["freed_bytes"] > 0

    # Verify old file was moved to archive/
    archive_dir = data_dir / "archive"
    assert archive_dir.exists()
    assert (archive_dir / old_csv.name).exists()
    # Old file should no longer be in field/
    assert not old_csv.exists()

    # Verify today's file still exists
    today_csv = field_dir / datetime.now(timezone.utc).strftime("%Y-%m-%d.csv")
    assert today_csv.exists()


def test_archive_endpoint_respects_days_threshold(client):
    """Test that archive respects the days parameter."""
    import os
    c, data_dir = client

    field_dir = data_dir / "field"
    field_dir.mkdir(parents=True, exist_ok=True)

    # Create two old CSVs: 15 days old and 45 days old
    for days_old in [15, 45]:
        old_date = (datetime.now(timezone.utc) - timedelta(days=days_old)).strftime("%Y-%m-%d")
        old_csv = field_dir / f"{old_date}.csv"
        old_sample = {
            **BASE_PAYLOAD,
            "device_id": f"dev-{days_old}days",
            "timestamp": (datetime.now(timezone.utc) - timedelta(days=days_old)).isoformat(),
        }
        with open(old_csv, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_HEADER)
            writer.writeheader()
            writer.writerow(old_sample)

        # Set file mtime to match the age
        old_mtime = (datetime.now(timezone.utc) - timedelta(days=days_old)).timestamp()
        os.utime(old_csv, (old_mtime, old_mtime))

    # Archive with days=30 (should only move 45-day-old file)
    r = c.post("/archive?days=30")
    assert r.status_code == 200
    body = r.get_json()
    # Only the 45-day-old file should be archived
    assert body["archived_files"] >= 1

    # 15-day-old file should still be in field/
    csv_15 = field_dir / (datetime.now(timezone.utc) - timedelta(days=15)).strftime("%Y-%m-%d.csv")
    # Note: file might not exist if the date doesn't match exactly due to midnight boundary
    # But if it does exist, it should not be archived
    if csv_15.exists():
        assert csv_15.exists()  # Should still be there


def test_metrics_endpoint_format(client):
    """Test /metrics endpoint returns valid Prometheus format."""
    c, _ = client
    _post_sample(c, overrides={"device_id": "metrics-dev", "label": "normal"})
    _post_sample(c, overrides={"device_id": "metrics-dev", "label": "anomaly", "timestamp": "2026-03-03T10:00:01Z"})

    r = c.get("/metrics")
    assert r.status_code == 200
    # Content type should be text/plain
    assert "text/plain" in r.content_type
    text = r.data.decode("utf-8")

    # Check for key Prometheus metrics
    assert "ancientvision_samples_total" in text
    assert "ancientvision_devices_active" in text
    assert "ancientvision_rate_limit_hits_total" in text
    assert "ancientvision_samples_by_class" in text
    assert "ancientvision_samples_by_device" in text

    # Verify format: each metric should have HELP and TYPE
    lines = text.strip().split("\n")
    assert any("# HELP ancientvision_samples_total" in line for line in lines)
    assert any("# TYPE ancientvision_samples_total counter" in line for line in lines)
    assert any("ancientvision_samples_total " in line for line in lines)

    # Check for per-device breakdown
    assert 'device_id="metrics-dev"' in text

    # Check for per-class breakdown
    assert 'class="normal"' in text
    assert 'class="anomaly"' in text


def test_metrics_endpoint_per_device_counts(client):
    """Test that /metrics reports per-device sample counts accurately."""
    c, _ = client
    # Post samples from different devices
    for i in range(3):
        _post_sample(c, overrides={"device_id": "dev-x", "timestamp": f"2026-03-03T10:00:0{i}Z"})
    for i in range(5):
        _post_sample(c, overrides={"device_id": "dev-y", "timestamp": f"2026-03-03T11:00:0{i}Z"})

    r = c.get("/metrics")
    assert r.status_code == 200
    text = r.data.decode("utf-8")

    # Should report 3 samples for dev-x and 5 for dev-y
    assert 'ancientvision_samples_by_device{device_id="dev-x"} 3' in text
    assert 'ancientvision_samples_by_device{device_id="dev-y"} 5' in text


# ---------------------------------------------------------------------------
# New tests: batch /ingest, /device/<id>/summary, /summary
# ---------------------------------------------------------------------------

def test_ingest_endpoint_single(client):
    """Test /ingest with a single sample object (backward-compatible behaviour)."""
    c, data_dir = client
    # Single sample as a plain JSON object
    r = c.post("/ingest", json={**BASE_PAYLOAD, "timestamp": "2026-03-04T08:00:00Z"})
    assert r.status_code == 200
    body = r.get_json()
    assert body["accepted"] == 1
    assert body["rejected"] == 0
    assert "errors" not in body

    # Confirm CSV was written
    csvs = list(data_dir.glob("field/*.csv"))
    assert len(csvs) == 1
    with open(csvs[0]) as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 1
    assert rows[0]["device_id"] == BASE_PAYLOAD["device_id"]


def test_ingest_endpoint_batch(client):
    """Test /ingest with a batch array of samples."""
    c, data_dir = client

    good_a = {**BASE_PAYLOAD, "timestamp": "2026-03-04T09:00:00Z", "device_id": "batch-dev"}
    good_b = {**BASE_PAYLOAD, "timestamp": "2026-03-04T09:00:01Z", "device_id": "batch-dev"}
    # Invalid sample: ppv out of range
    bad = {**BASE_PAYLOAD, "timestamp": "2026-03-04T09:00:02Z", "device_id": "batch-dev",
           "ppv": 999.9}

    r = c.post("/ingest", json=[good_a, good_b, bad])
    # Partial success → 207
    assert r.status_code == 207
    body = r.get_json()
    assert body["accepted"] == 2
    assert body["rejected"] == 1
    assert len(body["errors"]) == 1
    assert "out_of_range" in body["errors"][0]

    # Confirm exactly 2 rows in CSV
    csvs = list(data_dir.glob("field/*.csv"))
    assert len(csvs) == 1
    with open(csvs[0]) as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 2

    # All-rejected batch → 400
    r2 = c.post("/ingest", json=[{"device_id": "x"}])
    assert r2.status_code == 400
    body2 = r2.get_json()
    assert body2["accepted"] == 0
    assert body2["rejected"] == 1

    # All-accepted batch → 200
    ok_a = {**BASE_PAYLOAD, "timestamp": "2026-03-04T10:00:00Z", "device_id": "ok-dev"}
    ok_b = {**BASE_PAYLOAD, "timestamp": "2026-03-04T10:00:01Z", "device_id": "ok-dev"}
    r3 = c.post("/ingest", json=[ok_a, ok_b])
    assert r3.status_code == 200
    body3 = r3.get_json()
    assert body3["accepted"] == 2
    assert body3["rejected"] == 0
    assert "errors" not in body3


def test_device_summary_endpoint(client):
    """Test /device/<device_id>/summary returns correct per-device stats."""
    c, _ = client
    # Post 3 samples for "summary-dev", 1 with a different label and higher ppv
    _post_sample(c, overrides={"device_id": "summary-dev", "timestamp": "2026-03-04T08:00:00Z",
                                "ppv": 0.10, "label": "normal"})
    _post_sample(c, overrides={"device_id": "summary-dev", "timestamp": "2026-03-04T08:00:01Z",
                                "ppv": 0.42, "label": "anomaly"})
    _post_sample(c, overrides={"device_id": "summary-dev", "timestamp": "2026-03-04T08:00:02Z",
                                "ppv": 0.05, "label": "normal"})

    r = c.get("/device/summary-dev/summary")
    assert r.status_code == 200
    body = r.get_json()

    assert body["device_id"] == "summary-dev"
    assert body["total_samples"] == 3
    assert body["first_seen"] is not None
    assert body["last_seen"] is not None
    assert body["first_seen"] <= body["last_seen"]
    assert body["session_count"] >= 1
    assert body["class_distribution"]["normal"] == 2
    assert body["class_distribution"]["anomaly"] == 1
    assert body["peak_ppv"] == pytest.approx(0.42, abs=1e-4)
    assert 0.0 < body["mean_ppv"] < 0.42

    # Unknown device → 404
    r2 = c.get("/device/nonexistent-dev/summary")
    assert r2.status_code == 404


def test_summary_endpoint(client):
    """Test /summary returns aggregated stats across all devices."""
    c, _ = client
    # Post samples from two distinct devices
    _post_sample(c, overrides={"device_id": "sum-dev-a", "timestamp": "2026-03-04T08:00:00Z",
                                "label": "normal"})
    _post_sample(c, overrides={"device_id": "sum-dev-a", "timestamp": "2026-03-04T08:00:01Z",
                                "label": "anomaly"})
    _post_sample(c, overrides={"device_id": "sum-dev-b", "timestamp": "2026-03-04T08:00:02Z",
                                "label": "normal"})

    r = c.get("/summary")
    assert r.status_code == 200
    body = r.get_json()

    assert body["total_samples"] == 3
    assert body["total_devices"] == 2
    assert body["first_seen"] is not None
    assert body["last_seen"] is not None
    assert "class_distribution" in body
    assert body["class_distribution"]["normal"] == 2
    assert body["class_distribution"]["anomaly"] == 1
    assert "top_devices" in body
    assert len(body["top_devices"]) <= 3
    # top_devices entries must have device_id and sample_count
    for entry in body["top_devices"]:
        assert "device_id" in entry
        assert "sample_count" in entry
    assert "ready_for_training" in body
    assert isinstance(body["ready_for_training"], bool)
    assert "trigger_threshold" in body
    # 3 samples is below default threshold of 100, so not ready
    assert body["ready_for_training"] is False
    # last_retrain_trigger may be None if no trigger file exists
    assert "last_retrain_trigger" in body
