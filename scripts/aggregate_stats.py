#!/usr/bin/env python3
"""Aggregate field data statistics by hour and day.

Usage:
    python scripts/aggregate_stats.py
    python scripts/aggregate_stats.py --data-dir ./data/field --period daily
"""
import argparse, csv, os, sys
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

def load_field_data(data_dir):
    rows = []
    for f in sorted(os.listdir(data_dir)):
        if f.endswith(".csv"):
            try:
                with open(os.path.join(data_dir, f), newline="") as fh:
                    rows.extend(list(csv.DictReader(fh)))
            except Exception:
                pass
    return rows

def get_period_key(timestamp, period):
    """Extract period key from ISO timestamp string."""
    ts = str(timestamp or "")
    if len(ts) >= 16:
        if period == "hourly":
            return ts[:13] + ":00"  # YYYY-MM-DDTHH:00
        elif period == "daily":
            return ts[:10]          # YYYY-MM-DD
    return ts[:10] if len(ts) >= 10 else "unknown"

def aggregate(rows, period):
    buckets = defaultdict(list)
    for row in rows:
        key = get_period_key(row.get("timestamp", ""), period)
        try:
            ppv = float(row.get("ppv", 0) or 0)
            buckets[key].append(ppv)
        except ValueError:
            pass
    return buckets

def main():
    parser = argparse.ArgumentParser(description="Aggregate field data statistics")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--period", choices=["hourly", "daily"], default="daily")
    args = parser.parse_args()

    rows = load_field_data(args.data_dir)
    if not rows:
        print(f"No data in {args.data_dir}")
        return

    buckets = aggregate(rows, args.period)

    print(f"\n{args.period.capitalize()} PPV Statistics ({len(rows)} total samples):")
    print(f"  {'Period':<22} {'Count':>6} {'Mean':>8} {'Max':>8} {'Min':>8}")
    print("  " + "-"*56)
    for key in sorted(buckets.keys()):
        vals = buckets[key]
        n = len(vals)
        mean = sum(vals)/n
        print(f"  {key:<22} {n:>6} {mean:>8.4f} {max(vals):>8.4f} {min(vals):>8.4f}")
    print()

if __name__ == "__main__":
    main()
