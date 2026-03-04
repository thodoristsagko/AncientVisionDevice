#!/usr/bin/env python3
"""Pre-training data validator for AncientVision field CSV data.

Runs a suite of checks before training to catch common data quality issues:
  1. Minimum sample count (error < 10, warn < 100)
  2. Class balance (warn if any class < 20% of max class count)
  3. Feature physical bounds (ppv > 100, kurtosis < 0, etc.)
  4. Timestamp continuity (gaps > 1 hour between consecutive rows)
  5. Duplicate detection (identical timestamp + device_id + all features)
  6. NaN/null detection (missing or non-numeric values per column)
  7. Outlier detection (> 5 std devs from column mean)

Usage:
    python scripts/validate_training_data.py
    python scripts/validate_training_data.py --data-dir ./data/field
    python scripts/validate_training_data.py --data-dir ./data/field --strict

In --strict mode: exit code 1 if any warning is found.
Normal mode: exit code 1 only on errors.
"""

import argparse
import csv
import math
import os
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]

# All numeric feature columns expected in field CSV
NUMERIC_COLUMNS = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis", "stalta",
    "arias", "cav", "temp", "psdSlope",
    "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
    "cusum_max", "autoencoder_score",
]

# Physical bounds: (column, min_allowed, max_allowed, description)
# None means unbounded in that direction
PHYSICAL_BOUNDS = [
    ("rms",             0.0,   None,    "rms must be >= 0"),
    ("ppv",             0.0,   100.0,   "ppv must be in [0, 100] mm/s"),
    ("freq",            0.0,   500.0,   "freq must be in [0, 500] Hz"),
    ("crest",           1.0,   None,    "crest factor must be >= 1.0"),
    ("centroid",        0.0,   500.0,   "spectral centroid must be in [0, 500] Hz"),
    ("kurtosis",        0.0,   None,    "kurtosis must be >= 0"),
    ("stalta",          0.0,   None,    "STA/LTA must be >= 0"),
    ("arias",           0.0,   None,    "Arias intensity must be >= 0"),
    ("cav",             0.0,   None,    "CAV must be >= 0"),
    ("temp",          -50.0, 100.0,    "temperature must be in [-50, 100] C"),
    ("psdSlope",      -30.0,  10.0,    "PSD slope must be in [-30, 10] dB/oct"),
    ("ppv_trend",       0.0,  None,    "ppv_trend ratio must be >= 0"),
    ("freq_trend",      0.0,  None,    "freq_trend ratio must be >= 0"),
    ("kurtosis_trend",  0.0,  None,    "kurtosis_trend ratio must be >= 0"),
    ("stalta_trend",    0.0,  None,    "stalta_trend ratio must be >= 0"),
    ("cusum_max",       0.0,  None,    "cusum_max must be >= 0"),
    ("autoencoder_score", 0.0, None,  "autoencoder_score must be >= 0"),
]

TIMESTAMP_GAP_SECONDS = 3600  # 1 hour
OUTLIER_STD_MULTIPLIER = 5.0
MIN_SAMPLES_ERROR = 10
MIN_SAMPLES_WARN = 100
CLASS_BALANCE_THRESHOLD = 0.20  # 20% of max class


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _load_all_csv(data_dir: str) -> list:
    """Load all *.csv files in data_dir; return list of row dicts."""
    rows = []
    if not os.path.isdir(data_dir):
        return rows
    for fname in sorted(os.listdir(data_dir)):
        if not fname.endswith(".csv"):
            continue
        fpath = os.path.join(data_dir, fname)
        try:
            with open(fpath, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(dict(row))
        except (OSError, csv.Error) as exc:
            print(f"  WARNING: Could not read {fpath}: {exc}")
    return rows


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def _try_float(val) -> float | None:
    """Return float or None if unparseable/missing."""
    if val is None or str(val).strip() == "":
        return None
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def _try_timestamp(val) -> float | None:
    """Return POSIX timestamp (float) or None for various ISO formats."""
    if val is None or str(val).strip() == "":
        return None
    s = str(val).strip()
    # Try numeric epoch first
    try:
        return float(s)
    except ValueError:
        pass
    # Try ISO formats
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
    ):
        try:
            dt = datetime.strptime(s, fmt)
            return dt.replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    return None


# ---------------------------------------------------------------------------
# Check implementations
# ---------------------------------------------------------------------------

def check_minimum_samples(rows: list) -> tuple:
    """Check 1: Minimum sample count.

    Returns:
        (issues: list[dict])  each dict has keys: level, message
    """
    issues = []
    n = len(rows)
    if n < MIN_SAMPLES_ERROR:
        issues.append({
            "level": "ERROR",
            "message": f"Only {n} samples total — minimum required is {MIN_SAMPLES_ERROR}.",
            "count": n,
        })
    elif n < MIN_SAMPLES_WARN:
        issues.append({
            "level": "WARN",
            "message": (
                f"Only {n} samples total — recommend at least {MIN_SAMPLES_WARN} "
                "for reliable training."
            ),
            "count": n,
        })
    return issues


def check_class_balance(rows: list) -> tuple:
    """Check 2: Class balance."""
    issues = []
    label_counts = {}
    for row in rows:
        label = row.get("label", "").strip().lower()
        label_counts[label] = label_counts.get(label, 0) + 1

    labeled = {k: v for k, v in label_counts.items() if k}
    if not labeled:
        issues.append({
            "level": "ERROR",
            "message": "No rows have a 'label' column value.",
            "counts": {},
        })
        return issues

    max_count = max(labeled.values())
    for cls in CLASS_NAMES:
        cnt = labeled.get(cls, 0)
        if cnt == 0:
            issues.append({
                "level": "WARN",
                "message": f"Class '{cls}' has 0 samples — absent from dataset.",
                "class": cls,
                "count": cnt,
                "ratio": 0.0,
            })
        elif cnt < CLASS_BALANCE_THRESHOLD * max_count:
            ratio = cnt / max_count
            issues.append({
                "level": "WARN",
                "message": (
                    f"Class '{cls}' has {cnt} samples ({ratio * 100:.1f}% of max={max_count}). "
                    f"Recommend at least {CLASS_BALANCE_THRESHOLD * 100:.0f}% of max class count."
                ),
                "class": cls,
                "count": cnt,
                "ratio": ratio,
            })

    return issues, labeled


def check_physical_bounds(rows: list) -> list:
    """Check 3: Feature physical bounds."""
    issues = []
    violations = {}  # (col, bound_type) -> count

    for row in rows:
        for col, lo, hi, desc in PHYSICAL_BOUNDS:
            val = _try_float(row.get(col))
            if val is None:
                continue  # NaN check handled separately
            if lo is not None and val < lo:
                key = (col, "below_min")
                violations[key] = violations.get(key, 0) + 1
            if hi is not None and val > hi:
                key = (col, "above_max")
                violations[key] = violations.get(key, 0) + 1

    for (col, bound_type), cnt in sorted(violations.items()):
        bound_dir = "below minimum" if bound_type == "below_min" else "above maximum"
        lo_val = next((lo for c, lo, hi, d in PHYSICAL_BOUNDS if c == col), None)
        hi_val = next((hi for c, lo, hi, d in PHYSICAL_BOUNDS if c == col), None)
        bound_val = lo_val if bound_type == "below_min" else hi_val
        issues.append({
            "level": "WARN",
            "message": (
                f"{cnt} row(s) have '{col}' {bound_dir} physical limit ({bound_val})."
            ),
            "column": col,
            "direction": bound_dir,
            "count": cnt,
        })

    return issues


def check_timestamp_continuity(rows: list) -> list:
    """Check 4: Timestamp gaps > 1 hour."""
    issues = []
    timestamps = []
    for i, row in enumerate(rows):
        ts = _try_timestamp(row.get("timestamp"))
        if ts is not None:
            timestamps.append((i, ts))

    if len(timestamps) < 2:
        return issues  # Not enough timestamps to check

    # Sort by timestamp
    timestamps.sort(key=lambda x: x[1])

    gaps = []
    for k in range(1, len(timestamps)):
        prev_idx, prev_ts = timestamps[k - 1]
        curr_idx, curr_ts = timestamps[k]
        gap = curr_ts - prev_ts
        if gap > TIMESTAMP_GAP_SECONDS:
            gaps.append({
                "gap_seconds": gap,
                "gap_hours": gap / 3600,
                "row_before": prev_idx,
                "row_after": curr_idx,
            })

    if gaps:
        total_gaps = len(gaps)
        max_gap_h = max(g["gap_hours"] for g in gaps)
        issues.append({
            "level": "WARN",
            "message": (
                f"{total_gaps} timestamp gap(s) > 1 hour detected "
                f"(max gap: {max_gap_h:.1f} h). May indicate recording issues or session breaks."
            ),
            "gaps": gaps[:5],  # include up to 5 for reporting
            "total_gaps": total_gaps,
        })

    return issues


def check_duplicates(rows: list) -> list:
    """Check 5: Exact duplicate rows (same timestamp + device_id + all features)."""
    issues = []
    key_counts = {}
    dup_cols = ["timestamp", "device_id"] + NUMERIC_COLUMNS

    for row in rows:
        key_parts = []
        for col in dup_cols:
            val = row.get(col, "")
            key_parts.append(str(val).strip())
        key = "\x00".join(key_parts)
        key_counts[key] = key_counts.get(key, 0) + 1

    n_dups = sum(cnt - 1 for cnt in key_counts.values() if cnt > 1)
    n_dup_groups = sum(1 for cnt in key_counts.values() if cnt > 1)

    if n_dups > 0:
        issues.append({
            "level": "WARN",
            "message": (
                f"{n_dups} duplicate row(s) found in {n_dup_groups} group(s) "
                f"(identical timestamp + device_id + all features)."
            ),
            "duplicate_rows": n_dups,
            "duplicate_groups": n_dup_groups,
        })

    return issues


def check_nan_null(rows: list) -> list:
    """Check 6: NaN/null/missing values per column."""
    issues = []
    if not rows:
        return issues

    # Count all columns present
    all_cols = set()
    for row in rows:
        all_cols.update(row.keys())

    missing_counts = {}
    for col in sorted(all_cols):
        count = 0
        for row in rows:
            val = row.get(col)
            if val is None or str(val).strip() == "":
                count += 1
            elif col in NUMERIC_COLUMNS:
                # Also flag non-numeric values in numeric columns
                try:
                    float(val)
                except (ValueError, TypeError):
                    count += 1
        if count > 0:
            missing_counts[col] = count

    for col, cnt in sorted(missing_counts.items(), key=lambda x: -x[1]):
        pct = cnt / len(rows) * 100
        level = "ERROR" if pct > 50 else "WARN"
        issues.append({
            "level": level,
            "message": f"'{col}': {cnt}/{len(rows)} missing/null values ({pct:.1f}%).",
            "column": col,
            "missing_count": cnt,
            "missing_pct": pct,
        })

    return issues


def check_outliers(rows: list) -> list:
    """Check 7: Statistical outliers (> 5 std devs from column mean)."""
    issues = []
    if not rows:
        return issues

    for col in NUMERIC_COLUMNS:
        vals = []
        for row in rows:
            v = _try_float(row.get(col))
            if v is not None:
                vals.append(v)
        if len(vals) < 4:
            continue

        n = len(vals)
        mean = sum(vals) / n
        variance = sum((v - mean) ** 2 for v in vals) / n
        std = math.sqrt(variance) if variance > 0 else 0.0

        if std < 1e-10:
            continue  # constant column — no outliers possible

        threshold = OUTLIER_STD_MULTIPLIER * std
        outlier_count = sum(1 for v in vals if abs(v - mean) > threshold)

        if outlier_count > 0:
            max_z = max(abs(v - mean) / std for v in vals)
            issues.append({
                "level": "WARN",
                "message": (
                    f"'{col}': {outlier_count} outlier(s) > {OUTLIER_STD_MULTIPLIER:.0f} std from mean "
                    f"(mean={mean:.4f}, std={std:.4f}, max_z={max_z:.1f})."
                ),
                "column": col,
                "outlier_count": outlier_count,
                "mean": mean,
                "std": std,
                "max_z_score": max_z,
            })

    return issues


# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------

def _print_section(title: str, issues: list) -> None:
    """Print a validation section with issues."""
    print(f"\n  {title}")
    print(f"  {'─' * (len(title) + 2)}")
    if not issues:
        print("    OK — no issues found.")
    else:
        for issue in issues:
            level = issue.get("level", "INFO")
            msg = issue.get("message", "")
            prefix = "    [ERROR]" if level == "ERROR" else "    [WARN] "
            print(f"{prefix} {msg}")


def _count_by_level(issues: list) -> tuple:
    errors = sum(1 for i in issues if i.get("level") == "ERROR")
    warns = sum(1 for i in issues if i.get("level") == "WARN")
    return errors, warns


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate field data before ML training."
    )
    parser.add_argument(
        "--data-dir",
        default=os.path.join(REPO_DIR, "data", "field"),
        metavar="DIR",
        help="Directory containing field CSV files (default: ./data/field).",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit code 1 if ANY warning is found (not just errors).",
    )
    args = parser.parse_args()

    data_dir = args.data_dir

    print("=" * 72)
    print("TRAINING DATA VALIDATION REPORT")
    print("=" * 72)
    print(f"  Data directory: {data_dir}")

    # ---- Load data ----
    if not os.path.isdir(data_dir):
        print(f"\n  ERROR: Directory not found: {data_dir}", file=sys.stderr)
        sys.exit(1)

    rows = _load_all_csv(data_dir)
    csv_files = [f for f in os.listdir(data_dir) if f.endswith(".csv")] if os.path.isdir(data_dir) else []
    print(f"  CSV files found: {len(csv_files)}")
    print(f"  Total rows loaded: {len(rows)}")

    all_issues = []

    # ---- Check 1: Minimum samples ----
    c1 = check_minimum_samples(rows)
    _print_section("Check 1: Minimum Samples", c1)
    all_issues.extend(c1)

    # ---- Check 2: Class balance ----
    c2_result = check_class_balance(rows)
    c2 = c2_result[0] if isinstance(c2_result, tuple) else c2_result
    labeled_counts = c2_result[1] if isinstance(c2_result, tuple) and len(c2_result) > 1 else {}
    _print_section("Check 2: Class Balance", c2)
    if labeled_counts:
        print(f"    Class counts:")
        for cls in CLASS_NAMES:
            cnt = labeled_counts.get(cls, 0)
            bar = "#" * int(cnt / max(labeled_counts.values(), default=1) * 30) if labeled_counts else ""
            print(f"      {cls:<26} {cnt:>5}  {bar}")
        # Also print any unlabeled or unknown-class rows
        unknown = {k: v for k, v in labeled_counts.items() if k not in CLASS_NAMES}
        if unknown:
            for k, v in unknown.items():
                print(f"      {k:<26} {v:>5}  (unknown class)")
    all_issues.extend(c2)

    # ---- Check 3: Physical bounds ----
    c3 = check_physical_bounds(rows)
    _print_section("Check 3: Feature Physical Bounds", c3)
    all_issues.extend(c3)

    # ---- Check 4: Timestamp continuity ----
    c4 = check_timestamp_continuity(rows)
    _print_section("Check 4: Timestamp Continuity", c4)
    if c4:
        for issue in c4:
            gaps = issue.get("gaps", [])
            for g in gaps:
                print(f"      Gap: {g['gap_hours']:.1f}h between rows "
                      f"{g['row_before']} and {g['row_after']}")
    all_issues.extend(c4)

    # ---- Check 5: Duplicates ----
    c5 = check_duplicates(rows)
    _print_section("Check 5: Duplicate Detection", c5)
    all_issues.extend(c5)

    # ---- Check 6: NaN/null ----
    c6 = check_nan_null(rows)
    _print_section("Check 6: NaN/Null Detection", c6)
    all_issues.extend(c6)

    # ---- Check 7: Outliers ----
    c7 = check_outliers(rows)
    _print_section("Check 7: Statistical Outliers (>5 std)", c7)
    all_issues.extend(c7)

    # ---- Summary ----
    total_errors, total_warns = _count_by_level(all_issues)
    print()
    print("=" * 72)
    print("SUMMARY")
    print("=" * 72)
    print(f"  Total rows:   {len(rows)}")
    print(f"  Errors:       {total_errors}")
    print(f"  Warnings:     {total_warns}")
    print()

    if total_errors == 0 and total_warns == 0:
        print("  RESULT: PASS — data looks good for training.")
    elif total_errors > 0:
        print(f"  RESULT: FAIL — {total_errors} error(s) must be fixed before training.")
    else:
        if args.strict:
            print(f"  RESULT: FAIL (strict mode) — {total_warns} warning(s) found.")
        else:
            print(f"  RESULT: PASS with {total_warns} warning(s). Review before training.")

    # ---- Recommendations ----
    print()
    print("  Recommendations:")
    if total_errors == 0 and total_warns == 0:
        print("    - Data appears ready. Proceed with training.")
    else:
        if any(i.get("level") == "ERROR" and "minimum" in i.get("message", "").lower()
               for i in all_issues):
            print("    - Collect more field data before training.")
        if any(i.get("level") == "WARN" and "class" in i.get("message", "").lower()
               for i in all_issues):
            print("    - Collect more samples for under-represented classes.")
        if any(i.get("level") == "WARN" and "duplicate" in i.get("message", "").lower()
               for i in all_issues):
            print("    - Remove duplicate rows (e.g., with pandas drop_duplicates).")
        if any(i.get("level") == "WARN" and "gap" in i.get("message", "").lower()
               for i in all_issues):
            print("    - Review recording gaps — consider splitting into separate sessions.")
        if any(i.get("level") == "WARN" and "outlier" in i.get("message", "").lower()
               for i in all_issues):
            print("    - Inspect outlier rows — may be sensor glitches or valid extreme events.")
        if any(i.get("level") == "WARN" and "bounds" in i.get("message", "").lower()
               or "below" in i.get("message", "").lower()
               or "above" in i.get("message", "").lower()
               for i in all_issues):
            print("    - Check sensor calibration — some values exceed physical limits.")
        if any(i.get("level") in ("WARN", "ERROR") and "missing" in i.get("message", "").lower()
               for i in all_issues):
            print("    - Impute or drop rows with missing feature values.")

    print()

    # ---- Exit code ----
    if total_errors > 0:
        sys.exit(1)
    if args.strict and total_warns > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
