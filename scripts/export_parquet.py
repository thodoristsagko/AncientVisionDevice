#!/usr/bin/env python3
"""Export field CSV data to Parquet format for efficient analysis.

Falls back to JSON if pyarrow is not installed.

Usage:
    python scripts/export_parquet.py
    python scripts/export_parquet.py --data-dir ./data/field --output ./data/export.parquet
"""
import argparse, csv, json, os, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

NUMERIC_FIELDS = ["ppv", "rms", "freq", "crest", "kurtosis", "stalta",
                   "arias", "cav", "centroid", "temp"]

def load_csvs(data_dir):
    rows = []
    for f in sorted(os.listdir(data_dir)):
        if not f.endswith(".csv"):
            continue
        with open(os.path.join(data_dir, f), newline="") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                # Convert numeric fields
                clean = {}
                for k, v in row.items():
                    if k in NUMERIC_FIELDS:
                        try:
                            clean[k] = float(v) if v else None
                        except ValueError:
                            clean[k] = None
                    else:
                        clean[k] = v
                rows.append(clean)
    return rows

def export_parquet(rows, output_path):
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
        # Build table from list of dicts
        if not rows:
            print("No data to export.")
            return
        keys = list(rows[0].keys())
        arrays = {k: [r.get(k) for r in rows] for k in keys}
        table = pa.table(arrays)
        pq.write_table(table, output_path)
        print(f"Exported {len(rows)} rows to Parquet: {output_path}")
    except ImportError:
        # Fallback: JSON
        json_path = output_path.replace(".parquet", ".json")
        with open(json_path, "w") as f:
            json.dump(rows, f, indent=2)
        print(f"pyarrow not installed — exported {len(rows)} rows to JSON: {json_path}")

def main():
    parser = argparse.ArgumentParser(description="Export field CSV data to Parquet")
    parser.add_argument("--data-dir", default="./data/field")
    parser.add_argument("--output", default="./data/export.parquet")
    args = parser.parse_args()

    if not os.path.isdir(args.data_dir):
        print(f"No data dir at {args.data_dir}")
        sys.exit(1)
    rows = load_csvs(args.data_dir)
    if not rows:
        print("No CSV files found.")
        return
    export_parquet(rows, args.output)

if __name__ == "__main__":
    main()
