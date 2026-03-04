#!/usr/bin/env python3
"""
Model confidence and calibration analysis for AncientVision TFLite models.

Analyzes prediction confidence distribution, identifies low-confidence regions,
and checks if confidence scores are well-calibrated (high confidence = high accuracy).

Usage: python scripts/model_confidence_analysis.py
       [--assets-dir app/assets/ml] [--n-samples 500] [--output report.json]
"""

import argparse
import io
import json
import os
import random
import sys
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# UTF-8 stdout — needed on Windows where the default encoding is cp1252
# ---------------------------------------------------------------------------

if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

# ---------------------------------------------------------------------------
# TFLite import (tflite_runtime preferred, tensorflow as fallback)
# ---------------------------------------------------------------------------

try:
    from tflite_runtime.interpreter import Interpreter as TFLiteInterpreter
    _TFLITE_BACKEND = "tflite_runtime"
except ImportError:
    try:
        import tensorflow as tf
        TFLiteInterpreter = tf.lite.Interpreter
        _TFLITE_BACKEND = "tensorflow"
    except ImportError:
        TFLiteInterpreter = None
        _TFLITE_BACKEND = None

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LABELS = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]

FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis",
    "stalta", "arias", "cav", "temp", "psdSlope",
    "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
    "cusum_max", "autoencoder_score",
]

TREND_DEFAULTS = {
    "ppv_trend": 1.0,
    "freq_trend": 1.0,
    "kurtosis_trend": 1.0,
    "stalta_trend": 1.0,
    "cusum_max": 0.0,
    "autoencoder_score": 0.0,
    "temp": 0.0,
    "psdSlope": 0.0,
}

# Calibration bins: [0.5, 0.6), [0.6, 0.7), [0.7, 0.8), [0.8, 0.9), [0.9, 1.0]
CONF_BINS = [(0.5, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.0)]

LOW_CONF_THRESHOLD = 0.7

# ---------------------------------------------------------------------------
# Sample generation (mirrors simulate_field_data.py)
# ---------------------------------------------------------------------------


def _rng(lo: float, hi: float) -> float:
    """Uniform float in [lo, hi]."""
    return lo + random.random() * (hi - lo)


def _normal_features() -> dict:
    return {
        "rms":      _rng(0.001, 0.05),
        "ppv":      _rng(0.01,  0.3),
        "freq":     _rng(5.0,   50.0),
        "crest":    _rng(2.0,   6.0),
        "centroid": _rng(10.0,  40.0),
        "kurtosis": _rng(-1.0,  3.0),
        "stalta":   _rng(0.5,   2.0),
        "arias":    _rng(0.0,   0.001),
        "cav":      _rng(0.0,   0.01),
    }


def _soil_creep_features(index: int, total: int) -> dict:
    progress = index / max(total - 1, 1)
    ppv_base = 0.3 + progress * (1.5 - 0.3)
    freq_base = 40.0 - progress * 30.0
    return {
        "rms":      _rng(0.01,  0.08),
        "ppv":      max(0.31, ppv_base + _rng(-0.05, 0.05)),
        "freq":     max(5.0, freq_base + _rng(-3.0, 3.0)),
        "crest":    _rng(3.0,   7.0),
        "centroid": _rng(8.0,   25.0),
        "kurtosis": _rng(1.0,   5.0),
        "stalta":   _rng(1.5,   5.0),
        "arias":    _rng(0.0002, 0.005),
        "cav":      _rng(0.002,  0.02),
    }


def _crack_propagation_features() -> dict:
    return {
        "rms":      _rng(0.01,  0.08),
        "ppv":      _rng(0.5,   3.0),
        "freq":     _rng(10.0,  50.0),
        "crest":    _rng(8.0,   18.0),
        "centroid": _rng(15.0,  40.0),
        "kurtosis": _rng(8.0,   14.0),
        "stalta":   _rng(2.0,   8.0),
        "arias":    _rng(0.0005, 0.008),
        "cav":      _rng(0.005,  0.05),
    }


def _imminent_failure_features() -> dict:
    return {
        "rms":      _rng(0.05,  0.3),
        "ppv":      _rng(2.0,   10.0),
        "freq":     _rng(1.0,   15.0),
        "crest":    _rng(10.0,  25.0),
        "centroid": _rng(3.0,   15.0),
        "kurtosis": _rng(12.0,  30.0),
        "stalta":   _rng(8.0,   20.0),
        "arias":    _rng(0.01,  0.5),
        "cav":      _rng(0.05,  1.0),
    }


def generate_test_samples(n_samples: int) -> list:
    """
    Generate balanced synthetic test samples across all 4 classes.

    Returns a list of (feature_dict, label_str) tuples.
    Each class gets roughly n_samples // 4 samples.
    """
    samples = []
    per_class = n_samples // len(LABELS)
    remainder = n_samples - per_class * len(LABELS)

    for i, label in enumerate(LABELS):
        count = per_class + (1 if i < remainder else 0)
        for j in range(count):
            if label == "normal":
                feat = _normal_features()
            elif label == "soil_creep":
                feat = _soil_creep_features(j, count)
            elif label == "crack_propagation":
                feat = _crack_propagation_features()
            else:
                feat = _imminent_failure_features()

            # Fill in trend/derived fields with neutral defaults
            for k, v in TREND_DEFAULTS.items():
                feat.setdefault(k, v)

            samples.append((feat, label))

    # Shuffle for unbiased binning
    random.shuffle(samples)
    return samples


# ---------------------------------------------------------------------------
# Scaler helpers
# ---------------------------------------------------------------------------


def load_scaler(path: str) -> dict:
    """Load a JSON scaler with 'mean', 'scale', 'feature_names' keys."""
    with open(path, "r") as f:
        return json.load(f)


def apply_scaler(feat: dict, scaler: dict, feature_names: list) -> list:
    """
    Build and z-score normalize a feature vector.

    Args:
        feat: Feature dict (may have extra keys).
        scaler: Dict with 'mean' and 'scale' lists.
        feature_names: Ordered list of feature names.

    Returns:
        Normalized list of floats.
    """
    mean = scaler["mean"]
    scale = scaler["scale"]
    vec = [feat.get(name, TREND_DEFAULTS.get(name, 0.0)) for name in feature_names]
    if len(vec) != len(mean):
        raise ValueError(
            f"Feature vector length {len(vec)} != scaler length {len(mean)}"
        )
    return [(v - m) / max(s, 1e-10) for v, m, s in zip(vec, mean, scale)]


# ---------------------------------------------------------------------------
# TFLite interpreter helpers
# ---------------------------------------------------------------------------


def load_interpreter(tflite_path: str):
    """Load a TFLite model and return an allocated interpreter."""
    if TFLiteInterpreter is None:
        raise ImportError(
            "Neither tflite_runtime nor tensorflow is installed. "
            "Install one of them or use the ML Docker image."
        )
    interp = TFLiteInterpreter(model_path=tflite_path)
    interp.allocate_tensors()
    return interp


def run_inference(interpreter, input_array: np.ndarray) -> np.ndarray:
    """Run one inference; return output probabilities array."""
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()
    interpreter.set_tensor(input_details[0]["index"], input_array)
    interpreter.invoke()
    return interpreter.get_tensor(output_details[0]["index"])


# ---------------------------------------------------------------------------
# Core analysis
# ---------------------------------------------------------------------------


def run_analysis(
    assets_dir: str,
    n_samples: int,
) -> dict:
    """
    Run the full confidence and calibration analysis.

    Returns a result dict suitable for JSON export and ASCII printing.
    """
    # Paths
    tflite_path = os.path.join(assets_dir, "precursor_classifier.tflite")
    scaler_path = os.path.join(assets_dir, "precursor_classifier_scaler.json")
    config_path = os.path.join(assets_dir, "precursor_classifier_config.json")

    for p, name in [
        (tflite_path, "precursor_classifier.tflite"),
        (scaler_path, "precursor_classifier_scaler.json"),
        (config_path, "precursor_classifier_config.json"),
    ]:
        if not os.path.exists(p):
            print(f"ERROR: {name} not found at {p}", file=sys.stderr)
            sys.exit(1)

    # Load config, scaler, model
    with open(config_path, "r") as f:
        config = json.load(f)
    feature_names = config.get("feature_names", FEATURE_NAMES)
    class_names = config.get("class_names", LABELS)

    scaler = load_scaler(scaler_path)
    interpreter = load_interpreter(tflite_path)
    input_details = interpreter.get_input_details()
    dtype = input_details[0]["dtype"]

    # Generate test data
    test_samples = generate_test_samples(n_samples)

    # Run inference on all samples
    max_probs = []      # max probability (confidence) per sample
    pred_classes = []   # predicted class index per sample
    true_classes = []   # ground-truth class index per sample
    all_probs = []      # full probability vector per sample

    for feat, label in test_samples:
        norm_vec = apply_scaler(feat, scaler, feature_names)
        arr = np.array([norm_vec], dtype=dtype)
        out = run_inference(interpreter, arr)  # shape (1, n_classes)
        probs = out[0].tolist()
        pred_idx = int(np.argmax(probs))
        max_prob = float(probs[pred_idx])

        max_probs.append(max_prob)
        pred_classes.append(pred_idx)
        all_probs.append(probs)

        gt_idx = class_names.index(label) if label in class_names else -1
        true_classes.append(gt_idx)

    max_probs = np.array(max_probs)
    pred_classes = np.array(pred_classes)
    true_classes = np.array(true_classes)

    # -----------------------------------------------------------------------
    # 1. Confidence distribution
    # -----------------------------------------------------------------------
    dist_bins = {}
    for lo, hi in CONF_BINS:
        bin_key = f"{lo:.1f}-{hi:.1f}"
        if hi == 1.0:
            mask = (max_probs >= lo) & (max_probs <= hi)
        else:
            mask = (max_probs >= lo) & (max_probs < hi)
        count = int(mask.sum())
        pct = 100.0 * count / len(max_probs) if len(max_probs) > 0 else 0.0
        dist_bins[bin_key] = {"count": count, "pct": round(pct, 2)}

    # -----------------------------------------------------------------------
    # 2. Calibration curve
    # -----------------------------------------------------------------------
    valid_mask = true_classes >= 0  # exclude samples with unknown label
    calibration = []
    ece_numerator = 0.0
    ece_denominator = float(valid_mask.sum())

    for lo, hi in CONF_BINS:
        bin_key = f"{lo:.1f}-{hi:.1f}"
        if hi == 1.0:
            mask = (max_probs >= lo) & (max_probs <= hi) & valid_mask
        else:
            mask = (max_probs >= lo) & (max_probs < hi) & valid_mask

        n_bin = int(mask.sum())
        if n_bin == 0:
            calibration.append({
                "bin": bin_key,
                "n": 0,
                "mean_conf": None,
                "accuracy": None,
                "delta": None,
            })
            continue

        mean_conf = float(max_probs[mask].mean())
        correct = int((pred_classes[mask] == true_classes[mask]).sum())
        accuracy = correct / n_bin

        delta = accuracy - mean_conf
        ece_numerator += n_bin * abs(delta)

        calibration.append({
            "bin": bin_key,
            "n": n_bin,
            "mean_conf": round(mean_conf, 4),
            "accuracy": round(accuracy, 4),
            "delta": round(delta, 4),
        })

    ece = ece_numerator / ece_denominator if ece_denominator > 0 else 0.0

    # -----------------------------------------------------------------------
    # 3. Low-confidence analysis
    # -----------------------------------------------------------------------
    low_conf_mask = max_probs < LOW_CONF_THRESHOLD
    low_conf_count = int(low_conf_mask.sum())
    low_conf_pct = 100.0 * low_conf_count / len(max_probs) if len(max_probs) > 0 else 0.0

    # -----------------------------------------------------------------------
    # 4. Per-class confidence (correct vs incorrect)
    # -----------------------------------------------------------------------
    per_class_stats = {}
    for ci, cname in enumerate(class_names):
        gt_mask = (true_classes == ci) & valid_mask
        if gt_mask.sum() == 0:
            per_class_stats[cname] = {
                "correct_mean_conf": None,
                "incorrect_mean_conf": None,
                "n_correct": 0,
                "n_incorrect": 0,
            }
            continue

        correct_mask = gt_mask & (pred_classes == ci)
        incorrect_mask = gt_mask & (pred_classes != ci)

        # Confidence when predicting THIS class (regardless of correctness)
        # i.e. probability assigned to the ground-truth class
        probs_array = np.array(all_probs)
        gt_class_probs = probs_array[:, ci]  # probability of the true class

        correct_conf = (
            float(gt_class_probs[correct_mask].mean())
            if correct_mask.sum() > 0 else None
        )
        incorrect_conf = (
            float(gt_class_probs[incorrect_mask].mean())
            if incorrect_mask.sum() > 0 else None
        )

        per_class_stats[cname] = {
            "correct_mean_conf": round(correct_conf, 4) if correct_conf is not None else None,
            "incorrect_mean_conf": round(incorrect_conf, 4) if incorrect_conf is not None else None,
            "n_correct": int(correct_mask.sum()),
            "n_incorrect": int(incorrect_mask.sum()),
        }

    # -----------------------------------------------------------------------
    # Overall accuracy
    # -----------------------------------------------------------------------
    overall_correct = int((pred_classes[valid_mask] == true_classes[valid_mask]).sum())
    overall_accuracy = overall_correct / int(valid_mask.sum()) if valid_mask.sum() > 0 else 0.0

    return {
        "model": "precursor_classifier.tflite",
        "tflite_backend": _TFLITE_BACKEND,
        "n_samples": len(test_samples),
        "n_classes": len(class_names),
        "class_names": class_names,
        "overall_accuracy": round(overall_accuracy, 4),
        "confidence_distribution": dist_bins,
        "calibration_curve": calibration,
        "ece": round(ece, 4),
        "low_confidence": {
            "threshold": LOW_CONF_THRESHOLD,
            "count": low_conf_count,
            "pct": round(low_conf_pct, 2),
        },
        "per_class_confidence": per_class_stats,
    }


# ---------------------------------------------------------------------------
# ASCII report printer
# ---------------------------------------------------------------------------


def _bar(pct: float, width: int = 10) -> str:
    """Render a filled/empty bar: filled = round(pct/100 * width)."""
    filled = round(pct / 100.0 * width)
    filled = max(0, min(width, filled))
    return "\u2588" * filled + "\u2591" * (width - filled)


def _ece_label(ece: float) -> str:
    if ece < 0.05:
        return "excellent"
    if ece < 0.10:
        return "good"
    return "poor"


def print_report(result: dict) -> None:
    """Print the ASCII analysis report to stdout."""
    sep = "\u2550" * 46

    print()
    print("Model Confidence Analysis")
    print(sep)
    print(f"Model:        {result['model']}")
    print(f"Backend:      {result.get('tflite_backend', 'unknown')}")
    print(f"Test samples: {result['n_samples']}")
    print(f"Overall acc:  {result['overall_accuracy'] * 100:.1f}%")
    print()

    # Confidence distribution
    print("Confidence Distribution:")
    for bin_key, info in result["confidence_distribution"].items():
        pct = info["pct"]
        bar = _bar(pct)
        print(f"  {bin_key}  {bar} {pct:5.1f}%")
    print()

    # Calibration curve
    print("Calibration:")
    print(f"  {'Bin':<8} {'Conf':>6} {'Acc':>6}  {'Delta':>7}")
    ece = result["ece"]
    for entry in result["calibration_curve"]:
        if entry["mean_conf"] is None:
            print(f"  {entry['bin']:<8}  {'--':>6} {'--':>6}   {'no data':>7}")
            continue
        delta = entry["delta"]
        warn = " \u26a0" if abs(delta) > 0.10 else ""
        delta_str = f"{delta:+.2f}"
        print(
            f"  {entry['bin']:<8} "
            f"{entry['mean_conf']:>6.2f} "
            f"{entry['accuracy']:>6.2f}  "
            f"{delta_str:>7}{warn}"
        )
    ece_qual = _ece_label(ece)
    print(f"  ECE: {ece:.3f} (excellent < 0.05, good < 0.10, poor >= 0.10) [{ece_qual}]")
    print()

    # Low-confidence
    lc = result["low_confidence"]
    print(
        f"Low-confidence samples: {lc['pct']:.1f}% "
        f"({lc['count']}/{result['n_samples']}, max_prob < {lc['threshold']})"
    )
    print()

    # Per-class confidence
    print("Per-class confidence:")
    for cname, stats in result["per_class_confidence"].items():
        correct_str = (
            f"{stats['correct_mean_conf']:.2f}"
            if stats["correct_mean_conf"] is not None else "  --"
        )
        incorrect_str = (
            f"{stats['incorrect_mean_conf']:.2f}"
            if stats["incorrect_mean_conf"] is not None else "  --"
        )
        print(
            f"  {cname:<22} "
            f"correct: {correct_str}  "
            f"incorrect: {incorrect_str}"
        )
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Analyze model confidence and calibration for AncientVision TFLite models.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--assets-dir",
        default=DEFAULT_ASSETS_DIR,
        help=f"Directory containing TFLite models and scalers (default: {DEFAULT_ASSETS_DIR})",
    )
    p.add_argument(
        "--n-samples",
        type=int,
        default=500,
        help="Number of synthetic test samples to generate (default: 500)",
    )
    p.add_argument(
        "--output",
        default=None,
        help="Write JSON report to this file (default: print only, no file)",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducible sample generation (default: random)",
    )
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    if args.seed is not None:
        random.seed(args.seed)
        np.random.seed(args.seed)

    assets_dir = str(Path(args.assets_dir).resolve())

    result = run_analysis(
        assets_dir=assets_dir,
        n_samples=args.n_samples,
    )

    print_report(result)

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with open(out_path, "w") as f:
            json.dump(result, f, indent=2)
        print(f"JSON report written to: {out_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
