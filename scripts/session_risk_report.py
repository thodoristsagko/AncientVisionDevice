#!/usr/bin/env python3
"""
session_risk_report.py — Generate per-session risk assessment from collected data.

Usage:
    python scripts/session_risk_report.py [--data-dir DIR] [--session-gap SECONDS]

Groups readings into sessions (gap > session_gap seconds = new session, default 300s).
For each session: start time, duration, max PPV, alert count, risk level.
Risk levels: LOW (max PPV < 0.3), MEDIUM (0.3-1.0), HIGH (>1.0 mm/s).
Outputs ASCII table sorted by risk (HIGH first).
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
DEFAULT_SESSION_GAP = 300  # seconds

# DIN 4150-3 PPV thresholds (mm/s)
PPV_LOW_MAX = 0.3
PPV_MEDIUM_MAX = 1.0

RISK_ORDER = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}

# Alert anomaly levels that count as alerts
ALERT_LEVELS = {"soil_creep", "crack_propagation", "imminent_failure", "alert", "warning"}


def load_csv_files(data_dir: str) -> list:
    """Load all CSV rows from data_dir. Returns list of dicts sorted by timestamp."""
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
    # Try several common formats
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


def _ppv_risk_level(max_ppv: float) -> str:
    """Return DIN 4150-3 risk level string for a given max PPV (mm/s)."""
    if max_ppv > PPV_MEDIUM_MAX:
        return "HIGH"
    if max_ppv >= PPV_LOW_MAX:
        return "MEDIUM"
    return "LOW"


def group_sessions(rows: list, session_gap_s: float) -> list:
    """
    Group rows into sessions based on timestamp gaps.

    Returns list of dicts, each describing one session:
        start_ts, end_ts, readings, max_ppv, alert_count
    """
    # Filter rows with valid timestamps and ppv
    valid = []
    for row in rows:
        ts = _parse_timestamp(row.get("timestamp", ""))
        if ts < 0:
            continue
        try:
            ppv = float(row.get("ppv", "0") or "0")
        except (ValueError, TypeError):
            ppv = 0.0
        valid.append((ts, ppv, row))

    if not valid:
        return []

    # Sort by timestamp
    valid.sort(key=lambda x: x[0])

    sessions = []
    current_readings = []
    current_ppvs = []
    current_alerts = 0
    session_start = valid[0][0]
    prev_ts = valid[0][0]

    for ts, ppv, row in valid:
        if ts - prev_ts > session_gap_s and current_readings:
            # Close the current session
            sessions.append({
                "start_ts": session_start,
                "end_ts": prev_ts,
                "readings": list(current_readings),
                "max_ppv": max(current_ppvs) if current_ppvs else 0.0,
                "alert_count": current_alerts,
            })
            # Start new session
            current_readings = []
            current_ppvs = []
            current_alerts = 0
            session_start = ts

        current_readings.append(row)
        current_ppvs.append(ppv)
        anomaly = row.get("anomaly_level", "normal") or "normal"
        if anomaly.lower() in ALERT_LEVELS:
            current_alerts += 1
        prev_ts = ts

    # Close last session
    if current_readings:
        sessions.append({
            "start_ts": session_start,
            "end_ts": prev_ts,
            "readings": current_readings,
            "max_ppv": max(current_ppvs) if current_ppvs else 0.0,
            "alert_count": current_alerts,
        })

    return sessions


def build_session_records(sessions: list) -> list:
    """
    Convert raw session dicts to display records:
        start, end, duration_min, total_readings, alert_count, max_ppv, risk_level
    """
    records = []
    for s in sessions:
        start_dt = datetime.fromtimestamp(s["start_ts"], tz=timezone.utc)
        end_dt = datetime.fromtimestamp(s["end_ts"], tz=timezone.utc)
        duration_min = (s["end_ts"] - s["start_ts"]) / 60.0
        risk = _ppv_risk_level(s["max_ppv"])
        records.append({
            "start": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "end": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "duration_min": duration_min,
            "total_readings": len(s["readings"]),
            "alert_count": s["alert_count"],
            "max_ppv": s["max_ppv"],
            "risk_level": risk,
        })
    return records


def sort_records(records: list) -> list:
    """Sort by risk_level desc, then max_ppv desc."""
    return sorted(records, key=lambda r: (RISK_ORDER[r["risk_level"]], -r["max_ppv"]))


def print_table(records: list) -> None:
    """Print ASCII table of session risk records."""
    col_widths = {
        "start": 20,
        "end": 20,
        "duration_min": 12,
        "total_readings": 14,
        "alert_count": 12,
        "max_ppv": 10,
        "risk_level": 10,
    }
    headers = {
        "start": "Start",
        "end": "End",
        "duration_min": "Duration(m)",
        "total_readings": "Readings",
        "alert_count": "Alerts",
        "max_ppv": "MaxPPV",
        "risk_level": "Risk",
    }
    # Build separator
    sep = "+" + "+".join("-" * (w + 2) for w in col_widths.values()) + "+"
    # Header row
    header_row = (
        "| "
        + " | ".join(
            headers[k].center(col_widths[k]) for k in col_widths
        )
        + " |"
    )

    print(sep)
    print(header_row)
    print(sep)

    for rec in records:
        row_parts = []
        for k, w in col_widths.items():
            val = rec[k]
            if k == "duration_min":
                cell = f"{val:.1f}".rjust(w)
            elif k == "max_ppv":
                cell = f"{val:.4f}".rjust(w)
            elif k == "risk_level":
                cell = str(val).center(w)
            else:
                cell = str(val).ljust(w)
            row_parts.append(cell)
        print("| " + " | ".join(row_parts) + " |")

    print(sep)


def print_summary(records: list) -> None:
    """Print summary counts by risk level."""
    total = len(records)
    high = sum(1 for r in records if r["risk_level"] == "HIGH")
    medium = sum(1 for r in records if r["risk_level"] == "MEDIUM")
    low = sum(1 for r in records if r["risk_level"] == "LOW")
    print(f"\nTotal: {total} sessions, {high} high-risk, {medium} medium-risk, {low} low-risk")


def main(argv=None):
    """Entry point. Always exits 0."""
    parser = argparse.ArgumentParser(
        description="Generate per-session risk assessment report from collected CSV data."
    )
    parser.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        help=f"Directory containing field CSV files (default: {DEFAULT_DATA_DIR})",
    )
    parser.add_argument(
        "--session-gap",
        type=float,
        default=DEFAULT_SESSION_GAP,
        help=f"Gap in seconds between readings that starts a new session (default: {DEFAULT_SESSION_GAP})",
    )
    args = parser.parse_args(argv)

    rows = load_csv_files(args.data_dir)
    sessions = group_sessions(rows, args.session_gap)

    if not sessions:
        print("No sessions found")
        sys.exit(0)

    records = build_session_records(sessions)
    records = sort_records(records)
    print_table(records)
    print_summary(records)
    sys.exit(0)


if __name__ == "__main__":
    main()
