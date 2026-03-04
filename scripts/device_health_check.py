#!/usr/bin/env python3
"""
device_health_check.py — Quick health check for all devices in collected data.

Usage:
    python scripts/device_health_check.py [--data-dir DIR]

Checks per-device: data freshness, sample rate, PPV range, noise floor.
Prints a health table: Device | Last Seen | Sample Rate | Max PPV | Noise | Status
Status: HEALTHY / STALE / NOISY / SILENT
"""

import argparse
import csv
import math
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------

STALE_HOURS = 24          # Mark STALE if last sample is older than this
SILENT_MIN_RATE = 0.1     # samples/s — below this means SILENT
NOISY_PPV_THRESHOLD = 5.0 # mm/s noise floor — above this is NOISY
QUIET_PERCENTILE = 10     # use lowest 10% PPV readings for noise floor
QUIET_PPV_THRESHOLD = 0.01  # mm/s — samples below this are "quiet"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _rms(values: list) -> float:
    """Compute RMS of a sequence of floats."""
    if not values:
        return 0.0
    return math.sqrt(sum(v * v for v in values) / len(values))


def _parse_float(val) -> float | None:
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def _parse_timestamp(val: str) -> datetime | None:
    """Parse ISO 8601 timestamp string; returns UTC-aware datetime or None."""
    if not val:
        return None
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
    ):
        try:
            dt = datetime.strptime(val.strip(), fmt)
            return dt.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_data(data_dir: Path) -> list[dict]:
    """Load all CSV files from data_dir and return a combined list of row dicts."""
    rows = []
    for csv_path in sorted(data_dir.glob("*.csv")):
        try:
            with open(csv_path, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(row)
        except Exception:
            continue
    return rows


# ---------------------------------------------------------------------------
# Per-device analysis
# ---------------------------------------------------------------------------

def analyze_devices(rows: list[dict], now: datetime) -> dict[str, dict]:
    """
    Group rows by device_id and compute per-device health metrics.
    Returns dict of device_id -> health_info dict.
    """
    from collections import defaultdict
    device_rows: dict = defaultdict(list)
    for row in rows:
        dev = row.get("device_id") or "UNKNOWN"
        device_rows[dev].append(row)

    results = {}
    for device, dev_rows in device_rows.items():
        # Collect timestamps and PPV values
        timestamps = []
        ppv_vals = []
        for row in dev_rows:
            ts = _parse_timestamp(row.get("timestamp", ""))
            if ts is not None:
                timestamps.append(ts)
            pv = _parse_float(row.get("ppv"))
            if pv is not None:
                ppv_vals.append(pv)

        # Freshness
        last_seen: datetime | None = max(timestamps) if timestamps else None
        if last_seen is None:
            age_hours = float("inf")
        else:
            age_hours = (now - last_seen).total_seconds() / 3600.0

        # Sample rate: samples / total collection duration
        if len(timestamps) >= 2:
            duration_s = (max(timestamps) - min(timestamps)).total_seconds()
            sample_rate = len(timestamps) / duration_s if duration_s > 0 else 0.0
        elif len(timestamps) == 1:
            sample_rate = 1.0  # single sample, can't compute rate meaningfully
        else:
            sample_rate = 0.0

        # Max PPV
        max_ppv = max(ppv_vals) if ppv_vals else 0.0

        # Noise floor: RMS of lowest 10% PPV readings
        noise_floor = _compute_noise_floor(ppv_vals)

        # Status flags (multiple can apply; report most severe)
        flags = []
        if age_hours > STALE_HOURS:
            flags.append("STALE")
        if sample_rate < SILENT_MIN_RATE and len(dev_rows) > 1:
            flags.append("SILENT")
        if noise_floor > NOISY_PPV_THRESHOLD:
            flags.append("NOISY")

        if flags:
            # Priority: STALE > NOISY > SILENT
            if "STALE" in flags:
                status = "STALE"
            elif "NOISY" in flags:
                status = "NOISY"
            else:
                status = "SILENT"
        else:
            status = "HEALTHY"

        results[device] = {
            "last_seen": last_seen,
            "age_hours": age_hours,
            "sample_rate": sample_rate,
            "max_ppv": max_ppv,
            "noise_floor": noise_floor,
            "n_samples": len(dev_rows),
            "status": status,
        }

    return results


def _compute_noise_floor(ppv_vals: list[float]) -> float:
    """RMS of the lowest 10% PPV readings (noise floor estimate)."""
    if not ppv_vals:
        return 0.0
    # Try quiet samples first (PPV < QUIET_PPV_THRESHOLD)
    quiet = [v for v in ppv_vals if v < QUIET_PPV_THRESHOLD]
    if not quiet:
        # Fallback: lowest 10th percentile
        sorted_vals = sorted(ppv_vals)
        cutoff = max(1, int(len(sorted_vals) * QUIET_PERCENTILE / 100))
        quiet = sorted_vals[:cutoff]
    return _rms(quiet)


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def _format_last_seen(info: dict) -> str:
    last_seen = info["last_seen"]
    if last_seen is None:
        return "N/A"
    return last_seen.strftime("%Y-%m-%d %H:%M")


def print_table(results: dict[str, dict]) -> None:
    """Print ASCII health table sorted by status (non-HEALTHY first)."""
    if not results:
        return

    # Sort: non-HEALTHY first, then alphabetically by device
    def sort_key(item):
        dev, info = item
        order = {"STALE": 0, "NOISY": 1, "SILENT": 2, "HEALTHY": 3}
        return (order.get(info["status"], 4), dev)

    sorted_items = sorted(results.items(), key=sort_key)

    # Column widths
    dev_w = max(16, max(len(str(d)) for d in results) + 2)
    ts_w = 18
    rate_w = 13
    ppv_w = 10
    noise_w = 10
    status_w = 8

    header = (
        f"{'Device':<{dev_w}} "
        f"{'Last Seen':<{ts_w}} "
        f"{'Sample Rate':>{rate_w}} "
        f"{'Max PPV':>{ppv_w}} "
        f"{'Noise':>{noise_w}} "
        f"{'Status':>{status_w}}"
    )
    sep = "-" * len(header)

    print()
    print("Device Health Check")
    print(sep)
    print(header)
    print(sep)

    for dev, info in sorted_items:
        last_seen_str = _format_last_seen(info)
        rate_str = f"{info['sample_rate']:.2f} Hz"
        ppv_str = f"{info['max_ppv']:.4f}"
        noise_str = f"{info['noise_floor']:.4f}"
        status = info["status"]

        print(
            f"{str(dev):<{dev_w}} "
            f"{last_seen_str:<{ts_w}} "
            f"{rate_str:>{rate_w}} "
            f"{ppv_str:>{ppv_w}} "
            f"{noise_str:>{noise_w}} "
            f"{status:>{status_w}}"
        )

    print(sep)
    print()


def print_summary(results: dict[str, dict]) -> None:
    """Print summary line: N devices: X healthy, Y stale, Z noisy, W silent"""
    counts = {"HEALTHY": 0, "STALE": 0, "NOISY": 0, "SILENT": 0}
    for info in results.values():
        counts[info["status"]] = counts.get(info["status"], 0) + 1

    n = len(results)
    print(
        f"{n} device{'s' if n != 1 else ''}: "
        f"{counts['HEALTHY']} healthy, "
        f"{counts['STALE']} stale, "
        f"{counts['NOISY']} noisy, "
        f"{counts['SILENT']} silent"
    )
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Quick health check for all devices in collected data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        help="Directory containing field CSV files (default: ./data/field)",
    )
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)

    if not data_dir.exists():
        print(f"Data directory not found: {data_dir}")
        print("No data to analyze.")
        return 0

    rows = load_data(data_dir)

    if not rows:
        print("No data found.")
        print("0 devices: 0 healthy, 0 stale, 0 noisy, 0 silent")
        return 0

    now = datetime.now(tz=timezone.utc)
    results = analyze_devices(rows, now)

    if not results:
        print("No devices found in data.")
        print("0 devices: 0 healthy, 0 stale, 0 noisy, 0 silent")
        return 0

    print_table(results)
    print_summary(results)

    return 0


if __name__ == "__main__":
    sys.exit(main())
