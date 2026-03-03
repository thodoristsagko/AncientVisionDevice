#!/usr/bin/env python3
"""Auto-label CSV rows by threshold rules.

Reads all CSV files in --data-dir.  For each row that does NOT already have a
non-empty ``label`` column the script applies one of three labels:

    anomaly   — ppv >= ppv-anomaly  OR  sta_lta > 3.0
    precursor — ppv >= ppv-precursor  AND  kurtosis >= kurtosis-precursor
    normal    — everything else

In --dry-run mode the CSV files are not modified; only a preview is printed.

Usage
-----
    python scripts/batch_label.py
    python scripts/batch_label.py --data-dir ./data/field
    python scripts/batch_label.py --ppv-anomaly 0.5 --dry-run
"""

import argparse
import csv
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data", "field")


# ---------------------------------------------------------------------------
# Labelling logic
# ---------------------------------------------------------------------------

def _classify_row(
    row: dict,
    ppv_anomaly: float,
    ppv_precursor: float,
    kurtosis_precursor: float,
) -> str:
    """Return the appropriate label string for one row dict."""

    def _fval(key: str) -> float:
        try:
            return float(row.get(key) or 0)
        except (ValueError, TypeError):
            return 0.0

    ppv = _fval("ppv")
    sta_lta = _fval("sta_lta") or _fval("stalta")  # accept both spellings
    kurtosis = _fval("kurtosis")

    if ppv >= ppv_anomaly or sta_lta > 3.0:
        return "anomaly"
    if ppv >= ppv_precursor and kurtosis >= kurtosis_precursor:
        return "precursor"
    return "normal"


# ---------------------------------------------------------------------------
# CSV I/O
# ---------------------------------------------------------------------------

def _load_csv(path: str):
    """Return (fieldnames, rows) or (None, []) on error."""
    try:
        with open(path, newline="", encoding="utf-8") as fh:
            reader = csv.DictReader(fh)
            fieldnames = reader.fieldnames or []
            rows = [dict(r) for r in reader]
        return list(fieldnames), rows
    except (OSError, csv.Error) as exc:
        print(f"  Warning: cannot read {path}: {exc}", file=sys.stderr)
        return None, []


def _write_csv(path: str, fieldnames: list, rows: list) -> bool:
    """Overwrite path with fieldnames and rows.  Returns True on success."""
    try:
        with open(path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
        return True
    except OSError as exc:
        print(f"  Error writing {path}: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Main processing
# ---------------------------------------------------------------------------

def _process_file(
    path: str,
    ppv_anomaly: float,
    ppv_precursor: float,
    kurtosis_precursor: float,
    dry_run: bool,
) -> tuple:
    """
    Label unlabeled rows in one CSV file.

    Returns (n_normal, n_precursor, n_anomaly, n_skipped) counts.
    """
    fieldnames, rows = _load_csv(path)
    if fieldnames is None:
        return 0, 0, 0, 0

    if not rows:
        return 0, 0, 0, 0

    # Ensure label column exists in fieldnames
    if "label" not in fieldnames:
        fieldnames = list(fieldnames) + ["label"]

    n_normal = n_precursor = n_anomaly = n_skipped = 0
    changed = False

    for row in rows:
        existing = str(row.get("label") or "").strip()
        if existing:
            n_skipped += 1
            continue

        label = _classify_row(row, ppv_anomaly, ppv_precursor, kurtosis_precursor)
        row["label"] = label
        changed = True

        if label == "anomaly":
            n_anomaly += 1
        elif label == "precursor":
            n_precursor += 1
        else:
            n_normal += 1

    if dry_run:
        if changed:
            fname = os.path.basename(path)
            print(
                f"  [dry-run] {fname}: would label "
                f"{n_normal} normal, {n_precursor} precursor, {n_anomaly} anomaly"
                f"  ({n_skipped} already labeled, skipped)"
            )
    else:
        if changed:
            _write_csv(path, fieldnames, rows)

    return n_normal, n_precursor, n_anomaly, n_skipped


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Auto-label CSV rows using PPV / STA-LTA / kurtosis thresholds."
    )
    p.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help="Directory containing CSV files to label (default: ./data/field).",
    )
    p.add_argument(
        "--ppv-anomaly",
        type=float,
        default=0.3,
        metavar="FLOAT",
        help="PPV threshold for anomaly label (default: 0.3 mm/s).",
    )
    p.add_argument(
        "--ppv-precursor",
        type=float,
        default=0.1,
        metavar="FLOAT",
        help="Minimum PPV for precursor label (default: 0.1 mm/s).",
    )
    p.add_argument(
        "--kurtosis-precursor",
        type=float,
        default=4.0,
        metavar="FLOAT",
        help="Minimum kurtosis for precursor label (default: 4.0).",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview labels without writing CSV files.",
    )
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    data_dir = args.data_dir
    if not os.path.isdir(data_dir):
        print(f"Data directory not found: {data_dir}", file=sys.stderr)
        return 1

    csv_files = sorted(
        os.path.join(data_dir, f)
        for f in os.listdir(data_dir)
        if f.lower().endswith(".csv")
    )

    if not csv_files:
        print(f"No CSV files found in {data_dir}.")
        return 0

    total_normal = total_precursor = total_anomaly = total_skipped = 0

    for path in csv_files:
        n, p, a, s = _process_file(
            path,
            args.ppv_anomaly,
            args.ppv_precursor,
            args.kurtosis_precursor,
            args.dry_run,
        )
        total_normal += n
        total_precursor += p
        total_anomaly += a
        total_skipped += s

    total_labeled = total_normal + total_precursor + total_anomaly
    mode_str = " [dry-run]" if args.dry_run else ""
    print(
        f"{total_labeled} rows labeled{mode_str}: "
        f"{total_normal} normal, {total_precursor} precursor, {total_anomaly} anomaly"
        f"  ({total_skipped} rows already labeled, skipped)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
