#!/usr/bin/env python3
"""
data_quality_dashboard.py — Terminal data quality report for AncientVision.

Displays a live-updating dashboard summarising sample counts, per-device
statistics, recent PPV readings and alert counts sourced from CSV files in
a data directory.

Usage:
    python scripts/data_quality_dashboard.py \
        [--data-dir ./data/field] [--refresh 5]

In --refresh 0 mode the dashboard is printed once then the script exits.
Only stdlib is used.
"""

import argparse
import csv
import os
import signal
import sys
import time
from collections import defaultdict
from datetime import datetime, timedelta


# ── ANSI helpers ─────────────────────────────────────────────────────────────

CLEAR = "\033[2J\033[H"  # clear screen + move cursor to top-left


def _clear_screen() -> None:
    sys.stdout.write(CLEAR)
    sys.stdout.flush()


# ── Data loading ──────────────────────────────────────────────────────────────

def _load_data(data_dir: str) -> list[dict]:
    """
    Return a list of row dicts from all CSV files found directly inside
    data_dir.  Each row is expected (optionally) to have fields:
        device_id, timestamp, ppv, label
    Missing fields are tolerated — they default to empty string / 0.
    """
    rows: list[dict] = []
    if not os.path.isdir(data_dir):
        return rows
    for fname in sorted(os.listdir(data_dir)):
        if not fname.endswith(".csv"):
            continue
        fpath = os.path.join(data_dir, fname)
        try:
            with open(fpath, newline="", encoding="utf-8") as fh:
                reader = csv.DictReader(fh)
                for row in reader:
                    rows.append(row)
        except Exception:
            pass  # silently skip unreadable files
    return rows


# ── Statistics ────────────────────────────────────────────────────────────────

def _parse_float(value: str, default: float = 0.0) -> float:
    try:
        return float(value)
    except (ValueError, TypeError):
        return default


def _parse_timestamp(value: str) -> datetime | None:
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f"):
        try:
            return datetime.strptime(value.strip(), fmt)
        except (ValueError, AttributeError):
            pass
    return None


def _compute_stats(rows: list[dict]) -> dict:
    """
    Compute aggregate and per-device statistics from the raw row list.

    Returns a dict with keys:
        total, quality_pct, devices (dict by device_id),
        recent_anomalies (count in last hour)
    """
    total = len(rows)

    # Per-device buckets
    device_samples: dict[str, int] = defaultdict(int)
    device_last_ppv: dict[str, float] = defaultdict(float)
    device_last_ts: dict[str, datetime | None] = {}
    device_anomaly_count: dict[str, int] = defaultdict(int)

    anomaly_cutoff = datetime.now() - timedelta(hours=1)
    recent_anomalies = 0
    valid_samples = 0

    for row in rows:
        device_id = row.get("device_id", "unknown") or "unknown"
        device_samples[device_id] += 1

        ppv = _parse_float(row.get("ppv", "0") or "0")
        device_last_ppv[device_id] = ppv  # last row wins (files are sorted by name)

        ts = _parse_timestamp(row.get("timestamp", "") or "")
        if ts is not None:
            prev = device_last_ts.get(device_id)
            if prev is None or ts > prev:
                device_last_ts[device_id] = ts
            valid_samples += 1

            label = (row.get("label", "") or "").lower()
            if "anomal" in label or label in ("1", "true", "alert"):
                device_anomaly_count[device_id] += 1
                if ts >= anomaly_cutoff:
                    recent_anomalies += 1

    # Quality = fraction of rows that have a parseable timestamp
    quality_pct = (valid_samples / total * 100.0) if total > 0 else 0.0

    devices: dict[str, dict] = {}
    for dev in sorted(device_samples.keys()):
        last_ppv = device_last_ppv[dev]
        if last_ppv > 0.5:
            status = "HIGH PPV"
        elif last_ppv > 0.1:
            status = "ELEVATED"
        else:
            status = "OK"
        devices[dev] = {
            "samples": device_samples[dev],
            "last_ppv": last_ppv,
            "status": status,
        }

    return {
        "total": total,
        "quality_pct": quality_pct,
        "devices": devices,
        "recent_anomalies": recent_anomalies,
    }


# ── Rendering ─────────────────────────────────────────────────────────────────

_W = 62  # inner width of the box (between the side borders)


def _hline_top() -> str:
    return "╔" + "═" * _W + "╗"


def _hline_sep() -> str:
    return "╠" + "═" * _W + "╣"


def _hline_bot() -> str:
    return "╚" + "═" * _W + "╝"


def _row(text: str) -> str:
    return "║" + text.ljust(_W) + "║"


def _centre(text: str) -> str:
    return "║" + text.center(_W) + "║"


def _render(stats: dict, data_dir: str) -> str:
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    total = stats["total"]
    devices = stats["devices"]
    num_devices = len(devices)
    quality = stats["quality_pct"]
    recent_anomalies = stats["recent_anomalies"]

    lines: list[str] = []
    lines.append(_hline_top())
    lines.append(_centre("AncientVision Data Quality Dashboard"))
    lines.append(_centre(f"Updated: {now_str}"))

    # Summary row
    lines.append(_hline_sep())
    summary = (
        f" Total samples: {total:<6} │ Devices: {num_devices:<4} │"
        f" Quality: {quality:.1f}%"
    )
    lines.append(_row(summary))

    # Device table header
    col_dev = 14
    col_smp = 13
    col_ppv = 12
    col_sta = 15

    lines.append(
        "╠"
        + "═" * col_dev
        + "╦"
        + "═" * col_smp
        + "╦"
        + "═" * col_ppv
        + "╦"
        + "═" * col_sta
        + "╣"
    )
    header = (
        " Device".ljust(col_dev)
        + "║"
        + " Samples".ljust(col_smp)
        + "║"
        + " Last PPV".ljust(col_ppv)
        + "║"
        + " Status".ljust(col_sta)
    )
    lines.append("║" + header + "║")
    lines.append(
        "╠"
        + "═" * col_dev
        + "╬"
        + "═" * col_smp
        + "╬"
        + "═" * col_ppv
        + "╬"
        + "═" * col_sta
        + "╣"
    )

    if devices:
        for dev_id, info in devices.items():
            status_str = info["status"]
            if status_str == "OK":
                status_display = "✓ OK"
            elif status_str == "ELEVATED":
                status_display = "~ ELEVATED"
            else:
                status_display = "⚠ HIGH PPV"

            drow = (
                f" {dev_id}"[:col_dev].ljust(col_dev)
                + "║"
                + f" {info['samples']}"[:col_smp].ljust(col_smp)
                + "║"
                + f" {info['last_ppv']:.3f}"[:col_ppv].ljust(col_ppv)
                + "║"
                + f" {status_display}"[:col_sta].ljust(col_sta)
            )
            lines.append("║" + drow + "║")
    else:
        lines.append(_row(f"  (no CSV data found in {data_dir})"))

    lines.append(
        "╚"
        + "═" * col_dev
        + "╩"
        + "═" * col_smp
        + "╩"
        + "═" * col_ppv
        + "╩"
        + "═" * col_sta
        + "╝"
    )

    # Alerts footer
    alert_word = "anomaly" if recent_anomalies == 1 else "anomalies"
    lines.append("")
    lines.append(f"Recent alerts: {recent_anomalies} {alert_word} in last hour")

    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="AncientVision terminal data quality dashboard."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        help="Directory containing collected CSV sample files (default: ./data/field)",
    )
    parser.add_argument(
        "--refresh",
        type=int,
        default=5,
        help="Refresh interval in seconds; 0 = print once and exit (default: 5)",
    )
    args = parser.parse_args()

    data_dir = os.path.abspath(args.data_dir)

    # Graceful SIGINT
    running = [True]

    def _handle_sigint(signum, frame):  # noqa: ANN001
        running[0] = False

    signal.signal(signal.SIGINT, _handle_sigint)

    def _render_once() -> None:
        rows = _load_data(data_dir)
        stats = _compute_stats(rows)
        output = _render(stats, data_dir)
        if args.refresh != 0:
            _clear_screen()
        print(output, flush=True)

    if args.refresh == 0:
        _render_once()
        return

    try:
        while running[0]:
            _render_once()
            # Sleep in 1-second increments for responsive SIGINT
            for _ in range(args.refresh):
                if not running[0]:
                    break
                time.sleep(1)
    except KeyboardInterrupt:
        pass

    print("\nDashboard stopped.", flush=True)


if __name__ == "__main__":
    main()
