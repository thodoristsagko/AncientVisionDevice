#!/usr/bin/env python3
"""Check health of all AncientVision services and print a status table."""
import sys
import urllib.request
import urllib.error
import json
import time

SERVICES = [
    ("data-collector", "http://localhost:8765/health"),
    ("collector-stats", "http://localhost:8765/stats"),
]

def check(name: str, url: str) -> dict:
    start = time.time()
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            elapsed = int((time.time() - start) * 1000)
            body = resp.read().decode()
            return {"name": name, "status": "OK", "code": resp.status, "ms": elapsed, "body": body[:80]}
    except urllib.error.URLError as e:
        elapsed = int((time.time() - start) * 1000)
        return {"name": name, "status": "FAIL", "code": 0, "ms": elapsed, "body": str(e)[:80]}
    except Exception as e:
        return {"name": name, "status": "ERROR", "code": 0, "ms": 0, "body": str(e)[:80]}

def main():
    print(f"\n{'Service':<25} {'Status':<8} {'Code':<6} {'ms':<6} {'Details'}")
    print("-" * 80)
    all_ok = True
    for name, url in SERVICES:
        r = check(name, url)
        icon = "✓" if r["status"] == "OK" else "✗"
        print(f"  {icon} {r['name']:<23} {r['status']:<8} {r['code']:<6} {r['ms']:<6} {r['body']}")
        if r["status"] != "OK":
            all_ok = False
    print()
    if not all_ok:
        sys.exit(1)

if __name__ == "__main__":
    main()
