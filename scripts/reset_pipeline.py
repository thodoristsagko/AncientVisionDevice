"""
Reset pipeline: clears the retrain trigger and resets the baseline counter
to the current sample count.  No data is deleted.

Usage:
    python scripts/reset_pipeline.py [--data-dir /workspace/data] [--dry-run]
"""
import argparse
import sys
from pathlib import Path


def _read_int(path: Path, default: int = 0) -> int:
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def reset_pipeline(data_dir: Path, dry_run: bool = False) -> dict:
    """
    Core logic — separated from CLI for easy unit-testing.

    Returns a dict describing what was (or would be) done:
      {
        "trigger_deleted": bool,
        "baseline_was":    int,
        "baseline_set_to": int,
        "dry_run":         bool,
      }
    """
    trigger_file = data_dir / ".retrain_trigger"
    sample_count_file = data_dir / "field" / ".sample_count"
    baseline_file = data_dir / ".baseline_count"

    trigger_exists = trigger_file.exists()
    current_count = _read_int(sample_count_file, default=0)
    old_baseline = _read_int(baseline_file, default=0)

    if not dry_run:
        if trigger_exists:
            trigger_file.unlink()
        baseline_file.write_text(str(current_count))

    return {
        "trigger_deleted": trigger_exists,
        "baseline_was": old_baseline,
        "baseline_set_to": current_count,
        "dry_run": dry_run,
    }


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(
        description="Reset the retrain trigger and baseline counter."
    )
    parser.add_argument(
        "--data-dir",
        default="/workspace/data",
        help="Data directory (default: /workspace/data).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be done without making any changes.",
    )
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)

    result = reset_pipeline(data_dir, dry_run=args.dry_run)

    prefix = "[DRY RUN] " if result["dry_run"] else ""

    if result["trigger_deleted"]:
        print(f"{prefix}Deleted {data_dir / '.retrain_trigger'}")
    else:
        print(f"{prefix}No .retrain_trigger found — nothing to delete.")

    print(
        f"{prefix}Baseline: {result['baseline_was']} -> {result['baseline_set_to']} "
        f"(written to {data_dir / '.baseline_count'})"
    )


if __name__ == "__main__":
    main()
