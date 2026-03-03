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
from datetime import datetime, timezone
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

# Numeric range validation: field -> (min_inclusive, max_inclusive)
FIELD_RANGES = {
    "ppv":      (0.0, 100.0),
    "freq":     (0.0, 2000.0),
    "rms":      (0.0, 1000.0),
    "crest":    (0.0, 100.0),
    "kurtosis": (-5.0, 50.0),
    "stalta":   (0.0, 100.0),
}


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

    # Rate-limiting state: sliding window, max 10 requests/device_id/second
    _rate_windows: dict[str, list] = {}
    _rate_lock = threading.Lock()

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

    @app.route("/ingest", methods=["POST"])
    def ingest():
        data = request.get_json(silent=True) or {}

        # Check required fields
        missing = [f for f in REQUIRED_FIELDS if f not in data]
        if missing:
            jlog("warning", "ingest_rejected", reason="missing_fields", missing=missing)
            return jsonify({"error": f"missing fields: {missing}"}), 400

        # Rate limiting per device_id
        device_id = data.get("device_id", "")
        now_ts = time.monotonic()
        with _rate_lock:
            window = _rate_windows.get(device_id, [])
            # Keep only timestamps within the last 1 second
            window = [t for t in window if now_ts - t < 1.0]
            if len(window) >= 10:
                _rate_windows[device_id] = window
                jlog("warning", "ingest_rejected", reason="rate_limited", device_id=device_id)
                return jsonify({"error": "rate_limited", "device_id": device_id}), 429
            window.append(now_ts)
            _rate_windows[device_id] = window

        # Numeric range validation
        for field, (lo, hi) in FIELD_RANGES.items():
            if field in data:
                try:
                    val = float(data[field])
                except (TypeError, ValueError):
                    jlog("warning", "ingest_out_of_range", field=field, value=data[field])
                    return jsonify({"error": "out_of_range", "field": field, "value": data[field]}), 400
                if not (lo <= val <= hi):
                    jlog("warning", "ingest_out_of_range", field=field, value=val)
                    return jsonify({"error": "out_of_range", "field": field, "value": val}), 400

        status = _write_sample(data)
        if status == "duplicate":
            jlog("info", "ingest_duplicate", device_id=device_id, timestamp=data.get("timestamp"))
        else:
            jlog("info", "ingest_ok", device_id=device_id, timestamp=data.get("timestamp"),
                 label=data.get("label"))
            _invalidate_stats_cache()

        return jsonify({"status": status})

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

        collection_name = os.environ.get("FIRESTORE_COLLECTION", "vibration_samples")

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
