#!/usr/bin/env python3
"""Aggregate field data statistics by hour and day with trend analysis and heatmaps.

Usage:
    python scripts/aggregate_stats.py
    python scripts/aggregate_stats.py --data-dir ./data/field --period daily
    python scripts/aggregate_stats.py --data-dir ./data/field --output stats.json
"""
import argparse, csv, os, sys, json
from collections import defaultdict
from datetime import datetime, timedelta

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

def load_field_data(data_dir):
    rows = []
    if not os.path.isdir(data_dir):
        return rows
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
    device_activity = defaultdict(lambda: defaultdict(list))
    class_distribution = defaultdict(lambda: defaultdict(int))

    for row in rows:
        key = get_period_key(row.get("timestamp", ""), period)
        device_id = row.get("device_id", "unknown").strip() or "unknown"

        try:
            ppv = float(row.get("ppv", 0) or 0)
            buckets[key].append(ppv)
            device_activity[key][device_id].append(ppv)
        except ValueError:
            pass

        # Track class distribution
        label = row.get("label", "").strip().lower() or "unlabeled"
        class_distribution[key][label] += 1

    return buckets, device_activity, class_distribution

def print_device_heatmap(device_activity):
    """Print ASCII heatmap of device activity across days."""
    if not device_activity:
        return

    print("\n  Device Activity Heatmap (samples per device per day):")
    print()

    # Get sorted dates and devices
    dates = sorted(device_activity.keys())
    all_devices = set()
    for day_data in device_activity.values():
        all_devices.update(day_data.keys())
    devices = sorted(all_devices)

    if not devices or not dates:
        print("    (No device data to display)")
        return

    # Header
    print("    " + " " * 12 + "".join(f"{d[5:]:>4}" for d in dates[:20]))
    print("    " + "-" * (12 + min(len(dates), 20) * 4))

    # Rows (devices)
    for dev in devices[:15]:  # Limit to 15 devices
        row = f"    {dev[:12]:<12}"
        for date in dates[:20]:  # Limit to 20 days
            count = len(device_activity[date].get(dev, []))
            # Heat indicator: . = 0, 1-5 = 1, 6-20 = 2, 21+ = 3
            if count == 0:
                heat = "."
            elif count <= 5:
                heat = "░"
            elif count <= 20:
                heat = "▒"
            else:
                heat = "█"
            row += f"{heat:>4}"
        print(row)

    print("\n    Legend: . = 0 samples, ░ = 1-5, ▒ = 6-20, █ = 21+")

def compute_trend(buckets):
    """Compute 7-day trend: increasing, stable, or decreasing."""
    sorted_keys = sorted(buckets.keys())
    if len(sorted_keys) < 7:
        return "Insufficient data (<7 days)"

    # Last 7 days
    recent = sorted_keys[-7:]
    sample_counts = [len(buckets[k]) for k in recent]

    avg_first_3 = sum(sample_counts[:3]) / 3
    avg_last_3 = sum(sample_counts[-3:]) / 3

    pct_change = ((avg_last_3 - avg_first_3) / max(avg_first_3, 1)) * 100

    if pct_change > 10:
        return f"Increasing (+{pct_change:.1f}%)"
    elif pct_change < -10:
        return f"Decreasing ({pct_change:.1f}%)"
    else:
        return "Stable (±10%)"

def main():
    parser = argparse.ArgumentParser(description="Aggregate field data statistics")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--period", choices=["hourly", "daily"], default="daily")
    parser.add_argument("--output", type=str, default=None,
                        help="Optional: save results to JSON file")
    args = parser.parse_args()

    if not os.path.isabs(args.data_dir):
        args.data_dir = os.path.join(os.getcwd(), args.data_dir)

    rows = load_field_data(args.data_dir)
    if not rows:
        print(f"No data in {args.data_dir}")
        return

    buckets, device_activity, class_distribution = aggregate(rows, args.period)

    print(f"\n{args.period.capitalize()} PPV Statistics ({len(rows)} total samples):")
    print(f"  {'Period':<22} {'Count':>6} {'Mean':>8} {'Max':>8} {'Min':>8}")
    print("  " + "-"*56)

    output_data = {"period": args.period, "total_samples": len(rows), "periods": {}}

    for key in sorted(buckets.keys()):
        vals = buckets[key]
        n = len(vals)
        mean = sum(vals)/n
        max_val = max(vals)
        min_val = min(vals)
        print(f"  {key:<22} {n:>6} {mean:>8.4f} {max_val:>8.4f} {min_val:>8.4f}")

        # Class distribution for this period
        class_dist = class_distribution[key]
        output_data["periods"][key] = {
            "count": n,
            "mean_ppv": mean,
            "max_ppv": max_val,
            "min_ppv": min_val,
            "class_distribution": dict(class_dist)
        }

    print()

    # Device activity heatmap
    print_device_heatmap(device_activity)

    # Trend analysis
    print()
    print("=" * 70)
    print("TREND ANALYSIS (last 7 days)")
    print("=" * 70)
    print()
    trend = compute_trend(buckets)
    print(f"  {trend}")
    print()

    # Save to JSON if requested
    if args.output:
        output_data["trend"] = trend
        output_path = os.path.join(os.getcwd(), args.output)
        try:
            with open(output_path, "w") as f:
                json.dump(output_data, f, indent=2)
            print(f"Results saved to: {output_path}")
        except Exception as e:
            print(f"ERROR: Could not save to {output_path}: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
