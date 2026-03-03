"""
Field report: reads all CSV files in ./data/field/ and prints a summary.

Usage:
    python scripts/field_report.py [--data-dir ./data] [--json]

stdlib only — no external dependencies.
"""
import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path


def _collect_stats(field_dir: Path) -> dict:
    """
    Scan all *.csv files in field_dir and return a stats dict with:
      - total_samples     : int
      - samples_per_day   : {date_str: int}
      - samples_per_device: {device_id: int}
      - samples_per_label : {label: int}
      - csv_files         : int
    """
    total_samples = 0
    samples_per_day: dict = defaultdict(int)
    samples_per_device: dict = defaultdict(int)
    samples_per_label: dict = defaultdict(int)
    csv_files = 0

    for csv_path in sorted(field_dir.glob("*.csv")):
        csv_files += 1
        date_str = csv_path.stem  # filename without extension, e.g. "2026-03-03"
        try:
            with open(csv_path, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    total_samples += 1
                    samples_per_day[date_str] += 1
                    device = row.get("device_id", "").strip()
                    if device:
                        samples_per_device[device] += 1
                    label = row.get("label", "").strip()
                    if label:
                        samples_per_label[label] += 1
        except Exception:
            pass  # skip unreadable files silently

    return {
        "total_samples": total_samples,
        "samples_per_day": dict(samples_per_day),
        "samples_per_device": dict(samples_per_device),
        "samples_per_label": dict(samples_per_label),
        "csv_files": csv_files,
    }


def _print_table(stats: dict) -> None:
    """Print a human-readable summary table to stdout."""
    print("=" * 50)
    print("  Field Data Report")
    print("=" * 50)
    print(f"  CSV files scanned : {stats['csv_files']}")
    print(f"  Total samples     : {stats['total_samples']}")
    print()

    print("  Samples per day:")
    if stats["samples_per_day"]:
        for day, count in sorted(stats["samples_per_day"].items()):
            print(f"    {day:20s}  {count}")
    else:
        print("    (none)")
    print()

    print("  Samples per device:")
    if stats["samples_per_device"]:
        for device, count in sorted(stats["samples_per_device"].items()):
            print(f"    {device:30s}  {count}")
    else:
        print("    (none)")
    print()

    print("  Samples per label class:")
    if stats["samples_per_label"]:
        for label, count in sorted(stats["samples_per_label"].items()):
            print(f"    {label:30s}  {count}")
    else:
        print("    (none)")
    print("=" * 50)


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(
        description="Summarise collected field CSV data."
    )
    parser.add_argument(
        "--data-dir",
        default="./data",
        help="Root data directory (default: ./data). field/ subdirectory is read.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="output_json",
        help="Output stats as JSON instead of a human-readable table.",
    )
    args = parser.parse_args(argv)

    field_dir = Path(args.data_dir) / "field"
    stats = _collect_stats(field_dir)

    if args.output_json:
        print(json.dumps(stats, indent=2))
    else:
        _print_table(stats)


if __name__ == "__main__":
    main()
