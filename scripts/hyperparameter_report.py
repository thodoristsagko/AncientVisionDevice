#!/usr/bin/env python3
"""
hyperparameter_report.py — Report ML model hyperparameters and best practice assessment.

Usage:
    python scripts/hyperparameter_report.py [--model-dir DIR]

Reads train_precursor_classifier.py and extracts hyperparameters by scanning
for specific patterns. Compares against recommended values for this problem size.
Outputs a table: Parameter | Current Value | Recommended | Status (OK/WARN/NOTE)
"""

import argparse
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_TRAIN_SCRIPT = os.path.join(SCRIPT_DIR, "train_precursor_classifier.py")


# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------

def _first_int(text: str, *patterns: str) -> int | None:
    """Return the first integer match found for any of the given regex patterns."""
    for pat in patterns:
        m = re.search(pat, text)
        if m:
            try:
                return int(m.group(1))
            except (ValueError, IndexError):
                pass
    return None


def _first_float(text: str, *patterns: str) -> float | None:
    """Return the first float match found for any of the given regex patterns."""
    for pat in patterns:
        m = re.search(pat, text)
        if m:
            try:
                return float(m.group(1))
            except (ValueError, IndexError):
                pass
    return None


def extract_hyperparameters(source: str) -> dict:
    """
    Extract key hyperparameters from train_precursor_classifier.py source text.

    Returns a dict mapping parameter name -> extracted value (or None if not found).
    """
    params = {}

    # EPOCHS / epochs=
    params["epochs"] = _first_int(
        source,
        r"EPOCHS\s*=\s*(\d+)",
        r"epochs\s*=\s*(\d+)",
    )

    # BATCH_SIZE / batch_size=
    params["batch_size"] = _first_int(
        source,
        r"BATCH_SIZE\s*=\s*(\d+)",
        r"batch_size\s*=\s*(\d+)",
    )

    # learning_rate / lr=
    params["learning_rate"] = _first_float(
        source,
        r"learning_rate\s*=\s*([0-9]+\.?[0-9]*(?:e[+-]?\d+)?)",
        r"\blr\s*=\s*([0-9]+\.?[0-9]*(?:e[+-]?\d+)?)",
    )

    # PATIENCE (early stopping)
    params["patience"] = _first_int(
        source,
        r"PATIENCE\s*=\s*(\d+)",
        r"patience\s*=\s*(\d+)",
    )

    # n_splits (CV folds)
    params["cv_folds"] = _first_int(
        source,
        r"n_splits\s*=\s*(\d+)",
        r"N_SPLITS\s*=\s*(\d+)",
    )

    # Dense layer sizes — collect all Dense(<int> occurrences
    dense_matches = re.findall(r"Dense\s*\(\s*(\d+)", source)
    if dense_matches:
        params["hidden_layers"] = [int(v) for v in dense_matches]
    else:
        params["hidden_layers"] = None

    # L2 regularization value
    params["l2_reg"] = _first_float(
        source,
        r"l2\s*\(\s*([0-9]+\.?[0-9]*(?:e[+-]?\d+)?)\s*\)",
        r"L2\s*=\s*([0-9]+\.?[0-9]*(?:e[+-]?\d+)?)",
        r"l2_reg\s*=\s*([0-9]+\.?[0-9]*(?:e[+-]?\d+)?)",
    )

    return params


# ---------------------------------------------------------------------------
# Assessment
# ---------------------------------------------------------------------------

# Status codes
OK = "OK"
WARN = "WARN"
NOTE = "NOTE"


def _assess(val, ok_range, warn_range=None, note_val=None) -> str:
    """
    Return status string given value and ranges.
    ok_range: (lo, hi) inclusive — value in range → OK
    warn_range: if provided and value outside → WARN
    note_val: if provided and value != note_val → NOTE
    """
    if val is None:
        return NOTE
    if note_val is not None:
        return OK if val == note_val else NOTE
    lo, hi = ok_range
    if lo <= val <= hi:
        return OK
    if warn_range is not None:
        wlo, whi = warn_range
        if wlo <= val <= whi:
            return NOTE
    return WARN


def assess_parameters(params: dict) -> list:
    """
    Return list of (parameter, current_value_str, recommended_str, status) tuples.
    Recommended values are for a ~10k-sample, 17-feature, 4-class problem.
    """
    rows = []

    # epochs
    ep = params.get("epochs")
    ep_str = str(ep) if ep is not None else "not found"
    ep_rec = "100-500"
    if ep is None:
        ep_status = NOTE
    elif ep < 50 or ep > 1000:
        ep_status = WARN
    else:
        ep_status = OK
    rows.append(("epochs", ep_str, ep_rec, ep_status))

    # batch_size
    bs = params.get("batch_size")
    bs_str = str(bs) if bs is not None else "not found"
    bs_rec = "32-128"
    if bs is None:
        bs_status = NOTE
    elif bs < 8 or bs > 512:
        bs_status = WARN
    else:
        bs_status = OK
    rows.append(("batch_size", bs_str, bs_rec, bs_status))

    # learning_rate
    lr = params.get("learning_rate")
    lr_str = f"{lr:.6g}" if lr is not None else "not found"
    lr_rec = "0.0001-0.01"
    if lr is None:
        lr_status = NOTE
    elif lr > 0.1:
        lr_status = WARN
    else:
        lr_status = OK
    rows.append(("learning_rate", lr_str, lr_rec, lr_status))

    # patience
    pat = params.get("patience")
    pat_str = str(pat) if pat is not None else "not found"
    pat_rec = "10-30"
    if pat is None:
        pat_status = NOTE
    elif pat < 5:
        pat_status = WARN
    else:
        pat_status = OK
    rows.append(("patience", pat_str, pat_rec, pat_status))

    # cv_folds
    cv = params.get("cv_folds")
    cv_str = str(cv) if cv is not None else "not found"
    cv_rec = "5"
    if cv is None:
        cv_status = NOTE
    elif cv == 5:
        cv_status = OK
    else:
        cv_status = NOTE
    rows.append(("cv_folds", cv_str, cv_rec, cv_status))

    # hidden_layers
    hl = params.get("hidden_layers")
    hl_str = str(hl) if hl is not None else "not found"
    hl_rec = "e.g. [128,64] or [256,128,64]"
    hl_status = OK if hl is not None else NOTE
    rows.append(("hidden_layers", hl_str, hl_rec, hl_status))

    # l2_reg
    l2 = params.get("l2_reg")
    l2_str = f"{l2:.6g}" if l2 is not None else "not found"
    l2_rec = "0.0001-0.01"
    l2_status = OK if l2 is not None else NOTE
    rows.append(("l2_reg", l2_str, l2_rec, l2_status))

    return rows


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def render_table(rows: list) -> str:
    """Render assessment rows as an ASCII table."""
    headers = ["Parameter", "Current Value", "Recommended", "Status"]
    col_widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            col_widths[i] = max(col_widths[i], len(str(cell)))

    sep = "+-" + "-+-".join("-" * w for w in col_widths) + "-+"
    fmt = "| " + " | ".join(f"{{:<{w}}}" for w in col_widths) + " |"

    lines = [sep, fmt.format(*headers), sep]
    for r in rows:
        lines.append(fmt.format(*[str(c) for c in r]))
    lines.append(sep)
    return "\n".join(lines)


def render_summary(rows: list) -> str:
    """Return a one-line summary string."""
    warns = sum(1 for r in rows if r[3] == WARN)
    notes = sum(1 for r in rows if r[3] == NOTE)
    verdict = "GOOD" if warns == 0 else "NEEDS_REVIEW"
    return f"{warns} warnings, {notes} notes — model config looks {verdict}"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Report ML model hyperparameters and best practice assessment."
    )
    parser.add_argument(
        "--model-dir",
        default=SCRIPT_DIR,
        help="Directory to look for train_precursor_classifier.py (default: scripts/)",
    )
    args = parser.parse_args(argv)

    train_script = os.path.join(args.model_dir, "train_precursor_classifier.py")
    # Also check the canonical scripts/ path when --model-dir points to assets
    if not os.path.isfile(train_script):
        train_script = DEFAULT_TRAIN_SCRIPT

    if not os.path.isfile(train_script):
        print("train_precursor_classifier.py not found")
        return 0

    try:
        source = Path(train_script).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"Could not read {train_script}: {exc}")
        return 0

    params = extract_hyperparameters(source)
    rows = assess_parameters(params)

    print(f"\nHyperparameter Report — {os.path.basename(train_script)}")
    print(render_table(rows))
    print(render_summary(rows))
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
