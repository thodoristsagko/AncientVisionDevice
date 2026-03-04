#!/usr/bin/env python3
"""
model_size_report.py — Analyze TFLite model sizes and embedded deployment suitability.

Usage:
    python scripts/model_size_report.py [--model-dir DIR]

Checks: file size, parameter count estimate, inference time estimate,
        suitability for real-time embedded inference at 2Hz.
"""

import argparse
import os
import sys
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_MODEL_DIR = os.path.join(REPO_DIR, "app", "assets", "ml")

# Size category thresholds (bytes)
TINY_MAX = 50 * 1024        # < 50 KB
SMALL_MAX = 200 * 1024      # 50–200 KB
MEDIUM_MAX = 500 * 1024     # 200–500 KB
# > 500 KB → LARGE

# 2Hz suitability thresholds (ms)
TWO_HZ_OK_MAX = 500         # < 500ms → OK
TWO_HZ_WARN_MAX = 2000      # 500–2000ms → WARN
# > 2000ms → FAIL


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def size_category(size_bytes: int) -> str:
    """Return human-readable size category."""
    if size_bytes < TINY_MAX:
        return "TINY"
    if size_bytes < SMALL_MAX:
        return "SMALL"
    if size_bytes < MEDIUM_MAX:
        return "MEDIUM"
    return "LARGE"


def estimate_params(size_bytes: int) -> int:
    """Rough estimate: 4 bytes per float32 weight."""
    return size_bytes // 4


def estimate_inference_ms(n_params: int) -> float:
    """
    Very rough heuristic for embedded inference time.
    Assumes ~1M params takes ~10ms on a mid-tier embedded CPU.
    """
    return (n_params / 1_000_000) * 10.0


def two_hz_status(inference_ms: float) -> str:
    """Return OK / WARN / FAIL based on 2Hz (500ms budget) suitability."""
    if inference_ms < TWO_HZ_OK_MAX:
        return "OK"
    if inference_ms < TWO_HZ_WARN_MAX:
        return "WARN"
    return "FAIL"


def analyze_model(path: Path) -> dict:
    """Return analysis dict for a single .tflite file."""
    size_bytes = path.stat().st_size
    n_params = estimate_params(size_bytes)
    infer_ms = estimate_inference_ms(n_params)
    return {
        "name": path.name,
        "size_kb": size_bytes / 1024,
        "category": size_category(size_bytes),
        "est_params": n_params,
        "est_inference_ms": infer_ms,
        "two_hz_ok": two_hz_status(infer_ms),
    }


def scan_models(model_dir: str) -> list:
    """Return list of analysis dicts for all .tflite files in model_dir."""
    results = []
    if not os.path.isdir(model_dir):
        return results
    for fname in sorted(os.listdir(model_dir)):
        if not fname.endswith(".tflite"):
            continue
        fpath = Path(model_dir) / fname
        try:
            results.append(analyze_model(fpath))
        except OSError:
            pass
    return results


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def render_table(models: list) -> str:
    """Render model analysis as an ASCII table."""
    headers = ["Model", "Size KB", "Category", "Est.Params", "Est.InferenceMs", "2Hz_OK"]
    rows = []
    for m in models:
        rows.append((
            m["name"],
            f"{m['size_kb']:.1f}",
            m["category"],
            str(m["est_params"]),
            f"{m['est_inference_ms']:.2f}",
            m["two_hz_ok"],
        ))

    col_widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            col_widths[i] = max(col_widths[i], len(str(cell)))

    sep = "+-" + "-+-".join("-" * w for w in col_widths) + "-+"
    fmt = "| " + " | ".join(f"{{:<{w}}}" for w in col_widths) + " |"

    lines = [sep, fmt.format(*headers), sep]
    for r in rows:
        lines.append(fmt.format(*r))
    lines.append(sep)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze TFLite model sizes and embedded deployment suitability."
    )
    parser.add_argument(
        "--model-dir",
        default=DEFAULT_MODEL_DIR,
        help=f"Directory to scan for .tflite files (default: {DEFAULT_MODEL_DIR})",
    )
    args = parser.parse_args(argv)

    models = scan_models(args.model_dir)

    if not models:
        print("No .tflite files found")
        return 0

    print(f"\nModel Size Report — {args.model_dir}")
    print(render_table(models))

    # Summary
    ok_count = sum(1 for m in models if m["two_hz_ok"] == "OK")
    warn_count = sum(1 for m in models if m["two_hz_ok"] == "WARN")
    fail_count = sum(1 for m in models if m["two_hz_ok"] == "FAIL")
    print(
        f"\n{len(models)} model(s): {ok_count} OK, {warn_count} WARN, {fail_count} FAIL "
        f"for 2Hz real-time inference"
    )
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
