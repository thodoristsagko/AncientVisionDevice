#!/usr/bin/env python3
"""
Load test for the collector API.

Sends concurrent POST requests to /collect endpoint and measures latency.

Usage:
    python scripts/load_test.py [--url http://localhost:8765] [--n 500] [--concurrency 20] [--dry-run]

Metrics computed:
    - Total time, requests/second
    - p50, p95, p99 latency (milliseconds)
    - Error rate (%)
    - Exit code 1 if p95 > 500ms or error rate > 1%
"""
import argparse
import json
import math
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone, timedelta
from statistics import median, quantiles
from typing import List, Optional, Tuple


# ---------------------------------------------------------------------------
# Request payload generation
# ---------------------------------------------------------------------------


def generate_payload(index: int) -> dict:
    """
    Generate a realistic vibration sample for load testing.
    Varies timestamp and device_id to avoid deduplication.
    """
    ts = datetime.now(timezone.utc) - timedelta(seconds=100 - (index % 100))
    device_id = f"load-test-device-{index % 10}"

    return {
        "device_id": device_id,
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rms": 0.01 + (index % 100) * 0.0001,
        "ppv": 0.05 + (index % 50) * 0.001,
        "freq": 15.0 + (index % 30) * 0.5,
        "crest": 3.0 + (index % 20) * 0.1,
        "centroid": 20.0 + (index % 25) * 0.2,
        "kurtosis": 1.5 + (index % 15) * 0.05,
        "stalta": 1.0 + (index % 10) * 0.05,
        "arias": 0.0001 + (index % 50) * 0.00001,
        "cav": 0.002 + (index % 30) * 0.0001,
        "label": "normal",
    }


# ---------------------------------------------------------------------------
# HTTP request handling
# ---------------------------------------------------------------------------


class RequestResult:
    """Result of a single HTTP request."""

    def __init__(self, latency_ms: float, status_code: Optional[int] = None, error: Optional[str] = None):
        self.latency_ms = latency_ms
        self.status_code = status_code
        self.error = error
        self.success = status_code == 200 and error is None


def send_request(base_url: str, payload: dict) -> RequestResult:
    """Send POST request to /ingest and return timing + status."""
    url = f"{base_url}/ingest" if base_url.rstrip("/") else "http://localhost:8765/ingest"

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    start_time = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()  # Drain response
            latency_ms = (time.monotonic() - start_time) * 1000
            return RequestResult(latency_ms, status_code=resp.status)
    except urllib.error.HTTPError as exc:
        latency_ms = (time.monotonic() - start_time) * 1000
        return RequestResult(latency_ms, status_code=exc.code, error=f"HTTP {exc.code}")
    except urllib.error.URLError as exc:
        latency_ms = (time.monotonic() - start_time) * 1000
        return RequestResult(latency_ms, error=f"URLError: {exc.reason}")
    except Exception as exc:
        latency_ms = (time.monotonic() - start_time) * 1000
        return RequestResult(latency_ms, error=f"Error: {str(exc)}")


# ---------------------------------------------------------------------------
# Load test worker
# ---------------------------------------------------------------------------


def worker_thread(
    base_url: str,
    task_queue: List[int],
    results: List[RequestResult],
    results_lock: threading.Lock,
) -> None:
    """
    Worker thread: pull tasks from queue, send requests, collect results.
    """
    while True:
        index = None
        with results_lock:
            if task_queue:
                index = task_queue.pop(0)

        if index is None:
            break

        payload = generate_payload(index)
        result = send_request(base_url, payload)

        with results_lock:
            results.append(result)


# ---------------------------------------------------------------------------
# Main load test
# ---------------------------------------------------------------------------


def run_load_test(
    base_url: str = "http://localhost:8765",
    n_requests: int = 500,
    concurrency: int = 20,
    dry_run: bool = False,
) -> Tuple[float, float, dict]:
    """
    Run load test.

    Returns
    -------
    total_time : float
        Total elapsed time (seconds)
    req_per_sec : float
        Requests per second
    metrics : dict
        {
            "total_requests": int,
            "successful": int,
            "errors": int,
            "error_rate_pct": float,
            "p50_ms": float,
            "p95_ms": float,
            "p99_ms": float,
            "min_ms": float,
            "max_ms": float,
            "mean_ms": float,
        }
    """
    if dry_run:
        print(f"[DRY RUN] Would send {n_requests} requests with concurrency {concurrency}")
        for i in range(min(5, n_requests)):
            payload = generate_payload(i)
            print(f"  Sample {i}: {json.dumps(payload, indent=2)}")
        return 0.0, 0.0, {}

    print(f"Load test: {n_requests} requests, concurrency {concurrency}")
    print(f"Target: {base_url}/ingest\n")

    # Initialize task queue and results
    task_queue = list(range(n_requests))
    results: List[RequestResult] = []
    results_lock = threading.Lock()

    # Start timer
    start_time = time.monotonic()

    # Spawn worker threads
    threads = []
    for _ in range(concurrency):
        t = threading.Thread(target=worker_thread, args=(base_url, task_queue, results, results_lock))
        t.daemon = True
        t.start()
        threads.append(t)

    # Wait for all threads to complete
    for t in threads:
        t.join()

    total_time = time.monotonic() - start_time

    # Compute metrics
    successful = sum(1 for r in results if r.success)
    errors = len(results) - successful
    error_rate = 100.0 * errors / len(results) if results else 0.0

    latencies = sorted([r.latency_ms for r in results])
    min_latency = min(latencies) if latencies else 0.0
    max_latency = max(latencies) if latencies else 0.0
    mean_latency = sum(latencies) / len(latencies) if latencies else 0.0

    # Percentiles
    if len(latencies) >= 2:
        p50, p95, p99 = quantiles(latencies, n=100)
    else:
        p50 = p95 = p99 = 0.0

    req_per_sec = len(results) / total_time if total_time > 0 else 0.0

    metrics = {
        "total_requests": len(results),
        "successful": successful,
        "errors": errors,
        "error_rate_pct": error_rate,
        "p50_ms": p50,
        "p95_ms": p95,
        "p99_ms": p99,
        "min_ms": min_latency,
        "max_ms": max_latency,
        "mean_ms": mean_latency,
    }

    return total_time, req_per_sec, metrics


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------


def print_results(total_time: float, req_per_sec: float, metrics: dict) -> None:
    """Print results table."""
    if not metrics:
        return

    print("=" * 80)
    print("Load Test Results")
    print("=" * 80)
    print()
    print(f"Total time:        {total_time:.2f}s")
    print(f"Requests/second:   {req_per_sec:.1f}")
    print()
    print("Requests:")
    print(f"  Total:           {metrics['total_requests']}")
    print(f"  Successful:      {metrics['successful']}")
    print(f"  Errors:          {metrics['errors']}")
    print(f"  Error rate:      {metrics['error_rate_pct']:.2f}%")
    print()
    print("Latency (ms):")
    print(f"  Min:             {metrics['min_ms']:.2f}")
    print(f"  p50 (median):    {metrics['p50_ms']:.2f}")
    print(f"  p95:             {metrics['p95_ms']:.2f}")
    print(f"  p99:             {metrics['p99_ms']:.2f}")
    print(f"  Max:             {metrics['max_ms']:.2f}")
    print(f"  Mean:            {metrics['mean_ms']:.2f}")
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Load test for collector API. Measures latency and throughput.",
    )
    p.add_argument(
        "--url",
        default="http://localhost:8765",
        help="Base URL of collector service (default: http://localhost:8765)",
    )
    p.add_argument(
        "--n",
        type=int,
        default=500,
        help="Number of requests to send (default: 500)",
    )
    p.add_argument(
        "--concurrency",
        type=int,
        default=20,
        help="Number of concurrent worker threads (default: 20)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Generate payloads but don't send requests",
    )
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    total_time, req_per_sec, metrics = run_load_test(
        base_url=args.url,
        n_requests=args.n,
        concurrency=args.concurrency,
        dry_run=args.dry_run,
    )

    if args.dry_run:
        return 0

    print_results(total_time, req_per_sec, metrics)

    # Exit code 1 if p95 > 500ms or error rate > 1%
    if metrics["p95_ms"] > 500.0:
        print(f"FAIL: p95 latency {metrics['p95_ms']:.2f}ms exceeds 500ms threshold")
        return 1

    if metrics["error_rate_pct"] > 1.0:
        print(f"FAIL: error rate {metrics['error_rate_pct']:.2f}% exceeds 1% threshold")
        return 1

    print("PASS: All thresholds met")
    return 0


if __name__ == "__main__":
    sys.exit(main())
