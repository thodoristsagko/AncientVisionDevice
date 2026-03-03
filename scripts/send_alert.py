#!/usr/bin/env python3
"""Send alerts via webhook when PPV exceeds a threshold.

Scans one CSV file (--csv) or all CSVs in the default field data directory
for rows where PPV exceeds --threshold.  For each offending row an alert
message is formatted and optionally POSTed to a webhook URL.

Usage
-----
    python scripts/send_alert.py
    python scripts/send_alert.py --csv data/field/session_001.csv
    python scripts/send_alert.py --threshold 0.5
    python scripts/send_alert.py --webhook https://hooks.example.com/alert
    python scripts/send_alert.py --dry-run

Exit codes
----------
    0  No alerts triggered.
    1  One or more alerts were triggered (regardless of send success).
    2  At least one webhook send failed.
"""

import argparse
import csv
import json
import os
import sys
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data", "field")


# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------

def _load_csv(path: str) -> list:
    """Return list of row-dicts from a CSV file.  Silently skips unreadable files."""
    rows = []
    try:
        with open(path, newline="", encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))
    except (OSError, csv.Error) as exc:
        print(f"  Warning: cannot read {path}: {exc}", file=sys.stderr)
    return rows


def _collect_csv_files(csv_path: str | None, data_dir: str) -> list:
    """
    Return a list of (filepath, rows) tuples.

    If csv_path is given, read only that file.  Otherwise scan data_dir for
    every *.csv file.
    """
    if csv_path:
        return [(csv_path, _load_csv(csv_path))]

    result = []
    if not os.path.isdir(data_dir):
        return result
    for fname in sorted(os.listdir(data_dir)):
        if fname.lower().endswith(".csv"):
            fpath = os.path.join(data_dir, fname)
            result.append((fpath, _load_csv(fpath)))
    return result


# ---------------------------------------------------------------------------
# Alert logic
# ---------------------------------------------------------------------------

def _format_message(row: dict) -> str:
    """Build the human-readable alert string for one row."""
    try:
        ppv = float(row.get("ppv") or 0)
    except (ValueError, TypeError):
        ppv = 0.0
    timestamp = row.get("timestamp", "unknown")
    device_id = row.get("device_id", "unknown")
    return f"ALERT: PPV {ppv:.3f} mm/s at {timestamp} from device {device_id}"


def _post_webhook(url: str, payload: dict, timeout: int = 10) -> bool:
    """
    POST JSON payload to url.

    Returns True on HTTP 2xx, False on any error.
    """
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as exc:
        print(f"  Webhook HTTP {exc.code}: {exc.read().decode(errors='replace')}",
              file=sys.stderr)
        return False
    except Exception as exc:
        print(f"  Webhook error: {exc}", file=sys.stderr)
        return False


def _scan_for_alerts(file_rows: list, threshold: float) -> list:
    """
    Return a list of alert dicts for every row whose PPV exceeds threshold.

    Each dict has keys: message, ppv, timestamp, device_id, source_file.
    """
    alerts = []
    for filepath, rows in file_rows:
        for row in rows:
            try:
                ppv = float(row.get("ppv") or 0)
            except (ValueError, TypeError):
                continue
            if ppv > threshold:
                alerts.append({
                    "message": _format_message(row),
                    "ppv": ppv,
                    "timestamp": row.get("timestamp", ""),
                    "device_id": row.get("device_id", ""),
                    "source_file": os.path.basename(filepath),
                })
    return alerts


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Send alerts via webhook when PPV exceeds a threshold."
    )
    p.add_argument(
        "--csv",
        metavar="PATH",
        default=None,
        help="Path to a single CSV file to scan.  Defaults to all CSVs in data/field/.",
    )
    p.add_argument(
        "--threshold",
        type=float,
        default=0.3,
        metavar="FLOAT",
        help="PPV threshold in mm/s above which an alert is triggered (default: 0.3).",
    )
    p.add_argument(
        "--webhook",
        metavar="URL",
        default=None,
        help="Webhook URL to POST alerts to.  Omit to only print alerts.",
    )
    p.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help="Directory to scan for CSV files when --csv is not given.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be sent without actually sending.",
    )
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    file_rows = _collect_csv_files(args.csv, args.data_dir)
    if not file_rows:
        print("No CSV files found to scan.")
        return 0

    alerts = _scan_for_alerts(file_rows, args.threshold)
    n_alerts = len(alerts)

    if n_alerts == 0:
        print(f"0 alerts triggered (threshold={args.threshold} mm/s).")
        return 0

    # --- process alerts -------------------------------------------------------
    n_sent = 0
    n_failed = 0

    for alert in alerts:
        print(alert["message"])

        if args.webhook:
            payload = {
                "text": alert["message"],
                "level": "anomaly",
                "ppv": alert["ppv"],
                "timestamp": alert["timestamp"],
            }
            if args.dry_run:
                print(f"  [dry-run] would POST to {args.webhook}: {json.dumps(payload)}")
                n_sent += 1
            else:
                ok = _post_webhook(args.webhook, payload)
                if ok:
                    n_sent += 1
                else:
                    n_failed += 1
        elif args.dry_run:
            print(f"  [dry-run] no webhook configured — alert printed only")

    print(f"\n{n_alerts} alerts triggered, {n_sent} sent")
    if n_failed > 0:
        print(f"{n_failed} send(s) failed", file=sys.stderr)
        return 2
    return 1  # alerts found, all sends succeeded (or no webhook)


if __name__ == "__main__":
    sys.exit(main())
