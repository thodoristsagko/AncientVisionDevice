#!/usr/bin/env python3
"""
Pipeline Status Report — AncientVision system-wide health summary.

Usage:
    python scripts/pipeline_status.py
    python scripts/pipeline_status.py --data-dir ./data
    python scripts/pipeline_status.py --assets-dir app/assets/ml

Prints a formatted status report covering:
- ML model versions and configuration
- Training data statistics
- Field data summary
- System health checks
- Recommendations
"""

import argparse
import csv
import io
import json
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

# Force UTF-8 output on Windows
if sys.platform == "win32":
    try:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    except Exception:
        pass

# Suppress TensorFlow warnings
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"


# Constants
DEFAULT_DATA_DIR = "./data"
DEFAULT_ASSETS_DIR = "./app/assets/ml"
MODEL_AGE_WARNING_DAYS = 7


def _load_json_safe(file_path: str) -> dict:
    """Load JSON file safely, return empty dict on error."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _format_bytes(num_bytes: int) -> str:
    """Format bytes to human-readable format."""
    for unit in ["B", "KB", "MB", "GB"]:
        if num_bytes < 1024:
            return f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024
    return f"{num_bytes:.1f} TB"


def _get_file_age_days(file_path: str) -> float:
    """Get age of file in days. Returns -1 if file doesn't exist."""
    try:
        stat = os.stat(file_path)
        age_seconds = (datetime.now().timestamp() - stat.st_mtime)
        return age_seconds / (24 * 3600)
    except OSError:
        return -1


def _print_section_header(title: str) -> None:
    """Print a formatted section header."""
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)


def _print_subsection(title: str) -> None:
    """Print a subsection header."""
    print(f"\n{title}:")


def _count_samples_in_csv(csv_path: str) -> dict:
    """Count samples in a CSV file by label. Returns dict {label: count}."""
    label_counts = defaultdict(int)
    try:
        with open(csv_path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                label = row.get("label", "").strip() or "(unlabeled)"
                label_counts[label] += 1
    except (OSError, csv.Error):
        pass
    return dict(label_counts)


def _build_bar_chart(data: dict, max_width: int = 40) -> list:
    """Build ASCII bar chart lines from dict {label: count}."""
    lines = []
    if not data:
        lines.append("  (no data)")
        return lines

    max_count = max(data.values()) if data else 1
    total = sum(data.values())

    for label in sorted(data.keys()):
        count = data[label]
        pct = (count / total * 100) if total > 0 else 0
        bar_width = int(count / max_count * max_width) if max_count > 0 else 0
        bar = "█" * bar_width
        lines.append(f"  {label:25s} {bar:<{max_width}} {count:5d} ({pct:5.1f}%)")

    return lines


def section_ml_models(assets_dir: str) -> None:
    """Print ML Models section."""
    _print_section_header("1. ML Models")

    assets_path = Path(assets_dir)
    if not assets_path.exists():
        print(f"  [ERROR] Assets directory not found: {assets_dir}")
        return

    # Precursor classifier
    _print_subsection("Precursor Classifier")
    precursor_config_path = assets_path / "precursor_classifier_config.json"
    precursor_tflite_path = assets_path / "precursor_classifier.tflite"

    if precursor_config_path.exists():
        config = _load_json_safe(str(precursor_config_path))
        print(f"  Version          : {config.get('model_version', 'N/A')}")
        print(f"  Feature count    : {config.get('input_dim', 'N/A')}")
        print(f"  Classes          : {', '.join(config.get('class_names', []))}")

        if precursor_tflite_path.exists():
            size = precursor_tflite_path.stat().st_size
            age_days = _get_file_age_days(str(precursor_tflite_path))
            print(f"  TFLite file      : {_format_bytes(size)}")
            print(f"  Age              : {age_days:.1f} days", end="")
            if age_days > MODEL_AGE_WARNING_DAYS:
                print(" (⚠ older than 7 days)")
            else:
                print()
        else:
            print(f"  TFLite file      : [MISSING] {precursor_tflite_path.name}")
    else:
        print(f"  [MISSING] Config file: {precursor_config_path.name}")

    # Vibration anomaly detector
    _print_subsection("Vibration Anomaly Detector")
    vibration_config_path = assets_path / "vibration_model_config.json"
    vibration_tflite_path = assets_path / "vibration_anomaly.tflite"

    if vibration_config_path.exists():
        config = _load_json_safe(str(vibration_config_path))
        print(f"  Version          : {config.get('model_version', 'N/A')}")
        print(f"  Type             : {config.get('model_type', 'N/A')}")
        print(f"  Input dim        : {config.get('input_dim', 'N/A')}")

        if vibration_tflite_path.exists():
            size = vibration_tflite_path.stat().st_size
            age_days = _get_file_age_days(str(vibration_tflite_path))
            print(f"  TFLite file      : {_format_bytes(size)}")
            print(f"  Age              : {age_days:.1f} days", end="")
            if age_days > MODEL_AGE_WARNING_DAYS:
                print(" (⚠ older than 7 days)")
            else:
                print()
        else:
            print(f"  TFLite file      : [MISSING] {vibration_tflite_path.name}")
    else:
        print(f"  [MISSING] Config file: {vibration_config_path.name}")

    # Scaler files
    _print_subsection("Feature Scalers")
    scaler_files = {
        "Precursor": assets_path / "precursor_classifier_scaler.json",
        "Vibration": assets_path / "vibration_scaler.json",
    }
    for name, path in scaler_files.items():
        if path.exists():
            print(f"  {name:15s} : {_format_bytes(path.stat().st_size)}")
        else:
            print(f"  {name:15s} : [MISSING]")


def section_training_data(data_dir: str) -> None:
    """Print Training Data section."""
    _print_section_header("2. Training Data")

    field_dir = Path(data_dir) / "field"
    if not field_dir.exists():
        print(f"  [NOTICE] No field data directory: {field_dir}")
        return

    # Scan all CSV files
    csv_files = sorted(field_dir.glob("*.csv"))
    if not csv_files:
        print(f"  [NOTICE] No CSV files found in {field_dir}")
        return

    total_samples = 0
    all_label_counts = defaultdict(int)
    sample_dates = []

    for csv_path in csv_files:
        label_counts = _count_samples_in_csv(str(csv_path))
        num_samples = sum(label_counts.values())
        total_samples += num_samples

        for label, count in label_counts.items():
            all_label_counts[label] += count

        if num_samples > 0:
            sample_dates.append(csv_path.stem)

    print(f"  CSV files        : {len(csv_files)}")
    print(f"  Total samples    : {total_samples}")

    if sample_dates:
        print(f"  Date range       : {sample_dates[0]} to {sample_dates[-1]}")

    # Class distribution
    if all_label_counts:
        _print_subsection("Class Distribution")
        chart_lines = _build_bar_chart(dict(all_label_counts))
        for line in chart_lines:
            print(line)

        # Class imbalance ratio
        label_counts_vals = list(all_label_counts.values())
        if label_counts_vals:
            imbalance_ratio = max(label_counts_vals) / min(label_counts_vals) if min(label_counts_vals) > 0 else 0
            print(f"\n  Imbalance ratio  : {imbalance_ratio:.2f}x")
    else:
        print("  [NOTICE] No labeled samples found")


def section_pipeline_state(data_dir: str) -> None:
    """Print Pipeline State section."""
    _print_section_header("3. Pipeline State")

    data_path = Path(data_dir)

    # Retrain trigger
    retrain_trigger = data_path / ".retrain_trigger"
    if retrain_trigger.exists():
        print(f"  Retrain trigger  : [PRESENT] — run 'make train' to execute")
    else:
        print(f"  Retrain trigger  : (not set)")

    # Pipeline metrics
    metrics_path = data_path / "pipeline_metrics.json"
    if metrics_path.exists():
        _print_subsection("Last Training Run")
        metrics = _load_json_safe(str(metrics_path))

        if metrics:
            print(f"  Timestamp        : {metrics.get('timestamp', 'N/A')}")
            print(f"  Accuracy         : {metrics.get('test_accuracy', 'N/A')}")
            print(f"  Loss             : {metrics.get('test_loss', 'N/A')}")

            if "training_time_seconds" in metrics:
                secs = metrics["training_time_seconds"]
                print(f"  Training time    : {secs:.1f}s")

            if "model_version" in metrics:
                print(f"  Model version    : {metrics['model_version']}")
        else:
            print("  [ERROR] Failed to parse metrics file")
    else:
        print(f"  Pipeline metrics : (not found)")


def _check_import(pkg: str) -> bool:
    """Check if package is importable without full import."""
    try:
        __import__(pkg)
        return True
    except ImportError:
        return False


def section_system_check() -> None:
    """Print System Check section."""
    _print_section_header("4. System Check")

    # Python packages
    _print_subsection("Python Packages")
    required_packages = ["numpy", "pandas"]
    for pkg in required_packages:
        if _check_import(pkg):
            print(f"  {pkg:20s} : [OK]")
        else:
            print(f"  {pkg:20s} : [MISSING] Install with: pip install {pkg}")

    # Check tensorflow separately (slow to import)
    if _check_import("tensorflow"):
        print(f"  {'tensorflow':20s} : [OK]")
    else:
        print(f"  {'tensorflow':20s} : [MISSING] Install with: pip install tensorflow")

    # Optional packages
    optional_packages = ["flask", "scipy", "scikit-learn"]
    for pkg in optional_packages:
        if _check_import(pkg):
            print(f"  {pkg:20s} : [OK] (optional)")
        else:
            print(f"  {pkg:20s} : [not installed]")

    # Docker
    _print_subsection("Docker")
    try:
        result = subprocess.run(
            ["docker", "--version"],
            capture_output=True,
            text=True,
            timeout=3
        )
        if result.returncode == 0:
            version = result.stdout.strip()
            print(f"  Docker           : [OK] {version}")
        else:
            print(f"  Docker           : [ERROR] Command failed")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        print(f"  Docker           : [NOT AVAILABLE]")

    # Disk space
    _print_subsection("Disk Space")
    try:
        usage = shutil.disk_usage("./data")
        total_gb = usage.total / (1024**3)
        used_gb = usage.used / (1024**3)
        free_gb = usage.free / (1024**3)
        pct_used = (usage.used / usage.total * 100) if usage.total > 0 else 0

        print(f"  Total            : {total_gb:.1f} GB")
        print(f"  Used             : {used_gb:.1f} GB ({pct_used:.1f}%)")
        print(f"  Free             : {free_gb:.1f} GB")
    except OSError:
        print(f"  [ERROR] Cannot access disk usage")


def section_recommendations(data_dir: str, assets_dir: str) -> None:
    """Print Recommendations section."""
    _print_section_header("5. Recommendations")

    recs = []

    # Check field data
    field_dir = Path(data_dir) / "field"
    total_samples = 0
    if field_dir.exists():
        for csv_path in field_dir.glob("*.csv"):
            label_counts = _count_samples_in_csv(str(csv_path))
            total_samples += sum(label_counts.values())

    if total_samples == 0:
        recs.append("No field data found — run 'make collect' to start collection")
    elif total_samples < 100:
        recs.append(f"Only {total_samples} samples collected. Aim for 500+ samples for robust training")
    elif total_samples >= 500:
        recs.append(f"Good data collection: {total_samples} samples. Consider periodic retraining")

    # Check model age
    assets_path = Path(assets_dir)
    precursor_tflite = assets_path / "precursor_classifier.tflite"
    if precursor_tflite.exists():
        age_days = _get_file_age_days(str(precursor_tflite))
        if age_days > MODEL_AGE_WARNING_DAYS:
            recs.append(f"Precursor model is {age_days:.0f} days old — consider retraining")
    else:
        recs.append("Precursor model not found — run 'make train' to generate models")

    # Check retrain trigger
    retrain_trigger = Path(data_dir) / ".retrain_trigger"
    if retrain_trigger.exists():
        recs.append("Retraining has been triggered — run 'make train' to execute")

    # Class imbalance check
    field_dir = Path(data_dir) / "field"
    if field_dir.exists():
        all_label_counts = defaultdict(int)
        for csv_path in field_dir.glob("*.csv"):
            label_counts = _count_samples_in_csv(str(csv_path))
            for label, count in label_counts.items():
                all_label_counts[label] += count

        if all_label_counts and len(all_label_counts) > 1:
            counts = list(all_label_counts.values())
            imbalance = max(counts) / min(counts) if min(counts) > 0 else 0
            if imbalance > 3:
                recs.append(f"Class imbalance {imbalance:.1f}x detected — consider data augmentation")

    # Print recommendations
    if recs:
        for i, rec in enumerate(recs, 1):
            print(f"  {i}. {rec}")
    else:
        print("  ✓ No issues detected. System is healthy.")


def print_footer() -> None:
    """Print a summary footer."""
    print("\n" + "=" * 70)
    print(f"Report generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 70 + "\n")


def main(argv=None) -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Pipeline Status Report — AncientVision system-wide health summary"
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        help=f"Data directory (default: {DEFAULT_DATA_DIR})"
    )
    parser.add_argument(
        "--assets-dir",
        default=DEFAULT_ASSETS_DIR,
        help=f"ML assets directory (default: {DEFAULT_ASSETS_DIR})"
    )
    args = parser.parse_args(argv)

    # Print sections
    section_ml_models(args.assets_dir)
    section_training_data(args.data_dir)
    section_pipeline_state(args.data_dir)
    section_system_check()
    section_recommendations(args.data_dir, args.assets_dir)
    print_footer()


if __name__ == "__main__":
    main()
