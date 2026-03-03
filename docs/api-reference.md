# Data Collector API Reference

Base URL: `http://localhost:8765` (default port, configurable via `PORT` env var).

All endpoints return JSON unless otherwise noted. Error responses follow the shape:
```json
{"error": "<description>"}
```

## Authentication

When the `API_KEY` environment variable is set, all endpoints except `/health` and
`/metrics` require the header:

```
X-API-Key: <your-key>
```

Requests missing or supplying the wrong key receive `401 Unauthorized`.

---

## GET /health

Health check. Always returns `200 OK`. Not protected by API key.

**Response**

```json
{
  "status": "ok",
  "samples": 1234
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Always `"ok"` |
| `samples` | integer | Total samples written to CSV since service start |

---

## POST /ingest

Submit one sensor sample. Deduplicated by `timestamp + device_id` (in-memory,
per process). Samples are appended to a daily CSV file in `data/field/`.

**Request body (JSON)**

```json
{
  "device_id": "av-001",
  "timestamp": "2026-03-03T10:15:30.000Z",
  "rms": 0.045,
  "ppv": 0.12,
  "freq": 22.5,
  "crest": 2.8,
  "centroid": 18.3,
  "kurtosis": 1.7,
  "stalta": 1.1,
  "arias": 0.002,
  "cav": 0.05,
  "label": "normal"
}
```

| Field | Type | Required | Unit | Description |
|-------|------|----------|------|-------------|
| `device_id` | string | yes | — | Unique device identifier (e.g. `"av-001"`) |
| `timestamp` | string | yes | ISO 8601 UTC | Sample collection time |
| `rms` | float | yes | g | RMS acceleration |
| `ppv` | float | yes | mm/s | Peak Component Particle Velocity (DIN 4150-3) |
| `freq` | float | yes | Hz | Dominant frequency |
| `crest` | float | yes | — | Crest factor (peak/RMS) |
| `centroid` | float | yes | Hz | Spectral centroid |
| `kurtosis` | float | yes | — | Statistical kurtosis |
| `stalta` | float | yes | — | STA/LTA ratio |
| `arias` | float | yes | m/s | Arias intensity |
| `cav` | float | yes | m/s | Cumulative Absolute Velocity (EPRI) |
| `label` | string | yes | — | One of: `"normal"`, `"anomaly"`, `"precursor"`, `"unknown"` |

**Validation ranges**

| Field | Min | Max |
|-------|-----|-----|
| `ppv` | 0.0 | 100.0 |
| `freq` | 0.0 | 2000.0 |
| `rms` | 0.0 | 1000.0 |
| `crest` | 0.0 | 100.0 |
| `kurtosis` | -5.0 | 50.0 |
| `stalta` | 0.0 | 100.0 |

**Rate limit**: 10 requests per device per second (configurable via `/config`).

**Response — 200 OK**

```json
{"status": "ok"}
```

or if the sample was a duplicate:

```json
{"status": "duplicate"}
```

**Response — 400 Bad Request**

```json
{"error": "missing fields: ['label']"}
```

or for out-of-range:

```json
{"error": "out_of_range", "field": "ppv", "value": 999.0}
```

**Response — 429 Too Many Requests**

```json
{"error": "rate_limited", "device_id": "av-001"}
```

---

## GET /stats

Aggregate statistics about all collected data. Cached for 10 seconds.

**Response**

```json
{
  "total_samples": 5230,
  "samples_today": 312,
  "devices": ["av-001", "av-002"],
  "classes": {
    "normal": 4800,
    "precursor": 350,
    "anomaly": 80
  },
  "csv_files": 7
}
```

| Field | Type | Description |
|-------|------|-------------|
| `total_samples` | integer | Total rows across all CSV files |
| `samples_today` | integer | Rows in today's CSV file |
| `devices` | array[string] | Sorted list of unique device IDs |
| `classes` | object | Count per label value |
| `csv_files` | integer | Number of daily CSV files on disk |

---

## GET /export

Download all collected data as a single CSV file.

**Response**: `200 OK` with `Content-Type: text/csv` and
`Content-Disposition: attachment; filename="field_data_YYYY-MM-DD.csv"`.

The CSV contains the header row followed by all rows from all daily CSV files in
chronological order. If no data has been collected yet, only the header row is
returned.

**Column order in the CSV:**

```
device_id, timestamp, rms, ppv, freq, crest, centroid, kurtosis, stalta, arias, cav, label
```

---

## GET /devices

List all device IDs that have submitted data.

**Response**

```json
{
  "devices": ["av-001", "av-002"],
  "count": 2
}
```

---

## GET /quality

Data quality metrics: missing fields, out-of-range values, and duplicate records.

**Response**

```json
{
  "total_samples": 5230,
  "missing_required_fields": 12,
  "out_of_range_values": 3,
  "duplicate_records": 1,
  "quality_score": 0.997,
  "status": "good"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `total_samples` | integer | Total rows scanned |
| `missing_required_fields` | integer | Rows missing at least one of `device_id`, `timestamp`, `ppv`, `rms`, `freq`, `kurtosis` |
| `out_of_range_values` | integer | Rows with `ppv` outside [0, 100] |
| `duplicate_records` | integer | Rows with duplicate `(timestamp, device_id)` pairs |
| `quality_score` | float | 0.0–1.0; computed as `1 - (errors / (total * 3))` |
| `status` | string | `"good"` (>0.9), `"degraded"` (>0.7), or `"poor"` |

---

## POST /label

Update the label for a specific sample identified by `timestamp + device_id`.
Rewrites the matching CSV file(s) in place.

**Request body (JSON)**

```json
{
  "timestamp": "2026-03-03T10:15:30.000Z",
  "device_id": "av-001",
  "label": "precursor"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `timestamp` | string | yes | Must match the stored timestamp exactly |
| `device_id` | string | yes | Must match the stored device_id exactly |
| `label` | string | yes | One of: `"normal"`, `"anomaly"`, `"precursor"`, `"unknown"` |

**Response — 200 OK**

```json
{"status": "ok", "rows_updated": 1}
```

**Response — 400 Bad Request**

```json
{"error": "invalid label: 'bad'. Must be one of ['anomaly', 'normal', 'precursor', 'unknown']"}
```

**Response — 404 Not Found**

```json
{"error": "no matching row found"}
```

---

## GET /config

Return the current runtime configuration.

**Response**

```json
{
  "firestore_collection": "vibration_samples",
  "trigger_threshold": 100,
  "rate_limit_rps": 10,
  "max_ppv": 100
}
```

| Field | Type | Description |
|-------|------|-------------|
| `firestore_collection` | string | Firestore collection name for background sync |
| `trigger_threshold` | integer | New samples needed to trigger retraining |
| `rate_limit_rps` | integer | Max ingest requests per device per second |
| `max_ppv` | integer | Maximum accepted PPV value (mm/s) |

---

## POST /config

Update runtime configuration. Only `trigger_threshold` and `rate_limit_rps` are
writable; other fields are read-only.

**Request body (JSON)**

```json
{
  "trigger_threshold": 200,
  "rate_limit_rps": 5
}
```

| Field | Type | Range | Description |
|-------|------|-------|-------------|
| `trigger_threshold` | integer | 1–10000 | New samples needed to trigger retraining |
| `rate_limit_rps` | integer | 1–100 | Max ingest requests per device per second |

**Response — 200 OK** — returns the full config object (same shape as `GET /config`).

**Response — 400 Bad Request**

```json
{"error": ["trigger_threshold must be 1-10000"]}
```

---

## DELETE /data/old

Delete rows older than N days from all CSV files. Rows with unparseable timestamps
are kept.

**Query parameters**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `days` | integer | 30 | Delete rows with `timestamp` older than this many days |

**Example**

```
DELETE /data/old?days=90
```

**Response — 200 OK**

```json
{
  "deleted_rows": 142,
  "files_processed": 7
}
```

**Response — 400 Bad Request**

```json
{"error": "days must be an integer"}
```

---

## GET /metrics

Prometheus-compatible metrics in text exposition format (version 0.0.4). Not protected
by API key.

**Response**: `200 OK` with `Content-Type: text/plain; version=0.0.4`

```
# HELP ancientvision_samples_total Total samples collected
# TYPE ancientvision_samples_total counter
ancientvision_samples_total 5230

# HELP ancientvision_devices_active Number of unique devices
# TYPE ancientvision_devices_active gauge
ancientvision_devices_active 2

# HELP ancientvision_rate_limit_hits_total Rate limit rejections
# TYPE ancientvision_rate_limit_hits_total counter
ancientvision_rate_limit_hits_total 0
```

---

## GET /export/stream

Streaming NDJSON export of all collected data. Suitable for large datasets that would
be impractical as a single CSV download.

**Query parameters**

| Parameter | Type | Description |
|-----------|------|-------------|
| `device_id` | string | Optional. If provided, only rows matching this device ID are streamed. |

**Example**

```
GET /export/stream?device_id=av-001
```

**Response**: `200 OK` with `Content-Type: application/x-ndjson`. Each line is a JSON
object representing one sample:

```
{"device_id": "av-001", "timestamp": "2026-03-03T10:15:30.000Z", "rms": "0.045", ...}
{"device_id": "av-001", "timestamp": "2026-03-03T10:15:31.000Z", "rms": "0.048", ...}
```

Lines are streamed as each CSV file is read; the connection remains open until all
files have been processed.
