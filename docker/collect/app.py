"""
Data collection Flask API.
Receives vibration JSON from M5StickC (WiFi) and writes to CSV.
Firestore sync is added in Task 3.
"""
import csv
import os
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

    def _read_count():
        try:
            return int(count_file.read_text().strip())
        except Exception:
            return 0

    def _write_count(n):
        count_file.write_text(str(n))

    @app.route("/health")
    def health():
        return jsonify({"status": "ok", "samples": _read_count()})

    @app.route("/ingest", methods=["POST"])
    def ingest():
        data = request.get_json(silent=True) or {}
        missing = [f for f in REQUIRED_FIELDS if f not in data]
        if missing:
            return jsonify({"error": f"missing fields: {missing}"}), 400

        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        csv_path = field_dir / f"{date_str}.csv"
        write_header = not csv_path.exists()

        with open(csv_path, "a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_HEADER)
            if write_header:
                writer.writeheader()
            writer.writerow({k: data[k] for k in CSV_HEADER})

        _write_count(_read_count() + 1)
        return jsonify({"status": "ok"})

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8765)))
