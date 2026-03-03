#!/usr/bin/env python3
"""
session_playback.py — Replay a session CSV as if live.

Reads a CSV file and replays it in real time by computing inter-sample
delays from timestamp differences and either POSTing each sample to the
data-collector's /collect endpoint or printing it (--dry-run).

Usage:
    python scripts/session_playback.py <csv_file> \
        [--speed 1.0] [--url http://localhost:8765] [--dry-run]

If timestamp parsing fails the script falls back to a 200 ms inter-sample
delay.  Press Ctrl-C to stop playback at any time.
"""

import argparse
import csv
import json
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime


# ── Timestamp parsing ─────────────────────────────────────────────────────────

_TS_FORMATS = (
    "%Y-%m-%dT%H:%M:%S.%f",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S.%f",
    "%Y-%m-%d %H:%M:%S",
)

_FALLBACK_DELAY_S = 0.2  # 200 ms


def _parse_ts(value: str) -> datetime | None:
    for fmt in _TS_FORMATS:
        try:
            return datetime.strptime(value.strip(), fmt)
        except (ValueError, AttributeError):
            pass
    return None


# ── HTTP POST ─────────────────────────────────────────────────────────────────

def _post_sample(url: str, row: dict) -> tuple[bool, int]:
    """
    POST row as JSON to url/collect.
    Returns (success, status_code).
    """
    endpoint = url.rstrip("/") + "/collect"
    payload = json.dumps(row).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return True, resp.status
    except urllib.error.HTTPError as exc:
        return False, exc.code
    except Exception:
        return False, 0


# ── Progress line ─────────────────────────────────────────────────────────────

def _progress_line(row: dict, sent: bool, status: int, dry_run: bool) -> str:
    now = datetime.now().strftime("%H:%M:%S")
    ppv_raw = row.get("ppv", row.get("PPV", "?"))
    try:
        ppv_str = f"{float(ppv_raw):.3f}"
    except (ValueError, TypeError):
        ppv_str = str(ppv_raw)

    if dry_run:
        outcome = "dry-run"
    elif sent:
        outcome = f"sent ({status} OK)"
    else:
        outcome = f"FAILED ({status})"

    return f"[{now}] PPV={ppv_str} → {outcome}"


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Replay a session CSV in real time against the data-collector."
    )
    parser.add_argument("csv_file", help="Path to the session CSV to replay")
    parser.add_argument(
        "--speed",
        type=float,
        default=1.0,
        help="Playback speed multiplier (default: 1.0 = real time; 2.0 = 2× faster)",
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8765",
        help="Base URL of the data-collector service (default: http://localhost:8765)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print samples instead of POSTing them",
    )
    args = parser.parse_args()

    if args.speed <= 0:
        print("ERROR: --speed must be > 0", file=sys.stderr)
        sys.exit(1)

    # Graceful stop on Ctrl-C
    running = [True]

    def _handle_sigint(signum, frame):  # noqa: ANN001
        running[0] = False

    signal.signal(signal.SIGINT, _handle_sigint)

    # Load CSV
    try:
        with open(args.csv_file, newline="", encoding="utf-8") as fh:
            reader = csv.DictReader(fh)
            rows = list(reader)
    except FileNotFoundError:
        print(f"ERROR: file not found: {args.csv_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"ERROR reading CSV: {exc}", file=sys.stderr)
        sys.exit(1)

    if not rows:
        print("CSV file is empty — nothing to replay.")
        return

    print(
        f"Replaying {len(rows)} samples from {args.csv_file} "
        f"at {args.speed}× speed"
        + (" [dry-run]" if args.dry_run else f" → {args.url}"),
        flush=True,
    )

    # Detect timestamp field name
    ts_field: str | None = None
    for candidate in ("timestamp", "Timestamp", "time", "Time", "ts"):
        if candidate in rows[0]:
            ts_field = candidate
            break

    prev_ts: datetime | None = None
    prev_wall: float = time.monotonic()

    for i, row in enumerate(rows):
        if not running[0]:
            print("\nPlayback interrupted.")
            return

        # Compute delay from timestamp diff
        delay_s = _FALLBACK_DELAY_S
        if ts_field:
            cur_ts = _parse_ts(row.get(ts_field, "") or "")
            if cur_ts is not None and prev_ts is not None:
                diff = (cur_ts - prev_ts).total_seconds()
                if 0 < diff < 60:  # sanity: ignore gaps > 1 min
                    delay_s = diff
            prev_ts = cur_ts

        # Sleep to honour original timing (scaled by speed)
        if i > 0:
            target_wall = prev_wall + delay_s / args.speed
            now_wall = time.monotonic()
            sleep_s = target_wall - now_wall
            if sleep_s > 0:
                # Interruptible sleep in 50 ms chunks
                deadline = time.monotonic() + sleep_s
                while running[0] and time.monotonic() < deadline:
                    chunk = min(0.05, deadline - time.monotonic())
                    if chunk > 0:
                        time.sleep(chunk)

        prev_wall = time.monotonic()

        # Send or print
        if args.dry_run:
            line = _progress_line(row, sent=False, status=0, dry_run=True)
            print(line, flush=True)
        else:
            sent, status = _post_sample(args.url, row)
            line = _progress_line(row, sent=sent, status=status, dry_run=False)
            print(line, flush=True)

    print(f"\nPlayback complete — {len(rows)} samples replayed.", flush=True)


if __name__ == "__main__":
    main()
