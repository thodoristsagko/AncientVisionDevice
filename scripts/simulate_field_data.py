"""
E2E pipeline test utility.

Generates realistic fake vibration samples and POSTs them to the collect
service at POST /ingest.  Useful for end-to-end smoke-tests without needing
a real M5StickC device.

Usage
-----
    python scripts/simulate_field_data.py --count 100 --mode mixed
    python scripts/simulate_field_data.py --host 192.168.1.10 --port 8765 --mode imminent_failure
"""
import argparse
import math
import random
import sys
import urllib.error
import urllib.request
import json
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Sample generation
# ---------------------------------------------------------------------------

LABELS = ("normal", "soil_creep", "crack_propagation", "imminent_failure")

# Mixed-mode distribution: (label, cumulative_weight)
_MIXED_WEIGHTS = [
    ("normal",            0.60),
    ("soil_creep",        0.75),
    ("crack_propagation", 0.90),
    ("imminent_failure",  1.00),
]


def _rng(lo: float, hi: float) -> float:
    """Uniform float in [lo, hi]."""
    return lo + random.random() * (hi - lo)


def generate_sample(
    device_id: str,
    timestamp: datetime,
    mode: str,
    index: int = 0,
    total: int = 1,
) -> dict:
    """
    Return one sample dict with all 12 required fields.

    Parameters
    ----------
    device_id : str
    timestamp : datetime  — must be timezone-aware UTC
    mode      : str       — one of LABELS or 'mixed'
    index     : int       — 0-based position in the sequence (used for soil_creep ramp)
    total     : int       — total number of samples in the sequence
    """
    if mode == "mixed":
        r = random.random()
        label = next(lbl for lbl, thresh in _MIXED_WEIGHTS if r < thresh)
    else:
        label = mode

    if label == "normal":
        sample = _normal_sample(device_id, timestamp)
    elif label == "soil_creep":
        sample = _soil_creep_sample(device_id, timestamp, index, total)
    elif label == "crack_propagation":
        sample = _crack_propagation_sample(device_id, timestamp)
    else:  # imminent_failure
        sample = _imminent_failure_sample(device_id, timestamp)

    return sample


# ------------------------------------------------------------------
# Per-label generators
# ------------------------------------------------------------------

def _base_sample(device_id: str, timestamp: datetime, label: str) -> dict:
    """Minimal skeleton — callers fill in the physics fields."""
    return {
        "device_id": device_id,
        "timestamp": timestamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "label": label,
    }


def _normal_sample(device_id: str, timestamp: datetime) -> dict:
    s = _base_sample(device_id, timestamp, "normal")
    s.update({
        "rms":      _rng(0.001, 0.05),
        "ppv":      _rng(0.01,  0.3),
        "freq":     _rng(5.0,   50.0),
        "crest":    _rng(2.0,   6.0),
        "centroid": _rng(10.0,  40.0),
        "kurtosis": _rng(-1.0,  3.0),
        "stalta":   _rng(0.5,   2.0),
        "arias":    _rng(0.0,   0.001),
        "cav":      _rng(0.0,   0.01),
    })
    return s


def _soil_creep_sample(
    device_id: str, timestamp: datetime, index: int, total: int
) -> dict:
    """
    PPV ramps from 0.3 to 1.5 linearly over the sequence.
    Frequency drops from ~40 Hz towards ~10 Hz to model slow creep.
    """
    s = _base_sample(device_id, timestamp, "soil_creep")
    progress = index / max(total - 1, 1)          # 0.0 → 1.0
    ppv_base = 0.3 + progress * (1.5 - 0.3)       # 0.3 → 1.5
    freq_base = 40.0 - progress * (40.0 - 10.0)   # 40 → 10 Hz
    s.update({
        "rms":      _rng(0.01,  0.08),
        "ppv":      ppv_base + _rng(-0.05, 0.05),  # slight jitter around ramp
        "freq":     max(5.0, freq_base + _rng(-3.0, 3.0)),
        "crest":    _rng(3.0,   7.0),
        "centroid": _rng(8.0,   25.0),
        "kurtosis": _rng(1.0,   5.0),
        "stalta":   _rng(1.5,   5.0),
        "arias":    _rng(0.0002, 0.005),
        "cav":      _rng(0.002,  0.02),
    })
    # Clamp ppv so it is always > 0.3 (minimum for soil_creep label)
    s["ppv"] = max(0.31, s["ppv"])
    return s


def _crack_propagation_sample(device_id: str, timestamp: datetime) -> dict:
    """High crest factor and high kurtosis — impulsive cracking signature."""
    s = _base_sample(device_id, timestamp, "crack_propagation")
    s.update({
        "rms":      _rng(0.01,  0.08),
        "ppv":      _rng(0.5,   3.0),
        "freq":     _rng(10.0,  50.0),
        "crest":    _rng(8.0,   18.0),
        "centroid": _rng(15.0,  40.0),
        "kurtosis": _rng(8.0,   14.0),
        "stalta":   _rng(2.0,   8.0),
        "arias":    _rng(0.0005, 0.008),
        "cav":      _rng(0.005,  0.05),
    })
    return s


def _imminent_failure_sample(device_id: str, timestamp: datetime) -> dict:
    """Extreme values across all channels — collapse imminent."""
    s = _base_sample(device_id, timestamp, "imminent_failure")
    s.update({
        "rms":      _rng(0.05,  0.3),
        "ppv":      _rng(2.0,   10.0),
        "freq":     _rng(1.0,   15.0),
        "crest":    _rng(10.0,  25.0),
        "centroid": _rng(3.0,   15.0),
        "kurtosis": _rng(12.0,  30.0),
        "stalta":   _rng(8.0,   20.0),
        "arias":    _rng(0.01,  0.5),
        "cav":      _rng(0.05,  1.0),
    })
    return s


# ---------------------------------------------------------------------------
# HTTP sender
# ---------------------------------------------------------------------------

def send_sample(host: str, port: int, sample: dict) -> bool:
    """
    POST sample as JSON to http://<host>:<port>/ingest.

    Returns True on success (HTTP 200 + status ok/duplicate),
    False on any error (HTTP 4xx/5xx, network error, unexpected body).
    """
    url = f"http://{host}:{port}/ingest"
    body = json.dumps(sample).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            payload = json.loads(resp.read())
            return payload.get("status") in ("ok", "duplicate")
    except urllib.error.HTTPError as exc:
        print(f"  HTTP {exc.code}: {exc.read().decode()}", file=sys.stderr)
        return False
    except Exception as exc:
        print(f"  Error: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Send simulated vibration samples to the collect service."
    )
    p.add_argument("--host",      default="localhost",  help="Collect service hostname")
    p.add_argument("--port",      type=int, default=8765, help="Collect service port")
    p.add_argument("--count",     type=int, default=50,   help="Number of samples to send")
    p.add_argument("--device-id", default="sim-001",     help="Device ID string")
    p.add_argument(
        "--mode",
        choices=["normal", "soil_creep", "crack_propagation", "imminent_failure", "mixed"],
        default="mixed",
        help="Vibration pattern to simulate",
    )
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    host      = args.host
    port      = args.port
    count     = args.count
    device_id = args.device_id
    mode      = args.mode

    # Start timestamp: now, UTC, second-precision
    t0 = datetime.now(timezone.utc).replace(microsecond=0)

    sent   = 0
    failed = 0

    for i in range(count):
        ts = t0 + timedelta(seconds=i)
        sample = generate_sample(device_id, ts, mode, index=i, total=count)
        ok = send_sample(host, port, sample)
        if ok:
            sent += 1
        else:
            failed += 1

        # Progress every 10 samples
        completed = i + 1
        if completed % 10 == 0:
            print(f"Sent {completed}/{count}...")

    print(f"Done: {sent} sent, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
