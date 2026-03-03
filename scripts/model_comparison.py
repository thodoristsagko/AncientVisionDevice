#!/usr/bin/env python3
"""Compare ML model versions from training metrics JSON files.

Reads all precursor_training_metrics.json snapshots (if archived) and
the current one, printing a comparison table.

Usage:
    python scripts/model_comparison.py
"""
import json, os, glob, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")
ARCHIVE_DIR = os.path.join(REPO_DIR, "data", "model_archive")

def load_metrics(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def main():
    metrics_files = []
    current = os.path.join(ASSETS_DIR, "precursor_training_metrics.json")
    if os.path.isfile(current):
        m = load_metrics(current)
        if m:
            m["_source"] = "current"
            metrics_files.append(m)

    for f in sorted(glob.glob(os.path.join(ARCHIVE_DIR, "**", "precursor_training_metrics.json"), recursive=True)):
        m = load_metrics(f)
        if m:
            m["_source"] = os.path.relpath(f, REPO_DIR)
            metrics_files.append(m)

    if not metrics_files:
        print("No training metrics found.")
        print(f"  Current metrics: {current}")
        print(f"  Archive: {ARCHIVE_DIR}")
        return

    print(f"\nModel Version Comparison ({len(metrics_files)} version(s) found):\n")
    print(f"  {'Version/Source':<40} {'Date':<22} {'Samples':>8} {'CV_Acc':>8} {'Holdout':>8}")
    print("  " + "-"*90)
    for m in metrics_files:
        source = m.get("_source", "?")[:40]
        date = m.get("trained_at", "?")[:21]
        n = m.get("total_samples", "?")
        cv = m.get("cv_mean_accuracy", m.get("cv_accuracy_mean", "?"))
        holdout = m.get("holdout_accuracy", "?")
        cv_str = f"{cv:.4f}" if isinstance(cv, float) else str(cv)
        holdout_str = f"{holdout:.4f}" if isinstance(holdout, float) else str(holdout)
        print(f"  {source:<40} {date:<22} {str(n):>8} {cv_str:>8} {holdout_str:>8}")
    print()

if __name__ == "__main__":
    main()
