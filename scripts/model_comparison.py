#!/usr/bin/env python3
"""Compare ML model versions from training metrics JSON files.

Reads all precursor_training_metrics.json snapshots (if archived) and
the current one, printing a comparison table with confusion matrices,
per-class F1 scores, statistical significance, and model sizes.

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

def get_tflite_size_kb(model_name):
    """Return .tflite file size in KB, or None if not found."""
    tflite_path = os.path.join(ASSETS_DIR, model_name)
    if os.path.isfile(tflite_path):
        return os.path.getsize(tflite_path) / 1024.0
    return None

def print_confusion_matrix(cm, class_names):
    """Print ASCII confusion matrix."""
    if not cm or not class_names:
        return

    # Find max width for alignment
    max_name = max(len(c) for c in class_names) if class_names else 10
    col_w = max(6, max_name + 1)

    # Header
    print("\n    Confusion Matrix:")
    header = "    " + " " * col_w + "  ".join(f"{c[:col_w]:>{col_w}}" for c in class_names)
    print(header)
    print("    " + "-" * (len(header) - 4))

    # Rows
    for i, row_name in enumerate(class_names):
        if i < len(cm):
            row_vals = cm[i]
            row_str = f"    {row_name[:col_w]:<{col_w}}"
            for val in row_vals:
                row_str += f"  {val:>{col_w}}"
            print(row_str)

def print_per_class_f1(f1_scores, class_names):
    """Print per-class F1 scores in a simple format."""
    if not f1_scores or not class_names:
        return

    print("\n    Per-Class F1 Scores:")
    for i, name in enumerate(class_names):
        if i < len(f1_scores):
            score = f1_scores[i]
            if isinstance(score, (int, float)):
                bar_width = int(score * 20)
                bar = "█" * bar_width + "░" * (20 - bar_width)
                print(f"    {name:<20} {score:>6.4f}  {bar}")

def check_statistical_significance(acc1, acc2, threshold=0.02):
    """Check if accuracy difference is statistically significant."""
    if isinstance(acc1, (int, float)) and isinstance(acc2, (int, float)):
        diff = abs(acc1 - acc2)
        if diff <= threshold:
            return f"Not statistically significant (diff={diff:.4f})"
        return f"Statistically significant (diff={diff:.4f})"
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

    # Per-model details
    class_names = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]

    for idx, m in enumerate(metrics_files):
        source = m.get("_source", "?")[:40]
        print(f"\nDetailed Metrics for: {source}")
        print("-" * 70)

        # Confusion matrix
        cm = m.get("confusion_matrix")
        if cm:
            print_confusion_matrix(cm, class_names)

        # Per-class F1 scores
        f1_scores = m.get("f1_scores")
        if f1_scores:
            print_per_class_f1(f1_scores, class_names)

        # Model size
        tflite_size = get_tflite_size_kb("precursor_classifier.tflite")
        if tflite_size:
            print(f"\n    Model Size: {tflite_size:.1f} KB")

        # Complexity estimate
        n_samples = m.get("total_samples")
        n_features = len(m.get("feature_names", []))
        if n_samples and n_features:
            print(f"    Complexity: {n_features} features, {n_samples} samples")

    # Pairwise significance tests
    if len(metrics_files) >= 2:
        print("\n" + "=" * 70)
        print("STATISTICAL SIGNIFICANCE TESTS (2% threshold)")
        print("=" * 70)
        for i in range(len(metrics_files) - 1):
            m1 = metrics_files[i]
            m2 = metrics_files[i + 1]
            source1 = m1.get("_source", "?")[:30]
            source2 = m2.get("_source", "?")[:30]
            acc1 = m1.get("holdout_accuracy")
            acc2 = m2.get("holdout_accuracy")
            sig = check_statistical_significance(acc1, acc2)
            if sig:
                print(f"\n  {source1} vs {source2}:")
                print(f"    {sig}")

    print()

if __name__ == "__main__":
    main()
