#!/usr/bin/env python3
"""
Check device calibration quality from field CSV data.

Reads CSV files from --data-dir, identifies idle periods (ppv < idle_threshold),
and computes noise floor, bias, and drift per device.

Usage:
    python scripts/device_calibration_check.py --data-dir ./data/field
    python scripts/device_calibration_check.py --data-dir ./data/field \\
        --device-id AV-A4CF12
    python scripts/device_calibration_check.py --data-dir ./data/field \\
        --min-samples 50 --noise-threshold 0.005

Exit codes:
    0 — all devices OK
    1 — one or more devices need recalibration
    2 — usage error / no data found
"""

import argparse
import csv
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULT_NOISE_THRESHOLD = 0.005    # mm/s — noise floor must be below this for OK
DEFAULT_BIAS_THRESHOLD  = 0.005    # mm/s — absolute mean bias must be below this
DEFAULT_DRIFT_THRESHOLD = 0.001    # mm/s per hour — linear drift must be below this
DEFAULT_IDLE_PPV        = 0.01     # mm/s — samples below this are considered idle
DEFAULT_MIN_SAMPLES     = 100      # minimum idle samples required for valid check


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _parse_float(val: str) -> float | None:
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def _parse_timestamp(val: str) -> datetime | None:
    if not val:
        return None
    val = val.strip()
    if val.endswith("Z"):
        val = val[:-1] + "+00:00"
    formats = [
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
    ]
    for fmt in formats:
        try:
            dt = datetime.strptime(val, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


def load_device_data(data_dir: Path, device_id_filter: str | None = None) -> dict[str, list]:
    """
    Load all *.csv files in data_dir and group rows by device_id.

    Returns dict: {device_id: [{"timestamp": datetime, "ppv": float, "rms": float}, ...]}
    """
    device_rows: dict[str, list] = {}

    csv_files = sorted(data_dir.glob("*.csv"))
    if not csv_files:
        return device_rows

    for csv_path in csv_files:
        try:
            with open(csv_path, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    device = row.get("device_id", "").strip()
                    if not device:
                        continue
                    if device_id_filter and device != device_id_filter:
                        continue

                    ts = _parse_timestamp(row.get("timestamp", ""))
                    if ts is None:
                        continue

                    ppv = _parse_float(row.get("ppv", ""))
                    rms = _parse_float(row.get("rms", ""))
                    if ppv is None:
                        continue

                    device_rows.setdefault(device, []).append({
                        "timestamp": ts,
                        "ppv": ppv,
                        "rms": rms if rms is not None else ppv,
                    })
        except Exception:
            continue  # skip unreadable files

    # Sort each device's rows by timestamp
    for dev in device_rows:
        device_rows[dev].sort(key=lambda r: r["timestamp"])

    return device_rows


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------

def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def _std(values: list[float]) -> float:
    if len(values) < 2:
        return 0.0
    m = _mean(values)
    variance = sum((v - m) ** 2 for v in values) / (len(values) - 1)
    return math.sqrt(variance)


def _linear_slope(xs: list[float], ys: list[float]) -> float:
    """Compute least-squares linear regression slope."""
    n = len(xs)
    if n < 2:
        return 0.0
    xm = _mean(xs)
    ym = _mean(ys)
    num = sum((x - xm) * (y - ym) for x, y in zip(xs, ys))
    den = sum((x - xm) ** 2 for x in xs)
    return num / den if den != 0.0 else 0.0


# ---------------------------------------------------------------------------
# Calibration analysis
# ---------------------------------------------------------------------------

def analyze_device(
    device_id: str,
    rows: list[dict],
    idle_ppv_threshold: float,
    noise_threshold: float,
    bias_threshold: float,
    drift_threshold: float,
    min_samples: int,
) -> dict:
    """
    Compute calibration metrics for one device.

    Returns a dict with:
        device_id, idle_count, noise_floor, bias, drift_per_hour, status, issues
    """
    # Filter idle samples
    idle_rows = [r for r in rows if r["ppv"] < idle_ppv_threshold]

    result = {
        "device_id": device_id,
        "total_samples": len(rows),
        "idle_count": len(idle_rows),
        "noise_floor": None,
        "bias": None,
        "drift_per_hour": None,
        "status": "INSUFFICIENT DATA",
        "issues": [],
    }

    if len(idle_rows) < min_samples:
        result["issues"].append(
            f"Only {len(idle_rows)} idle samples (need >= {min_samples})"
        )
        return result

    ppv_values = [r["ppv"] for r in idle_rows]

    # Noise floor = standard deviation of PPV during idle
    noise_floor = _std(ppv_values)
    result["noise_floor"] = noise_floor

    # Bias = mean PPV during idle (should be ~0)
    bias = _mean(ppv_values)
    result["bias"] = bias

    # Drift = linear slope of PPV vs time (in mm/s per hour)
    t0 = idle_rows[0]["timestamp"]
    xs = [(r["timestamp"] - t0).total_seconds() / 3600.0 for r in idle_rows]
    ys = [r["ppv"] for r in idle_rows]
    drift_per_hour = _linear_slope(xs, ys)
    result["drift_per_hour"] = drift_per_hour

    # Determine status
    issues = []
    if noise_floor >= noise_threshold:
        issues.append(f"Noise floor {noise_floor:.4f} >= {noise_threshold:.4f} mm/s")
    if abs(bias) >= bias_threshold:
        issues.append(f"Bias |{bias:.4f}| >= {bias_threshold:.4f} mm/s")
    if abs(drift_per_hour) >= drift_threshold:
        issues.append(f"Drift {drift_per_hour:.5f} mm/s/h >= {drift_threshold:.5f} threshold")

    result["issues"] = issues
    result["status"] = "OK" if not issues else "RECALIBRATE"
    return result


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def _sign(v: float) -> str:
    return f"+{v:.4f}" if v >= 0 else f"{v:.4f}"


def print_table(results: list[dict]) -> None:
    """Print calibration check results as a formatted table."""
    SEP = "-" * 75
    HDR = "-" * 75

    print("")
    print("Device Calibration Check")
    print(HDR)
    print(
        f"{'Device':<18} {'Idle':<6} {'Noise Floor':>12} {'Bias':>10} {'Drift/h':>10}  Status"
    )
    print(SEP)

    for r in results:
        device = r["device_id"]
        idle = r["idle_count"]
        nf   = f"{r['noise_floor']:.4f} mm/s"   if r["noise_floor"]        is not None else "N/A"
        bias = _sign(r["bias"]) + " mm/s"         if r["bias"]               is not None else "N/A"
        drft = f"{r['drift_per_hour']:.5f} mm/s/h" if r["drift_per_hour"]  is not None else "N/A"
        status = r["status"]
        flag = "[OK]" if status == "OK" else ("[!]" if status == "RECALIBRATE" else "[-]")
        print(f"{device:<18} {idle:<6} {nf:>12} {bias:>14} {drft:>15}  {flag} {status}")

    print(SEP)
    print("")

    # Per-device issue details
    any_issues = False
    for r in results:
        if r["issues"]:
            any_issues = True
            print(f"  {r['device_id']}: {'; '.join(r['issues'])}")
    if any_issues:
        print("")


def print_json(results: list[dict]) -> None:
    import json
    serializable = []
    for r in results:
        s = dict(r)
        serializable.append(s)
    print(json.dumps(serializable, indent=2))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check device calibration quality from field CSV data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data/field",
        metavar="DIR",
        help="Directory containing field CSV files (default: ./data/field).",
    )
    parser.add_argument(
        "--device-id",
        default=None,
        metavar="ID",
        help="Only check this device (default: all devices).",
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=DEFAULT_MIN_SAMPLES,
        metavar="N",
        help=f"Minimum idle samples required for a valid check (default: {DEFAULT_MIN_SAMPLES}).",
    )
    parser.add_argument(
        "--noise-threshold",
        type=float,
        default=DEFAULT_NOISE_THRESHOLD,
        metavar="MM_S",
        help=(
            f"Noise floor threshold in mm/s; above this means RECALIBRATE "
            f"(default: {DEFAULT_NOISE_THRESHOLD})."
        ),
    )
    parser.add_argument(
        "--bias-threshold",
        type=float,
        default=DEFAULT_BIAS_THRESHOLD,
        metavar="MM_S",
        help=(
            f"Absolute bias threshold in mm/s (default: {DEFAULT_BIAS_THRESHOLD})."
        ),
    )
    parser.add_argument(
        "--drift-threshold",
        type=float,
        default=DEFAULT_DRIFT_THRESHOLD,
        metavar="MM_S_H",
        help=(
            f"Drift threshold in mm/s per hour (default: {DEFAULT_DRIFT_THRESHOLD})."
        ),
    )
    parser.add_argument(
        "--idle-ppv",
        type=float,
        default=DEFAULT_IDLE_PPV,
        metavar="MM_S",
        help=(
            f"PPV below which a sample is considered idle (default: {DEFAULT_IDLE_PPV})."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="output_json",
        help="Output results as JSON instead of a table.",
    )
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        print(f"ERROR: Data directory not found: {data_dir}", file=sys.stderr)
        sys.exit(2)

    device_data = load_device_data(data_dir, device_id_filter=args.device_id)

    if not device_data:
        if args.device_id:
            print(
                f"ERROR: No data found for device '{args.device_id}' in {data_dir}",
                file=sys.stderr,
            )
        else:
            print(f"ERROR: No device data found in {data_dir}", file=sys.stderr)
        sys.exit(2)

    results = []
    for device_id, rows in sorted(device_data.items()):
        r = analyze_device(
            device_id=device_id,
            rows=rows,
            idle_ppv_threshold=args.idle_ppv,
            noise_threshold=args.noise_threshold,
            bias_threshold=args.bias_threshold,
            drift_threshold=args.drift_threshold,
            min_samples=args.min_samples,
        )
        results.append(r)

    if args.output_json:
        print_json(results)
    else:
        print_table(results)

    # Exit 1 if any device needs recalibration
    needs_recal = any(r["status"] == "RECALIBRATE" for r in results)
    sys.exit(1 if needs_recal else 0)


if __name__ == "__main__":
    main()
