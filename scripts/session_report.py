#!/usr/bin/env python3
"""
Generate a Markdown or HTML report from a session's field data.

The session CSV must have at minimum: timestamp, ppv, anomaly_level
Optional columns: device_id, rms, freq, kurtosis, label

Usage:
    python scripts/session_report.py --session-csv path/to/session.csv
    python scripts/session_report.py --session-csv path/to/session.csv \\
        --output report.md --format md --site-name "Paros North Trench"
    python scripts/session_report.py --session-csv path/to/session.csv \\
        --output report.html --format html
"""

import argparse
import csv
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# DIN 4150-3 residential PPV limit (mm/s) — 1–10 Hz range (most conservative)
DIN_4150_RESIDENTIAL = 3.0

ANOMALY_LEVELS_ORDERED = ["normal", "anomaly", "critical"]


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _parse_float(val: str) -> float:
    """Parse float from string, returning 0.0 on error."""
    try:
        return float(val)
    except (ValueError, TypeError):
        return 0.0


def _parse_timestamp(val: str) -> datetime | None:
    """Parse ISO-8601 timestamp string to datetime (UTC).  Returns None on failure."""
    if not val:
        return None
    # Strip trailing Z and microseconds variants
    val = val.strip()
    formats = [
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
    ]
    # Handle trailing Z (Python < 3.11 strptime doesn't grok Z)
    if val.endswith("Z"):
        val = val[:-1] + "+00:00"
    for fmt in formats:
        try:
            dt = datetime.strptime(val, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


def load_csv(path: Path) -> list[dict]:
    """Load CSV rows, parsing numeric fields. Skips rows with unparseable timestamps."""
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ts = _parse_timestamp(row.get("timestamp", ""))
            if ts is None:
                continue
            rows.append({
                "timestamp": ts,
                "ppv":           _parse_float(row.get("ppv", "0")),
                "rms":           _parse_float(row.get("rms", "0")),
                "freq":          _parse_float(row.get("freq", "0")),
                "kurtosis":      _parse_float(row.get("kurtosis", "0")),
                "anomaly_level": row.get("anomaly_level", row.get("label", "normal")).strip().lower(),
                "device_id":     row.get("device_id", "").strip(),
            })
    return sorted(rows, key=lambda r: r["timestamp"])


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def _percentile(values: list[float], pct: float) -> float:
    """Compute p-th percentile of values (0–100)."""
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * pct / 100.0
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def compute_stats(rows: list[dict]) -> dict:
    """Return a statistics dict computed from session rows."""
    if not rows:
        return {}

    first_ts = rows[0]["timestamp"]
    last_ts = rows[-1]["timestamp"]
    duration_s = (last_ts - first_ts).total_seconds()
    n = len(rows)
    sample_rate = n / duration_s if duration_s > 0 else 0.0

    ppvs = [r["ppv"] for r in rows]
    mean_ppv = sum(ppvs) / n if n else 0.0
    max_ppv = max(ppvs) if ppvs else 0.0
    p95_ppv = _percentile(ppvs, 95)

    # Anomaly level distribution
    level_counts: dict[str, int] = {}
    for r in rows:
        lvl = r["anomaly_level"] or "normal"
        level_counts[lvl] = level_counts.get(lvl, 0) + 1

    level_pct: dict[str, float] = {
        lvl: count / n * 100.0 for lvl, count in level_counts.items()
    }

    # Alert count: anomaly or critical
    alert_count = sum(
        1 for r in rows if r["anomaly_level"] in ("anomaly", "critical")
    )
    critical_count = sum(
        1 for r in rows if r["anomaly_level"] == "critical"
    )

    # Dominant precursor pattern (most frequent non-normal label among class labels)
    # The collector uses anomaly_level; classify by anomaly_level words
    non_normal_labels: dict[str, int] = {}
    for r in rows:
        lvl = r["anomaly_level"]
        if lvl and lvl not in ("normal", ""):
            non_normal_labels[lvl] = non_normal_labels.get(lvl, 0) + 1

    dominant_pattern = (
        max(non_normal_labels, key=lambda k: non_normal_labels[k])
        if non_normal_labels
        else "normal"
    )

    # DIN 4150-3 exceedances
    din_exceedances = sum(1 for v in ppvs if v > DIN_4150_RESIDENTIAL)

    # Device IDs
    device_ids = sorted({r["device_id"] for r in rows if r["device_id"]})

    return {
        "first_ts": first_ts,
        "last_ts": last_ts,
        "duration_s": duration_s,
        "sample_count": n,
        "sample_rate": sample_rate,
        "mean_ppv": mean_ppv,
        "max_ppv": max_ppv,
        "p95_ppv": p95_ppv,
        "level_counts": level_counts,
        "level_pct": level_pct,
        "alert_count": alert_count,
        "critical_count": critical_count,
        "dominant_pattern": dominant_pattern,
        "din_exceedances": din_exceedances,
        "device_ids": device_ids,
        "ppvs": ppvs,
        "rows": rows,
    }


# ---------------------------------------------------------------------------
# ASCII charts
# ---------------------------------------------------------------------------

def _format_duration(seconds: float) -> str:
    """Format seconds as e.g. '1h 23m 5s'."""
    secs = int(seconds)
    h = secs // 3600
    m = (secs % 3600) // 60
    s = secs % 60
    parts = []
    if h:
        parts.append(f"{h}h")
    if m or h:
        parts.append(f"{m}m")
    parts.append(f"{s}s")
    return " ".join(parts)


def _ascii_bar_chart(rows: list[dict], bin_minutes: int = 5) -> str:
    """Return ASCII bar chart of PPV over time in bin_minutes-minute bins."""
    if not rows:
        return "(no data)"

    first_ts = rows[0]["timestamp"]
    bin_secs = bin_minutes * 60

    # Accumulate max PPV per bin
    bins: dict[int, list[float]] = {}
    for r in rows:
        elapsed = (r["timestamp"] - first_ts).total_seconds()
        b = int(elapsed // bin_secs)
        bins.setdefault(b, []).append(r["ppv"])

    if not bins:
        return "(no data)"

    max_bin = max(bins)
    # Compute max PPV per bin (using peak, which is most safety-relevant)
    bin_maxes = {b: max(v) for b, v in bins.items()}
    global_max = max(bin_maxes.values()) if bin_maxes else 1.0
    bar_width = 40

    lines = [f"{'Time':>8}  {'PPV peak (mm/s)':30}  Max"]
    for b in range(max_bin + 1):
        t_min = b * bin_minutes
        peak = bin_maxes.get(b, 0.0)
        filled = int(round(peak / global_max * bar_width)) if global_max > 0 else 0
        bar = "#" * filled + "-" * (bar_width - filled)
        marker = " <-- DIN" if peak > DIN_4150_RESIDENTIAL else ""
        lines.append(f"{t_min:>6}m  [{bar}]  {peak:.3f}{marker}")

    return "\n".join(lines)


def _ascii_level_bars(level_pct: dict[str, float]) -> str:
    """Return ASCII bar representation of anomaly level percentages."""
    bar_width = 30
    lines = []
    for lvl in ["normal", "anomaly", "critical"]:
        pct = level_pct.get(lvl, 0.0)
        filled = int(round(pct / 100.0 * bar_width))
        bar = "#" * filled + "-" * (bar_width - filled)
        lines.append(f"  {lvl:<12} [{bar}]  {pct:.1f}%")
    # Any other levels
    for lvl, pct in sorted(level_pct.items()):
        if lvl not in ("normal", "anomaly", "critical"):
            filled = int(round(pct / 100.0 * bar_width))
            bar = "#" * filled + "-" * (bar_width - filled)
            lines.append(f"  {lvl:<12} [{bar}]  {pct:.1f}%")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Markdown report builder
# ---------------------------------------------------------------------------

def build_markdown(stats: dict, site_name: str) -> str:
    """Build a Markdown session report from stats dict."""
    s = stats
    date_str = s["first_ts"].strftime("%Y-%m-%d")
    duration_str = _format_duration(s["duration_s"])
    device_str = ", ".join(s["device_ids"]) if s["device_ids"] else "Unknown"

    lines = []
    lines.append("# AncientVision Field Session Report")
    lines.append("")
    lines.append(
        f"**Date**: {date_str}  "
        f"**Duration**: {duration_str}  "
        f"**Device**: {device_str}"
    )
    if site_name:
        lines.append(f"**Site**: {site_name}")
    lines.append("")

    # Summary section
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- Samples: {s['sample_count']:,} ({s['sample_rate']:.1f} Hz)")
    lines.append(f"- Mean PPV: {s['mean_ppv']:.3f} mm/s")
    lines.append(f"- Peak PPV: {s['max_ppv']:.3f} mm/s")
    lines.append(f"- 95th percentile PPV: {s['p95_ppv']:.3f} mm/s")

    anomaly_pct = s["level_pct"].get("anomaly", 0.0) + s["level_pct"].get("critical", 0.0)
    lines.append(f"- Time in ANOMALY or CRITICAL: {anomaly_pct:.1f}%")
    lines.append(f"- Total alerts (anomaly + critical): {s['alert_count']}")
    lines.append(f"- Critical alerts: {s['critical_count']}")
    lines.append(f"- Dominant non-normal pattern: {s['dominant_pattern']}")
    lines.append("")

    # PPV Timeline
    lines.append("## PPV Timeline")
    lines.append("")
    lines.append("Max PPV per 5-minute bin:")
    lines.append("")
    lines.append("```")
    lines.append(_ascii_bar_chart(s["rows"], bin_minutes=5))
    lines.append("```")
    lines.append("")

    # Anomaly distribution
    lines.append("## Anomaly Level Distribution")
    lines.append("")
    lines.append("```")
    lines.append(_ascii_level_bars(s["level_pct"]))
    lines.append("```")
    lines.append("")

    # Recommendations
    lines.append("## Recommendations")
    lines.append("")
    lines.append("Based on the session data:")
    lines.append("")

    if s["din_exceedances"] > 0:
        lines.append(
            f"- **PPV exceeded DIN 4150-3 residential limit ({DIN_4150_RESIDENTIAL} mm/s)**"
            f" {s['din_exceedances']} time(s). "
            "Site evacuation protocol should be reviewed."
        )
    else:
        lines.append(
            f"- PPV stayed below DIN 4150-3 residential limit ({DIN_4150_RESIDENTIAL} mm/s)."
        )

    if s["critical_count"] > 0:
        lines.append(
            f"- **{s['critical_count']} CRITICAL alert(s) detected.** "
            "Review session for imminent-failure precursors."
        )

    if s["dominant_pattern"] == "imminent_failure":
        lines.append(
            "- **Dominant pattern: imminent_failure.** "
            "Strong recommendation to suspend excavation and assess structural stability."
        )
    elif s["dominant_pattern"] == "crack_propagation":
        lines.append(
            "- Dominant pattern: crack_propagation. "
            "Increased monitoring frequency recommended."
        )
    elif s["dominant_pattern"] == "soil_creep":
        lines.append(
            "- Dominant pattern: soil_creep. "
            "Monitor for escalation; ensure drainage is clear."
        )
    else:
        lines.append(
            "- No significant anomaly pattern detected. Normal operations may continue."
        )

    lines.append("")
    lines.append("---")
    lines.append(
        f"*Generated by AncientVision session_report.py — "
        f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}*"
    )
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# HTML report builder (minimal)
# ---------------------------------------------------------------------------

def build_html(stats: dict, site_name: str) -> str:
    """Build a minimal HTML session report from stats dict."""
    md = build_markdown(stats, site_name)
    # Convert bare-minimum Markdown to HTML without external deps
    import html as html_lib
    escaped = html_lib.escape(md)
    # Very light conversion: headings, bold, code blocks
    lines_out = []
    in_code = False
    for line in md.split("\n"):
        if line.startswith("```"):
            if not in_code:
                lines_out.append("<pre><code>")
                in_code = True
            else:
                lines_out.append("</code></pre>")
                in_code = False
            continue
        if in_code:
            lines_out.append(html_lib.escape(line))
            continue
        # Headings
        if line.startswith("### "):
            lines_out.append(f"<h3>{html_lib.escape(line[4:])}</h3>")
        elif line.startswith("## "):
            lines_out.append(f"<h2>{html_lib.escape(line[3:])}</h2>")
        elif line.startswith("# "):
            lines_out.append(f"<h1>{html_lib.escape(line[2:])}</h1>")
        elif line.startswith("- "):
            # Bold inside list item
            content = html_lib.escape(line[2:])
            content = _bold_to_html(content)
            lines_out.append(f"<li>{content}</li>")
        elif line.startswith("---"):
            lines_out.append("<hr>")
        elif line.startswith("*") and line.endswith("*"):
            lines_out.append(f"<em>{html_lib.escape(line[1:-1])}</em>")
        elif line.strip() == "":
            lines_out.append("<br>")
        else:
            content = html_lib.escape(line)
            content = _bold_to_html(content)
            lines_out.append(f"<p>{content}</p>")

    body = "\n".join(lines_out)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AncientVision Session Report</title>
  <style>
    body {{ font-family: monospace; max-width: 900px; margin: 40px auto; padding: 0 20px; }}
    h1 {{ color: #2c3e50; }}
    h2 {{ color: #34495e; border-bottom: 1px solid #ccc; padding-bottom: 4px; }}
    pre {{ background: #f4f4f4; padding: 12px; overflow-x: auto; }}
    li {{ margin: 4px 0; }}
    b {{ color: #c0392b; }}
  </style>
</head>
<body>
{body}
</body>
</html>
"""


def _bold_to_html(text: str) -> str:
    """Convert **text** to <b>text</b> (simple, non-nested)."""
    import re
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate a Markdown or HTML report from a field session CSV."
    )
    parser.add_argument(
        "--session-csv",
        required=True,
        metavar="PATH",
        help="Path to session CSV file.",
    )
    parser.add_argument(
        "--output",
        default=None,
        metavar="PATH",
        help="Output file path (default: print to stdout).",
    )
    parser.add_argument(
        "--format",
        choices=["md", "html"],
        default="md",
        help="Output format: md (Markdown) or html (default: md).",
    )
    parser.add_argument(
        "--site-name",
        default="",
        metavar="NAME",
        help="Optional site name to include in report header.",
    )
    args = parser.parse_args(argv)

    csv_path = Path(args.session_csv)
    if not csv_path.exists():
        print(f"ERROR: Session CSV not found: {csv_path}", file=sys.stderr)
        sys.exit(1)

    rows = load_csv(csv_path)
    if not rows:
        print("ERROR: No valid rows found in CSV (check timestamp column).", file=sys.stderr)
        sys.exit(1)

    stats = compute_stats(rows)

    if args.format == "html":
        content = build_html(stats, args.site_name)
    else:
        content = build_markdown(stats, args.site_name)

    if args.output:
        out_path = Path(args.output)
        out_path.write_text(content, encoding="utf-8")
        print(f"Report written to: {out_path}", file=sys.stderr)
    else:
        print(content)


if __name__ == "__main__":
    main()
