#!/usr/bin/env python3
"""Simulate specific vibration anomaly patterns and send them to the collect service.

Unlike simulate_field_data.py (which targets /ingest with full labels), this
script posts to POST /collect and generates data whose physical parameters
match real-world anomaly signatures used by the on-device precursor classifier.

Patterns
--------
    soil_creep   Gradually increasing PPV (0.05→0.15), moderate kurtosis,
                 low-frequency energy (2-8 Hz).
    crack        Sudden high-amplitude spike (0.2→0.5 mm/s), very high
                 kurtosis (8-15), high-frequency content (15-40 Hz).
    imminent     Extreme PPV (0.5+), kurtosis > 15, broadband frequency.
    mixed        Random mix of all three patterns — useful for training diversity.

Usage
-----
    python scripts/simulate_anomaly.py
    python scripts/simulate_anomaly.py --count 50 --pattern crack
    python scripts/simulate_anomaly.py --count 200 --pattern mixed --url http://localhost:8765
    python scripts/simulate_anomaly.py --count 10 --pattern imminent --dry-run

Exit code 0 on full success, 1 if any send failed.
"""

import argparse
import json
import math
import random
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Random helpers
# ---------------------------------------------------------------------------

def _rng(lo: float, hi: float) -> float:
    """Uniform float in [lo, hi]."""
    return lo + random.random() * (hi - lo)


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


# ---------------------------------------------------------------------------
# Per-pattern sample generators
# ---------------------------------------------------------------------------

def _soil_creep_sample(
    device_id: str, timestamp: datetime, index: int, total: int
) -> dict:
    """
    Gradually increasing PPV over the sequence (0.05 → 0.15 mm/s).
    Kurtosis 3-5, dominant frequency 2-8 Hz — classic slow mass-movement
    signature before a soil avalanche.
    """
    progress = index / max(total - 1, 1)          # 0.0 → 1.0
    ppv_base = 0.05 + progress * (0.15 - 0.05)    # 0.05 → 0.15 mm/s
    freq_base = 8.0 - progress * (8.0 - 2.0)      # 8 Hz → 2 Hz (slowing)

    ppv = _clamp(ppv_base + _rng(-0.01, 0.01), 0.01, 1.0)
    freq = _clamp(freq_base + _rng(-1.0, 1.0), 1.0, 10.0)
    kurtosis = _rng(3.0, 5.0)
    rms = ppv * _rng(0.25, 0.45)
    sta_lta = _rng(1.2, 2.5)
    crest = _rng(2.5, 5.0)
    centroid = _rng(3.0, 10.0)
    arias = rms ** 2 * _rng(0.05, 0.2)
    cav = rms * _rng(0.5, 1.5)

    return {
        "device_id": device_id,
        "timestamp": timestamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ppv": round(ppv, 6),
        "rms": round(rms, 6),
        "freq": round(freq, 3),
        "kurtosis": round(kurtosis, 4),
        "sta_lta": round(sta_lta, 4),
        "crest": round(crest, 4),
        "centroid": round(centroid, 3),
        "arias": round(arias, 8),
        "cav": round(cav, 6),
        "pattern": "soil_creep",
    }


def _crack_sample(device_id: str, timestamp: datetime, index: int, total: int) -> dict:
    """
    Sudden amplitude spike (0.2→0.5 mm/s), high kurtosis (8-15),
    high-frequency content (15-40 Hz) — impulsive crack-propagation signature.
    The spike occurs at a random position in the sequence.
    """
    # Create a burst envelope: amplitude peaks near the middle of the sequence
    progress = index / max(total - 1, 1)
    # Bell-curve-like envelope centred at 0.5
    envelope = math.exp(-8 * (progress - 0.5) ** 2)

    ppv = _clamp(0.2 + envelope * (0.5 - 0.2) + _rng(-0.02, 0.02), 0.05, 2.0)
    freq = _rng(15.0, 40.0)
    kurtosis = _rng(8.0, 15.0)
    rms = ppv * _rng(0.15, 0.3)      # high crest factor → low RMS relative to PPV
    sta_lta = _rng(2.0, 6.0)
    crest = _rng(6.0, 14.0)
    centroid = _rng(15.0, 35.0)
    arias = rms ** 2 * _rng(0.1, 0.5)
    cav = rms * _rng(1.0, 3.0)

    return {
        "device_id": device_id,
        "timestamp": timestamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ppv": round(ppv, 6),
        "rms": round(rms, 6),
        "freq": round(freq, 3),
        "kurtosis": round(kurtosis, 4),
        "sta_lta": round(sta_lta, 4),
        "crest": round(crest, 4),
        "centroid": round(centroid, 3),
        "arias": round(arias, 8),
        "cav": round(cav, 6),
        "pattern": "crack",
    }


def _imminent_sample(device_id: str, timestamp: datetime, index: int, total: int) -> dict:
    """
    Very high PPV (0.5+), kurtosis > 15, multiple frequency components —
    collapse-imminent signature with broadband energy.
    """
    # Amplitude continues to grow throughout the sequence
    progress = index / max(total - 1, 1)
    ppv = _clamp(0.5 + progress * 2.0 + _rng(-0.05, 0.1), 0.4, 10.0)
    # Two dominant frequency bands mixed together
    freq_low = _rng(2.0, 8.0)
    freq_high = _rng(20.0, 50.0)
    freq = freq_low if random.random() < 0.5 else freq_high
    kurtosis = _rng(15.0, 35.0)
    rms = ppv * _rng(0.2, 0.5)
    sta_lta = _rng(5.0, 20.0)
    crest = _rng(10.0, 25.0)
    centroid = _rng(5.0, 30.0)   # broadband → variable centroid
    arias = rms ** 2 * _rng(0.5, 2.0)
    cav = rms * _rng(2.0, 6.0)

    return {
        "device_id": device_id,
        "timestamp": timestamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ppv": round(ppv, 6),
        "rms": round(rms, 6),
        "freq": round(freq, 3),
        "kurtosis": round(kurtosis, 4),
        "sta_lta": round(sta_lta, 4),
        "crest": round(crest, 4),
        "centroid": round(centroid, 3),
        "arias": round(arias, 8),
        "cav": round(cav, 6),
        "pattern": "imminent",
    }


# Pattern dispatch table
_GENERATORS = {
    "soil_creep": _soil_creep_sample,
    "crack":      _crack_sample,
    "imminent":   _imminent_sample,
}

_MIXED_PATTERNS = list(_GENERATORS.keys())


def _generate_sample(
    pattern: str, device_id: str, timestamp: datetime, index: int, total: int
) -> dict:
    """Return one sample dict for the requested pattern (or random if 'mixed')."""
    if pattern == "mixed":
        chosen = random.choice(_MIXED_PATTERNS)
    else:
        chosen = pattern
    return _GENERATORS[chosen](device_id, timestamp, index, total)


# ---------------------------------------------------------------------------
# HTTP sender
# ---------------------------------------------------------------------------

def _post_sample(url: str, sample: dict, timeout: int = 10) -> bool:
    """POST sample JSON to url/collect.  Returns True on 2xx."""
    body = json.dumps(sample).encode("utf-8")
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
        detail = exc.read().decode(errors="replace")
        print(f"\n  HTTP {exc.code}: {detail}", file=sys.stderr)
        return False
    except Exception as exc:
        print(f"\n  Send error: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Progress bar
# ---------------------------------------------------------------------------

BAR_WIDTH = 40


def _progress_bar(current: int, total: int, sent: int, failed: int) -> str:
    """Return a # character progress bar string."""
    filled = int(BAR_WIDTH * current / max(total, 1))
    bar = "#" * filled + "-" * (BAR_WIDTH - filled)
    pct = int(100 * current / max(total, 1))
    return f"\r[{bar}] {pct:3d}%  sent={sent} failed={failed}"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Simulate specific vibration anomaly patterns and POST to collect service."
    )
    p.add_argument(
        "--count",
        type=int,
        default=50,
        metavar="N",
        help="Number of samples to generate and send (default: 50).",
    )
    p.add_argument(
        "--pattern",
        choices=["soil_creep", "crack", "imminent", "mixed"],
        default="mixed",
        help="Anomaly pattern to simulate (default: mixed).",
    )
    p.add_argument(
        "--url",
        default="http://localhost:8765",
        metavar="URL",
        help="Base URL of the collect service (default: http://localhost:8765).",
    )
    p.add_argument(
        "--device-id",
        default="sim-anomaly-001",
        metavar="ID",
        help="Device ID string to embed in each sample (default: sim-anomaly-001).",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print samples instead of sending them.",
    )
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    count     = args.count
    pattern   = args.pattern
    device_id = args.device_id
    collect_url = args.url.rstrip("/") + "/collect"

    t0 = datetime.now(timezone.utc).replace(microsecond=0)

    print(
        f"Simulating {count} samples  pattern={pattern}  "
        f"{'[dry-run] ' if args.dry_run else ''}-> {collect_url}"
    )

    sent = failed = 0

    for i in range(count):
        ts = t0 + timedelta(seconds=i)
        sample = _generate_sample(pattern, device_id, ts, index=i, total=count)

        if args.dry_run:
            print(json.dumps(sample))
            sent += 1
        else:
            ok = _post_sample(collect_url, sample)
            if ok:
                sent += 1
            else:
                failed += 1

        # Update progress bar in place
        print(_progress_bar(i + 1, count, sent, failed), end="", flush=True)

    # Final newline after progress bar
    print()
    print(f"Done: {sent} sent, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
