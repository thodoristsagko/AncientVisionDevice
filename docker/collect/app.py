"""
Data collection Flask API.
Receives vibration JSON from M5StickC (WiFi) and writes to CSV.
Deduplicates by timestamp+device_id (in-memory; survives for the process lifetime).
Firestore background sync runs when GOOGLE_APPLICATION_CREDENTIALS is set.
"""
import csv
import io
import json
import logging
import os
import threading
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

from flask import Flask, Response, jsonify, request

logging.basicConfig(format="%(message)s", level=logging.INFO)


def jlog(level, event, **kwargs):
    msg = json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "event": event, **kwargs})
    getattr(logging, level)(msg)


REQUIRED_FIELDS = [
    "device_id", "timestamp", "rms", "ppv", "freq", "crest",
    "centroid", "kurtosis", "stalta", "arias", "cav", "label"
]

CSV_HEADER = REQUIRED_FIELDS

# Columns required for schema validation (Task 4)
SCHEMA_REQUIRED_COLUMNS = ["device_id", "timestamp", "ppv", "rms", "freq", "kurtosis"]

# Valid label values (Task 1)
VALID_LABELS = {"normal", "anomaly", "precursor", "unknown"}

# Numeric range validation: field -> (min_inclusive, max_inclusive)
FIELD_RANGES = {
    "ppv":      (0.0, 100.0),
    "freq":     (0.0, 2000.0),
    "rms":      (0.0, 1000.0),
    "crest":    (0.0, 100.0),
    "kurtosis": (-5.0, 50.0),
    "stalta":   (0.0, 100.0),
}

# Module-level config dict (Task 2)
_config: dict = {
    "firestore_collection": os.environ.get("FIRESTORE_COLLECTION", "vibration_samples"),
    "trigger_threshold": 100,
    "rate_limit_rps": 10,
    "max_ppv": 100,
}

# Module-level rate-limit hits counter (Task 5)
_rate_limit_hits: int = 0
_rate_limit_hits_lock = threading.Lock()


def create_app():
    app = Flask(__name__)
    data_dir = Path(os.environ.get("DATA_DIR", "/workspace/data"))
    field_dir = data_dir / "field"
    field_dir.mkdir(parents=True, exist_ok=True)

    count_file = field_dir / ".sample_count"
    _count_lock = threading.Lock()
    _csv_lock = threading.Lock()
    _seen_keys: set = set()
    _seen_lock = threading.Lock()

    # Stats cache: {"data": <dict|None>, "ts": <float>}
    _stats_cache: dict = {"data": None, "ts": 0.0}
    _stats_lock = threading.Lock()

    # Rate-limiting state: sliding window, max rate_limit_rps requests/device_id/second
    _rate_windows: dict[str, list] = {}
    _rate_lock = threading.Lock()

    # Task 4: Scan existing CSV files for schema validation
    invalid_files: list = []
    for csv_path in sorted(field_dir.glob("*.csv")):
        try:
            with open(csv_path, newline="") as f:
                reader = csv.DictReader(f)
                fieldnames = reader.fieldnames or []
                missing_cols = [c for c in SCHEMA_REQUIRED_COLUMNS if c not in fieldnames]
                if missing_cols:
                    jlog("warning", "csv_schema_invalid", file=str(csv_path.name),
                         missing_columns=missing_cols)
                    invalid_files.append(csv_path.name)
        except Exception as exc:
            jlog("warning", "csv_schema_read_error", file=str(csv_path.name), error=str(exc))
            invalid_files.append(csv_path.name)

    app.config["invalid_files"] = invalid_files

    def _read_count():
        try:
            return int(count_file.read_text().strip())
        except Exception:
            return 0

    def _write_count(n):
        count_file.write_text(str(n))

    def _write_sample(data: dict) -> str:
        """Write one validated sample dict to CSV. Returns 'ok' or 'duplicate'."""
        key = f"{data['device_id']}|{data['timestamp']}"
        with _seen_lock:
            if key in _seen_keys:
                return "duplicate"
            _seen_keys.add(key)

        with _csv_lock:
            date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            csv_path = field_dir / f"{date_str}.csv"
            write_header = not csv_path.exists()
            with open(csv_path, "a", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=CSV_HEADER)
                if write_header:
                    writer.writeheader()
                writer.writerow({k: data[k] for k in CSV_HEADER})

        with _count_lock:
            _write_count(_read_count() + 1)
        return "ok"

    def _invalidate_stats_cache():
        with _stats_lock:
            _stats_cache["ts"] = 0.0

    def _compute_stats() -> dict:
        """Scan all CSV files in field_dir and return stats dict."""
        total_samples = 0
        samples_today = 0
        devices: set = set()
        classes: dict = {}
        csv_files = sorted(field_dir.glob("*.csv"))
        today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        for csv_path in csv_files:
            is_today = (csv_path.stem == today_str)
            try:
                with open(csv_path, newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        total_samples += 1
                        if is_today:
                            samples_today += 1
                        dev = row.get("device_id", "")
                        if dev:
                            devices.add(dev)
                        lbl = row.get("label", "")
                        if lbl:
                            classes[lbl] = classes.get(lbl, 0) + 1
            except Exception:
                pass

        return {
            "total_samples": total_samples,
            "samples_today": samples_today,
            "devices": sorted(devices),
            "classes": classes,
            "csv_files": len(csv_files),
        }

    @app.route("/health")
    def health():
        return jsonify({"status": "ok", "samples": _read_count()})

    def _check_rate_limit(device_id: str) -> bool:
        """Check and update rate limit for device_id. Returns True if allowed, False if limited."""
        now_ts = time.monotonic()
        rps_limit = _config["rate_limit_rps"]
        with _rate_lock:
            window = _rate_windows.get(device_id, [])
            window = [t for t in window if now_ts - t < 1.0]
            if len(window) >= rps_limit:
                _rate_windows[device_id] = window
                return False
            window.append(now_ts)
            _rate_windows[device_id] = window
        return True

    def _validate_sample(data: dict) -> str | None:
        """Validate a single sample dict. Returns None if valid, or an error string."""
        missing = [f for f in REQUIRED_FIELDS if f not in data]
        if missing:
            return f"missing fields: {missing}"
        for field, (lo, hi) in FIELD_RANGES.items():
            if field in data:
                try:
                    val = float(data[field])
                except (TypeError, ValueError):
                    return f"out_of_range: {field}={data[field]}"
                if not (lo <= val <= hi):
                    return f"out_of_range: {field}={val}"
        return None

    @app.route("/ingest", methods=["POST"])
    def ingest():
        """Batch ingest endpoint for phone session sync.
        Accepts either a single sample or an array of samples.
        """
        # Check request size limit (50 KB max for batches)
        if request.content_length and request.content_length > 51200:
            jlog("warning", "ingest_rejected", reason="payload_too_large",
                 size_bytes=request.content_length)
            return jsonify({"error": "payload too large"}), 413

        body = request.get_json(silent=True)
        if body is None:
            return jsonify({"error": "invalid JSON"}), 400

        # Normalise: wrap single object in a list
        if isinstance(body, dict):
            samples = [body]
        elif isinstance(body, list):
            samples = body
        else:
            return jsonify({"error": "body must be a JSON object or array"}), 400

        if not samples:
            return jsonify({"error": "empty batch"}), 400

        accepted = 0
        rejected = 0
        errors: list[str] = []
        cache_invalidated = False

        for idx, data in enumerate(samples):
            if not isinstance(data, dict):
                rejected += 1
                errors.append(f"[{idx}] not an object")
                continue

            # Validation
            err = _validate_sample(data)
            if err:
                rejected += 1
                errors.append(f"[{idx}] {err}")
                jlog("warning", "ingest_rejected", reason="validation", index=idx, error=err)
                continue

            # Rate limiting per device_id
            device_id = data.get("device_id", "")
            if not _check_rate_limit(device_id):
                rejected += 1
                errors.append(f"[{idx}] rate_limited: {device_id}")
                jlog("warning", "ingest_rejected", reason="rate_limited", device_id=device_id, index=idx)
                global _rate_limit_hits
                with _rate_limit_hits_lock:
                    _rate_limit_hits += 1
                continue

            status = _write_sample(data)
            if status == "duplicate":
                jlog("info", "ingest_duplicate", device_id=device_id,
                     timestamp=data.get("timestamp"))
            else:
                jlog("info", "ingest_ok", device_id=device_id,
                     timestamp=data.get("timestamp"), label=data.get("label"))
                cache_invalidated = True
            accepted += 1

        if cache_invalidated:
            _invalidate_stats_cache()

        response_body = {"accepted": accepted, "rejected": rejected}
        if errors:
            response_body["errors"] = errors

        if accepted == 0:
            return jsonify(response_body), 400
        if rejected > 0:
            return jsonify(response_body), 207
        return jsonify(response_body)

    @app.route("/stats")
    def stats():
        """Return aggregate statistics about collected data. Cached for 10s."""
        now_ts = time.monotonic()
        with _stats_lock:
            if _stats_cache["data"] is not None and (now_ts - _stats_cache["ts"]) < 10.0:
                return jsonify(_stats_cache["data"])

        result = _compute_stats()

        with _stats_lock:
            _stats_cache["data"] = result
            _stats_cache["ts"] = time.monotonic()

        return jsonify(result)

    @app.route("/export")
    def export():
        """Return all collected CSV data as a single CSV download."""
        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        filename = f"field_data_{date_str}.csv"

        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=CSV_HEADER, extrasaction="ignore")
        header_written = False

        for csv_path in sorted(field_dir.glob("*.csv")):
            try:
                with open(csv_path, newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        if not header_written:
                            writer.writeheader()
                            header_written = True
                        writer.writerow(row)
            except Exception:
                pass

        if not header_written:
            # No data yet: write just the header
            writer.writeheader()

        csv_content = buf.getvalue()
        return Response(
            csv_content,
            mimetype="text/csv",
            headers={"Content-Disposition": f'attachment; filename="{filename}"'},
        )

    @app.route("/quality")
    def quality():
        """Return data quality stats: missing fields, out-of-range values, duplicate rate."""
        try:
            csvs = sorted(field_dir.glob("*.csv"))
            total = 0
            missing_fields = 0
            out_of_range = 0
            duplicates = 0
            seen = set()

            QUALITY_REQUIRED_FIELDS = ["device_id", "timestamp", "ppv", "rms", "freq", "kurtosis"]

            for csv_path in csvs:
                try:
                    with open(csv_path, newline="") as f:
                        reader = csv.DictReader(f)
                        for row in reader:
                            total += 1
                            # Check required fields
                            for field in QUALITY_REQUIRED_FIELDS:
                                if not row.get(field):
                                    missing_fields += 1
                                    break
                            # Check ranges
                            try:
                                ppv = float(row.get("ppv", 0) or 0)
                                if ppv < 0 or ppv > 100:
                                    out_of_range += 1
                            except (ValueError, TypeError):
                                out_of_range += 1
                            # Check duplicates by timestamp+device
                            key = (row.get("timestamp", ""), row.get("device_id", ""))
                            if key in seen:
                                duplicates += 1
                            seen.add(key)
                except Exception:
                    pass

            quality_score = 1.0 if total == 0 else max(0.0, 1.0 - (missing_fields + out_of_range + duplicates) / (total * 3))

            return jsonify({
                "total_samples": total,
                "missing_required_fields": missing_fields,
                "out_of_range_values": out_of_range,
                "duplicate_records": duplicates,
                "quality_score": round(quality_score, 3),
                "status": "good" if quality_score > 0.9 else "degraded" if quality_score > 0.7 else "poor"
            })
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/devices")
    def devices():
        """Return sorted list of unique device_ids that have sent data."""
        device_set: set = set()
        for csv_path in field_dir.glob("*.csv"):
            try:
                with open(csv_path, newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        dev = row.get("device_id", "")
                        if dev:
                            device_set.add(dev)
            except Exception:
                pass
        sorted_devices = sorted(device_set)
        return jsonify({"devices": sorted_devices, "count": len(sorted_devices)})

    # --- Per-device summary endpoint ---

    @app.route("/device/<device_id>/summary", methods=["GET"])
    def device_summary(device_id: str):
        """Return per-device statistics summary."""
        # Validate device_id
        if "/" in device_id or "\\" in device_id or len(device_id) > 50:
            return jsonify({"error": "invalid device_id"}), 400

        total_samples = 0
        first_seen: str | None = None
        last_seen: str | None = None
        sessions: set = set()
        class_dist: dict = {}
        peak_ppv = 0.0
        ppv_sum = 0.0
        ppv_count = 0

        for csv_path in sorted(field_dir.glob("*.csv")):
            try:
                with open(csv_path, newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        if row.get("device_id") != device_id:
                            continue
                        total_samples += 1
                        ts_str = row.get("timestamp", "")
                        if ts_str:
                            if first_seen is None or ts_str < first_seen:
                                first_seen = ts_str
                            if last_seen is None or ts_str > last_seen:
                                last_seen = ts_str
                            # Session = date portion of timestamp
                            date_part = ts_str[:10]
                            sessions.add(date_part)
                        lbl = row.get("label", "")
                        if lbl:
                            class_dist[lbl] = class_dist.get(lbl, 0) + 1
                        try:
                            ppv_val = float(row.get("ppv", 0) or 0)
                            if ppv_val > peak_ppv:
                                peak_ppv = ppv_val
                            ppv_sum += ppv_val
                            ppv_count += 1
                        except (ValueError, TypeError):
                            pass
            except Exception as exc:
                jlog("warning", "device_summary_read_error", file=csv_path.name, error=str(exc))

        if total_samples == 0:
            return jsonify({"error": "device not found"}), 404

        mean_ppv = round(ppv_sum / ppv_count, 6) if ppv_count > 0 else 0.0

        jlog("info", "device_summary_ok", device_id=device_id, total_samples=total_samples)
        return jsonify({
            "device_id": device_id,
            "total_samples": total_samples,
            "first_seen": first_seen,
            "last_seen": last_seen,
            "session_count": len(sessions),
            "class_distribution": class_dist,
            "peak_ppv": round(peak_ppv, 6),
            "mean_ppv": mean_ppv,
        })

    # --- Overall summary endpoint ---

    @app.route("/summary", methods=["GET"])
    def summary():
        """Return overall collection summary aggregated across all devices."""
        total_samples = 0
        first_seen: str | None = None
        last_seen: str | None = None
        all_devices: set = set()
        class_dist: dict = {}
        device_counts: dict = {}

        for csv_path in sorted(field_dir.glob("*.csv")):
            try:
                with open(csv_path, newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        total_samples += 1
                        dev = row.get("device_id", "")
                        if dev:
                            all_devices.add(dev)
                            device_counts[dev] = device_counts.get(dev, 0) + 1
                        ts_str = row.get("timestamp", "")
                        if ts_str:
                            if first_seen is None or ts_str < first_seen:
                                first_seen = ts_str
                            if last_seen is None or ts_str > last_seen:
                                last_seen = ts_str
                        lbl = row.get("label", "")
                        if lbl:
                            class_dist[lbl] = class_dist.get(lbl, 0) + 1
            except Exception as exc:
                jlog("warning", "summary_read_error", file=csv_path.name, error=str(exc))

        # Top 3 most active devices
        top_devices = sorted(device_counts.items(), key=lambda x: x[1], reverse=True)[:3]
        top_devices_list = [{"device_id": d, "sample_count": n} for d, n in top_devices]

        # Training readiness
        trigger_threshold = _config["trigger_threshold"]
        ready_for_training = total_samples >= trigger_threshold

        # Last retrain trigger time
        retrain_trigger_path = field_dir.parent / ".retrain_trigger"
        last_retrain_trigger: str | None = None
        if retrain_trigger_path.exists():
            try:
                mtime = retrain_trigger_path.stat().st_mtime
                last_retrain_trigger = datetime.fromtimestamp(
                    mtime, tz=timezone.utc
                ).isoformat()
            except Exception:
                pass

        jlog("info", "summary_ok", total_samples=total_samples,
             total_devices=len(all_devices))
        return jsonify({
            "total_samples": total_samples,
            "total_devices": len(all_devices),
            "first_seen": first_seen,
            "last_seen": last_seen,
            "class_distribution": class_dist,
            "top_devices": top_devices_list,
            "ready_for_training": ready_for_training,
            "trigger_threshold": trigger_threshold,
            "last_retrain_trigger": last_retrain_trigger,
        })

    # --- Task 1: /label endpoint ---

    @app.route("/label", methods=["POST"])
    def label():
        """Update the label for a specific sample identified by timestamp+device_id."""
        body = request.get_json(silent=True) or {}
        timestamp = body.get("timestamp", "")
        device_id = body.get("device_id", "")
        new_label = body.get("label", "")

        if not timestamp or not device_id:
            return jsonify({"error": "missing fields: timestamp, device_id"}), 400

        # Validate label whitelist
        if new_label not in VALID_LABELS:
            return jsonify({"error": f"invalid label: {new_label!r}. Must be one of {sorted(VALID_LABELS)}"}), 400

        # Prevent path traversal injection in device_id and timestamp
        dangerous_chars = ("..", "/", "\\")
        for field_val, field_name in [(device_id, "device_id"), (timestamp, "timestamp")]:
            for dangerous in dangerous_chars:
                if dangerous in field_val:
                    jlog("warning", "label_injection_attempt", field=field_name, value=field_val)
                    return jsonify({"error": f"suspicious characters in {field_name}"}), 400

        total_updated = 0

        with _csv_lock:
            for csv_path in sorted(field_dir.glob("*.csv")):
                try:
                    with open(csv_path, newline="") as f:
                        reader = csv.DictReader(f)
                        fieldnames = reader.fieldnames or []
                        rows = list(reader)

                    # Ensure label column exists
                    if "label" not in fieldnames:
                        fieldnames = list(fieldnames) + ["label"]

                    updated = 0
                    for row in rows:
                        if row.get("timestamp") == timestamp and row.get("device_id") == device_id:
                            row["label"] = new_label
                            updated += 1

                    if updated > 0:
                        with open(csv_path, "w", newline="") as f:
                            writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
                            writer.writeheader()
                            writer.writerows(rows)
                        total_updated += updated
                        jlog("info", "label_updated", device_id=device_id, timestamp=timestamp,
                             label=new_label, rows=updated, file=csv_path.name)
                except Exception as exc:
                    jlog("warning", "label_error", file=str(csv_path.name), error=str(exc))

        if total_updated == 0:
            return jsonify({"error": "no matching row found"}), 404

        _invalidate_stats_cache()
        return jsonify({"status": "ok", "rows_updated": total_updated})

    # --- Task 2: /config endpoint ---

    @app.route("/config", methods=["GET", "POST"])
    def config():
        """GET returns current config. POST updates trigger_threshold and rate_limit_rps."""
        if request.method == "GET":
            return jsonify(dict(_config))

        body = request.get_json(silent=True) or {}
        errors = []

        if "trigger_threshold" in body:
            try:
                val = int(body["trigger_threshold"])
                if not (1 <= val <= 10000):
                    errors.append("trigger_threshold must be 1-10000")
                else:
                    _config["trigger_threshold"] = val
            except (TypeError, ValueError):
                errors.append("trigger_threshold must be an integer")

        if "rate_limit_rps" in body:
            try:
                val = int(body["rate_limit_rps"])
                if not (1 <= val <= 100):
                    errors.append("rate_limit_rps must be 1-100")
                else:
                    _config["rate_limit_rps"] = val
            except (TypeError, ValueError):
                errors.append("rate_limit_rps must be an integer")

        if errors:
            return jsonify({"error": errors}), 400

        jlog("info", "config_updated", **{k: _config[k] for k in ("trigger_threshold", "rate_limit_rps")})
        return jsonify(dict(_config))

    # --- Task 3: /data/old retention endpoint ---

    @app.route("/data/old", methods=["DELETE"])
    def delete_old_data():
        """Delete rows older than ?days=N (default 30) from all CSV files."""
        try:
            days = int(request.args.get("days", 30))
            if days < 0:
                return jsonify({"error": "days must be >= 0"}), 400
        except (TypeError, ValueError):
            return jsonify({"error": "days must be an integer"}), 400

        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        total_deleted = 0
        files_processed = 0

        with _csv_lock:
            for csv_path in sorted(field_dir.glob("*.csv")):
                try:
                    with open(csv_path, newline="") as f:
                        reader = csv.DictReader(f)
                        fieldnames = reader.fieldnames or []
                        rows = list(reader)

                    kept = []
                    deleted = 0
                    for row in rows:
                        ts_str = row.get("timestamp", "")
                        try:
                            # Parse ISO 8601 timestamp; handle with or without timezone
                            ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                            if ts.tzinfo is None:
                                ts = ts.replace(tzinfo=timezone.utc)
                            if ts < cutoff:
                                deleted += 1
                            else:
                                kept.append(row)
                        except (ValueError, AttributeError):
                            # Unparseable timestamp: keep row
                            kept.append(row)

                    if deleted > 0:
                        with open(csv_path, "w", newline="") as f:
                            writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
                            writer.writeheader()
                            writer.writerows(kept)
                        total_deleted += deleted
                        jlog("info", "retention_deleted", file=csv_path.name, deleted=deleted,
                             kept=len(kept), cutoff_days=days)

                    files_processed += 1
                except Exception as exc:
                    jlog("warning", "retention_error", file=str(csv_path.name), error=str(exc))

        if total_deleted > 0:
            _invalidate_stats_cache()

        return jsonify({"deleted_rows": total_deleted, "files_processed": files_processed})

    # --- Task 4: /data/invalid endpoint ---

    @app.route("/data/invalid")
    def data_invalid():
        """Return list of CSV files that failed schema validation on startup."""
        return jsonify({"invalid_files": app.config.get("invalid_files", [])})

    # --- Task 5: /metrics endpoint (Prometheus) ---

    @app.route("/metrics")
    def metrics():
        """Return Prometheus-compatible metrics in exposition format with per-device breakdown."""
        stats_data = _compute_stats()
        total_samples = stats_data["total_samples"]
        devices_active = len(stats_data["devices"])
        class_counts = stats_data.get("classes", {})

        with _rate_limit_hits_lock:
            hits = _rate_limit_hits

        lines = [
            "# HELP ancientvision_samples_total Total samples collected",
            "# TYPE ancientvision_samples_total counter",
            f"ancientvision_samples_total {total_samples}",
            "# HELP ancientvision_devices_active Number of unique devices",
            "# TYPE ancientvision_devices_active gauge",
            f"ancientvision_devices_active {devices_active}",
            "# HELP ancientvision_rate_limit_hits_total Rate limit rejections",
            "# TYPE ancientvision_rate_limit_hits_total counter",
            f"ancientvision_rate_limit_hits_total {hits}",
        ]

        # Per-class sample counts
        lines.append("# HELP ancientvision_samples_by_class Samples per label class")
        lines.append("# TYPE ancientvision_samples_by_class gauge")
        for class_label in sorted(class_counts.keys()):
            count = class_counts[class_label]
            lines.append(f'ancientvision_samples_by_class{{class="{class_label}"}} {count}')

        # Per-device sample counts
        lines.append("# HELP ancientvision_samples_by_device Samples per device_id")
        lines.append("# TYPE ancientvision_samples_by_device gauge")
        device_counts = {}
        for csv_path in sorted(field_dir.glob("*.csv")):
            try:
                with open(csv_path, newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        dev = row.get("device_id", "")
                        if dev:
                            device_counts[dev] = device_counts.get(dev, 0) + 1
            except Exception:
                pass
        for device_id in sorted(device_counts.keys()):
            count = device_counts[device_id]
            lines.append(f'ancientvision_samples_by_device{{device_id="{device_id}"}} {count}')

        lines.append("")
        return Response("\n".join(lines), mimetype="text/plain; version=0.0.4")

    # --- Pagination and Archive endpoints ---

    @app.route("/data")
    def paginated_data():
        """Return paginated collected data with optional filtering.

        Query parameters:
        - page (int, default 1): Page number (1-indexed)
        - per_page (int, default 50): Samples per page
        - device_id (str, optional): Filter by device_id
        - date_from (str, optional): ISO 8601 date (e.g. 2026-03-01)
        - date_to (str, optional): ISO 8601 date (e.g. 2026-03-04)

        Returns: {"data": [...], "total": N, "page": 1, "per_page": 50, "pages": 10}
        """
        try:
            page = int(request.args.get("page", 1))
            per_page = int(request.args.get("per_page", 50))
            device_filter = request.args.get("device_id", "").strip() or None
            date_from_str = request.args.get("date_from", "").strip() or None
            date_to_str = request.args.get("date_to", "").strip() or None

            if page < 1:
                return jsonify({"error": "page must be >= 1"}), 400
            if per_page < 1 or per_page > 1000:
                return jsonify({"error": "per_page must be 1-1000"}), 400
        except (TypeError, ValueError):
            return jsonify({"error": "page and per_page must be integers"}), 400

        # Parse date filters
        date_from = None
        date_to = None
        try:
            if date_from_str:
                # Parse as ISO date (YYYY-MM-DD)
                date_from = datetime.fromisoformat(date_from_str).replace(tzinfo=timezone.utc)
            if date_to_str:
                # Parse as ISO date, add 1 day to include entire day
                date_to = (datetime.fromisoformat(date_to_str) + timedelta(days=1)).replace(tzinfo=timezone.utc)
        except ValueError:
            return jsonify({"error": "date_from and date_to must be ISO 8601 dates (YYYY-MM-DD)"}), 400

        # Collect all matching rows
        all_rows = []
        for csv_path in sorted(field_dir.glob("*.csv")):
            try:
                with open(csv_path, newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        # Device filter
                        if device_filter and row.get("device_id") != device_filter:
                            continue
                        # Date range filter
                        if date_from or date_to:
                            ts_str = row.get("timestamp", "")
                            try:
                                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                                if ts.tzinfo is None:
                                    ts = ts.replace(tzinfo=timezone.utc)
                                if date_from and ts < date_from:
                                    continue
                                if date_to and ts >= date_to:
                                    continue
                            except (ValueError, AttributeError):
                                continue
                        all_rows.append(row)
            except Exception:
                pass

        total = len(all_rows)
        total_pages = (total + per_page - 1) // per_page if total > 0 else 1
        start_idx = (page - 1) * per_page
        end_idx = start_idx + per_page
        page_data = all_rows[start_idx:end_idx]

        return jsonify({
            "data": page_data,
            "total": total,
            "page": page,
            "per_page": per_page,
            "pages": total_pages,
        })

    @app.route("/archive", methods=["POST"])
    def archive_data():
        """Move collected CSV data older than ?days (default 30) to {DATA_DIR}/archive/.

        Query parameters:
        - days (int, default 30): Age threshold in days

        Returns: {"archived_files": N, "archived_samples": N, "freed_bytes": N}
        Requires API_KEY if set.
        """
        try:
            days = int(request.args.get("days", 30))
            if days < 0:
                return jsonify({"error": "days must be >= 0"}), 400
        except (TypeError, ValueError):
            return jsonify({"error": "days must be an integer"}), 400

        archive_dir = data_dir / "archive"
        archive_dir.mkdir(parents=True, exist_ok=True)

        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        archived_files = 0
        archived_samples = 0
        freed_bytes = 0

        with _csv_lock:
            for csv_path in sorted(field_dir.glob("*.csv")):
                # Check file mtime
                try:
                    file_mtime = datetime.fromtimestamp(csv_path.stat().st_mtime, tz=timezone.utc)
                    if file_mtime >= cutoff:
                        # File is recent enough, skip
                        continue
                except Exception:
                    continue

                # Count samples in file
                sample_count = 0
                try:
                    with open(csv_path, newline="") as f:
                        reader = csv.DictReader(f)
                        sample_count = sum(1 for _ in reader)
                except Exception:
                    pass

                # Move file to archive
                try:
                    archive_path = archive_dir / csv_path.name
                    file_size = csv_path.stat().st_size
                    csv_path.rename(archive_path)
                    archived_files += 1
                    archived_samples += sample_count
                    freed_bytes += file_size
                    jlog("info", "archive_moved", file=csv_path.name, samples=sample_count,
                         bytes=file_size, archive=archive_path.name)
                except Exception as exc:
                    jlog("warning", "archive_error", file=csv_path.name, error=str(exc))

        if archived_files > 0:
            _invalidate_stats_cache()

        jlog("info", "archive_complete", files=archived_files, samples=archived_samples, bytes=freed_bytes)
        return jsonify({
            "archived_files": archived_files,
            "archived_samples": archived_samples,
            "freed_bytes": freed_bytes,
        })

    # --- Sessions endpoints ---

    sessions_dir = data_dir / "sessions"
    sessions_dir.mkdir(parents=True, exist_ok=True)

    SESSION_REQUIRED_FIELDS = ["device_id", "start_time", "end_time"]
    SESSION_CSV_HEADER = [
        "session_id", "device_id", "start_time", "end_time",
        "duration_min", "peak_ppv", "sample_count", "anomaly_events",
    ]

    @app.route("/sessions", methods=["POST"])
    def ingest_session():
        """Accept a session summary from the phone app."""
        body = request.get_json(silent=True) or {}

        missing = [f for f in SESSION_REQUIRED_FIELDS if f not in body]
        if missing:
            jlog("warning", "session_rejected", reason="missing_fields", missing=missing)
            return jsonify({"error": f"missing fields: {missing}"}), 400

        device_id = body["device_id"]
        now_ts = datetime.now(timezone.utc)
        timestamp_str = now_ts.strftime("%Y%m%dT%H%M%S%f")
        session_id = f"session_{device_id}_{timestamp_str}"
        filename = f"{session_id}.json"

        session_data = {
            "session_id": session_id,
            "device_id": device_id,
            "start_time": body["start_time"],
            "end_time": body["end_time"],
            "peak_ppv": body.get("peak_ppv"),
            "sample_count": body.get("sample_count"),
            "anomaly_events": body.get("anomaly_events"),
            "session_export": body.get("session_export"),
            "received_at": now_ts.isoformat(),
        }

        session_path = sessions_dir / filename
        try:
            session_path.write_text(json.dumps(session_data, indent=2))
        except Exception as exc:
            jlog("warning", "session_write_error", session_id=session_id, error=str(exc))
            return jsonify({"error": "failed to store session"}), 500

        jlog("info", "session_ingested", session_id=session_id, device_id=device_id)
        return jsonify({"status": "ok", "session_id": session_id})

    @app.route("/sessions", methods=["GET"])
    def list_sessions():
        """Return list of session summaries (one per JSON file in sessions/ directory)."""
        summaries = []
        for session_path in sorted(sessions_dir.glob("session_*.json")):
            try:
                raw = json.loads(session_path.read_text())
                # Return summary without the (potentially large) session_export
                summaries.append({k: raw.get(k) for k in [
                    "session_id", "device_id", "start_time", "end_time",
                    "peak_ppv", "sample_count", "anomaly_events", "received_at",
                ]})
            except Exception as exc:
                jlog("warning", "session_read_error", file=session_path.name, error=str(exc))

        return jsonify({"sessions": summaries, "count": len(summaries)})

    @app.route("/sessions/<session_id>", methods=["GET"])
    def get_session(session_id):
        """Return the full session JSON for a specific session."""
        # Prevent path traversal
        if ".." in session_id or "/" in session_id or "\\" in session_id:
            return jsonify({"error": "invalid session_id"}), 400

        session_path = sessions_dir / f"{session_id}.json"
        if not session_path.exists():
            return jsonify({"error": "session not found"}), 404

        try:
            data = json.loads(session_path.read_text())
        except Exception as exc:
            jlog("warning", "session_read_error", file=session_path.name, error=str(exc))
            return jsonify({"error": "failed to read session"}), 500

        return jsonify(data)

    @app.route("/sessions/export", methods=["GET"])
    def export_sessions():
        """Return all sessions as a CSV download."""
        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        filename = f"sessions_{date_str}.csv"

        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=SESSION_CSV_HEADER, extrasaction="ignore")
        header_written = False

        for session_path in sorted(sessions_dir.glob("session_*.json")):
            try:
                raw = json.loads(session_path.read_text())

                # Compute duration_min from start_time and end_time
                duration_min = None
                try:
                    start = datetime.fromisoformat(raw["start_time"].replace("Z", "+00:00"))
                    end = datetime.fromisoformat(raw["end_time"].replace("Z", "+00:00"))
                    duration_min = round((end - start).total_seconds() / 60.0, 3)
                except Exception:
                    pass

                row = {
                    "session_id": raw.get("session_id", ""),
                    "device_id": raw.get("device_id", ""),
                    "start_time": raw.get("start_time", ""),
                    "end_time": raw.get("end_time", ""),
                    "duration_min": duration_min,
                    "peak_ppv": raw.get("peak_ppv", ""),
                    "sample_count": raw.get("sample_count", ""),
                    "anomaly_events": raw.get("anomaly_events", ""),
                }

                if not header_written:
                    writer.writeheader()
                    header_written = True
                writer.writerow(row)

            except Exception as exc:
                jlog("warning", "session_export_error", file=session_path.name, error=str(exc))

        if not header_written:
            writer.writeheader()

        csv_content = buf.getvalue()
        return Response(
            csv_content,
            mimetype="text/csv",
            headers={"Content-Disposition": f'attachment; filename="{filename}"'},
        )

    # --- Task 7: /export/stream endpoint (NDJSON) ---

    @app.route("/export/stream")
    def export_stream():
        """Stream all collected data as NDJSON. Supports optional ?device_id=X filter."""
        device_filter = request.args.get("device_id", "").strip() or None

        def generate():
            for csv_path in sorted(field_dir.glob("*.csv")):
                try:
                    with open(csv_path, newline="") as f:
                        reader = csv.DictReader(f)
                        for row in reader:
                            if device_filter and row.get("device_id") != device_filter:
                                continue
                            yield json.dumps(row) + "\n"
                except Exception as exc:
                    jlog("warning", "export_stream_error", file=str(csv_path.name), error=str(exc))

        return Response(generate(), mimetype="application/x-ndjson")

    # --- Task 6: CORS headers and security headers ---

    @app.after_request
    def _add_cors_and_security_headers(response):
        """Add CORS and security headers to all responses."""
        cors_origin = os.environ.get("CORS_ORIGIN", "*")
        response.headers["Access-Control-Allow-Origin"] = cors_origin
        response.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        return response

    @app.before_request
    def _api_key_auth():
        """Enforce API key if API_KEY env var is set. Exempt: /health, /metrics."""
        api_key = os.environ.get("API_KEY", "").strip()
        if not api_key:
            # Dev mode: authentication disabled
            return None
        exempt = {"/health", "/metrics"}
        if request.path in exempt:
            return None
        provided = request.headers.get("X-API-Key", "")
        if provided != api_key:
            jlog("warning", "auth_rejected", path=request.path,
                 remote=request.remote_addr)
            return jsonify({"error": "unauthorized"}), 401
        return None

    def _start_firestore_sync():
        """
        Background thread: polls Firestore every 5 min for phone-uploaded samples.
        Silently skips if GOOGLE_APPLICATION_CREDENTIALS is not set.
        Extra fields from Firestore docs are ignored; 'label' defaults to 'unknown'.
        """
        creds = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if not creds:
            jlog("info", "startup", firestore_sync="disabled", reason="no_credentials")
            return

        collection_name = _config["firestore_collection"]

        def _loop():
            from google.cloud import firestore
            db = firestore.Client()
            while True:
                try:
                    for doc in db.collection(collection_name).stream():
                        raw = doc.to_dict()
                        raw.setdefault("label", "unknown")
                        if any(f not in raw for f in REQUIRED_FIELDS):
                            continue
                        sample = {k: raw[k] for k in REQUIRED_FIELDS}
                        _write_sample(sample)
                except Exception as exc:
                    jlog("warning", "firestore_sync_error", error=str(exc))
                time.sleep(300)

        threading.Thread(target=_loop, daemon=True).start()

    # Lazy-start sync on first request so tests (which never make requests
    # to the real server) are not affected.
    @app.before_request
    def _lazy_sync():
        if not getattr(app, "_sync_started", False):
            app._sync_started = True
            jlog("info", "startup", data_dir=str(data_dir))
            _start_firestore_sync()

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8765)))
