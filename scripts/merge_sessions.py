#!/usr/bin/env python3
"""Merge multiple field CSV files into a single CSV.

Reads all CSV files found in --data-dir and writes a unified CSV to --output.

Features
--------
- Unifies column headers: the output contains the union of every column found
  across all files.  Missing values for a given row are written as empty strings.
- Adds a ``source_file`` column recording the originating filename.
- Optionally sorts rows by any column (default: ``timestamp``).
- Optionally removes duplicate rows based on (timestamp, device_id).

Usage
-----
    python scripts/merge_sessions.py
    python scripts/merge_sessions.py --data-dir ./data/field --output merged.csv
    python scripts/merge_sessions.py --sort-by timestamp --dedup
    python scripts/merge_sessions.py --output /tmp/all.csv --dedup
"""

import argparse
import csv
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data", "field")
DEFAULT_OUTPUT = os.path.join(REPO_DIR, "merged.csv")


# ---------------------------------------------------------------------------
# CSV I/O helpers
# ---------------------------------------------------------------------------

def _load_csv(path: str, source_name: str) -> tuple:
    """
    Return (fieldnames_list, rows_list) for one CSV file.

    Each row dict gets an extra ``source_file`` key.
    Returns ([], []) on read error.
    """
    try:
        with open(path, newline="", encoding="utf-8") as fh:
            reader = csv.DictReader(fh)
            fieldnames = list(reader.fieldnames or [])
            rows = []
            for row in reader:
                d = dict(row)
                d["source_file"] = source_name
                rows.append(d)
        return fieldnames, rows
    except (OSError, csv.Error) as exc:
        print(f"  Warning: cannot read {path}: {exc}", file=sys.stderr)
        return [], []


def _write_csv(path: str, fieldnames: list, rows: list) -> bool:
    """Write rows to path using fieldnames.  Returns True on success."""
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(
                fh, fieldnames=fieldnames, extrasaction="ignore",
                restval=""
            )
            writer.writeheader()
            writer.writerows(rows)
        return True
    except OSError as exc:
        print(f"Error writing {path}: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Core merge logic
# ---------------------------------------------------------------------------

def _union_fieldnames(all_fieldnames: list) -> list:
    """
    Return the ordered union of all fieldnames lists.

    The order preserves first occurrence; ``source_file`` is placed last.
    """
    seen = {}  # name -> insertion index
    for names in all_fieldnames:
        for name in names:
            if name != "source_file" and name not in seen:
                seen[name] = len(seen)
    ordered = sorted(seen, key=lambda n: seen[n])
    ordered.append("source_file")
    return ordered


def _dedup_rows(rows: list) -> tuple:
    """
    Remove rows with duplicate (timestamp, device_id) keys.

    The first occurrence is kept.  Returns (deduplicated_rows, n_removed).
    """
    seen_keys = set()
    unique = []
    n_removed = 0
    for row in rows:
        key = (row.get("timestamp", ""), row.get("device_id", ""))
        if key in seen_keys:
            n_removed += 1
        else:
            seen_keys.add(key)
            unique.append(row)
    return unique, n_removed


def _sort_rows(rows: list, sort_by: str) -> list:
    """Sort rows by column sort_by, treating missing values as empty string."""
    return sorted(rows, key=lambda r: r.get(sort_by) or "")


def merge(
    data_dir: str,
    output: str,
    sort_by: str | None,
    dedup: bool,
) -> int:
    """
    Merge all CSVs in data_dir into output.

    Returns exit code (0 = success, 1 = error).
    """
    if not os.path.isdir(data_dir):
        print(f"Data directory not found: {data_dir}", file=sys.stderr)
        return 1

    csv_files = sorted(
        f for f in os.listdir(data_dir) if f.lower().endswith(".csv")
    )

    if not csv_files:
        print(f"No CSV files found in {data_dir}.")
        return 0

    all_fieldnames_lists = []
    all_rows = []
    n_files_loaded = 0

    for fname in csv_files:
        fpath = os.path.join(data_dir, fname)
        fieldnames, rows = _load_csv(fpath, fname)
        if fieldnames is not None and rows is not None:
            all_fieldnames_lists.append(fieldnames)
            all_rows.extend(rows)
            n_files_loaded += 1

    if not all_rows:
        print("No rows found in any CSV file.")
        return 0

    # Build unified column list
    unified_fields = _union_fieldnames(all_fieldnames_lists)

    # Dedup before sort so sort order is deterministic
    n_dedup_removed = 0
    if dedup:
        all_rows, n_dedup_removed = _dedup_rows(all_rows)

    # Sort
    if sort_by:
        all_rows = _sort_rows(all_rows, sort_by)

    # Write
    ok = _write_csv(output, unified_fields, all_rows)
    if not ok:
        return 1

    print(
        f"Merged {n_files_loaded} files, {len(all_rows)} total rows, "
        f"{n_dedup_removed} duplicates removed"
    )
    print(f"Output: {output}")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Merge multiple field session CSVs into a single CSV file."
    )
    p.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help="Directory containing CSV files to merge (default: ./data/field).",
    )
    p.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        metavar="FILE",
        help="Output CSV file path (default: merged.csv in repo root).",
    )
    p.add_argument(
        "--sort-by",
        default="timestamp",
        metavar="COLUMN",
        help="Column name to sort merged rows by (default: timestamp). "
             "Pass empty string to disable sorting.",
    )
    p.add_argument(
        "--dedup",
        action="store_true",
        help="Remove duplicate rows based on (timestamp, device_id).",
    )
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)
    sort_col = args.sort_by if args.sort_by else None
    return merge(args.data_dir, args.output, sort_col, args.dedup)


if __name__ == "__main__":
    sys.exit(main())
