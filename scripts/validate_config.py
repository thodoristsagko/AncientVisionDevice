#!/usr/bin/env python3
"""Validate all JSON config/scaler/metrics files in the ML assets directory.

Usage:
    python scripts/validate_config.py
    python scripts/validate_config.py --assets-dir app/assets/ml

Validation rules:
  *_config.json          — must have 'feature_names' (list) and 'version' keys
  *_scaler.json          — must have 'mean' (list) and 'std' (list) keys;
                           lengths must match the paired *_config.json
  *_training_metrics.json — must have 'trained_at', 'total_samples',
                            'holdout_accuracy' keys
  Cross-check            — config feature_names length == scaler mean/std length

Prints a status table (PASS / FAIL + reason). Exits with code 1 if any file
fails validation.

Uses only stdlib — no external packages required.
"""

import argparse
import json
import os
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_ASSETS_DIR = "app/assets/ml"

STATUS_PASS = "PASS"
STATUS_FAIL = "FAIL"
STATUS_SKIP = "SKIP"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_json(path: str) -> tuple:
    """Return (data_dict, error_string). error_string is None on success."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data, None
    except (OSError, json.JSONDecodeError) as exc:
        return None, str(exc)


def _check_list_key(data: dict, key: str) -> str | None:
    """Return error string if key is missing or not a list, else None."""
    if key not in data:
        return f"missing key '{key}'"
    if not isinstance(data[key], list):
        return f"'{key}' must be a list, got {type(data[key]).__name__}"
    return None


def _check_scalar_key(data: dict, key: str) -> str | None:
    """Return error string if key is missing, else None."""
    if key not in data:
        return f"missing key '{key}'"
    return None


# ---------------------------------------------------------------------------
# Per-type validators
# ---------------------------------------------------------------------------

def validate_config(data: dict) -> list:
    """Return list of error strings for a *_config.json file."""
    errors = []
    err = _check_list_key(data, "feature_names")
    if err:
        errors.append(err)
    err = _check_scalar_key(data, "version")
    if err:
        errors.append(err)
    return errors


def validate_scaler(data: dict) -> list:
    """Return list of error strings for a *_scaler.json file."""
    errors = []
    err_mean = _check_list_key(data, "mean")
    err_std = _check_list_key(data, "std")
    if err_mean:
        errors.append(err_mean)
    if err_std:
        errors.append(err_std)
    if not err_mean and not err_std:
        if len(data["mean"]) != len(data["std"]):
            errors.append(
                f"'mean' length ({len(data['mean'])}) != 'std' length ({len(data['std'])})"
            )
    return errors


def validate_training_metrics(data: dict) -> list:
    """Return list of error strings for a *_training_metrics.json file."""
    errors = []
    for key in ("trained_at", "total_samples", "holdout_accuracy"):
        err = _check_scalar_key(data, key)
        if err:
            errors.append(err)
    return errors


# ---------------------------------------------------------------------------
# Cross-checks
# ---------------------------------------------------------------------------

def cross_check_config_scaler(
    config_data: dict,
    scaler_data: dict,
    config_name: str,
    scaler_name: str,
) -> list:
    """Return list of cross-check error strings."""
    errors = []
    feature_names = config_data.get("feature_names")
    scaler_mean = scaler_data.get("mean")
    scaler_std = scaler_data.get("std")

    if not isinstance(feature_names, list) or not isinstance(scaler_mean, list):
        return errors  # already caught by individual validators

    n_features = len(feature_names)
    if len(scaler_mean) != n_features:
        errors.append(
            f"cross-check {config_name}<>{scaler_name}: "
            f"feature_names length ({n_features}) != scaler mean length ({len(scaler_mean)})"
        )
    if isinstance(scaler_std, list) and len(scaler_std) != n_features:
        errors.append(
            f"cross-check {config_name}<>{scaler_name}: "
            f"feature_names length ({n_features}) != scaler std length ({len(scaler_std)})"
        )
    return errors


# ---------------------------------------------------------------------------
# Main validation runner
# ---------------------------------------------------------------------------

def validate_directory(assets_dir: str) -> int:
    """Validate all JSON files in assets_dir.

    Returns:
        Exit code — 0 if all pass, 1 if any fail.
    """
    if not os.path.isdir(assets_dir):
        print(f"Error: assets directory not found: {assets_dir}", file=sys.stderr)
        return 1

    json_files = sorted(
        f for f in os.listdir(assets_dir) if f.endswith(".json")
    )

    if not json_files:
        print(f"No JSON files found in '{assets_dir}'.")
        return 0

    # Collect results: list of (filename, status, reason)
    results = []
    # Also collect parsed data for cross-checks
    parsed: dict = {}  # filename -> data dict

    for fname in json_files:
        fpath = os.path.join(assets_dir, fname)
        data, load_err = _load_json(fpath)
        if load_err:
            results.append((fname, STATUS_FAIL, f"JSON parse error: {load_err}"))
            parsed[fname] = None
            continue

        parsed[fname] = data

        if "_config.json" in fname:
            errors = validate_config(data)
        elif "_scaler.json" in fname:
            errors = validate_scaler(data)
        elif "_training_metrics.json" in fname:
            errors = validate_training_metrics(data)
        else:
            results.append((fname, STATUS_SKIP, "no validation rule for this filename pattern"))
            continue

        if errors:
            results.append((fname, STATUS_FAIL, "; ".join(errors)))
        else:
            results.append((fname, STATUS_PASS, ""))

    # ---- Cross-checks: pair each *_config.json with its *_scaler.json -----
    cross_errors = []
    for fname in json_files:
        if "_config.json" not in fname:
            continue
        # Derive expected scaler filename by replacing _config with _scaler
        scaler_name = fname.replace("_config.json", "_scaler.json")
        if scaler_name not in parsed:
            continue  # no paired scaler — not an error here
        config_data = parsed.get(fname)
        scaler_data = parsed.get(scaler_name)
        if config_data is None or scaler_data is None:
            continue  # already failed to parse
        errs = cross_check_config_scaler(config_data, scaler_data, fname, scaler_name)
        cross_errors.extend(errs)

    # ---- Print results table -----------------------------------------------
    col_file = max(len(f) for f in json_files) + 2
    col_file = max(col_file, 30)
    col_status = 6

    print(f"\nValidation results for: {assets_dir}")
    print(f"{'File':<{col_file}}{'Status':<{col_status}}  Reason")
    print("-" * (col_file + col_status + 40))

    any_fail = False
    for fname, status, reason in results:
        if status == STATUS_FAIL:
            any_fail = True
        print(f"{fname:<{col_file}}{status:<{col_status}}  {reason}")

    # Cross-check summary
    if cross_errors:
        any_fail = True
        print()
        print("Cross-check failures:")
        for err in cross_errors:
            print(f"  FAIL  {err}")

    # Summary line
    n_pass = sum(1 for _, s, _ in results if s == STATUS_PASS)
    n_fail = sum(1 for _, s, _ in results if s == STATUS_FAIL)
    n_skip = sum(1 for _, s, _ in results if s == STATUS_SKIP)
    print()
    print(
        f"Summary: {n_pass} passed, {n_fail} failed, {n_skip} skipped"
        + (f", {len(cross_errors)} cross-check error(s)" if cross_errors else "")
    )
    print()

    return 1 if any_fail else 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate JSON config/scaler/metrics files in the ML assets directory."
    )
    parser.add_argument(
        "--assets-dir",
        default=DEFAULT_ASSETS_DIR,
        metavar="DIR",
        help=f"Path to the ML assets directory (default: {DEFAULT_ASSETS_DIR}).",
    )
    args = parser.parse_args()

    exit_code = validate_directory(args.assets_dir)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
