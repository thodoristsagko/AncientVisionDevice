#!/usr/bin/env python3
"""
compliance_report.py — Vibration standard compliance report.

Checks field data against vibration exposure standards:
  DIN 4150-3  (Germany)  — building damage thresholds (mm/s)
  BS 7385-2   (UK)       — building vibration limits  (mm/s)
  ISO 4866    (ISO)      — vibration measurement and evaluation guidelines

Usage:
  python scripts/compliance_report.py --standard all
  python scripts/compliance_report.py --standard din
  python scripts/compliance_report.py --input session.csv --standard bs
"""

import argparse
import csv
import json
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Standard threshold definitions (PPV in mm/s)
# ---------------------------------------------------------------------------

# Each level: (label, threshold_mm_s)
# A measurement exceeds a level when PPV > threshold.
STANDARDS = {
    "din": {
        "name": "DIN 4150-3",
        "description": "German standard — structural vibration, residential buildings",
        "levels": [
            ("Category I  (sensitive)",  0.3),
            ("Category II (normal)",     1.0),
            ("Category III (robust)",    5.0),
        ],
        "unit": "mm/s",
    },
    "bs": {
        "name": "BS 7385-2",
        "description": "UK standard — evaluation of vibration in buildings",
        "levels": [
            ("Category I",    3.0),
            ("Category II",  10.0),
            ("Category III", 50.0),
        ],
        "unit": "mm/s",
    },
    "iso": {
        "name": "ISO 4866",
        "description": "International — mechanical vibration of fixed structures",
        "levels": [
            ("Zone A (negligible)",   0.5),
            ("Zone B (acceptable)",   2.0),
            ("Zone C (undesirable)", 10.0),
        ],
        "unit": "mm/s",
    },
}


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_ppv_from_csv(path: str) -> list:
    """Load PPV values from a CSV file. Returns list of floats."""
    values = []
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            raw = row.get("ppv") or row.get("PPV") or row.get("peak_ppv")
            if raw is None:
                continue
            try:
                v = float(raw)
            except (TypeError, ValueError):
                continue
            if v >= 0 and v == v:  # non-negative and not NaN
                values.append(v)
    return values


def load_ppv_from_api(host: str, port: int) -> list:
    """Fetch PPV values from the collector REST API."""
    import urllib.error
    import urllib.request

    url = f"http://{host}:{port}/data"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Cannot reach collector at {url}: {exc}") from exc

    rows = raw if isinstance(raw, list) else raw.get("samples", raw.get("data", []))
    values = []
    for row in rows:
        v_raw = row.get("ppv") or row.get("PPV")
        if v_raw is None:
            continue
        try:
            v = float(v_raw)
        except (TypeError, ValueError):
            continue
        if v >= 0 and v == v:
            values.append(v)
    return values


# ---------------------------------------------------------------------------
# Compliance logic
# ---------------------------------------------------------------------------

def check_standard(ppv_values: list, standard_key: str) -> dict:
    """Check PPV values against one standard.

    Returns a dict with:
      standard_key, name, description,
      total_samples, max_ppv,
      levels: list[{label, threshold, exceedances, compliant}],
      overall_compliant: bool
    """
    std = STANDARDS[standard_key]
    total = len(ppv_values)
    max_ppv = max(ppv_values) if ppv_values else 0.0

    level_results = []
    overall_compliant = True

    for label, threshold in std["levels"]:
        count = sum(1 for v in ppv_values if v > threshold)
        compliant = (count == 0)
        if not compliant:
            overall_compliant = False
        level_results.append({
            "label": label,
            "threshold": threshold,
            "exceedances": count,
            "compliant": compliant,
        })

    return {
        "standard_key": standard_key,
        "name": std["name"],
        "description": std["description"],
        "total_samples": total,
        "max_ppv": max_ppv,
        "levels": level_results,
        "overall_compliant": overall_compliant,
    }


def run_compliance_checks(ppv_values: list, selected_standards: list) -> list:
    """Run checks for each selected standard. Returns list of result dicts."""
    return [check_standard(ppv_values, key) for key in selected_standards]


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def format_report(ppv_values: list, results: list) -> str:
    """Format compliance results as a human-readable string."""
    lines = []
    lines.append("")
    lines.append("=" * 68)
    lines.append("  AncientVision Vibration Compliance Report")
    lines.append("=" * 68)

    if not ppv_values:
        lines.append("  No PPV measurements found.")
        lines.append("=" * 68)
        return "\n".join(lines)

    lines.append(f"  Total measurements : {len(ppv_values)}")
    lines.append(f"  Max observed PPV   : {max(ppv_values):.4f} mm/s")
    lines.append(f"  Min observed PPV   : {min(ppv_values):.4f} mm/s")
    lines.append(f"  Avg observed PPV   : {sum(ppv_values)/len(ppv_values):.4f} mm/s")
    lines.append("")

    for result in results:
        status = "COMPLIANT" if result["overall_compliant"] else "EXCEEDANCE FOUND"
        lines.append(f"  [{status}] {result['name']}")
        lines.append(f"  {result['description']}")
        lines.append("")
        lines.append(f"    {'Level':<35} {'Limit':>7}  {'Exceed':>6}  Status")
        lines.append(f"    {'-'*35} {'-'*7}  {'-'*6}  {'-'*9}")
        for lvl in result["levels"]:
            t_str = f"{lvl['threshold']:>5.1f}"
            exc = lvl["exceedances"]
            lvl_status = "OK" if lvl["compliant"] else "FAIL"
            lines.append(
                f"    {lvl['label']:<35} {t_str} mm/s  {exc:>6}  {lvl_status}"
            )
        lines.append("")

    all_compliant = all(r["overall_compliant"] for r in results)
    lines.append("-" * 68)
    overall_label = (
        "FULLY COMPLIANT"
        if all_compliant
        else "NON-COMPLIANT — EXCEEDANCES DETECTED"
    )
    lines.append(f"  Overall: {overall_label}")
    lines.append("=" * 68)
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Compliance report against vibration exposure standards."
    )
    parser.add_argument(
        "--standard",
        choices=["din", "bs", "iso", "all"],
        default="all",
        help="Which standard to check (default: all)",
    )
    parser.add_argument(
        "--input", "-i",
        metavar="FILE",
        default=None,
        help="CSV file to read (default: use collector API).",
    )
    parser.add_argument(
        "--host",
        default="localhost",
        help="Collector API host (default: localhost).",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8765,
        help="Collector API port (default: 8765).",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output file path for the report (default: stdout)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Output raw JSON instead of formatted report.",
    )
    args = parser.parse_args(argv)

    # Load data
    try:
        if args.input:
            ppv_values = load_ppv_from_csv(args.input)
        else:
            ppv_values = load_ppv_from_api(args.host, args.port)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    selected = list(STANDARDS.keys()) if args.standard == "all" else [args.standard]
    results = run_compliance_checks(ppv_values, selected)

    if args.json_output:
        payload = {
            "total_measurements": len(ppv_values),
            "max_ppv": max(ppv_values) if ppv_values else 0.0,
            "standards": results,
            "all_compliant": all(r["overall_compliant"] for r in results),
        }
        report_text = json.dumps(payload, indent=2)
    else:
        report_text = format_report(ppv_values, results)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(report_text + "\n")
        print(f"Report written to: {args.output}")
    else:
        print(report_text)

    # Exit 1 if exceedances found or no data
    all_compliant = all(r["overall_compliant"] for r in results)
    if not ppv_values or not all_compliant:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
