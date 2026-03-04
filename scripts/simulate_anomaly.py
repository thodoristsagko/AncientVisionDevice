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
    python scripts/simulate_anomaly.py --count 100 --pattern soil_creep --csv-output data.csv
    python scripts/simulate_anomaly.py --count 50 --pattern imminent --verify

Exit code 0 on full success, 1 if any send failed.
"""

import argparse
import csv
import json
import math
import random
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Model features (17 total)
# ---------------------------------------------------------------------------

FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis", "stalta",
    "arias", "cav", "temp", "psdSlope",
    "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
    "cusum_max", "autoencoder_score",
]

# ---------------------------------------------------------------------------
# Random helpers
# ---------------------------------------------------------------------------

def _rng(lo: float, hi: float) -> float:
    """Uniform float in [lo, hi]."""
    return lo + random.random() * (hi - lo)


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def _add_noise(value: float, noise_floor: float = 0.005) -> float:
    """Add Gaussian background noise proportional to noise floor."""
    noise_amplitude = noise_floor * random.gauss(0, 1)
    return max(0, value + noise_amplitude)


# ---------------------------------------------------------------------------
# Per-pattern sample generators
# ---------------------------------------------------------------------------

def _soil_creep_sample(
    device_id: str, timestamp: datetime, index: int, total: int, noise_floor: float = 0.005
) -> dict:
    """
    Gradually increasing PPV over the sequence (0.05 → 0.15 mm/s).
    Kurtosis 3-5, dominant frequency 2-8 Hz — classic slow mass-movement
    signature before a soil avalanche. All 17 features with trend correlations.
    """
    progress = index / max(total - 1, 1)          # 0.0 → 1.0
    ppv_base = 0.05 + progress * (0.15 - 0.05)    # 0.05 → 0.15 mm/s
    freq_base = 8.0 - progress * (8.0 - 2.0)      # 8 Hz → 2 Hz (slowing)

    # Correlated trend features: soil_creep shows rising trends together
    corr_factor = progress * _rng(0, 0.8)
    ppv_trend = _clamp(0.8 + corr_factor + _rng(-0.05, 0.1), 0.5, 2.0)
    kurtosis_trend = _clamp(0.8 + corr_factor + _rng(-0.05, 0.1), 0.5, 2.0)
    freq_trend = _clamp(1.1 - progress * 0.3 + _rng(-0.1, 0.1), 0.7, 1.5)  # freq dropping
    stalta_trend = _clamp(0.8 + corr_factor * 0.5 + _rng(-0.05, 0.1), 0.5, 1.5)

    ppv = _add_noise(_clamp(ppv_base + _rng(-0.01, 0.01), 0.01, 1.0), noise_floor)
    freq = _add_noise(_clamp(freq_base + _rng(-1.0, 1.0), 1.0, 10.0), noise_floor)
    kurtosis = _add_noise(_rng(3.0, 5.0), noise_floor * 2)
    rms = _add_noise(ppv * _rng(0.25, 0.45), noise_floor)
    sta_lta = _add_noise(_rng(1.2, 2.5), noise_floor)
    crest = _add_noise(_rng(2.5, 5.0), noise_floor)
    centroid = _add_noise(_rng(3.0, 10.0), noise_floor * 2)
    arias = _add_noise(rms ** 2 * _rng(0.05, 0.2), noise_floor)
    cav = _add_noise(rms * _rng(0.5, 1.5), noise_floor)
    temp = _add_noise(_rng(15, 35), noise_floor)
    psd_slope = _add_noise(_rng(-3, -0.5), noise_floor)
    cusum_max = _add_noise(progress * 0.5 + _rng(0, 0.3), noise_floor)
    ae_score = _add_noise(progress * 0.3 + _rng(0, 0.2), noise_floor)

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
        "temp": round(temp, 2),
        "psd_slope": round(psd_slope, 3),
        "ppv_trend": round(ppv_trend, 4),
        "freq_trend": round(freq_trend, 4),
        "kurtosis_trend": round(kurtosis_trend, 4),
        "stalta_trend": round(stalta_trend, 4),
        "cusum_max": round(cusum_max, 4),
        "autoencoder_score": round(ae_score, 4),
        "pattern": "soil_creep",
    }


def _crack_sample(device_id: str, timestamp: datetime, index: int, total: int, noise_floor: float = 0.005) -> dict:
    """
    Sudden amplitude spike (0.2→0.5 mm/s), high kurtosis (8-15),
    high-frequency content (15-40 Hz) — impulsive crack-propagation signature.
    The spike occurs near the middle of the sequence. All 17 features.
    """
    # Create a burst envelope: amplitude peaks near the middle of the sequence
    progress = index / max(total - 1, 1)
    # Bell-curve-like envelope centred at 0.5
    envelope = math.exp(-8 * (progress - 0.5) ** 2)

    ppv = _add_noise(_clamp(0.2 + envelope * (0.5 - 0.2) + _rng(-0.02, 0.02), 0.05, 2.0), noise_floor)
    freq = _add_noise(_rng(15.0, 40.0), noise_floor * 2)
    kurtosis = _add_noise(_rng(8.0, 15.0), noise_floor * 2)
    rms = _add_noise(ppv * _rng(0.15, 0.3), noise_floor)      # high crest factor
    sta_lta = _add_noise(_rng(2.0, 6.0), noise_floor)
    crest = _add_noise(_rng(6.0, 14.0), noise_floor * 2)
    centroid = _add_noise(_rng(15.0, 35.0), noise_floor * 2)
    arias = _add_noise(rms ** 2 * _rng(0.1, 0.5), noise_floor)
    cav = _add_noise(rms * _rng(1.0, 3.0), noise_floor)
    temp = _add_noise(_rng(15, 35), noise_floor)
    psd_slope = _add_noise(_rng(-2, 1), noise_floor)  # flat to rising (high freq dominant)

    # Crack patterns show impulsive burst with some trend elevation
    ppv_trend = _add_noise(_clamp(0.9 + envelope * 0.5, 0.8, 1.5), noise_floor)
    kurtosis_trend = _add_noise(_clamp(0.9 + envelope * 0.8, 0.8, 1.8), noise_floor)
    freq_trend = _add_noise(_clamp(1.0 + _rng(-0.1, 0.1), 0.8, 1.2), noise_floor)
    stalta_trend = _add_noise(_clamp(0.9 + envelope * 0.6, 0.8, 1.6), noise_floor)
    cusum_max = _add_noise(envelope * 0.8 + _rng(0, 0.3), noise_floor)
    ae_score = _add_noise(envelope * 0.5 + _rng(0, 0.2), noise_floor)

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
        "temp": round(temp, 2),
        "psd_slope": round(psd_slope, 3),
        "ppv_trend": round(ppv_trend, 4),
        "freq_trend": round(freq_trend, 4),
        "kurtosis_trend": round(kurtosis_trend, 4),
        "stalta_trend": round(stalta_trend, 4),
        "cusum_max": round(cusum_max, 4),
        "autoencoder_score": round(ae_score, 4),
        "pattern": "crack",
    }


def _imminent_sample(device_id: str, timestamp: datetime, index: int, total: int, noise_floor: float = 0.005) -> dict:
    """
    Very high PPV (0.5+), kurtosis > 15, multiple frequency components —
    collapse-imminent signature with broadband energy. All 17 features.
    """
    # Amplitude continues to grow throughout the sequence
    progress = index / max(total - 1, 1)
    ppv = _add_noise(_clamp(0.5 + progress * 2.0 + _rng(-0.05, 0.1), 0.4, 10.0), noise_floor)
    # Two dominant frequency bands mixed together
    freq_low = _rng(2.0, 8.0)
    freq_high = _rng(20.0, 50.0)
    freq = _add_noise(freq_low if random.random() < 0.5 else freq_high, noise_floor * 2)
    kurtosis = _add_noise(_rng(15.0, 35.0), noise_floor * 3)
    rms = _add_noise(ppv * _rng(0.2, 0.5), noise_floor)
    sta_lta = _add_noise(_rng(5.0, 20.0), noise_floor * 2)
    crest = _add_noise(_rng(10.0, 25.0), noise_floor * 2)
    centroid = _add_noise(_rng(5.0, 30.0), noise_floor * 2)   # broadband
    arias = _add_noise(rms ** 2 * _rng(0.5, 2.0), noise_floor)
    cav = _add_noise(rms * _rng(2.0, 6.0), noise_floor)
    temp = _add_noise(_rng(15, 35), noise_floor)
    psd_slope = _add_noise(_rng(-3, 1), noise_floor * 2)  # broadband → variable slope

    # Imminent failure: all trends rise sharply together
    ppv_trend = _add_noise(_clamp(1.0 + progress * 1.2, 0.8, 2.5), noise_floor)
    kurtosis_trend = _add_noise(_clamp(1.0 + progress * 1.5, 0.8, 2.8), noise_floor)
    freq_trend = _add_noise(_clamp(1.0 + progress * 0.5, 0.8, 1.8), noise_floor)
    stalta_trend = _add_noise(_clamp(1.0 + progress * 1.3, 0.8, 2.6), noise_floor)
    cusum_max = _add_noise(_clamp(progress * 1.5, 0, 1.0), noise_floor)
    ae_score = _add_noise(_clamp(progress * 0.8, 0, 1.0), noise_floor)

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
        "temp": round(temp, 2),
        "psd_slope": round(psd_slope, 3),
        "ppv_trend": round(ppv_trend, 4),
        "freq_trend": round(freq_trend, 4),
        "kurtosis_trend": round(kurtosis_trend, 4),
        "stalta_trend": round(stalta_trend, 4),
        "cusum_max": round(cusum_max, 4),
        "autoencoder_score": round(ae_score, 4),
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
    pattern: str, device_id: str, timestamp: datetime, index: int, total: int, noise_floor: float = 0.005
) -> dict:
    """Return one sample dict for the requested pattern (or random if 'mixed')."""
    if pattern == "mixed":
        chosen = random.choice(_MIXED_PATTERNS)
    else:
        chosen = pattern
    return _GENERATORS[chosen](device_id, timestamp, index, total, noise_floor)


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
    p.add_argument(
        "--csv-output",
        type=str,
        metavar="FILE",
        help="Save simulated time series to CSV file (same format as real field data).",
    )
    p.add_argument(
        "--noise-floor",
        type=float,
        default=0.005,
        metavar="G",
        help="Background noise amplitude (default: 0.005 g).",
    )
    p.add_argument(
        "--verify",
        action="store_true",
        help="After sending, verify responses from collector API.",
    )
    return p


def _save_csv(filepath: str, samples: list) -> None:
    """Save samples to CSV file with all fields."""
    path = Path(filepath)
    path.parent.mkdir(parents=True, exist_ok=True)

    if not samples:
        return

    # Use all keys from first sample
    fieldnames = list(samples[0].keys())

    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(samples)
    print(f"  Saved {len(samples)} samples to {filepath}")


def _verify_sample(url: str, sample: dict) -> bool:
    """POST to collector and verify response OK."""
    body = json.dumps(sample).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            result = json.loads(resp.read())
            return result.get("status") in ("ok", "duplicate")
    except Exception as e:
        print(f"  Verify failed: {e}", file=sys.stderr)
        return False


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    count      = args.count
    pattern    = args.pattern
    device_id  = args.device_id
    noise_floor = args.noise_floor
    collect_url = args.url.rstrip("/") + "/collect"
    csv_output = args.csv_output
    verify     = args.verify

    t0 = datetime.now(timezone.utc).replace(microsecond=0)

    print(
        f"Simulating {count} samples  pattern={pattern}  "
        f"noise={noise_floor:.3f}g  "
        f"{'[dry-run] ' if args.dry_run else ''}-> {collect_url}"
    )

    sent = failed = 0
    samples = []

    for i in range(count):
        ts = t0 + timedelta(seconds=i)
        sample = _generate_sample(pattern, device_id, ts, index=i, total=count, noise_floor=noise_floor)
        samples.append(sample)

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

    # Save CSV if requested
    if csv_output:
        print(f"Saving CSV...")
        _save_csv(csv_output, samples)

    # Verification mode
    if verify and not args.dry_run and sent > 0:
        print(f"Verifying {sent} samples with collector...")
        verify_ok = 0
        for sample in samples[:min(10, sent)]:  # Spot-check first 10
            if _verify_sample(collect_url, sample):
                verify_ok += 1
        print(f"  Verified: {verify_ok}/{min(10, sent)} samples")

    print()
    print(f"Done: {sent} sent, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
