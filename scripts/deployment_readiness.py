#!/usr/bin/env python3
"""
deployment_readiness.py — Pre-deployment readiness checks for AncientVision.

Validates that the system is ready for field deployment:
  - ML model assets present and non-empty
  - Scaler files present and parseable as JSON
  - Required scripts exist
  - Docker Compose files present
  - Data directory accessible

Exits with code 0 if all checks pass, 1 if any check fails.
Outputs a GitHub Actions step summary when GITHUB_STEP_SUMMARY is set.
"""

import json
import os
import sys
from pathlib import Path
from typing import List, Tuple

# ---------------------------------------------------------------------------
# Check definitions  (label, path-or-callable, required)
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent

ASSET_DIR = ROOT / "app" / "assets" / "ml"
SCRIPTS_DIR = ROOT / "scripts"
DATA_DIR = ROOT / "data" / "field"


def check_file_exists(path: Path) -> Tuple[bool, str]:
    if path.exists() and path.stat().st_size > 0:
        size_kb = path.stat().st_size // 1024
        return True, f"OK  ({size_kb} KB)"
    if path.exists():
        return False, "FAIL (file is empty)"
    return False, "FAIL (not found)"


def check_json_parseable(path: Path) -> Tuple[bool, str]:
    if not path.exists():
        return False, "FAIL (not found)"
    try:
        with open(path, encoding="utf-8") as fh:
            json.load(fh)
        return True, "OK  (valid JSON)"
    except json.JSONDecodeError as exc:
        return False, f"FAIL (JSON error: {exc})"


def check_dir_exists(path: Path) -> Tuple[bool, str]:
    if path.is_dir():
        n = sum(1 for _ in path.iterdir())
        return True, f"OK  ({n} entries)"
    return False, "WARN (directory not found — will be created on first collection)"


# ---------------------------------------------------------------------------
# Checks table
# ---------------------------------------------------------------------------

CHECKS: List[Tuple[str, callable, bool]] = [
    # (label, checker_lambda, is_fatal)
    ("ML model: precursor_classifier.tflite",
     lambda: check_file_exists(ASSET_DIR / "precursor_classifier.tflite"), True),
    ("ML model: ml_anomaly_model.tflite",
     lambda: check_file_exists(ASSET_DIR / "ml_anomaly_model.tflite"), True),
    ("Scaler:   precursor_scaler.json",
     lambda: check_json_parseable(ASSET_DIR / "precursor_scaler.json"), True),
    ("Scaler:   anomaly_scaler.json",
     lambda: check_json_parseable(ASSET_DIR / "anomaly_scaler.json"), False),
    ("Script:   run_pipeline.py",
     lambda: check_file_exists(SCRIPTS_DIR / "run_pipeline.py"), True),
    ("Script:   health_check.py",
     lambda: check_file_exists(SCRIPTS_DIR / "health_check.py"), True),
    ("Script:   field_report.py",
     lambda: check_file_exists(SCRIPTS_DIR / "field_report.py"), False),
    ("Compose:  docker-compose.yml",
     lambda: check_file_exists(ROOT / "docker-compose.yml"), True),
    ("Compose:  docker-compose.collect.yml",
     lambda: check_file_exists(ROOT / "docker-compose.collect.yml"), True),
    ("Compose:  docker-compose.train.yml",
     lambda: check_file_exists(ROOT / "docker-compose.train.yml"), True),
    ("Data dir: data/field",
     lambda: check_dir_exists(DATA_DIR), False),
]


def run_checks() -> Tuple[List[dict], int]:
    results = []
    failures = 0
    for label, checker, is_fatal in CHECKS:
        ok, detail = checker()
        if not ok and is_fatal:
            failures += 1
        results.append({"label": label, "ok": ok, "detail": detail, "fatal": is_fatal})
    return results, failures


def print_results(results: List[dict], failures: int) -> None:
    print()
    print("AncientVision — Deployment Readiness Check")
    print("=" * 60)
    for r in results:
        icon = "PASS" if r["ok"] else ("FAIL" if r["fatal"] else "WARN")
        print(f"  [{icon:4s}]  {r['label']:<44}  {r['detail']}")
    print()
    if failures == 0:
        print("Result: READY FOR DEPLOYMENT")
    else:
        print(f"Result: NOT READY  ({failures} fatal check(s) failed)")
    print()


def write_step_summary(results: List[dict], failures: int) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    lines = [
        "## AncientVision Deployment Readiness Check\n",
        "| Status | Check | Detail |",
        "| ------ | ----- | ------ |",
    ]
    for r in results:
        if r["ok"]:
            icon = ":white_check_mark:"
        elif r["fatal"]:
            icon = ":x:"
        else:
            icon = ":warning:"
        lines.append(f"| {icon} | {r['label']} | {r['detail']} |")

    lines.append("")
    if failures == 0:
        lines.append("**Result: READY FOR DEPLOYMENT** :rocket:")
    else:
        lines.append(f"**Result: NOT READY** — {failures} fatal check(s) failed :stop_sign:")

    with open(summary_path, "a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main() -> int:
    results, failures = run_checks()
    print_results(results, failures)
    write_step_summary(results, failures)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
