#!/usr/bin/env python3
"""
export_training_dataset.py — Export collected field data for ML training.

Usage:
    python scripts/export_training_dataset.py [--data-dir DIR] [--output FILE] [--min-samples N]

Reads all CSV files from data dir, normalizes columns to match training format,
deduplicates, and exports to a single training-ready CSV.

Output columns: ppv, ax, ay, az, rms, kurtosis, crest_factor, sta_lta, label
"""

import argparse
import csv
import math
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data")
DEFAULT_OUTPUT = os.path.join(REPO_DIR, "data", "training_export.csv")

OUTPUT_COLUMNS = ["ppv", "ax", "ay", "az", "rms", "kurtosis", "crest_factor", "sta_lta", "label"]

# ---------------------------------------------------------------------------
# Label normalization
# ---------------------------------------------------------------------------

_LABEL_MAP = {
    "safe": "normal",
    "SAFE": "normal",
    "anomaly": "anomaly",
    "ANOMALY": "anomaly",
    "warning": "precursor",
    "WARNING": "precursor",
    # Pass-through values (kept as-is)
    "normal": "normal",
    "soil_creep": "soil_creep",
    "crack_propagation": "crack_propagation",
    "imminent_failure": "imminent_failure",
    "precursor": "precursor",
}


def _normalize_label(raw: str) -> str:
    """Normalize a raw label string to the canonical training label set."""
    if not raw:
        return raw
    stripped = raw.strip()
    return _LABEL_MAP.get(stripped, stripped)


# ---------------------------------------------------------------------------
# Derived feature computation
# ---------------------------------------------------------------------------

def _fval(row: dict, key: str) -> float:
    """Return float value for key from row, or NaN if missing/invalid."""
    val = row.get(key)
    if val is None or str(val).strip() == "":
        return float("nan")
    try:
        return float(val)
    except (ValueError, TypeError):
        return float("nan")


def _compute_rms(row: dict) -> float:
    """Compute RMS from ax, ay, az: sqrt(ax^2 + ay^2 + az^2) / sqrt(3)."""
    ax = _fval(row, "ax")
    ay = _fval(row, "ay")
    az = _fval(row, "az")
    if math.isnan(ax) or math.isnan(ay) or math.isnan(az):
        return float("nan")
    return math.sqrt((ax * ax + ay * ay + az * az) / 3.0)


def _compute_kurtosis_single(az: float) -> float:
    """
    Kurtosis from a single az value is undefined; return NaN.
    Kurtosis is computed per-file batch where we have multiple samples.
    """
    return float("nan")


def _compute_crest_factor(row: dict, rms: float) -> float:
    """Compute crest_factor = max(|az|) / rms for a single row."""
    az = _fval(row, "az")
    if math.isnan(az) or math.isnan(rms) or rms == 0.0:
        return float("nan")
    return abs(az) / rms


def _batch_kurtosis(az_values: list) -> list:
    """
    Compute per-row kurtosis using window of all az values.
    kurtosis = mean(x^4) / (mean(x^2)^2)
    Returns a list of float values (one per row, all identical since we use full batch).
    """
    n = len(az_values)
    if n == 0:
        return []

    valid = [v for v in az_values if not math.isnan(v)]
    if len(valid) < 2:
        return [float("nan")] * n

    mean_x2 = sum(v * v for v in valid) / len(valid)
    mean_x4 = sum(v * v * v * v for v in valid) / len(valid)

    if mean_x2 == 0.0:
        return [float("nan")] * n

    kurt = mean_x4 / (mean_x2 * mean_x2)
    return [kurt] * n


# ---------------------------------------------------------------------------
# CSV loading and processing
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


def _process_rows(rows: list) -> list:
    """
    Process a list of CSV row dicts:
    - Normalize labels
    - Drop rows missing ppv, ax, ay, az
    - Compute derived features where missing
    Returns list of output dicts with OUTPUT_COLUMNS keys.
    """
    # Filter rows missing required fields
    valid_rows = []
    for row in rows:
        ppv = _fval(row, "ppv")
        ax = _fval(row, "ax")
        ay = _fval(row, "ay")
        az = _fval(row, "az")
        if math.isnan(ppv) or math.isnan(ax) or math.isnan(ay) or math.isnan(az):
            continue
        valid_rows.append(row)

    if not valid_rows:
        return []

    # Batch compute kurtosis if needed
    az_values = []
    needs_kurtosis = []
    for row in valid_rows:
        existing_k = _fval(row, "kurtosis")
        needs_kurtosis.append(math.isnan(existing_k))
        az_values.append(_fval(row, "az"))

    batch_kurt = None
    if any(needs_kurtosis):
        batch_kurt = _batch_kurtosis(az_values)

    out_rows = []
    for i, row in enumerate(valid_rows):
        ppv = _fval(row, "ppv")
        ax = _fval(row, "ax")
        ay = _fval(row, "ay")
        az = _fval(row, "az")

        # RMS
        rms_val = _fval(row, "rms")
        if math.isnan(rms_val):
            rms_val = _compute_rms(row)

        # Kurtosis
        kurt_val = _fval(row, "kurtosis")
        if math.isnan(kurt_val) and batch_kurt is not None:
            kurt_val = batch_kurt[i]

        # Crest factor
        cf_val = _fval(row, "crest_factor")
        if math.isnan(cf_val):
            cf_val = _fval(row, "crest")  # accept alternate column name
        if math.isnan(cf_val):
            cf_val = _compute_crest_factor(row, rms_val)

        # STA/LTA — use 1.0 as placeholder if missing
        sta_lta_val = _fval(row, "sta_lta")
        if math.isnan(sta_lta_val):
            sta_lta_val = _fval(row, "stalta")
        if math.isnan(sta_lta_val):
            sta_lta_val = 1.0

        # Normalize label
        raw_label = str(row.get("label") or "").strip()
        label = _normalize_label(raw_label)

        def _fmt(v):
            if math.isnan(v):
                return ""
            return str(v)

        out_rows.append({
            "ppv": ppv,
            "ax": ax,
            "ay": ay,
            "az": az,
            "rms": rms_val if not math.isnan(rms_val) else "",
            "kurtosis": kurt_val if not math.isnan(kurt_val) else "",
            "crest_factor": cf_val if not math.isnan(cf_val) else "",
            "sta_lta": sta_lta_val,
            "label": label,
        })

    return out_rows


def _dedup(rows: list) -> list:
    """Drop exact duplicate rows (all column values identical)."""
    seen = set()
    out = []
    for row in rows:
        key = tuple(str(row.get(c, "")) for c in OUTPUT_COLUMNS)
        if key not in seen:
            seen.add(key)
            out.append(row)
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Export collected field CSVs in ML training format.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help="Directory to search for CSV files (default: ./data/).",
    )
    p.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        metavar="FILE",
        help="Output CSV path (default: data/training_export.csv).",
    )
    p.add_argument(
        "--min-samples",
        type=int,
        default=0,
        metavar="N",
        help="Minimum sample count required; exit 1 if fewer (default: 0).",
    )
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    data_dir = args.data_dir
    output_path = args.output
    min_samples = args.min_samples

    if not os.path.isdir(data_dir):
        print(f"Data directory not found: {data_dir}", file=sys.stderr)
        # Write empty output and exit 0 when no data dir
        _write_output(output_path, [])
        return 0

    # Find all CSV files in data_dir (non-recursive, top-level only)
    csv_files = sorted(
        os.path.join(data_dir, f)
        for f in os.listdir(data_dir)
        if f.lower().endswith(".csv")
    )

    if not csv_files:
        print(f"No CSV files found in {data_dir}.")
        _write_output(output_path, [])
        return 0

    all_rows = []
    for path in csv_files:
        # Skip the output file itself if it's in the same directory
        if os.path.abspath(path) == os.path.abspath(output_path):
            continue
        _, rows = _load_csv(path)
        processed = _process_rows(rows)
        all_rows.extend(processed)

    # Deduplicate
    all_rows = _dedup(all_rows)

    # Check min-samples constraint
    if min_samples > 0 and len(all_rows) < min_samples:
        print(
            f"Error: only {len(all_rows)} samples after filtering "
            f"(required: {min_samples})",
            file=sys.stderr,
        )
        return 1

    # Write output
    _write_output(output_path, all_rows)

    # Compute per-class stats
    label_counts: dict = {}
    for row in all_rows:
        lbl = str(row.get("label") or "unlabeled")
        label_counts[lbl] = label_counts.get(lbl, 0) + 1

    stats_parts = []
    for lbl in ["normal", "soil_creep", "crack_propagation", "imminent_failure"]:
        cnt = label_counts.get(lbl, 0)
        stats_parts.append(f"{cnt} {lbl}")
    # Include any labels not in the standard set
    for lbl, cnt in sorted(label_counts.items()):
        if lbl not in ("normal", "soil_creep", "crack_propagation", "imminent_failure"):
            stats_parts.append(f"{cnt} {lbl}")

    print(f"Exported {len(all_rows)} samples: {', '.join(stats_parts)}")
    return 0


def _write_output(path: str, rows: list) -> None:
    """Write rows to output CSV, creating parent directories as needed."""
    out_dir = os.path.dirname(os.path.abspath(path))
    os.makedirs(out_dir, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=OUTPUT_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in OUTPUT_COLUMNS})


if __name__ == "__main__":
    sys.exit(main())
