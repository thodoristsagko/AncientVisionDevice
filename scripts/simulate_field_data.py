"""
E2E pipeline test utility.

Generates realistic fake vibration samples and POSTs them to the collect
service at POST /ingest.  Useful for end-to-end smoke-tests without needing
a real M5StickC device.

Usage
-----
    python scripts/simulate_field_data.py --count 100 --mode mixed
    python scripts/simulate_field_data.py --host 192.168.1.10 --port 8765 --mode imminent_failure
    python scripts/simulate_field_data.py --count 50 --delay 0.5 --n-devices 3
    python scripts/simulate_field_data.py --scenario scenario.json --burst 20
    python scripts/simulate_field_data.py --seed 42 --count 100           # reproducible run
    python scripts/simulate_field_data.py --burst-count 5 --count 100     # inject 5 spikes
"""
import argparse
import json
import math
import random
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Expose the module-level RNG so callers (and tests) can seed it.
_rng_state = random.Random()

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
    return lo + _rng_state.random() * (hi - lo)


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
        r = _rng_state.random()
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


def _spike_sample(device_id: str, timestamp: datetime) -> dict:
    """
    Single sudden high-PPV spike event (PPV >= 5.0 mm/s).

    Used by --burst-count to inject abrupt transients that should always be
    detected as imminent_failure regardless of the base stream mode.
    """
    s = _base_sample(device_id, timestamp, "imminent_failure")
    s.update({
        "rms":      _rng(0.1,   0.5),
        "ppv":      _rng(5.0,   15.0),   # guaranteed spike: PPV >= 5 mm/s
        "freq":     _rng(1.0,   10.0),
        "crest":    _rng(15.0,  30.0),
        "centroid": _rng(2.0,   10.0),
        "kurtosis": _rng(20.0,  40.0),
        "stalta":   _rng(12.0,  25.0),
        "arias":    _rng(0.05,  1.0),
        "cav":      _rng(0.1,   2.0),
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
    p.add_argument("--device-id", default="sim-001",     help="Device ID string (ignored if --n-devices > 1)")
    p.add_argument(
        "--mode",
        choices=["normal", "soil_creep", "crack_propagation", "imminent_failure", "mixed"],
        default="mixed",
        help="Vibration pattern to simulate (ignored if --scenario is set)",
    )
    p.add_argument(
        "--delay",
        type=float,
        default=0.1,
        help="Delay in seconds between samples (default: 0.1s). Use 0 for back-to-back.",
    )
    p.add_argument(
        "--n-devices",
        type=int,
        default=1,
        help="Number of simultaneous devices to simulate (default: 1)",
    )
    p.add_argument(
        "--burst",
        type=int,
        default=0,
        help="Burst mode: send N samples as fast as possible, then pause. 0 = disabled (default)",
    )
    p.add_argument(
        "--scenario",
        type=str,
        help="YAML/JSON file with scenario events (overrides --mode and --count)",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducible simulation (default: unseeded)",
    )
    p.add_argument(
        "--burst-count",
        type=int,
        default=0,
        dest="burst_count",
        help="Number of sudden high-PPV spike events to inject into the stream (default: 0)",
    )
    return p


def _load_scenario(filepath: str) -> list:
    """Load scenario file (JSON/YAML) and return list of event dicts.

    Expected format:
    {
      "events": [
        {"mode": "normal", "duration": 30, "ppv": 0.05},
        {"mode": "soil_creep", "duration": 15, "ppv": 0.15},
        ...
      ]
    }

    Returns list of (mode, duration_samples, count) tuples.
    """
    path = Path(filepath)
    if not path.exists():
        print(f"Error: scenario file not found: {filepath}", file=sys.stderr)
        sys.exit(1)

    content = path.read_text()

    # Try JSON first
    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        # Try YAML
        try:
            import yaml
            data = yaml.safe_load(content)
        except ImportError:
            print("Error: YAML format requires 'pyyaml' (use JSON for this test)", file=sys.stderr)
            sys.exit(1)

    if "events" not in data:
        print("Error: scenario file must have 'events' key", file=sys.stderr)
        sys.exit(1)

    events = []
    for event in data["events"]:
        mode = event.get("mode", "normal")
        duration = event.get("duration", 10)
        if mode not in LABELS and mode != "mixed":
            print(f"Error: invalid mode '{mode}' in scenario", file=sys.stderr)
            sys.exit(1)
        events.append((mode, duration))

    return events


def _print_progress_bar(current: int, total: int, sent: int, failed: int) -> None:
    """Print an in-place progress bar."""
    if total == 0:
        return
    filled = int(50 * current / total)
    bar = "=" * filled + ">" + " " * (50 - filled - 1) if filled < 50 else "=" * 50
    pct = int(100 * current / total)
    sys.stdout.write(f"\r[{bar}] {current}/{total} ({pct}%)  sent={sent} failed={failed}")
    sys.stdout.flush()


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    # Apply random seed for reproducibility if requested.
    if args.seed is not None:
        _rng_state.seed(args.seed)

    host = args.host
    port = args.port
    delay = args.delay
    n_devices = args.n_devices
    burst = args.burst
    n_burst_count = args.burst_count  # number of spike events to inject
    scenario_file = args.scenario

    # Parse scenario if provided
    if scenario_file:
        events = _load_scenario(scenario_file)
        total_samples = sum(duration for _, duration in events)
        print(f"Loaded scenario with {len(events)} events, {total_samples} total samples")
    else:
        count = args.count
        mode = args.mode
        events = [(mode, count)]
        total_samples = count

    # Pre-compute spike injection indices: spread n_burst_count spikes evenly
    # across the total sample range so they are distributed throughout the
    # stream rather than all clumped at the end.
    spike_indices: set[int] = set()
    if n_burst_count > 0 and total_samples > 0:
        step = max(1, total_samples // (n_burst_count + 1))
        for k in range(1, n_burst_count + 1):
            spike_indices.add(min(k * step, total_samples - 1))

    # Start timestamp: now, UTC, second-precision
    t0 = datetime.now(timezone.utc).replace(microsecond=0)

    sent = 0
    failed = 0
    sample_index = 0
    wall_time_start = time.time()

    # If n_devices > 1, generate multiple device IDs
    if n_devices > 1:
        device_ids = [f"sim-{i:03d}" for i in range(n_devices)]
    else:
        device_ids = [args.device_id]

    burst_send_count = 0  # counter for --burst (rate-limiting), separate from --burst-count

    for mode, duration in events:
        for i in range(duration):
            # Round-robin through devices if multi-device
            dev_idx = (sample_index % len(device_ids)) if n_devices > 1 else 0
            device_id = device_ids[dev_idx]

            ts = t0 + timedelta(seconds=sample_index)

            # Inject a spike at pre-computed positions (--burst-count).
            if sample_index in spike_indices:
                sample = _spike_sample(device_id, ts)
            else:
                sample = generate_sample(device_id, ts, mode, index=i, total=duration)

            ok = send_sample(host, port, sample)
            if ok:
                sent += 1
            else:
                failed += 1

            sample_index += 1
            burst_send_count += 1

            # Update progress bar
            _print_progress_bar(sample_index, total_samples, sent, failed)

            # Burst mode: send N samples fast, then delay
            if burst > 0 and burst_send_count >= burst:
                time.sleep(delay)
                burst_send_count = 0
            elif delay > 0:
                # Normal delay between samples
                time.sleep(delay)

    # Final summary
    wall_time_elapsed = time.time() - wall_time_start
    print()
    print()
    print("=" * 70)
    print(f"Summary:")
    print(f"  Total sent:      {sent}")
    print(f"  Total failed:    {failed}")
    print(f"  Total samples:   {total_samples}")
    if n_devices > 1:
        print(f"  Devices:         {n_devices}")
    if n_burst_count > 0:
        print(f"  Spike events:    {n_burst_count}")
    print(f"  Wall time:       {wall_time_elapsed:.1f}s")
    print(f"  Avg rate:        {total_samples / wall_time_elapsed:.1f} samples/sec")
    if scenario_file:
        print(f"  Scenario:        {scenario_file}")
    print("=" * 70)

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
