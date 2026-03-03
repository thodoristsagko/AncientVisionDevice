#!/usr/bin/env python3
"""Check health of all AncientVision services and print a coloured status table.

Usage:
    python scripts/health_check.py
    python scripts/health_check.py --timeout 10
    python scripts/health_check.py --url http://myhost:8765

Exit code:
    0  — all checked services are healthy
    1  — one or more services are unhealthy or returned an error
"""

import sys
import argparse
import urllib.request
import urllib.error
import json
import time

# ---------------------------------------------------------------------------
# ANSI colour helpers (no external dependencies)
# ---------------------------------------------------------------------------

_RESET  = "\033[0m"
_GREEN  = "\033[32m"
_YELLOW = "\033[33m"
_RED    = "\033[31m"
_BOLD   = "\033[1m"
_DIM    = "\033[2m"

def _green(s: str)  -> str: return f"{_GREEN}{s}{_RESET}"
def _yellow(s: str) -> str: return f"{_YELLOW}{s}{_RESET}"
def _red(s: str)    -> str: return f"{_RED}{s}{_RESET}"
def _bold(s: str)   -> str: return f"{_BOLD}{s}{_RESET}"
def _dim(s: str)    -> str: return f"{_DIM}{s}{_RESET}"

# ---------------------------------------------------------------------------
# Service definitions
# Each entry: (display_name, url_template, detail_extractor_fn)
# url_template uses {base} as the collector base URL.
# ---------------------------------------------------------------------------

def _collector_detail(body: str) -> str:
    """Extract a human-readable detail string from the collector /health body."""
    try:
        data = json.loads(body)
        samples = data.get("samples_received", data.get("samples", "?"))
        return f"samples={samples}"
    except (json.JSONDecodeError, AttributeError):
        return body[:60].strip() if body else ""


def _stats_detail(body: str) -> str:
    """Extract detail from /stats endpoint."""
    try:
        data = json.loads(body)
        devices = data.get("active_devices", data.get("devices", "?"))
        rate_hits = data.get("rate_limit_hits", "?")
        return f"devices={devices}  rate_limit_hits={rate_hits}"
    except (json.JSONDecodeError, AttributeError):
        return body[:60].strip() if body else ""


SERVICES_TEMPLATE = [
    ("data-collector",  "{base}/health",  _collector_detail),
    ("collector-stats", "{base}/stats",   _stats_detail),
    ("trainer",         None,             None),          # optional: not always running
    ("prometheus",      "http://localhost:9090/-/healthy", lambda b: b.strip()[:40]),
    ("grafana",         "http://localhost:3000/api/health", lambda b: b.strip()[:40]),
]

# ---------------------------------------------------------------------------
# Core check logic
# ---------------------------------------------------------------------------

def check(name: str, url: str | None, timeout: int, detail_fn) -> dict:
    """Perform a single HTTP health check.  Returns a result dict."""
    if url is None:
        return {
            "name":   name,
            "status": "N/A",
            "ms":     None,
            "detail": "not configured",
        }

    start = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            elapsed_ms = int((time.monotonic() - start) * 1000)
            body = resp.read().decode(errors="replace")
            detail = detail_fn(body) if detail_fn else body[:60].strip()
            return {
                "name":   name,
                "status": "OK",
                "ms":     elapsed_ms,
                "detail": detail,
            }
    except urllib.error.HTTPError as e:
        elapsed_ms = int((time.monotonic() - start) * 1000)
        return {
            "name":   name,
            "status": "FAIL",
            "ms":     elapsed_ms,
            "detail": f"HTTP {e.code} {e.reason}",
        }
    except urllib.error.URLError as e:
        elapsed_ms = int((time.monotonic() - start) * 1000)
        reason = str(e.reason) if hasattr(e, "reason") else str(e)
        return {
            "name":   name,
            "status": "FAIL",
            "ms":     elapsed_ms,
            "detail": reason[:80],
        }
    except Exception as e:
        return {
            "name":   name,
            "status": "ERROR",
            "ms":     None,
            "detail": str(e)[:80],
        }

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

_COL_SERVICE = 20
_COL_STATUS  =  8
_COL_LATENCY =  9
_SEPARATOR   = "\u2500" * (_COL_SERVICE + _COL_STATUS + _COL_LATENCY + 2 + 40)


def _status_cell(result: dict) -> str:
    status = result["status"]
    if status == "OK":
        return _green(f"\u2713 OK   ")   # ✓
    if status == "N/A":
        return _yellow(f"? N/A  ")
    return _red(f"\u2717 {status:<5}")   # ✗


def _latency_cell(result: dict) -> str:
    ms = result["ms"]
    if ms is None:
        return _dim("   \u2014   ")       # —
    if ms < 100:
        return _green(f"{ms}ms".ljust(7))
    if ms < 500:
        return _yellow(f"{ms}ms".ljust(7))
    return _red(f"{ms}ms".ljust(7))


def print_table(results: list[dict]) -> None:
    header = (
        f"{'Service':<{_COL_SERVICE}}  "
        f"{'Status':<{_COL_STATUS}}  "
        f"{'Latency':<{_COL_LATENCY}}  "
        f"Detail"
    )
    print()
    print(_bold(header))
    print(_dim(_SEPARATOR))
    for r in results:
        name    = r["name"][:_COL_SERVICE].ljust(_COL_SERVICE)
        status  = _status_cell(r)
        latency = _latency_cell(r)
        detail  = r.get("detail", "")
        print(f"{name}  {status}  {latency}  {detail}")
    print()

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check health of all AncientVision services.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8765",
        metavar="URL",
        help="Base URL of the data-collector service (default: http://localhost:8765)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=5,
        metavar="SECONDS",
        help="Per-service HTTP timeout in seconds (default: 5)",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI colour output",
    )
    return parser.parse_args()


def disable_color() -> None:
    """Replace all colour functions with identity functions."""
    global _green, _yellow, _red, _bold, _dim
    _green  = lambda s: s  # noqa: E731
    _yellow = lambda s: s  # noqa: E731
    _red    = lambda s: s  # noqa: E731
    _bold   = lambda s: s  # noqa: E731
    _dim    = lambda s: s  # noqa: E731


def main() -> None:
    args = parse_args()

    if args.no_color or not sys.stdout.isatty():
        disable_color()

    # Build concrete service list by expanding {base} in URL templates
    services = []
    for name, url_tmpl, detail_fn in SERVICES_TEMPLATE:
        url = url_tmpl.format(base=args.url) if url_tmpl else None
        services.append((name, url, detail_fn))

    # Run all checks
    results = []
    for name, url, detail_fn in services:
        results.append(check(name, url, args.timeout, detail_fn))

    print_table(results)

    # Exit 1 if any non-N/A service is not OK
    any_failure = any(
        r["status"] not in ("OK", "N/A") for r in results
    )
    if any_failure:
        sys.exit(1)


if __name__ == "__main__":
    main()
