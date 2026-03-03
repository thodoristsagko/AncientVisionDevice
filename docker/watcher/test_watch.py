from pathlib import Path
from watch import should_trigger, reset_baseline, TRIGGER_THRESHOLD


def test_no_trigger_below_threshold(tmp_path):
    count_file = tmp_path / "field" / ".sample_count"
    count_file.parent.mkdir()
    count_file.write_text("50")
    (tmp_path / ".baseline_count").write_text("0")
    assert should_trigger(tmp_path) is False


def test_triggers_at_threshold(tmp_path):
    count_file = tmp_path / "field" / ".sample_count"
    count_file.parent.mkdir()
    count_file.write_text("100")
    (tmp_path / ".baseline_count").write_text("0")
    assert should_trigger(tmp_path) is True


def test_no_trigger_when_already_triggered(tmp_path):
    count_file = tmp_path / "field" / ".sample_count"
    count_file.parent.mkdir()
    count_file.write_text("200")
    (tmp_path / ".baseline_count").write_text("150")
    assert should_trigger(tmp_path) is False  # only 50 new


def test_reset_baseline(tmp_path):
    (tmp_path / "field").mkdir()
    (tmp_path / "field" / ".sample_count").write_text("250")
    reset_baseline(tmp_path)
    assert int((tmp_path / ".baseline_count").read_text()) == 250
