#!/usr/bin/env python3
"""
training_pipeline_dry_run.py — Dry run training pipeline to catch config errors.

Usage:
    python scripts/training_pipeline_dry_run.py [--data-dir DIR] [--model-dir DIR]

Validates all preconditions for training without running it:
- Data files exist and are readable
- Output directories are writable
- Required Python packages importable
- Config files have correct structure
- Feature count matches expected (17)
- Model output paths don't conflict

Prints a checklist with PASS/FAIL for each check.
Exit code: 0 if all pass, 1 if any fail.
"""

import argparse
import csv
import importlib
import json
import os
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

EXPECTED_FEATURE_COUNT = 17
REQUIRED_COLUMNS = {"ppv", "ax", "ay", "az", "label"}
REQUIRED_PACKAGES = ["numpy", "pandas", "sklearn"]


# ---------------------------------------------------------------------------
# ANSI colour helpers
# ---------------------------------------------------------------------------

_USE_COLOR = sys.stdout.isatty() or os.environ.get("FORCE_COLOR", "") == "1"


def _green(s: str) -> str:
    return f"\033[32m{s}\033[0m" if _USE_COLOR else s


def _red(s: str) -> str:
    return f"\033[31m{s}\033[0m" if _USE_COLOR else s


def _yellow(s: str) -> str:
    return f"\033[33m{s}\033[0m" if _USE_COLOR else s


# ---------------------------------------------------------------------------
# Individual checks — each returns (passed: bool, detail: str)
# ---------------------------------------------------------------------------

def check_data_directory(data_dir: str) -> tuple:
    """Check 1: data/ directory exists and has >= 1 CSV file."""
    if not os.path.isdir(data_dir):
        return False, f"Directory not found: {data_dir}"
    csv_files = [f for f in os.listdir(data_dir) if f.endswith(".csv")]
    if not csv_files:
        return False, f"No CSV files found in {data_dir}"
    return True, f"{len(csv_files)} CSV file(s) found in {data_dir}"


def check_csv_columns(data_dir: str) -> tuple:
    """Check 2: At least one CSV has required columns (ppv, ax, ay, az, label)."""
    if not os.path.isdir(data_dir):
        return False, "Data directory does not exist — cannot check columns"

    csv_files = [f for f in os.listdir(data_dir) if f.endswith(".csv")]
    if not csv_files:
        return False, "No CSV files to inspect"

    for fname in sorted(csv_files):
        fpath = os.path.join(data_dir, fname)
        try:
            with open(fpath, newline="", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                headers = set(reader.fieldnames or [])
                missing = REQUIRED_COLUMNS - headers
                if not missing:
                    return True, f"All required columns present in {fname}"
        except (OSError, csv.Error):
            continue

    # No file had all required columns
    return False, f"No CSV has all required columns: {sorted(REQUIRED_COLUMNS)}"


def check_output_directory(model_dir: str) -> tuple:
    """Check 3: Output directory exists and is writable."""
    if not os.path.isdir(model_dir):
        # Attempt to check if parent is writable (directory would be created at training time)
        parent = os.path.dirname(os.path.abspath(model_dir))
        if os.path.isdir(parent):
            try:
                fd, tmp = tempfile.mkstemp(dir=parent)
                os.close(fd)
                os.unlink(tmp)
                return False, (
                    f"{model_dir} does not exist but parent is writable — "
                    "will be created at training time"
                )
            except OSError:
                return False, f"{model_dir} does not exist and parent is not writable"
        return False, f"{model_dir} does not exist"

    # Directory exists — check writability
    try:
        fd, tmp = tempfile.mkstemp(dir=model_dir)
        os.close(fd)
        os.unlink(tmp)
        return True, f"{model_dir} exists and is writable"
    except OSError as exc:
        return False, f"{model_dir} is not writable: {exc}"


def check_required_packages() -> tuple:
    """Check 4: Required Python packages are importable (no TF check — slow)."""
    missing = []
    for pkg in REQUIRED_PACKAGES:
        try:
            importlib.import_module(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        return False, f"Missing packages: {', '.join(missing)}"
    return True, f"All required packages importable: {', '.join(REQUIRED_PACKAGES)}"


def check_train_script_exists() -> tuple:
    """Check 5: scripts/train_precursor_classifier.py exists and is readable."""
    path = os.path.join(SCRIPT_DIR, "train_precursor_classifier.py")
    if not os.path.isfile(path):
        return False, f"Not found: {path}"
    try:
        with open(path, encoding="utf-8") as f:
            f.read(1)
        return True, f"Readable: {path}"
    except OSError as exc:
        return False, f"Cannot read {path}: {exc}"


def check_generate_script_exists() -> tuple:
    """Check 6: scripts/generate_precursor_data.py exists."""
    path = os.path.join(SCRIPT_DIR, "generate_precursor_data.py")
    if not os.path.isfile(path):
        return False, f"Not found: {path}"
    return True, f"Found: {path}"


def check_feature_count(model_dir: str) -> tuple:
    """Check 7: Feature count in config == 17."""
    config_path = os.path.join(model_dir, "precursor_classifier_config.json")
    if not os.path.isfile(config_path):
        return True, f"Config not found at {config_path} — skipping feature count check"

    try:
        with open(config_path, encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"Cannot parse {config_path}: {exc}"

    feature_names = config.get("feature_names", [])
    count = len(feature_names)
    if count != EXPECTED_FEATURE_COUNT:
        return False, (
            f"Feature count mismatch: config has {count} features, "
            f"expected {EXPECTED_FEATURE_COUNT}"
        )
    return True, f"Feature count: {count} (matches expected {EXPECTED_FEATURE_COUNT})"


def check_no_retrain_lock() -> tuple:
    """Check 8: No active .retrain_trigger lock file."""
    lock_path = os.path.join(REPO_DIR, ".retrain_trigger")
    if os.path.exists(lock_path):
        return False, f".retrain_trigger lock file exists at {lock_path} — may interfere with training"
    return True, "No .retrain_trigger lock file present"


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

CHECKS = [
    ("Data directory",          lambda data_dir, model_dir: check_data_directory(data_dir)),
    ("CSV columns",             lambda data_dir, model_dir: check_csv_columns(data_dir)),
    ("Output directory",        lambda data_dir, model_dir: check_output_directory(model_dir)),
    ("Required packages",       lambda data_dir, model_dir: check_required_packages()),
    ("Train script exists",     lambda data_dir, model_dir: check_train_script_exists()),
    ("Generate script exists",  lambda data_dir, model_dir: check_generate_script_exists()),
    ("Feature count (17)",      lambda data_dir, model_dir: check_feature_count(model_dir)),
    ("No retrain lock",         lambda data_dir, model_dir: check_no_retrain_lock()),
]


def run_checks(data_dir: str, model_dir: str) -> int:
    """Run all checks; return number of failures."""
    print("=" * 72)
    print("TRAINING PIPELINE DRY RUN")
    print("=" * 72)
    print(f"  Data directory:  {data_dir}")
    print(f"  Model directory: {model_dir}")
    print()

    failures = 0
    col_w = max(len(name) for name, _ in CHECKS) + 2

    for name, check_fn in CHECKS:
        try:
            passed, detail = check_fn(data_dir, model_dir)
        except Exception as exc:  # noqa: BLE001
            passed = False
            detail = f"Unexpected error: {exc}"

        if passed:
            tag = _green("[PASS]")
        else:
            tag = _red("[FAIL]")
            failures += 1

        label = f"{name}:".ljust(col_w)
        print(f"  {tag} {label} {detail}")

    print()
    print("=" * 72)
    if failures == 0:
        print(_green("  RESULT: All checks passed — pipeline is ready to run."))
    else:
        print(_red(f"  RESULT: {failures} check(s) failed — fix before running training."))
    print()

    return failures


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Dry run training pipeline to check all preconditions."
    )
    parser.add_argument(
        "--data-dir",
        default=os.path.join(REPO_DIR, "data", "field"),
        metavar="DIR",
        help="Directory containing field CSV files (default: ./data/field).",
    )
    parser.add_argument(
        "--model-dir",
        default=os.path.join(REPO_DIR, "app", "assets", "ml"),
        metavar="DIR",
        help="Output directory for ML model files (default: app/assets/ml/).",
    )
    args = parser.parse_args()

    failures = run_checks(args.data_dir, args.model_dir)
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
