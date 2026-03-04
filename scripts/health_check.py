#!/usr/bin/env python3
"""Health check — ping all AncientVision services, print status table."""

import sys
import time
import urllib.request
import urllib.error
import socket
import argparse
import os
from pathlib import Path
from datetime import datetime

# Force UTF-8 output on Windows
if sys.platform == "win32":
    try:
        import io
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    except Exception:
        pass


class ServiceCheck:
    """Single service health check."""

    def __init__(self, name: str, url: str = None, file_path: str = None, timeout: float = 5.0):
        self.name = name
        self.url = url
        self.file_path = file_path
        self.timeout = timeout
        self.status = None
        self.latency = None
        self.note = None

    def check(self) -> bool:
        """Check service health. Returns True if healthy, False otherwise."""
        if self.url:
            return self._check_http()
        elif self.file_path:
            return self._check_file()
        return False

    def _check_http(self) -> bool:
        """Check HTTP service."""
        try:
            start = time.time()
            response = urllib.request.urlopen(self.url, timeout=self.timeout)
            self.latency = (time.time() - start) * 1000

            if response.status == 200:
                self.status = "[UP]"
                self.note = f"{self.url.split('://')[-1]} {response.status} OK"
                return True
            else:
                self.status = "[DOWN]"
                self.note = f"HTTP {response.status}"
                return False
        except urllib.error.URLError as e:
            self.status = "[DOWN]"
            self.note = f"Connection refused or timeout"
            return False
        except socket.timeout:
            self.status = "[DOWN]"
            self.note = f"Timeout after {self.timeout}s"
            return False
        except Exception as e:
            self.status = "[DOWN]"
            self.note = str(e)[:40]
            return False

    def _check_file(self) -> bool:
        """Check file/directory existence."""
        path = Path(self.file_path)
        if path.exists():
            self.status = "[PRESENT]"
            if path.is_dir():
                files = list(path.glob("**/*.tflite"))
                self.note = f"{len(files)} .tflite files found"
            else:
                self.note = "File exists"
            return True
        else:
            self.status = "[ABSENT]"
            self.note = "Not found"
            return False


def format_latency(latency: float = None) -> str:
    """Format latency in milliseconds."""
    if latency is None:
        return "-"
    return f"{latency:.0f}ms"


def print_status_table(checks: list) -> None:
    """Print formatted status table."""
    # Header
    print("\n" + "=" * 80)
    print(f"AncientVision Health Check — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 80)
    print(f"{'Service':<20} {'Status':<12} {'Latency':<10} {'Note':<40}")
    print("-" * 80)

    # Rows
    for check in checks:
        status_str = check.status or "? UNKNOWN"
        latency_str = format_latency(check.latency)
        note_str = (check.note or "")[:39]
        print(f"{check.name:<20} {status_str:<12} {latency_str:<10} {note_str:<40}")

    print("=" * 80 + "\n")


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Health check — ping all AncientVision services"
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="Timeout per service (seconds, default 5)"
    )
    args = parser.parse_args()

    # Define services to check
    checks = [
        ServiceCheck("data-collector", url="http://localhost:8765/health", timeout=args.timeout),
        ServiceCheck("prometheus", url="http://localhost:9090/-/healthy", timeout=args.timeout),
        ServiceCheck("grafana", url="http://localhost:3000/api/health", timeout=args.timeout),
        ServiceCheck("nginx", url="http://localhost:80/health", timeout=args.timeout),
        ServiceCheck(".retrain_trigger", file_path="./data/.retrain_trigger"),
        ServiceCheck("ML models", file_path="./app/assets/ml"),
    ]

    # Run checks
    critical_services = ["data-collector", "nginx"]
    all_healthy = True

    for check in checks:
        is_healthy = check.check()
        if check.name in critical_services and not is_healthy:
            all_healthy = False

    # Print results
    print_status_table(checks)

    # Exit status
    if all_healthy:
        print("[OK] All critical services are UP")
        return 0
    else:
        print("[ERROR] Some critical services are DOWN")
        return 1


if __name__ == "__main__":
    sys.exit(main())
