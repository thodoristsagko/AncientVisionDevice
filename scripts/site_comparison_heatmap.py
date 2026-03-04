#!/usr/bin/env python3
"""Generate an ASCII heatmap of peak PPV values across a dig site.

Reads session data with GPS coordinates, groups measurements into a
configurable grid, and renders a colour-coded ASCII heatmap to the
terminal showing peak PPV per grid cell.

Usage
-----
    python site_comparison_heatmap.py [--input session.csv] [--cell-size 5]
    python site_comparison_heatmap.py --input data.csv --cell-size 2
    python site_comparison_heatmap.py --host 192.168.1.10 --port 8765

Expected CSV columns (or JSON fields from /data API):
    lat, lon, ppv   — required
    timestamp       — optional (used for display only)

Grid
----
The bounding box of all GPS points is divided into cells of `cell_size`
metres (approximate).  One degree of latitude ≈ 111 000 m; one degree of
longitude ≈ 111 000 * cos(lat) m.

Output
------
Each cell prints the peak PPV in mm/s using a three-tier symbol:
  . (dot)   — PPV < 0.3 mm/s   (DIN 4150-3 safe zone)
  * (star)  — PPV 0.3–1.0 mm/s (warning zone)
  # (hash)  — PPV > 1.0 mm/s   (exceedance zone)
  (space)   — no measurements in this cell

Orientation: north is up (highest lat at top), west is left.
"""

import argparse
import csv
import json
import math
import sys
import urllib.error
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

METERS_PER_DEGREE_LAT: float = 111_000.0

# DIN 4150-3 thresholds (mm/s)
PPV_SAFE_MAX: float = 0.3
PPV_WARN_MAX: float = 1.0

# Symbols for each tier (from safe to critical)
SYM_SAFE: str = "."
SYM_WARN: str = "*"
SYM_CRIT: str = "#"
SYM_EMPTY: str = " "


# ---------------------------------------------------------------------------
# Data loading  (same pattern as battery_life_estimator.py)
# ---------------------------------------------------------------------------

def _fetch_from_api(host: str, port: int) -> list[dict]:
    url = f"http://{host}:{port}/data"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Cannot reach collector at {url}: {exc}") from exc

    if isinstance(raw, dict):
        return raw.get("samples", raw.get("data", []))
    if isinstance(raw, list):
        return raw
    raise RuntimeError(f"Unexpected API response type: {type(raw)}")


def _load_csv(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def load_data(input_path: str | None, host: str, port: int) -> list[dict]:
    if input_path:
        return _load_csv(input_path)
    return _fetch_from_api(host, port)


# ---------------------------------------------------------------------------
# Grid computation
# ---------------------------------------------------------------------------

def _safe_float(value, default: float = float("nan")) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def build_grid(
    rows: list[dict],
    cell_size_m: float,
) -> tuple[list[list[float]], dict]:
    """Build a 2-D grid of peak PPV values.

    Parameters
    ----------
    rows : list[dict]
        Data rows; each must have 'lat', 'lon', 'ppv' fields.
    cell_size_m : float
        Desired cell size in metres.

    Returns
    -------
    grid : list[list[float]]
        2-D list [row][col] of peak PPV (NaN = no data).
        Row 0 is the northernmost (highest latitude) row.
    meta : dict
        Grid metadata: lat_min, lat_max, lon_min, lon_max,
        n_rows, n_cols, cell_size_m, point_count.
    """
    # ---- Filter rows with valid coordinates ------------------------------
    points: list[tuple[float, float, float]] = []  # (lat, lon, ppv)
    for row in rows:
        lat = _safe_float(row.get("lat"))
        lon = _safe_float(row.get("lon"))
        ppv = _safe_float(row.get("ppv"))
        if not (math.isnan(lat) or math.isnan(lon) or math.isnan(ppv)):
            points.append((lat, lon, ppv))

    if not points:
        return [], {
            "lat_min": 0, "lat_max": 0, "lon_min": 0, "lon_max": 0,
            "n_rows": 0, "n_cols": 0, "cell_size_m": cell_size_m,
            "point_count": 0,
        }

    lats = [p[0] for p in points]
    lons = [p[1] for p in points]

    lat_min, lat_max = min(lats), max(lats)
    lon_min, lon_max = min(lons), max(lons)

    # Convert cell size to degrees
    mid_lat = (lat_min + lat_max) / 2.0
    deg_lat_per_cell = cell_size_m / METERS_PER_DEGREE_LAT
    cos_lat = math.cos(math.radians(mid_lat)) or 1e-9
    deg_lon_per_cell = cell_size_m / (METERS_PER_DEGREE_LAT * cos_lat)

    # Grid dimensions — at least 1 cell in each direction
    lat_span = lat_max - lat_min
    lon_span = lon_max - lon_min

    n_rows = max(1, math.ceil(lat_span / deg_lat_per_cell) + 1)
    n_cols = max(1, math.ceil(lon_span / deg_lon_per_cell) + 1)

    # Initialise with NaN
    grid: list[list[float]] = [
        [float("nan")] * n_cols for _ in range(n_rows)
    ]

    # Populate grid — row 0 = northernmost (highest lat)
    for lat, lon, ppv in points:
        if deg_lat_per_cell > 0:
            row_idx = int((lat_max - lat) / deg_lat_per_cell)
        else:
            row_idx = 0
        if deg_lon_per_cell > 0:
            col_idx = int((lon - lon_min) / deg_lon_per_cell)
        else:
            col_idx = 0

        row_idx = max(0, min(n_rows - 1, row_idx))
        col_idx = max(0, min(n_cols - 1, col_idx))

        existing = grid[row_idx][col_idx]
        if math.isnan(existing) or ppv > existing:
            grid[row_idx][col_idx] = ppv

    meta = {
        "lat_min": lat_min,
        "lat_max": lat_max,
        "lon_min": lon_min,
        "lon_max": lon_max,
        "n_rows": n_rows,
        "n_cols": n_cols,
        "cell_size_m": cell_size_m,
        "point_count": len(points),
    }
    return grid, meta


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _cell_symbol(ppv: float) -> str:
    if math.isnan(ppv):
        return SYM_EMPTY
    if ppv > PPV_WARN_MAX:
        return SYM_CRIT
    if ppv > PPV_SAFE_MAX:
        return SYM_WARN
    return SYM_SAFE


def render_heatmap(grid: list[list[float]], meta: dict) -> str:
    """Render ASCII heatmap string from grid and metadata."""
    if not grid:
        return "(no GPS data to display)"

    n_rows = meta["n_rows"]
    n_cols = meta["n_cols"]

    lines: list[str] = []

    # Header
    lines.append("")
    lines.append("=" * (n_cols + 4))
    lines.append(
        f"  AncientVision Site Heatmap  "
        f"({n_rows}x{n_cols} grid, cell={meta['cell_size_m']:.0f} m)"
    )
    lines.append(
        f"  Points: {meta['point_count']}  "
        f"Lat [{meta['lat_min']:.5f}, {meta['lat_max']:.5f}]  "
        f"Lon [{meta['lon_min']:.5f}, {meta['lon_max']:.5f}]"
    )
    lines.append("=" * (n_cols + 4))

    # North label
    lines.append("  N")
    lines.append("  ^")

    # Grid rows (row 0 = northernmost)
    for r in range(n_rows):
        row_syms = "".join(_cell_symbol(grid[r][c]) for c in range(n_cols))
        lines.append(f"  {row_syms}")

    lines.append("")
    lines.append("  --> E")
    lines.append("")

    # Legend
    lines.append("  Legend:")
    lines.append(f"    {SYM_EMPTY}  = no data")
    lines.append(f"    {SYM_SAFE}  = PPV < {PPV_SAFE_MAX} mm/s  (DIN 4150-3 safe)")
    lines.append(f"    {SYM_WARN}  = PPV {PPV_SAFE_MAX}–{PPV_WARN_MAX} mm/s  (warning)")
    lines.append(f"    {SYM_CRIT}  = PPV > {PPV_WARN_MAX} mm/s  (exceedance)")
    lines.append("")

    return "\n".join(lines)


def render_stats(grid: list[list[float]], meta: dict) -> str:
    """Return a brief stats summary string."""
    all_vals = [
        grid[r][c]
        for r in range(meta["n_rows"])
        for c in range(meta["n_cols"])
        if not math.isnan(grid[r][c])
    ]
    if not all_vals:
        return "  No measurements found."

    return (
        f"  Max PPV : {max(all_vals):.4f} mm/s\n"
        f"  Min PPV : {min(all_vals):.4f} mm/s\n"
        f"  Avg PPV : {sum(all_vals)/len(all_vals):.4f} mm/s\n"
        f"  Cells   : {len(all_vals)} populated / "
        f"{meta['n_rows'] * meta['n_cols']} total"
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Render ASCII heatmap of peak PPV values across a dig site."
    )
    p.add_argument("--input", "-i", metavar="FILE",
                   help="CSV file to read (default: use collector API).")
    p.add_argument("--host", default="localhost",
                   help="Collector API host (default: localhost).")
    p.add_argument("--port", type=int, default=8765,
                   help="Collector API port (default: 8765).")
    p.add_argument("--cell-size", type=float, default=5.0, metavar="M",
                   help="Grid cell size in metres (default: 5).")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        rows = load_data(args.input, args.host, args.port)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    grid, meta = build_grid(rows, args.cell_size)
    print(render_heatmap(grid, meta))
    print(render_stats(grid, meta))
    print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
