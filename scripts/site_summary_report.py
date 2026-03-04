#!/usr/bin/env python3
"""
Generate a comprehensive site safety summary report from all field data.

Aggregates across all sessions, devices, and time periods to produce
a single Markdown report suitable for project stakeholders.

Usage:
    python scripts/site_summary_report.py --data-dir ./data/field --site-name "Paros Dig 2026"
    python scripts/site_summary_report.py --data-dir ./data/field --output site_report.md
"""

import argparse
import sys
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict

try:
    import pandas as pd
    import numpy as np
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

LABELS = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]
ALERT_LEVELS = ["SAFE", "ANOMALY", "CRITICAL"]


def load_all_data(data_dir: Path):
    """Load all field CSVs, return merged DataFrame."""
    if not HAS_PANDAS:
        return None, "pandas not available"

    csv_files = sorted(data_dir.glob("*.csv"))
    if not csv_files:
        return None, f"No CSV files in {data_dir}"

    frames = []
    for f in csv_files:
        try:
            df = pd.read_csv(f)
            df["_source_file"] = f.name
            frames.append(df)
        except Exception:
            continue

    if not frames:
        return None, "No readable CSV files"

    merged = pd.concat(frames, ignore_index=True)

    if "timestamp" in merged.columns:
        merged["timestamp"] = pd.to_datetime(merged["timestamp"], errors="coerce")

    return merged, None


def compute_site_stats(df) -> dict:
    """Compute overall site statistics."""
    stats = {
        "total_samples": len(df),
        "total_sessions": df["_source_file"].nunique() if "_source_file" in df.columns else 1,
    }

    if "timestamp" in df.columns:
        ts = df["timestamp"].dropna()
        if not ts.empty:
            stats["monitoring_start"] = str(ts.min().date())
            stats["monitoring_end"] = str(ts.max().date())
            duration = ts.max() - ts.min()
            stats["monitoring_days"] = max(1, duration.days)

    if "device_id" in df.columns:
        stats["n_devices"] = df["device_id"].nunique()
        stats["devices"] = df["device_id"].unique().tolist()

    if "ppv" in df.columns:
        ppv = df["ppv"].dropna()
        stats["ppv_mean"] = round(float(ppv.mean()), 4)
        stats["ppv_max"] = round(float(ppv.max()), 4)
        stats["ppv_p95"] = round(float(ppv.quantile(0.95)), 4)
        stats["ppv_above_1"] = int((ppv > 1.0).sum())
        stats["ppv_above_3"] = int((ppv > 3.0).sum())

    if "anomaly_level" in df.columns:
        stats["anomaly_counts"] = df["anomaly_level"].value_counts().to_dict()

    if "label" in df.columns:
        label_counts = df["label"].value_counts()
        stats["class_distribution"] = label_counts.to_dict()
        precursor_count = sum(
            label_counts.get(l, 0) for l in ["soil_creep", "crack_propagation", "imminent_failure"]
        )
        stats["precursor_events"] = int(precursor_count)

    return stats


def compute_daily_stats(df) -> list:
    """Compute per-day summary."""
    if "timestamp" not in df.columns:
        return []

    df2 = df.copy()
    df2["date"] = df2["timestamp"].dt.date

    daily = []
    for date, group in df2.groupby("date"):
        day_stats = {"date": str(date), "n_samples": len(group)}
        if "ppv" in group.columns:
            ppv = group["ppv"].dropna()
            day_stats["max_ppv"] = round(float(ppv.max()), 4) if len(ppv) > 0 else 0.0
        if "anomaly_level" in group.columns:
            levels = group["anomaly_level"].value_counts()
            day_stats["anomaly"] = int(levels.get("ANOMALY", 0))
            day_stats["critical"] = int(levels.get("CRITICAL", 0))
        daily.append(day_stats)

    return daily


def build_markdown(stats: dict, daily: list, site_name: str) -> str:
    """Build Markdown report string."""
    lines = []
    now = datetime.now().strftime("%Y-%m-%d %H:%M")

    lines.append(f"# AncientVision Site Safety Report")
    lines.append(f"**Site:** {site_name}  ")
    lines.append(f"**Generated:** {now}  ")
    lines.append("")

    # Executive summary
    lines.append("## Executive Summary")
    lines.append("")
    lines.append(f"| Parameter | Value |")
    lines.append(f"|-----------|-------|")
    lines.append(f"| Total Samples | {stats.get('total_samples', 0):,} |")
    lines.append(f"| Sessions | {stats.get('total_sessions', 0)} |")
    lines.append(f"| Devices | {stats.get('n_devices', 'N/A')} |")
    lines.append(f"| Monitoring Period | {stats.get('monitoring_start', 'N/A')} to {stats.get('monitoring_end', 'N/A')} |")
    lines.append(f"| Peak PPV | {stats.get('ppv_max', 'N/A')} mm/s |")
    lines.append(f"| Mean PPV | {stats.get('ppv_mean', 'N/A')} mm/s |")
    lines.append(f"| PPV > 1.0 mm/s | {stats.get('ppv_above_1', 0)} events |")
    lines.append(f"| PPV > 3.0 mm/s | {stats.get('ppv_above_3', 0)} events |")
    lines.append(f"| Precursor Events | {stats.get('precursor_events', 0)} |")
    lines.append("")

    # Safety assessment
    peak = stats.get("ppv_max", 0.0)
    if peak > 5.0:
        safety_color = "🔴 HIGH RISK"
    elif peak > 1.0:
        safety_color = "🟡 MODERATE RISK"
    else:
        safety_color = "🟢 LOW RISK"

    lines.append("## Safety Assessment")
    lines.append("")
    lines.append(f"**Overall Risk Level:** {safety_color}")
    lines.append("")

    # Anomaly counts
    anomaly_counts = stats.get("anomaly_counts", {})
    if anomaly_counts:
        lines.append("## Alert Summary")
        lines.append("")
        lines.append("| Level | Count |")
        lines.append("|-------|-------|")
        for level in ["CRITICAL", "ANOMALY", "SAFE"]:
            count = anomaly_counts.get(level, 0)
            lines.append(f"| {level} | {count:,} |")
        lines.append("")

    # Class distribution
    class_dist = stats.get("class_distribution", {})
    if class_dist:
        lines.append("## ML Classification Summary")
        lines.append("")
        lines.append("| Class | Count | % |")
        lines.append("|-------|-------|---|")
        total = sum(class_dist.values())
        for label in LABELS:
            count = class_dist.get(label, 0)
            pct = 100 * count / total if total > 0 else 0
            lines.append(f"| {label} | {count:,} | {pct:.1f}% |")
        lines.append("")

    # Daily timeline
    if daily:
        lines.append("## Daily Timeline")
        lines.append("")
        lines.append("| Date | Samples | Max PPV | ANOMALY | CRITICAL |")
        lines.append("|------|---------|---------|---------|----------|")
        for day in daily[-14:]:  # Last 14 days
            lines.append(
                f"| {day['date']} | {day['n_samples']} | "
                f"{day.get('max_ppv', 0.0):.4f} | "
                f"{day.get('anomaly', 0)} | {day.get('critical', 0)} |"
            )
        lines.append("")

    lines.append("---")
    lines.append("*Generated by AncientVision monitoring system*")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Generate site safety summary report")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--site-name", default="Archaeological Site")
    parser.add_argument("--output", help="Output Markdown file path")
    args = parser.parse_args()

    if not HAS_PANDAS:
        print("pandas required: pip install pandas")
        return 1

    data_dir = Path(args.data_dir)
    df, err = load_all_data(data_dir)
    if err:
        print(f"Info: {err}")
        # Still generate an empty report
        report = build_markdown({}, [], args.site_name)
    else:
        stats = compute_site_stats(df)
        daily = compute_daily_stats(df)
        report = build_markdown(stats, daily, args.site_name)

    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
        print(f"Report written to: {args.output}")
    else:
        print(report)

    return 0


if __name__ == "__main__":
    sys.exit(main())
