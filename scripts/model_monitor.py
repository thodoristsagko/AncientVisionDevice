#!/usr/bin/env python3
"""
Model performance monitor for AncientVision.

Continuously monitors the deployed TFLite model against field data,
detecting performance degradation and triggering alerts.

Usage:
    python scripts/model_monitor.py --assets-dir app/assets/ml --data-dir ./data/field
    python scripts/model_monitor.py --once   # Single check, exit with code 1 if degraded
"""

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Optional
import numpy as np

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

# Alert thresholds
ACCURACY_DEGRADATION_THRESHOLD = 0.10   # 10% drop from baseline triggers alert
MIN_CONFIDENCE_THRESHOLD = 0.60          # Alert if avg confidence drops below 60%
MAX_LOW_CONFIDENCE_FRACTION = 0.30       # Alert if >30% of predictions are low-confidence
MIN_SAMPLES_FOR_EVAL = 20               # Need at least 20 labeled samples to evaluate


def load_tflite(model_path: str):
    """Load a TFLite interpreter."""
    try:
        import tflite_runtime.interpreter as tflite
        return tflite.Interpreter(model_path=model_path)
    except ImportError:
        import tensorflow as tf
        return tf.lite.Interpreter(model_path=model_path)


def load_scaler(scaler_path: str) -> Optional[dict]:
    """Load z-score scaler from JSON."""
    try:
        with open(scaler_path) as f:
            return json.load(f)
    except Exception:
        return None


def apply_scaler(features: list, scaler: dict) -> list:
    """Apply z-score normalization."""
    mean = scaler.get("mean", [0.0] * len(features))
    scale = scaler.get("scale", [1.0] * len(features))
    return [(v - m) / (s if s > 1e-10 else 1.0)
            for v, m, s in zip(features, mean, scale)]


FEATURE_COLS = [
    "ppv", "rms", "dominant_freq", "crest", "spectral_centroid",
    "kurtosis", "sta_lta", "arias", "cav", "psd_slope", "wavelet_energy",
    "ppv_trend", "freq_trend", "kurtosis_trend", "sta_lta_trend",
    "cusum_max", "autoencoder_score"
]

LABELS = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]


def run_inference_batch(interpreter, scaler, feature_rows):
    """Run inference on a list of feature dicts. Returns (predictions, confidences)."""
    interpreter.allocate_tensors()
    in_detail = interpreter.get_input_details()[0]
    out_detail = interpreter.get_output_details()[0]
    in_idx = in_detail["index"]
    out_idx = out_detail["index"]

    predictions = []
    confidences = []

    for row in feature_rows:
        features = [float(row.get(col, 0.0)) for col in FEATURE_COLS]
        if scaler:
            features = apply_scaler(features, scaler)
        inp = np.array([features], dtype=np.float32)
        interpreter.set_tensor(in_idx, inp)
        interpreter.invoke()
        probs = interpreter.get_tensor(out_idx)[0]
        pred_idx = int(np.argmax(probs))
        predictions.append(LABELS[pred_idx] if pred_idx < len(LABELS) else "unknown")
        confidences.append(float(np.max(probs)))

    return predictions, confidences


def evaluate_field_data(data_dir: Path, interpreter, scaler) -> dict:
    """Evaluate model on labeled field CSVs. Returns metrics dict."""
    if not HAS_PANDAS:
        return {"error": "pandas not available"}

    csv_files = list(data_dir.glob("*.csv"))
    if not csv_files:
        return {"error": f"No CSV files in {data_dir}"}

    all_rows = []
    for f in csv_files:
        try:
            df = pd.read_csv(f)
            if "label" in df.columns:
                all_rows.extend(df.to_dict("records"))
        except Exception:
            continue

    labeled = [r for r in all_rows if r.get("label") and r["label"] in LABELS]
    if len(labeled) < MIN_SAMPLES_FOR_EVAL:
        return {"error": f"Only {len(labeled)} labeled samples (need {MIN_SAMPLES_FOR_EVAL})"}

    predictions, confidences = run_inference_batch(interpreter, scaler, labeled)
    true_labels = [r["label"] for r in labeled]

    correct = sum(p == t for p, t in zip(predictions, true_labels))
    accuracy = correct / len(labeled)
    avg_confidence = float(np.mean(confidences))
    low_conf_count = sum(c < 0.6 for c in confidences)
    low_conf_fraction = low_conf_count / len(labeled)

    return {
        "accuracy": round(accuracy, 4),
        "avg_confidence": round(avg_confidence, 4),
        "low_confidence_fraction": round(low_conf_fraction, 4),
        "n_samples": len(labeled),
        "n_correct": correct,
    }


def check_degradation(metrics: dict, baseline: Optional[dict]) -> list:
    """Return list of alert strings if degradation detected."""
    alerts = []

    if "error" in metrics:
        return [f"Evaluation error: {metrics['error']}"]

    if metrics["avg_confidence"] < MIN_CONFIDENCE_THRESHOLD:
        alerts.append(
            f"Low avg confidence: {metrics['avg_confidence']:.1%} "
            f"(threshold: {MIN_CONFIDENCE_THRESHOLD:.1%})"
        )

    if metrics["low_confidence_fraction"] > MAX_LOW_CONFIDENCE_FRACTION:
        alerts.append(
            f"High low-confidence rate: {metrics['low_confidence_fraction']:.1%} "
            f"(threshold: {MAX_LOW_CONFIDENCE_FRACTION:.1%})"
        )

    if baseline and "accuracy" in baseline:
        drop = baseline["accuracy"] - metrics["accuracy"]
        if drop > ACCURACY_DEGRADATION_THRESHOLD:
            alerts.append(
                f"Accuracy degradation: {metrics['accuracy']:.1%} vs baseline "
                f"{baseline['accuracy']:.1%} (drop: {drop:.1%})"
            )

    return alerts


def load_baseline(assets_dir: Path) -> Optional[dict]:
    """Load model baseline metrics if available."""
    baseline_file = assets_dir / "model_baseline.json"
    if not baseline_file.exists():
        return None
    try:
        with open(baseline_file) as f:
            return json.load(f)
    except Exception:
        return None


def save_baseline(assets_dir: Path, metrics: dict):
    """Save current metrics as the new baseline."""
    baseline_file = assets_dir / "model_baseline.json"
    with open(baseline_file, "w") as f:
        json.dump(metrics, f, indent=2)
    print(f"Baseline saved to: {baseline_file}")


def print_report(metrics: dict, alerts: list, baseline: Optional[dict]):
    """Print a formatted monitoring report."""
    print()
    print("=" * 50)
    print("  AncientVision — Model Performance Monitor")
    print("=" * 50)

    if "error" in metrics:
        print(f"  ERROR: {metrics['error']}")
    else:
        print(f"  Samples evaluated : {metrics['n_samples']}")
        print(f"  Accuracy          : {metrics['accuracy']:.1%}")
        if baseline and "accuracy" in baseline:
            delta = metrics["accuracy"] - baseline["accuracy"]
            sign = "+" if delta >= 0 else ""
            print(f"  vs Baseline       : {sign}{delta:.1%}")
        print(f"  Avg confidence    : {metrics['avg_confidence']:.1%}")
        print(f"  Low-conf rate     : {metrics['low_confidence_fraction']:.1%}")

    print()
    if alerts:
        print(f"  ⚠  {len(alerts)} ALERT(S) DETECTED:")
        for a in alerts:
            print(f"     • {a}")
    else:
        print("  ✓  No degradation detected")
    print("=" * 50)
    print()


def main():
    parser = argparse.ArgumentParser(description="Monitor AncientVision model performance")
    parser.add_argument("--assets-dir", default="app/assets/ml", help="Model assets directory")
    parser.add_argument("--data-dir", default="./data/field", help="Field data directory")
    parser.add_argument("--once", action="store_true", help="Single check then exit")
    parser.add_argument("--interval", type=int, default=300, help="Check interval seconds (default 300)")
    parser.add_argument("--set-baseline", action="store_true", help="Save current metrics as baseline")
    parser.add_argument("--output", help="Write JSON results to file")
    args = parser.parse_args()

    assets_dir = Path(args.assets_dir)
    data_dir = Path(args.data_dir)

    model_path = assets_dir / "precursor_classifier.tflite"
    scaler_path = assets_dir / "precursor_classifier_scaler.json"

    if not model_path.exists():
        print(f"Model not found: {model_path}")
        print("Run training first: make train")
        return 1

    interpreter = load_tflite(str(model_path))
    scaler = load_scaler(str(scaler_path))
    baseline = load_baseline(assets_dir)

    exit_code = 0

    while True:
        metrics = evaluate_field_data(data_dir, interpreter, scaler)
        alerts = check_degradation(metrics, baseline)

        print_report(metrics, alerts, baseline)

        if args.set_baseline and "error" not in metrics:
            save_baseline(assets_dir, metrics)
            args.set_baseline = False  # Only set once

        if args.output and "error" not in metrics:
            result = {
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "metrics": metrics,
                "alerts": alerts,
                "has_baseline": baseline is not None,
            }
            with open(args.output, "w") as f:
                json.dump(result, f, indent=2)

        if alerts:
            exit_code = 1

        if args.once:
            return exit_code

        print(f"Next check in {args.interval}s (Ctrl+C to stop)...")
        try:
            time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\nMonitor stopped.")
            return 0


if __name__ == "__main__":
    sys.exit(main())
