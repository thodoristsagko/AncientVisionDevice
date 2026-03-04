#!/usr/bin/env python3
"""
label_field_data.py — Semi-automated labeling for collected field data.

Usage:
    python scripts/label_field_data.py [--data-dir DIR] [--auto]

Shows stats for unlabeled rows (label is empty or 'unknown').
With --auto: applies rule-based labels based on PPV thresholds:
  PPV < 0.1  -> normal
  PPV 0.1-0.3 -> normal (low activity)
  PPV 0.3-1.0 -> precursor
  PPV > 1.0  -> imminent_failure
Updates CSV files in-place.
"""

import argparse
import csv
import os
import shutil
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data")

# PPV thresholds (mm/s)
PPV_NORMAL_MAX = 0.3       # below this -> normal
PPV_PRECURSOR_MAX = 1.0    # 0.3-1.0 -> precursor
# above PPV_PRECURSOR_MAX -> imminent_failure


# ---------------------------------------------------------------------------
# Label classification
# ---------------------------------------------------------------------------

def _classify_by_ppv(ppv: float) -> str:
    """Apply rule-based label from PPV value."""
    if ppv < PPV_NORMAL_MAX:
        return "normal"
    if ppv <= PPV_PRECURSOR_MAX:
        return "precursor"
    return "imminent_failure"


def _is_unlabeled(label_val) -> bool:
    """Return True if the label value is considered unlabeled."""
    if label_val is None:
        return True
    stripped = str(label_val).strip().lower()
    return stripped in ("", "unknown")


# ---------------------------------------------------------------------------
# CSV I/O
# ---------------------------------------------------------------------------

def _load_csv(path: str):
    """Return (fieldnames, rows) or (None, []) on error."""
    try:
        with open(path, newline="", encoding="utf-8") as fh:
            reader = csv.DictReader(fh)
            fieldnames = list(reader.fieldnames or [])
            rows = [dict(r) for r in reader]
        return fieldnames, rows
    except (OSError, csv.Error) as exc:
        print(f"  Warning: cannot read {path}: {exc}", file=sys.stderr)
        return None, []


def _write_csv(path: str, fieldnames: list, rows: list) -> bool:
    """Overwrite path with fieldnames and rows. Returns True on success."""
    try:
        with open(path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
        return True
    except OSError as exc:
        print(f"  Error writing {path}: {exc}", file=sys.stderr)
        return False


def _backup_file(path: str) -> bool:
    """Create a .bak copy of path before modification. Returns True on success."""
    bak_path = path + ".bak"
    try:
        shutil.copy2(path, bak_path)
        return True
    except OSError as exc:
        print(f"  Warning: could not create backup {bak_path}: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Per-file processing
# ---------------------------------------------------------------------------

def _count_unlabeled(rows: list, fieldnames: list) -> int:
    """Return count of unlabeled rows."""
    if "label" not in fieldnames:
        return len(rows)
    return sum(1 for row in rows if _is_unlabeled(row.get("label")))


def _process_file_auto(path: str) -> tuple:
    """
    Apply auto-labels to unlabeled rows in one CSV file.
    Creates .bak backup before modifying.

    Returns (n_normal, n_precursor, n_imminent_failure, n_skipped).
    """
    fieldnames, rows = _load_csv(path)
    if fieldnames is None:
        return 0, 0, 0, 0

    if not rows:
        return 0, 0, 0, 0

    # Ensure label column exists
    if "label" not in fieldnames:
        fieldnames = list(fieldnames) + ["label"]

    n_normal = n_precursor = n_imminent = n_skipped = 0
    changed = False

    for row in rows:
        if not _is_unlabeled(row.get("label")):
            n_skipped += 1
            continue

        # Get PPV value
        ppv_raw = row.get("ppv")
        try:
            ppv = float(ppv_raw) if ppv_raw not in (None, "") else 0.0
        except (ValueError, TypeError):
            ppv = 0.0

        label = _classify_by_ppv(ppv)
        row["label"] = label
        changed = True

        if label == "normal":
            n_normal += 1
        elif label == "precursor":
            n_precursor += 1
        else:
            n_imminent += 1

    if changed:
        if not _backup_file(path):
            # Backup failed but continue — warn was already printed
            pass
        _write_csv(path, fieldnames, rows)

    return n_normal, n_precursor, n_imminent, n_skipped


def _process_file_dry(path: str) -> int:
    """Return count of unlabeled rows in path without modifying it."""
    fieldnames, rows = _load_csv(path)
    if fieldnames is None:
        return 0
    return _count_unlabeled(rows, fieldnames)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Semi-automated labeling helper for collected field data.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help="Directory containing CSV files to label (default: ./data/).",
    )
    p.add_argument(
        "--auto",
        action="store_true",
        help=(
            "Apply rule-based labels using PPV thresholds and update CSVs in place. "
            "Without --auto, only prints counts of unlabeled rows (dry run)."
        ),
    )
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    data_dir = args.data_dir

    if not os.path.isdir(data_dir):
        print(f"Data directory not found: {data_dir}", file=sys.stderr)
        return 0

    csv_files = sorted(
        os.path.join(data_dir, f)
        for f in os.listdir(data_dir)
        if f.lower().endswith(".csv")
    )

    if not csv_files:
        print(f"No CSV files found in {data_dir}.")
        return 0

    if not args.auto:
        # Dry run — just print counts per file
        total_unlabeled = 0
        for path in csv_files:
            count = _process_file_dry(path)
            fname = os.path.basename(path)
            print(f"  {fname}: {count} unlabeled rows")
            total_unlabeled += count
        print(f"Total unlabeled rows: {total_unlabeled}")
        print("(Run with --auto to apply labels.)")
        return 0

    # Auto-label mode
    total_normal = total_precursor = total_imminent = total_skipped = 0

    for path in csv_files:
        n, p, imm, s = _process_file_auto(path)
        total_normal += n
        total_precursor += p
        total_imminent += imm
        total_skipped += s

    total_labeled = total_normal + total_precursor + total_imminent
    print(
        f"Labeled {total_labeled} rows: "
        f"{total_normal} normal, {total_precursor} precursor, "
        f"{total_imminent} imminent_failure"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
