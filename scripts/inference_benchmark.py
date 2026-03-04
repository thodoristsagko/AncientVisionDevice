#!/usr/bin/env python3
"""Measure TFLite inference latency for precursor classifier and/or anomaly autoencoder.

Runs N inferences with random input vectors and reports:
  mean, median, p95, p99, min, max latency in milliseconds

Also measures:
  - Model load time
  - Memory footprint (model file size as proxy; RSS if psutil available)
  - Single-thread performance (num_threads=1 to simulate low-end device)

Usage:
    python scripts/inference_benchmark.py
    python scripts/inference_benchmark.py --n-runs 1000
    python scripts/inference_benchmark.py --model precursor
    python scripts/inference_benchmark.py --model anomaly
    python scripts/inference_benchmark.py --model both --n-runs 500
"""

import argparse
import os
import sys
import time

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

PRECURSOR_TFLITE = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
ANOMALY_TFLITE = os.path.join(ASSETS_DIR, "vibration_anomaly.tflite")

# Input dimensions
PRECURSOR_INPUT_DIM = 17
ANOMALY_INPUT_DIM = 11

# Inference budget for 2 Hz (500 ms)
BUDGET_MS = 500.0


# ---------------------------------------------------------------------------
# TFLite loader
# ---------------------------------------------------------------------------

def _load_interpreter(path: str, num_threads: int = 1):
    """Load a TFLite interpreter with num_threads.

    Returns (interpreter, load_time_ms) or raises ImportError.
    """
    t0 = time.perf_counter()
    try:
        try:
            from tflite_runtime.interpreter import Interpreter  # noqa: PLC0415
            interp = Interpreter(model_path=path, num_threads=num_threads)
        except ImportError:
            import tensorflow as tf  # noqa: PLC0415
            interp = tf.lite.Interpreter(model_path=path, num_threads=num_threads)
        interp.allocate_tensors()
    except Exception as exc:
        raise RuntimeError(f"Failed to load TFLite model from {path}: {exc}") from exc
    load_ms = (time.perf_counter() - t0) * 1000.0
    return interp, load_ms


def _get_input_dtype(interp) -> type:
    return interp.get_input_details()[0]["dtype"]


def _get_input_shape(interp) -> tuple:
    return tuple(interp.get_input_details()[0]["shape"])


# ---------------------------------------------------------------------------
# Benchmark runner
# ---------------------------------------------------------------------------

def _run_benchmark(interp, input_dim: int, n_runs: int, rng: np.random.Generator) -> np.ndarray:
    """Run n_runs inferences; return latency array in milliseconds."""
    dtype = _get_input_dtype(interp)
    in_det = interp.get_input_details()
    out_det = interp.get_output_details()
    in_idx = in_det[0]["index"]
    out_idx = out_det[0]["index"]

    # Pre-generate random inputs (do not include generation time in latency)
    inputs = rng.standard_normal((n_runs, input_dim)).astype(dtype)

    latencies_ms = np.empty(n_runs, dtype=np.float64)

    for i in range(n_runs):
        arr = inputs[i : i + 1]  # shape (1, input_dim)
        t0 = time.perf_counter()
        interp.set_tensor(in_idx, arr)
        interp.invoke()
        _ = interp.get_tensor(out_idx)
        latencies_ms[i] = (time.perf_counter() - t0) * 1000.0

    return latencies_ms


# ---------------------------------------------------------------------------
# Memory footprint
# ---------------------------------------------------------------------------

def _get_memory_info(model_path: str) -> dict:
    """Return memory info dict: file_size_kb, process_rss_mb (if psutil available)."""
    info = {}
    if os.path.isfile(model_path):
        info["file_size_kb"] = os.path.getsize(model_path) / 1024
    else:
        info["file_size_kb"] = 0.0

    try:
        import psutil  # noqa: PLC0415
        process = psutil.Process(os.getpid())
        mem = process.memory_info()
        info["process_rss_mb"] = mem.rss / (1024 * 1024)
    except ImportError:
        info["process_rss_mb"] = None

    return info


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def _percentile(arr: np.ndarray, p: float) -> float:
    """Compute p-th percentile (0-100) of arr."""
    n = len(arr)
    if n == 0:
        return 0.0
    sorted_arr = np.sort(arr)
    idx = (p / 100.0) * (n - 1)
    lo = int(idx)
    hi = min(lo + 1, n - 1)
    frac = idx - lo
    return float(sorted_arr[lo] * (1 - frac) + sorted_arr[hi] * frac)


def _print_latency_table(latencies_ms: np.ndarray, label: str, n_runs: int) -> None:
    """Print a formatted latency statistics table."""
    mean_ms = float(latencies_ms.mean())
    median_ms = _percentile(latencies_ms, 50)
    p95_ms = _percentile(latencies_ms, 95)
    p99_ms = _percentile(latencies_ms, 99)
    min_ms = float(latencies_ms.min())
    max_ms = float(latencies_ms.max())

    print(f"\n  {label}  (N={n_runs} runs, single thread)")
    print(f"  {'─' * 50}")
    print(f"  {'Metric':<12}  {'Value (ms)':>10}")
    print(f"  {'─' * 26}")
    print(f"  {'mean':<12}  {mean_ms:>10.3f}")
    print(f"  {'median':<12}  {median_ms:>10.3f}")
    print(f"  {'p95':<12}  {p95_ms:>10.3f}")
    print(f"  {'p99':<12}  {p99_ms:>10.3f}")
    print(f"  {'min':<12}  {min_ms:>10.3f}")
    print(f"  {'max':<12}  {max_ms:>10.3f}")
    print(f"  {'─' * 26}")

    # Recommendation
    margin = BUDGET_MS - p95_ms
    margin_pct = margin / BUDGET_MS * 100
    freq_hz = 1000.0 / p95_ms if p95_ms > 0 else float("inf")
    print()
    if margin >= 0:
        print(f"  Recommendation:")
        print(f"    At p95={p95_ms:.2f}ms, 2Hz inference (budget={BUDGET_MS:.0f}ms) "
              f"has {margin_pct:.1f}% margin ({margin:.1f}ms free).")
        print(f"    Maximum sustainable inference rate: {freq_hz:.1f} Hz")
    else:
        overrun = -margin
        print(f"  WARNING: p95 latency ({p95_ms:.2f}ms) exceeds 2Hz budget "
              f"({BUDGET_MS:.0f}ms) by {overrun:.1f}ms.")
        print(f"    Consider reducing inference rate to <= {freq_hz:.1f} Hz.")


def _print_model_info(model_path: str, load_ms: float, mem: dict) -> None:
    """Print model load time and memory footprint."""
    file_kb = mem.get("file_size_kb", 0.0)
    rss_mb = mem.get("process_rss_mb")

    print(f"  Model file:   {model_path}")
    print(f"  File size:    {file_kb:.1f} KB")
    print(f"  Load time:    {load_ms:.2f} ms")
    if rss_mb is not None:
        print(f"  Process RSS:  {rss_mb:.1f} MB  (after model load)")
    else:
        print(f"  Process RSS:  N/A (install psutil for memory tracking)")


# ---------------------------------------------------------------------------
# Per-model benchmark
# ---------------------------------------------------------------------------

def _benchmark_model(model_path: str, input_dim: int, model_label: str,
                      n_runs: int, rng: np.random.Generator) -> None:
    """Load model, run benchmark, print full report."""
    print(f"\n{'=' * 60}")
    print(f"  {model_label}")
    print(f"{'=' * 60}")

    if not os.path.isfile(model_path):
        print(f"  WARNING: Model not found at {model_path}")
        print(f"  Run the training script first:")
        if "precursor" in model_path:
            print("    python scripts/generate_precursor_data.py")
        else:
            print("    python scripts/train_autoencoder.py")
        return

    # Measure memory before load
    mem_before = None
    try:
        import psutil  # noqa: PLC0415
        mem_before = psutil.Process(os.getpid()).memory_info().rss / (1024 * 1024)
    except ImportError:
        pass

    # Load model
    try:
        interp, load_ms = _load_interpreter(model_path, num_threads=1)
    except RuntimeError as exc:
        print(f"  ERROR: {exc}", file=sys.stderr)
        return
    except ImportError:
        print("  ERROR: TFLite not available. Install tensorflow or tflite-runtime.",
              file=sys.stderr)
        print("  Install: pip install tensorflow==2.15.1", file=sys.stderr)
        return

    # Memory footprint
    mem_info = _get_memory_info(model_path)
    if mem_before is not None and mem_info.get("process_rss_mb") is not None:
        mem_info["model_overhead_mb"] = mem_info["process_rss_mb"] - mem_before

    _print_model_info(model_path, load_ms, mem_info)
    if "model_overhead_mb" in mem_info:
        print(f"  Model RSS overhead: {mem_info['model_overhead_mb']:.1f} MB")

    # Warm-up run (excluded from benchmark)
    dtype = _get_input_dtype(interp)
    warmup_input = rng.standard_normal((1, input_dim)).astype(dtype)
    in_idx = interp.get_input_details()[0]["index"]
    out_idx = interp.get_output_details()[0]["index"]
    interp.set_tensor(in_idx, warmup_input)
    interp.invoke()
    _ = interp.get_tensor(out_idx)

    # Benchmark
    print(f"\n  Running {n_runs} inference(s)...")
    latencies_ms = _run_benchmark(interp, input_dim, n_runs, rng)

    _print_latency_table(latencies_ms, model_label, n_runs)

    # Throughput
    total_sec = latencies_ms.sum() / 1000.0
    throughput = n_runs / total_sec if total_sec > 0 else 0.0
    print(f"\n  Total benchmark time: {total_sec * 1000:.1f} ms for {n_runs} runs")
    print(f"  Throughput:           {throughput:.1f} inferences/sec")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Benchmark TFLite inference latency for AncientVision models."
    )
    parser.add_argument(
        "--n-runs", type=int, default=1000, metavar="N",
        help="Number of inference runs per model (default: 1000).",
    )
    parser.add_argument(
        "--model", choices=["precursor", "anomaly", "both"], default="both",
        help="Which model(s) to benchmark (default: both).",
    )
    args = parser.parse_args()

    n_runs = max(1, args.n_runs)
    rng = np.random.default_rng(42)

    print("=" * 60)
    print("INFERENCE LATENCY BENCHMARK")
    print("=" * 60)
    print(f"  Runs per model:   {n_runs}")
    print(f"  Thread count:     1  (simulating low-end device)")
    print(f"  Inference budget: {BUDGET_MS:.0f} ms  (2 Hz target)")

    # Check TFLite availability early
    tflite_available = False
    try:
        try:
            import tflite_runtime.interpreter  # noqa: PLC0415, F401
            tflite_available = True
        except ImportError:
            import tensorflow  # noqa: PLC0415, F401
            tflite_available = True
    except ImportError:
        pass

    if not tflite_available:
        print("\n  ERROR: TFLite not available.", file=sys.stderr)
        print("  Install tensorflow: pip install tensorflow==2.15.1", file=sys.stderr)
        print("  Or tflite-runtime: pip install tflite-runtime", file=sys.stderr)
        sys.exit(1)

    if args.model in ("precursor", "both"):
        _benchmark_model(
            PRECURSOR_TFLITE, PRECURSOR_INPUT_DIM,
            "Precursor Classifier  (17-feature, 4-class)",
            n_runs, rng,
        )

    if args.model in ("anomaly", "both"):
        _benchmark_model(
            ANOMALY_TFLITE, ANOMALY_INPUT_DIM,
            "Anomaly Autoencoder  (11-feature)",
            n_runs, rng,
        )

    print()
    print("=" * 60)
    print("Done.")


if __name__ == "__main__":
    main()
