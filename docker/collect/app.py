"""
Data collection Flask API.
Receives vibration JSON from M5StickC (WiFi) and writes to CSV.
Deduplicates by timestamp+device_id (in-memory; survives for the process lifetime).
Firestore background sync runs when GOOGLE_APPLICATION_CREDENTIALS is set.
"""
import csv
import os
import threading
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, request

REQUIRED_FIELDS = [
    "device_id", "timestamp", "rms", "ppv", "freq", "crest",
    "centroid", "kurtosis", "stalta", "arias", "cav", "label"
]

CSV_HEADER = REQUIRED_FIELDS


def create_app():
    app = Flask(__name__)
    data_dir = Path(os.environ.get("DATA_DIR", "/workspace/data"))
    field_dir = data_dir / "field"
    field_dir.mkdir(parents=True, exist_ok=True)

    count_file = field_dir / ".sample_count"
    _count_lock = threading.Lock()
    _seen_keys: set = set()
    _seen_lock = threading.Lock()

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

    @app.route("/health")
    def health():
        return jsonify({"status": "ok", "samples": _read_count()})

    @app.route("/ingest", methods=["POST"])
    def ingest():
        data = request.get_json(silent=True) or {}
        missing = [f for f in REQUIRED_FIELDS if f not in data]
        if missing:
            return jsonify({"error": f"missing fields: {missing}"}), 400
        status = _write_sample(data)
        return jsonify({"status": status})

    def _start_firestore_sync():
        """
        Background thread: polls Firestore every 5 min for phone-uploaded samples.
        Silently skips if GOOGLE_APPLICATION_CREDENTIALS is not set.
        Extra fields from Firestore docs are ignored; 'label' defaults to 'unknown'.
        """
        import time

        creds = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if not creds:
            app.logger.info("Firestore sync disabled (no credentials)")
            return

        def _loop():
            from google.cloud import firestore
            db = firestore.Client()
            while True:
                try:
                    for doc in db.collection("vibration_samples").stream():
                        raw = doc.to_dict()
                        raw.setdefault("label", "unknown")
                        if any(f not in raw for f in REQUIRED_FIELDS):
                            continue
                        sample = {k: raw[k] for k in REQUIRED_FIELDS}
                        _write_sample(sample)
                except Exception as exc:
                    app.logger.warning("Firestore sync error: %s", exc)
                time.sleep(300)

        threading.Thread(target=_loop, daemon=True).start()

    # Lazy-start sync on first request so tests (which never make requests
    # to the real server) are not affected.
    @app.before_request
    def _lazy_sync():
        if not getattr(app, "_sync_started", False):
            app._sync_started = True
            _start_firestore_sync()

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8765)))
