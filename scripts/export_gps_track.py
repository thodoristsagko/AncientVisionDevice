#!/usr/bin/env python3
"""
Export GPS track data from AncientVision field sessions as GPX or KML.

Reads field CSVs containing lat/lon columns and exports waypoints
colored by anomaly level, suitable for Google Earth or GPS devices.

Usage:
    python scripts/export_gps_track.py --data-dir ./data/field --format gpx
    python scripts/export_gps_track.py --data-dir ./data/field --format kml --output track.kml
"""

import argparse
import sys
from datetime import datetime
from pathlib import Path
from xml.etree.ElementTree import Element, SubElement, tostring
from xml.dom import minidom

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False


# Color mapping for KML (AABBGGRR format)
KML_COLORS = {
    "CRITICAL":   "ff0000ff",  # red
    "ANOMALY":    "ff00aaff",  # amber/orange
    "SAFE":       "ff00ff00",  # green
    "normal":     "ff00ff00",
    "soil_creep": "ff00d7ff",  # gold
    "crack_propagation": "ff0088ff",  # orange
    "imminent_failure":  "ff0000ff",  # red
}

GPX_HEADER = """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="AncientVision"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
     xsi:schemaLocation="http://www.topografix.com/GPX/1/1
     http://www.topografix.com/GPX/1/1/gpx.xsd">
"""


def load_field_data(data_dir: Path):
    """Load all field CSVs with lat/lon data."""
    if not HAS_PANDAS:
        return None, "pandas not available"

    csv_files = sorted(data_dir.glob("*.csv"))
    if not csv_files:
        return None, f"No CSV files in {data_dir}"

    frames = []
    for f in csv_files:
        try:
            df = pd.read_csv(f)
            # Accept various column name conventions
            for lat_col in ["lat", "latitude", "gps_lat"]:
                if lat_col in df.columns:
                    df = df.rename(columns={lat_col: "lat"})
                    break
            for lon_col in ["lon", "longitude", "gps_lon"]:
                if lon_col in df.columns:
                    df = df.rename(columns={lon_col: "lon"})
                    break
            if "lat" in df.columns and "lon" in df.columns:
                frames.append(df)
        except Exception:
            continue

    if not frames:
        return None, "No CSV files with GPS data (need lat/lon columns)"

    merged = pd.concat(frames, ignore_index=True)
    merged = merged.dropna(subset=["lat", "lon"])
    merged = merged[(merged["lat"].abs() <= 90) & (merged["lon"].abs() <= 180)]

    return merged, None


def export_gpx(df, output_path: Path):
    """Export as GPX trackpoints."""
    lines = [GPX_HEADER, "  <trk><name>AncientVision Field Session</name><trkseg>\n"]

    for _, row in df.iterrows():
        lat = float(row["lat"])
        lon = float(row["lon"])
        ts = row.get("timestamp", "")
        ppv = row.get("ppv", "")
        level = row.get("anomaly_level", "")

        lines.append(f'    <trkpt lat="{lat:.6f}" lon="{lon:.6f}">\n')
        if ts:
            lines.append(f"      <time>{ts}</time>\n")
        desc_parts = []
        if ppv:
            desc_parts.append(f"PPV:{ppv}")
        if level:
            desc_parts.append(f"Level:{level}")
        if desc_parts:
            lines.append(f"      <desc>{' '.join(desc_parts)}</desc>\n")
        lines.append("    </trkpt>\n")

    lines.append("  </trkseg></trk>\n</gpx>")

    text = "".join(lines)
    output_path.write_text(text, encoding="utf-8")
    return len(df)


def export_kml(df, output_path: Path):
    """Export as KML with color-coded placemarks by anomaly level."""
    kml = Element("kml", xmlns="http://www.opengis.net/kml/2.2")
    doc = SubElement(kml, "Document")
    name_el = SubElement(doc, "name")
    name_el.text = "AncientVision Field Session"

    # Add styles
    for level, color in KML_COLORS.items():
        style = SubElement(doc, "Style", id=f"style_{level}")
        icon_style = SubElement(style, "IconStyle")
        color_el = SubElement(icon_style, "color")
        color_el.text = color
        scale_el = SubElement(icon_style, "scale")
        scale_el.text = "0.8"

    # Add placemarks
    folder = SubElement(doc, "Folder")
    folder_name = SubElement(folder, "name")
    folder_name.text = "Vibration Events"

    for i, (_, row) in enumerate(df.iterrows()):
        lat = float(row["lat"])
        lon = float(row["lon"])
        ppv = row.get("ppv", 0.0)
        level = str(row.get("anomaly_level", row.get("label", "SAFE")))

        pm = SubElement(folder, "Placemark")
        pm_name = SubElement(pm, "name")
        pm_name.text = f"Event {i+1}"

        desc = SubElement(pm, "description")
        desc_parts = [f"PPV: {ppv} mm/s", f"Level: {level}"]
        if "timestamp" in row:
            desc_parts.append(f"Time: {row['timestamp']}")
        desc.text = " | ".join(desc_parts)

        style_url = SubElement(pm, "styleUrl")
        style_url.text = f"#style_{level}"

        point = SubElement(pm, "Point")
        coords = SubElement(point, "coordinates")
        coords.text = f"{lon:.6f},{lat:.6f},0"

    # Pretty-print XML
    xml_str = minidom.parseString(tostring(kml)).toprettyxml(indent="  ")
    output_path.write_text(xml_str, encoding="utf-8")
    return len(df)


def main():
    parser = argparse.ArgumentParser(description="Export GPS track from field sessions")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--format", choices=["gpx", "kml"], default="gpx")
    parser.add_argument("--output", help="Output file path (default: track.gpx or track.kml)")
    args = parser.parse_args()

    if not HAS_PANDAS:
        print("pandas required: pip install pandas")
        return 1

    data_dir = Path(args.data_dir)
    df, err = load_field_data(data_dir)

    if err:
        print(f"Info: {err}")
        print("To add GPS data, ensure your field CSVs have 'lat' and 'lon' columns.")
        return 0

    ext = args.format
    output_path = Path(args.output) if args.output else Path(f"track.{ext}")

    if args.format == "gpx":
        count = export_gpx(df, output_path)
    else:
        count = export_kml(df, output_path)

    print(f"Exported {count} GPS points to: {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
