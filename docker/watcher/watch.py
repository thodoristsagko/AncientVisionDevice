"""
File watcher: polls ./data/field/.sample_count every POLL_INTERVAL seconds.
Writes ./data/.retrain_trigger when new samples since last run >= TRIGGER_THRESHOLD.
"""
import os
import time
from pathlib import Path

TRIGGER_THRESHOLD = int(os.environ.get("TRIGGER_THRESHOLD", "100"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))


def _read_int(path: Path, default: int = 0) -> int:
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def should_trigger(data_dir: Path) -> bool:
    total = _read_int(data_dir / "field" / ".sample_count")
    baseline = _read_int(data_dir / ".baseline_count")
    return (total - baseline) >= TRIGGER_THRESHOLD


def reset_baseline(data_dir: Path) -> None:
    total = _read_int(data_dir / "field" / ".sample_count")
    (data_dir / ".baseline_count").write_text(str(total))


def main() -> None:
    data_dir = Path(os.environ.get("DATA_DIR", "/workspace/data"))
    trigger_file = data_dir / ".retrain_trigger"
    print(f"Watching {data_dir} — trigger at {TRIGGER_THRESHOLD} new samples", flush=True)
    while True:
        if not trigger_file.exists() and should_trigger(data_dir):
            print("Threshold reached — writing .retrain_trigger", flush=True)
            trigger_file.touch()
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
