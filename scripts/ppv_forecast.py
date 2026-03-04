#!/usr/bin/env python3
"""
ppv_forecast.py — Forecast future PPV levels using exponential smoothing.

Usage:
    python scripts/ppv_forecast.py [--data-dir DIR] [--horizon MINUTES] [--alpha FLOAT]

Uses Holt-Winters single exponential smoothing to forecast PPV N minutes ahead.
--alpha: smoothing factor 0.1-0.9 (default 0.3, lower = more smoothing)
--horizon: minutes to forecast ahead (default 5, max 60)
Outputs: current trend, forecast value, confidence interval, alert threshold ETA.
"""

import argparse
import csv
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data")
DEFAULT_HORIZON = 5       # minutes
DEFAULT_ALPHA = 0.3
MAX_HORIZON = 60

# DIN 4150-3 PPV thresholds (mm/s)
DIN_THRESHOLDS = [
    (0.3, "DIN 4150-3 sensitive structures"),
    (1.0, "DIN 4150-3 commercial buildings"),
    (5.0, "DIN 4150-3 industrial structures"),
]

TREND_WINDOW = 5   # number of smoothed values to assess trend


def load_csv_files(data_dir: str) -> list:
    """Load all CSV rows from data_dir sorted by filename. Returns list of dicts."""
    rows = []
    if not os.path.isdir(data_dir):
        return rows
    for fname in sorted(os.listdir(data_dir)):
        if not fname.endswith(".csv"):
            continue
        fpath = os.path.join(data_dir, fname)
        try:
            with open(fpath, newline="", encoding="utf-8") as fh:
                reader = csv.DictReader(fh)
                rows.extend(list(reader))
        except OSError:
            pass
    return rows


def _parse_timestamp(ts_str: str) -> float:
    """Parse ISO 8601 timestamp to Unix epoch float. Returns -1 on failure."""
    if not ts_str:
        return -1.0
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
    ):
        try:
            dt = datetime.strptime(ts_str, fmt)
            dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            continue
    return -1.0


def prepare_series(rows: list) -> list:
    """
    Extract and sort (timestamp, ppv) pairs from rows.
    Skips rows with invalid timestamps or ppv.
    Returns list of (float, float) sorted by timestamp.
    """
    series = []
    for row in rows:
        ts = _parse_timestamp(row.get("timestamp", ""))
        if ts < 0:
            continue
        try:
            ppv = float(row.get("ppv", "0") or "0")
        except (ValueError, TypeError):
            ppv = 0.0
        series.append((ts, ppv))
    series.sort(key=lambda x: x[0])
    return series


def apply_exponential_smoothing(series: list, alpha: float) -> list:
    """
    Apply single exponential smoothing to the PPV series.

    s_t = alpha * ppv_t + (1 - alpha) * s_{t-1}

    Returns list of smoothed values in the same order as series.
    """
    if not series:
        return []
    smoothed = []
    s = series[0][1]  # initialise with first observation
    for _, ppv in series:
        s = alpha * ppv + (1.0 - alpha) * s
        smoothed.append(s)
    return smoothed


def detect_trend(smoothed: list) -> tuple:
    """
    Detect linear trend from the last TREND_WINDOW smoothed values.

    Returns (is_positive_trend, slope_per_step) where slope is in mm/s per
    observation step.  is_positive_trend is True only when every consecutive
    pair in the window is strictly increasing.
    """
    window = smoothed[-TREND_WINDOW:] if len(smoothed) >= TREND_WINDOW else smoothed
    if len(window) < 2:
        return False, 0.0

    # Check strictly monotonically increasing
    is_positive = all(window[i] > window[i - 1] for i in range(1, len(window)))

    # Linear slope via least-squares (simple rise-over-run)
    n = len(window)
    xs = list(range(n))
    x_mean = (n - 1) / 2.0
    y_mean = sum(window) / n
    numerator = sum((xs[i] - x_mean) * (window[i] - y_mean) for i in range(n))
    denominator = sum((xs[i] - x_mean) ** 2 for i in range(n))
    slope = numerator / denominator if denominator != 0 else 0.0

    return is_positive, slope


def compute_rmse(series: list, smoothed: list) -> float:
    """Compute RMSE of in-sample residuals (observation - smoothed)."""
    if len(series) < 2 or len(smoothed) < 2:
        return 0.0
    errors = [(series[i][1] - smoothed[i]) ** 2 for i in range(len(series))]
    mse = sum(errors) / len(errors)
    return mse ** 0.5


def forecast(smoothed: list, horizon_steps: int, slope: float, is_positive: bool) -> float:
    """
    Forecast `horizon_steps` steps ahead.

    For single exponential smoothing the flat forecast is simply the last
    smoothed value.  When a positive trend is detected, add a linear trend
    term: slope * horizon_steps.
    """
    if not smoothed:
        return 0.0
    base = smoothed[-1]
    if is_positive:
        return base + slope * horizon_steps
    return base


def estimate_eta_to_threshold(current_ppv: float, slope_per_step: float,
                               step_interval_s: float, threshold: float) -> float:
    """
    Estimate seconds until PPV reaches `threshold` given current PPV and
    slope in mm/s per observation step.

    Returns float seconds, or -1.0 if threshold already exceeded or trend
    not positive.
    """
    if slope_per_step <= 0:
        return -1.0
    if current_ppv >= threshold:
        return -1.0
    steps_needed = (threshold - current_ppv) / slope_per_step
    return steps_needed * step_interval_s


def main(argv=None):
    """Entry point. Always exits 0."""
    parser = argparse.ArgumentParser(
        description="Forecast future PPV levels using exponential smoothing."
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        help=f"Directory containing field CSV files (default: {DEFAULT_DATA_DIR})",
    )
    parser.add_argument(
        "--horizon",
        type=int,
        default=DEFAULT_HORIZON,
        help=f"Minutes to forecast ahead (default: {DEFAULT_HORIZON}, max: {MAX_HORIZON})",
    )
    parser.add_argument(
        "--alpha",
        type=float,
        default=DEFAULT_ALPHA,
        help=f"Smoothing factor 0.1-0.9 (default: {DEFAULT_ALPHA})",
    )
    args = parser.parse_args(argv)

    # Clamp inputs
    alpha = max(0.1, min(0.9, args.alpha))
    horizon = max(1, min(MAX_HORIZON, args.horizon))

    rows = load_csv_files(args.data_dir)
    series = prepare_series(rows)

    if not series:
        print("No data found.")
        sys.exit(0)

    smoothed = apply_exponential_smoothing(series, alpha)
    rmse = compute_rmse(series, smoothed)
    ci_half = 1.96 * rmse  # 95% confidence interval half-width

    is_positive, slope = detect_trend(smoothed)

    # Estimate average time step in seconds
    if len(series) >= 2:
        total_time = series[-1][0] - series[0][0]
        step_s = total_time / (len(series) - 1) if len(series) > 1 else 1.0
    else:
        step_s = 1.0

    # Convert horizon from minutes to steps
    horizon_s = horizon * 60.0
    horizon_steps = horizon_s / step_s if step_s > 0 else horizon_s

    forecast_val = forecast(smoothed, horizon_steps, slope, is_positive)
    forecast_low = max(0.0, forecast_val - ci_half)
    forecast_high = forecast_val + ci_half

    current_ppv = series[-1][1]
    current_smoothed = smoothed[-1]

    # Print results
    print()
    print("=" * 52)
    print("  PPV Forecast (Exponential Smoothing)")
    print("=" * 52)
    print(f"  Alpha (smoothing factor):  {alpha:.2f}")
    print(f"  Observations loaded:       {len(series)}")
    print(f"  Forecast horizon:          {horizon} min")
    print()
    print(f"  Current PPV:               {current_ppv:.4f} mm/s")
    print(f"  Smoothed PPV (now):        {current_smoothed:.4f} mm/s")
    print(f"  In-sample RMSE:            {rmse:.4f} mm/s")
    print()
    trend_label = "INCREASING (trend term applied)" if is_positive else "FLAT"
    print(f"  Trend:                     {trend_label}")
    print(f"  Forecast ({horizon:2d} min ahead):   {forecast_val:.4f} mm/s")
    print(f"  95% CI:                    [{forecast_low:.4f}, {forecast_high:.4f}] mm/s")
    print()

    # Threshold ETA
    if is_positive and slope > 0:
        print("  Alert threshold ETAs (if trend continues):")
        for thresh, label in DIN_THRESHOLDS:
            eta_s = estimate_eta_to_threshold(current_smoothed, slope, step_s, thresh)
            if eta_s < 0:
                status = "already exceeded" if current_smoothed >= thresh else "trend too slow"
                print(f"    {thresh:.1f} mm/s ({label}): {status}")
            elif eta_s < 3600:
                minutes = eta_s / 60.0
                print(f"    {thresh:.1f} mm/s ({label}): ~{minutes:.1f} min")
            else:
                hours = eta_s / 3600.0
                print(f"    {thresh:.1f} mm/s ({label}): ~{hours:.1f} h")
    else:
        print("  Alert threshold ETAs: N/A (no positive trend detected)")

    print("=" * 52)
    print()

    sys.exit(0)


if __name__ == "__main__":
    main()
