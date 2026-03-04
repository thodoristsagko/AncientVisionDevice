#!/usr/bin/env python3
"""
Live terminal dashboard for AncientVision data pipeline.
Shows real-time stats from the data collector API.

Usage:
    python scripts/live_dashboard.py [--url http://localhost:8765] [--interval 2]
    python scripts/live_dashboard.py --url http://192.168.1.10:8765 --interval 5
    python scripts/live_dashboard.py --data-dir /path/to/data
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

try:
    import curses
    _CURSES_AVAILABLE = True
except ImportError:
    _CURSES_AVAILABLE = False

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

LABELS = ("normal", "soil_creep", "crack_propagation", "imminent_failure")

# LABEL_COLORS only used internally by _init_colors(); guarded at call sites.
_LABEL_COLORS_SPEC = {
    "normal":            "GREEN",
    "soil_creep":        "YELLOW",
    "crack_propagation": "MAGENTA",
    "imminent_failure":  "RED",
}


def _fetch_json(url: str, timeout: float = 3.0):
    """
    Fetch JSON from URL.  Returns (data_dict, None) on success,
    (None, error_string) on failure.
    """
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read()), None
    except urllib.error.URLError as exc:
        return None, f"URLError: {exc.reason}"
    except Exception as exc:
        return None, str(exc)


def fetch_health(base_url: str):
    return _fetch_json(f"{base_url}/health")


def fetch_stats(base_url: str):
    return _fetch_json(f"{base_url}/stats")


def fetch_recent(base_url: str, n: int = 5):
    return _fetch_json(f"{base_url}/data?per_page={n}&page=1")


# ---------------------------------------------------------------------------
# Curses colour pairs
# ---------------------------------------------------------------------------

# Pair numbers (1-indexed, only meaningful when curses is available)
PAIR_HEADER  = 1
PAIR_HEALTHY = 2
PAIR_WARN    = 3
PAIR_ERROR   = 4
PAIR_DIM     = 5
PAIR_LABEL   = {
    "normal":            6,
    "soil_creep":        7,
    "crack_propagation": 8,
    "imminent_failure":  9,
}
PAIR_BAR     = 10


def _init_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(PAIR_HEADER,  curses.COLOR_CYAN,    -1)
    curses.init_pair(PAIR_HEALTHY, curses.COLOR_GREEN,   -1)
    curses.init_pair(PAIR_WARN,    curses.COLOR_YELLOW,  -1)
    curses.init_pair(PAIR_ERROR,   curses.COLOR_RED,     -1)
    curses.init_pair(PAIR_DIM,     curses.COLOR_WHITE,   -1)
    curses.init_pair(PAIR_LABEL["normal"],            curses.COLOR_GREEN,   -1)
    curses.init_pair(PAIR_LABEL["soil_creep"],        curses.COLOR_YELLOW,  -1)
    curses.init_pair(PAIR_LABEL["crack_propagation"], curses.COLOR_MAGENTA, -1)
    curses.init_pair(PAIR_LABEL["imminent_failure"],  curses.COLOR_RED,     -1)
    curses.init_pair(PAIR_BAR,     curses.COLOR_BLUE,   -1)


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

def _safe_addstr(win, y: int, x: int, text: str, attr=0):
    """addstr that silently ignores out-of-bounds writes."""
    max_y, max_x = win.getmaxyx()
    if y < 0 or y >= max_y or x < 0 or x >= max_x:
        return
    # Clip text to available width
    available = max_x - x - 1
    if available <= 0:
        return
    try:
        win.addstr(y, x, text[:available], attr)
    except curses.error:
        pass


def _draw_bar(win, y: int, x: int, value: int, max_value: int, width: int, pair: int):
    """Draw an ASCII bar chart: value/max_value scaled to width chars."""
    if max_value == 0:
        filled = 0
    else:
        filled = int(round(width * value / max_value))
    filled = min(filled, width)
    bar = "\u2588" * filled + " " * (width - filled)
    _safe_addstr(win, y, x, bar, curses.color_pair(pair))


def _draw_hline(win, y: int, char: str = "-"):
    max_y, max_x = win.getmaxyx()
    if y < 0 or y >= max_y:
        return
    _safe_addstr(win, y, 0, char * (max_x - 1), curses.color_pair(PAIR_DIM))


# ---------------------------------------------------------------------------
# Main draw routine
# ---------------------------------------------------------------------------

def draw_dashboard(
    stdscr,
    base_url: str,
    data_dir: Path,
    health_data,
    health_err,
    stats_data,
    stats_err,
    recent_data,
    recent_err,
    last_refresh: float,
    interval: int,
):
    """Render the full dashboard onto stdscr."""
    stdscr.erase()
    max_y, max_x = stdscr.getmaxyx()

    row = 0

    # -----------------------------------------------------------------------
    # 1. Header
    # -----------------------------------------------------------------------
    now_str = datetime.now().strftime("%Y-%m-%d  %H:%M:%S")
    title = "  AncientVision Live Dashboard"
    _safe_addstr(stdscr, row, 0, title + " " * (max_x - len(title) - len(now_str) - 1) + now_str,
                 curses.color_pair(PAIR_HEADER) | curses.A_BOLD)
    row += 1
    _draw_hline(stdscr, row, "=")
    row += 1

    # -----------------------------------------------------------------------
    # 2. Collector status
    # -----------------------------------------------------------------------
    _safe_addstr(stdscr, row, 0, "COLLECTOR STATUS", curses.color_pair(PAIR_HEADER) | curses.A_BOLD)
    row += 1

    if health_err:
        _safe_addstr(stdscr, row, 2, "\u25cf Collector OFFLINE", curses.color_pair(PAIR_ERROR) | curses.A_BOLD)
        _safe_addstr(stdscr, row, 24, f"({health_err})", curses.color_pair(PAIR_ERROR))
        row += 1
    else:
        is_healthy = isinstance(health_data, dict) and health_data.get("status") == "ok"
        dot_color = PAIR_HEALTHY if is_healthy else PAIR_WARN
        status_label = "healthy" if is_healthy else "degraded"
        _safe_addstr(stdscr, row, 2, f"\u25cf {status_label.upper()}", curses.color_pair(dot_color) | curses.A_BOLD)

        if isinstance(health_data, dict):
            uptime = health_data.get("uptime_seconds", health_data.get("uptime", "?"))
            if isinstance(uptime, (int, float)):
                h = int(uptime) // 3600
                m = (int(uptime) % 3600) // 60
                s = int(uptime) % 60
                uptime_str = f"  uptime {h:02d}:{m:02d}:{s:02d}"
            else:
                uptime_str = f"  uptime {uptime}"
            _safe_addstr(stdscr, row, 20, uptime_str, curses.color_pair(PAIR_DIM))
        row += 1

    _safe_addstr(stdscr, row, 2,
                 f"URL: {base_url}   refresh every {interval}s   last update: {time.strftime('%H:%M:%S', time.localtime(last_refresh))}",
                 curses.color_pair(PAIR_DIM))
    row += 1
    _draw_hline(stdscr, row)
    row += 1

    # -----------------------------------------------------------------------
    # 3. Sample stats
    # -----------------------------------------------------------------------
    _safe_addstr(stdscr, row, 0, "SAMPLE STATS", curses.color_pair(PAIR_HEADER) | curses.A_BOLD)
    row += 1

    if stats_err or not isinstance(stats_data, dict):
        _safe_addstr(stdscr, row, 2, "No stats available", curses.color_pair(PAIR_WARN))
        row += 1
    else:
        total = stats_data.get("total_samples", stats_data.get("total", 0))
        devices = stats_data.get("devices", stats_data.get("device_counts", {}))

        _safe_addstr(stdscr, row, 2, f"Total samples: {total}", curses.color_pair(PAIR_DIM))
        row += 1

        if isinstance(devices, dict) and devices:
            _safe_addstr(stdscr, row, 2, "Per device:", curses.color_pair(PAIR_DIM))
            row += 1
            bar_width = max(10, min(40, max_x - 30))
            max_dev = max(devices.values()) if devices.values() else 1
            for dev_id, count in sorted(devices.items()):
                label_part = f"  {dev_id[:16]:<16} {count:>5}  "
                _safe_addstr(stdscr, row, 0, label_part, curses.color_pair(PAIR_DIM))
                _draw_bar(stdscr, row, len(label_part), count, max_dev, bar_width, PAIR_BAR)
                row += 1
                if row >= max_y - 2:
                    break

    _draw_hline(stdscr, row)
    row += 1

    # -----------------------------------------------------------------------
    # 4. Class distribution
    # -----------------------------------------------------------------------
    _safe_addstr(stdscr, row, 0, "CLASS DISTRIBUTION", curses.color_pair(PAIR_HEADER) | curses.A_BOLD)
    row += 1

    class_counts = {}
    if isinstance(stats_data, dict):
        # Try several key names the collector might use
        class_counts = (
            stats_data.get("class_distribution") or
            stats_data.get("label_counts") or
            stats_data.get("classes") or
            {}
        )

    if not isinstance(class_counts, dict) or not class_counts:
        _safe_addstr(stdscr, row, 2, "No class data available", curses.color_pair(PAIR_WARN))
        row += 1
    else:
        bar_width = max(10, min(40, max_x - 35))
        max_cls = max(class_counts.values()) if class_counts.values() else 1
        for lbl in LABELS:
            count = class_counts.get(lbl, 0)
            pair = PAIR_LABEL.get(lbl, PAIR_DIM)
            label_part = f"  {lbl:<22} {count:>5}  "
            _safe_addstr(stdscr, row, 0, label_part, curses.color_pair(pair))
            _draw_bar(stdscr, row, len(label_part), count, max_cls, bar_width, pair)
            row += 1
            if row >= max_y - 2:
                break

    _draw_hline(stdscr, row)
    row += 1

    # -----------------------------------------------------------------------
    # 5. Recent activity
    # -----------------------------------------------------------------------
    _safe_addstr(stdscr, row, 0, "RECENT ACTIVITY  (last 5 samples)", curses.color_pair(PAIR_HEADER) | curses.A_BOLD)
    row += 1

    if recent_err or not isinstance(recent_data, dict):
        _safe_addstr(stdscr, row, 2, "No recent data", curses.color_pair(PAIR_WARN))
        row += 1
    else:
        samples = recent_data.get("data", recent_data.get("samples", []))
        if not samples:
            _safe_addstr(stdscr, row, 2, "(empty)", curses.color_pair(PAIR_DIM))
            row += 1
        else:
            for sample in samples[:5]:
                if row >= max_y - 2:
                    break
                ts   = sample.get("timestamp", "??:??:??")[-8:]  # HH:MM:SS
                dev  = str(sample.get("device_id", "?"))[:12]
                lbl  = str(sample.get("label", "?"))
                ppv  = sample.get("ppv", 0.0)
                rms  = sample.get("rms", 0.0)
                pair = PAIR_LABEL.get(lbl, PAIR_DIM)
                line = f"  {ts}  {dev:<12}  ppv={ppv:6.3f}  rms={rms:6.4f}  "
                _safe_addstr(stdscr, row, 0, line, curses.color_pair(PAIR_DIM))
                _safe_addstr(stdscr, row, len(line), f"[{lbl}]", curses.color_pair(pair) | curses.A_BOLD)
                row += 1

    _draw_hline(stdscr, row)
    row += 1

    # -----------------------------------------------------------------------
    # 6. Trainer status
    # -----------------------------------------------------------------------
    _safe_addstr(stdscr, row, 0, "TRAINER STATUS", curses.color_pair(PAIR_HEADER) | curses.A_BOLD)
    row += 1

    trigger_file = data_dir / ".retrain_trigger"
    if trigger_file.exists():
        mtime = datetime.fromtimestamp(trigger_file.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
        _safe_addstr(stdscr, row, 2, f"\u25cf Retrain PENDING", curses.color_pair(PAIR_WARN) | curses.A_BOLD)
        _safe_addstr(stdscr, row, 22, f"  (trigger file created {mtime})", curses.color_pair(PAIR_DIM))
    else:
        _safe_addstr(stdscr, row, 2, "\u25cf No retrain pending", curses.color_pair(PAIR_HEALTHY))
    row += 1

    # -----------------------------------------------------------------------
    # Footer
    # -----------------------------------------------------------------------
    footer = "  Press q to quit"
    if row < max_y - 1:
        _safe_addstr(stdscr, max_y - 1, 0, footer, curses.color_pair(PAIR_DIM) | curses.A_REVERSE)

    stdscr.refresh()


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def _run(stdscr, args):
    """Main curses event loop."""
    _init_colors()
    curses.curs_set(0)         # hide cursor
    stdscr.nodelay(True)       # non-blocking getch
    stdscr.timeout(200)        # getch timeout 200 ms

    base_url = args.url.rstrip("/")
    interval = args.interval
    data_dir = Path(args.data_dir)

    health_data = health_err = None
    stats_data  = stats_err  = None
    recent_data = recent_err = None
    last_refresh = 0.0

    while True:
        # Check for 'q' key
        ch = stdscr.getch()
        if ch in (ord("q"), ord("Q")):
            break

        # Refresh data if interval has elapsed
        now = time.time()
        if now - last_refresh >= interval:
            health_data, health_err  = fetch_health(base_url)
            stats_data,  stats_err   = fetch_stats(base_url)
            recent_data, recent_err  = fetch_recent(base_url, n=5)
            last_refresh = now

        draw_dashboard(
            stdscr, base_url, data_dir,
            health_data, health_err,
            stats_data,  stats_err,
            recent_data, recent_err,
            last_refresh, interval,
        )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Live terminal dashboard for AncientVision data pipeline."
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8765",
        help="Collector base URL (default: http://localhost:8765)",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=2,
        help="Poll interval in seconds (default: 2)",
    )
    parser.add_argument(
        "--data-dir",
        default="./data",
        help="Path to data directory (checked for .retrain_trigger, default: ./data)",
    )
    args = parser.parse_args(argv)

    if not _CURSES_AVAILABLE:
        print(
            "Error: curses is not available on this platform.\n"
            "  On Windows, install windows-curses:  pip install windows-curses\n"
            "  Or run inside the Docker ml-dev container:\n"
            "    make dev-ml\n"
            "    python scripts/live_dashboard.py",
            file=sys.stderr,
        )
        return 1

    try:
        curses.wrapper(_run, args)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
