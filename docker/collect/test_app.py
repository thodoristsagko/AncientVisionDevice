import csv
import os
import pytest
from app import create_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c, tmp_path


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
