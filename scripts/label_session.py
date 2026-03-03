#!/usr/bin/env python3
"""Interactive CLI tool to label rows in a field CSV session.

Usage:
    python scripts/label_session.py <csv_file>
    python scripts/label_session.py data/field/session_001.csv
    python scripts/label_session.py data/field/session_001.csv --start-label normal
    python scripts/label_session.py data/field/session_001.csv --relabel

For each row the tool prints a one-line summary and prompts for a label:

    [12:34:56] PPV=0.234 RMS=0.123 FREQ=8.5  KURTOSIS=2.1
    Label [n=normal, a=anomaly, p=precursor, s=skip, q=quit]:

Supported keys:
  n — normal
  a — anomaly
  s — soil_creep
  c — crack_propagation
  f — imminent_failure
  S — skip (do not change label for this row)
  q — quit (saves current progress and exits)

Behaviour:
  - Rows that already have a non-empty `label` are skipped unless --relabel is set.
  - After each label is chosen the row is written back to disk immediately
    (no data loss on Ctrl+C — the partial file is always valid CSV).
  - A summary of labels applied in this session is printed on exit.

Keyboard input: uses single-keypress on Linux/macOS (tty/termios) and falls
back to line-buffered input() on Windows or when stdin is not a terminal.

Uses only stdlib — no external packages required.
"""

import argparse
import csv
import os
import sys
import signal

# ---------------------------------------------------------------------------
# Key map
# ---------------------------------------------------------------------------

KEY_MAP = {
    "n": "normal",
    "a": "anomaly",
    "s": "soil_creep",
    "c": "crack_propagation",
    "f": "imminent_failure",
}
SKIP_KEY = "S"
QUIT_KEY = "q"

PROMPT = (
    f"Label [n=normal, a=anomaly, s=soil_creep, c=crack_propagation, "
    f"f=imminent_failure, S=skip, q=quit]: "
)

# ---------------------------------------------------------------------------
# Single-keypress input (Unix) with Windows fallback
# ---------------------------------------------------------------------------

def _try_import_tty():
    """Return (tty, termios) modules if available, else (None, None)."""
    try:
        import tty
        import termios
        return tty, termios
    except ImportError:
        return None, None


def read_single_key(prompt: str) -> str:
    """Read a single character without requiring Enter.

    Falls back to input() on Windows or non-TTY stdin.
    """
    tty_mod, termios_mod = _try_import_tty()

    if tty_mod is None or not sys.stdin.isatty():
        # Windows or non-interactive: use line-buffered input
        sys.stdout.write(prompt)
        sys.stdout.flush()
        line = input()
        return line.strip()[:1] if line.strip() else ""

    # Unix single-keypress
    sys.stdout.write(prompt)
    sys.stdout.flush()
    fd = sys.stdin.fileno()
    old_settings = termios_mod.tcgetattr(fd)
    try:
        tty_mod.setraw(fd)
        ch = sys.stdin.read(1)
    finally:
        termios_mod.tcsetattr(fd, termios_mod.TCSADRAIN, old_settings)
    sys.stdout.write("\n")
    sys.stdout.flush()
    return ch


# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------

def load_csv(path: str) -> tuple:
    """Return (fieldnames, rows) from a CSV file.

    rows is a list of OrderedDict (csv.DictReader output).
    """
    if not os.path.isfile(path):
        print(f"Error: file not found: {path}", file=sys.stderr)
        sys.exit(1)
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            fieldnames = reader.fieldnames or []
            rows = [dict(row) for row in reader]
        return list(fieldnames), rows
    except (OSError, csv.Error) as exc:
        print(f"Error reading {path}: {exc}", file=sys.stderr)
        sys.exit(1)


def save_csv(path: str, fieldnames: list, rows: list) -> None:
    """Write rows back to the CSV file, preserving column order."""
    try:
        with open(path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
    except OSError as exc:
        print(f"\nError saving {path}: {exc}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Row summary formatting
# ---------------------------------------------------------------------------

TIMESTAMP_COLS = ("timestamp", "time", "ts", "datetime")


def _detect_col(row: dict, candidates: tuple) -> str | None:
    for c in candidates:
        if c in row:
            return c
    return None


def _fmt_float(row: dict, col: str, label: str, width: int = 7, decimals: int = 3) -> str:
    raw = row.get(col, "")
    try:
        val = float(raw)
        return f"{label}={val:{width}.{decimals}f}"
    except (TypeError, ValueError):
        return f"{label}=     N/A"


def format_row_summary(idx: int, total: int, row: dict) -> str:
    """Format a one-line summary of a CSV row for display."""
    ts_col = _detect_col(row, TIMESTAMP_COLS)
    ts_str = ""
    if ts_col:
        raw_ts = row.get(ts_col, "").strip()
        # Show only the time portion if it looks like ISO datetime
        if "T" in raw_ts:
            ts_str = raw_ts.split("T")[1][:8]
        elif " " in raw_ts:
            ts_str = raw_ts.split(" ")[1][:8]
        else:
            ts_str = raw_ts[:8]

    ts_part = f"[{ts_str}]" if ts_str else f"[row {idx+1}]"

    ppv_part = _fmt_float(row, "ppv", "PPV")
    rms_part = _fmt_float(row, "rms", "RMS")
    freq_part = _fmt_float(row, "freq", "FREQ", width=6, decimals=1)
    kurt_part = _fmt_float(row, "kurtosis", "KURTOSIS", width=5, decimals=2)

    progress = f"({idx+1}/{total})"
    return f"{progress:>10}  {ts_part}  {ppv_part}  {rms_part}  {freq_part}  {kurt_part}"


# ---------------------------------------------------------------------------
# Labeling loop
# ---------------------------------------------------------------------------

def label_session(
    csv_path: str,
    start_label: str,
    relabel: bool,
) -> None:
    """Run the interactive labeling session."""

    fieldnames, rows = load_csv(csv_path)

    # Ensure 'label' column exists
    if "label" not in fieldnames:
        fieldnames.append("label")
        for row in rows:
            row.setdefault("label", "")

    total = len(rows)
    if total == 0:
        print("No rows found in CSV.")
        return

    # Statistics for this session
    session_counts: dict = {}
    rows_labeled_this_session = 0
    rows_skipped = 0
    rows_already_labeled = 0

    # Handle Ctrl+C gracefully — save before exiting
    def _handle_sigint(sig, frame):
        print("\n\n[Interrupted] Saving current progress...")
        save_csv(csv_path, fieldnames, rows)
        _print_summary(session_counts, rows_labeled_this_session, rows_already_labeled, rows_skipped)
        sys.exit(0)

    signal.signal(signal.SIGINT, _handle_sigint)

    print(f"\nLabeling session: {csv_path}  ({total} rows)")
    print(f"  Relabel existing: {'yes' if relabel else 'no'}")
    if start_label:
        print(f"  Default label: {start_label}")
    print()

    for idx, row in enumerate(rows):
        existing_label = row.get("label", "").strip()

        # Skip already-labeled rows unless --relabel
        if existing_label and not relabel:
            rows_already_labeled += 1
            continue

        # Print row summary
        print(format_row_summary(idx, total, row))
        if existing_label:
            print(f"  (current label: {existing_label})")

        while True:
            key = read_single_key(PROMPT)

            if key == QUIT_KEY:
                print("\nQuitting. Saving progress...")
                save_csv(csv_path, fieldnames, rows)
                _print_summary(
                    session_counts, rows_labeled_this_session,
                    rows_already_labeled, rows_skipped,
                )
                return

            if key == SKIP_KEY or key == "":
                rows_skipped += 1
                print(f"  -> skipped")
                break

            if key in KEY_MAP:
                label = KEY_MAP[key]
                row["label"] = label
                session_counts[label] = session_counts.get(label, 0) + 1
                rows_labeled_this_session += 1
                print(f"  -> {label}")
                # Save after every label (no data loss on Ctrl+C)
                save_csv(csv_path, fieldnames, rows)
                break

            # Unknown key — give hint
            valid = ", ".join(f"{k}={v}" for k, v in KEY_MAP.items())
            print(f"  Unknown key '{key}'. Valid: {valid}, S=skip, q=quit")

    print("\nAll rows processed.")
    save_csv(csv_path, fieldnames, rows)
    _print_summary(session_counts, rows_labeled_this_session, rows_already_labeled, rows_skipped)


def _print_summary(
    session_counts: dict,
    labeled: int,
    already: int,
    skipped: int,
) -> None:
    """Print end-of-session summary."""
    print()
    print("Session Summary")
    print("===============")
    print(f"  Labeled this session : {labeled}")
    print(f"  Already labeled      : {already} (skipped)")
    print(f"  Skipped (S key)      : {skipped}")
    if session_counts:
        print()
        print("  Labels applied:")
        for label in sorted(session_counts.keys()):
            print(f"    {label:<25}: {session_counts[label]}")
    print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Interactive CLI to label rows in a field CSV session."
    )
    parser.add_argument("csv_file", metavar="CSV_FILE", help="Path to the CSV file to label.")
    parser.add_argument(
        "--start-label",
        default="",
        metavar="LABEL",
        help=(
            "Default label to suggest (informational only — user still confirms). "
            "Example: --start-label normal"
        ),
    )
    parser.add_argument(
        "--relabel",
        action="store_true",
        default=False,
        help="Re-prompt for rows that already have a label (default: skip them).",
    )
    args = parser.parse_args()

    label_session(
        csv_path=args.csv_file,
        start_label=args.start_label,
        relabel=args.relabel,
    )


if __name__ == "__main__":
    main()
