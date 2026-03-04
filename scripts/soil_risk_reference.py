#!/usr/bin/env python3
"""
Vibration safety standards reference for archaeological sites.

Provides threshold lookup, standard comparison, and risk assessment
based on PPV values against multiple international standards.

Usage:
    python scripts/soil_risk_reference.py                  # Show all standards
    python scripts/soil_risk_reference.py --ppv 0.5        # Assess a PPV value
    python scripts/soil_risk_reference.py --list standards # List all standards
"""

import argparse
import sys

# Vibration standards database
STANDARDS = {
    "DIN 4150-3 (Germany)": {
        "description": "Structural vibration limits for buildings",
        "categories": {
            "Sensitive structures (monuments, ruins)": 0.2,
            "Residential buildings (day)": 5.0,
            "Residential buildings (night)": 2.5,
            "Commercial/industrial buildings": 10.0,
        },
        "reference": "DIN 4150-3:1999",
        "notes": "Lower values for foundations of historic structures",
    },
    "BS 7385-2 (UK)": {
        "description": "British Standard for building vibrations",
        "categories": {
            "Residential (4 Hz continuous)": 2.0,
            "Residential (10 Hz continuous)": 4.0,
            "Residential (50 Hz continuous)": 10.0,
            "Historic structures (guideline)": 0.5,
        },
        "reference": "BS 7385-2:1993",
        "notes": "Frequency-dependent — values shown for typical frequencies",
    },
    "ISO 4866": {
        "description": "International standard for structural vibration",
        "categories": {
            "Sensitive equipment/heritage (general)": 0.5,
            "Residential (low sensitivity)": 5.0,
            "Industrial": 15.0,
        },
        "reference": "ISO 4866:2010",
        "notes": "Framework standard; requires national adaptation",
    },
    "EPRI Arias Intensity": {
        "description": "Earthquake engineering ground motion metric",
        "categories": {
            "Low damage potential (AI < 0.05 m/s)": 0.05,
            "Moderate damage potential (AI < 0.3 m/s)": 0.3,
            "High damage potential (AI > 0.3 m/s)": 1.0,
        },
        "reference": "EPRI NP-6728",
        "notes": "Arias Intensity in m/s, not directly PPV",
    },
    "AncientVision Custom (Archaeological)": {
        "description": "Conservative thresholds for fragile soil structures",
        "categories": {
            "Safe (undisturbed baseline)": 0.1,
            "Monitor (increased attention)": 0.3,
            "Anomaly (possible precursor)": 1.0,
            "Critical (imminent risk)": 3.0,
        },
        "reference": "Internal — AncientVision v5",
        "notes": "Tuned for loose/granular archaeological soil; lower than construction standards",
    },
}


def assess_ppv(ppv: float) -> list:
    """Assess a PPV value against all standards. Returns list of findings."""
    findings = []
    for std_name, std in STANDARDS.items():
        exceeded = []
        safe_under = []
        for category, threshold in std["categories"].items():
            if ppv > threshold:
                exceeded.append((category, threshold))
            else:
                safe_under.append((category, threshold))
        findings.append({
            "standard": std_name,
            "exceeded": exceeded,
            "safe_under": safe_under,
            "reference": std["reference"],
        })
    return findings


def print_standards():
    """Print all standards reference table."""
    enc = getattr(sys.stdout, "encoding", "utf-8") or "utf-8"
    use_unicode = enc.lower().startswith("utf")
    TICK = "✓" if use_unicode else "OK"
    WARN = "⚠" if use_unicode else "!!"

    print()
    print("=" * 65)
    print("  Vibration Safety Standards — Archaeological Site Reference")
    print("=" * 65)

    for std_name, std in STANDARDS.items():
        print()
        print(f"  {std_name}")
        print(f"  {std['description']}")
        print(f"  Reference: {std['reference']}")
        if std.get("notes"):
            print(f"  Note: {std['notes']}")
        print()
        print(f"  {'Category':<45} {'Threshold':>10}")
        print("  " + "-" * 58)
        for category, threshold in std["categories"].items():
            print(f"  {category:<45} {threshold:>9.2f} mm/s")

    print()
    print("=" * 65)
    print()


def print_ppv_assessment(ppv: float):
    """Print assessment of a given PPV value."""
    enc = getattr(sys.stdout, "encoding", "utf-8") or "utf-8"
    use_unicode = enc.lower().startswith("utf")
    TICK = "✓" if use_unicode else "OK"
    WARN = "⚠" if use_unicode else "!!"
    DANGER = "✗" if use_unicode else "XX"

    findings = assess_ppv(ppv)

    print()
    print("=" * 65)
    print(f"  PPV Assessment: {ppv:.3f} mm/s")
    print("=" * 65)

    for f in findings:
        std = f["standard"]
        exceeded = f["exceeded"]
        safe_under = f["safe_under"]

        if not exceeded:
            status = f"  {TICK} WITHIN LIMITS"
        elif len(exceeded) == len(exceeded) + len(safe_under):
            status = f"  {DANGER} EXCEEDS ALL LIMITS"
        else:
            status = f"  {WARN} EXCEEDS {len(exceeded)} LIMIT(S)"

        print()
        print(f"  [{f['reference']}] {std}")
        print(f"  {status}")

        for cat, thresh in exceeded:
            print(f"    {DANGER} EXCEEDS {cat}: {thresh:.2f} mm/s")
        for cat, thresh in safe_under[:2]:  # Show first 2 safe categories
            print(f"    {TICK} Safe under {cat}: {thresh:.2f} mm/s")

    print()
    print("=" * 65)

    # Overall verdict
    all_findings = assess_ppv(ppv)
    total_exceeded = sum(len(f["exceeded"]) for f in all_findings)
    if total_exceeded == 0:
        verdict = "SAFE — within all monitored standards"
    elif total_exceeded <= 2:
        verdict = "CAUTION — exceeds some conservative thresholds"
    else:
        verdict = "WARNING — exceeds multiple standard limits"
    print(f"  Overall: {verdict}")
    print("=" * 65)
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Vibration safety standards reference for archaeological sites"
    )
    parser.add_argument("--ppv", type=float, help="Assess a specific PPV value (mm/s)")
    parser.add_argument("--list", choices=["standards"], help="List available standards")
    args = parser.parse_args()

    if args.ppv is not None:
        print_ppv_assessment(args.ppv)
    else:
        print_standards()

    return 0


if __name__ == "__main__":
    sys.exit(main())
