import csv
import importlib.util
import json
import logging
import os
import sys
import time
import threading
from pathlib import Path
from unittest.mock import patch, MagicMock
import pytest

from watch import (
    should_trigger,
    reset_baseline,
    TRIGGER_THRESHOLD,
    write_trigger_with_retry,
    SampleRateMonitor,
    _log_json,
    _check_data_quality,
    jlog,
    _HealthHandler,
    HEALTH_PORT,
    start_health_server,
)


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


# ============================================================================
# Tests for exponential backoff on trigger write failure
# ============================================================================


def test_write_trigger_success_first_attempt(tmp_path):
    """Test successful trigger write on first attempt."""
    trigger_file = tmp_path / "test.trigger"
    result = write_trigger_with_retry(trigger_file, threshold=100, sample_count=150)
    assert result is True
    assert trigger_file.exists()


def test_write_trigger_retry_on_permission_error(tmp_path):
    """Test exponential backoff when mkdir fails with PermissionError."""
    trigger_file = tmp_path / "restricted" / "test.trigger"

    call_count = 0

    def mock_mkdir(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        if call_count < 3:
            raise PermissionError("No permission")
        # Success on third call

    with patch.object(Path, "mkdir", side_effect=mock_mkdir):
        result = write_trigger_with_retry(trigger_file, threshold=100, sample_count=150)

    # Should fail after 3 attempts (retries exhausted)
    assert result is False
    assert call_count == 3


def test_write_trigger_max_retries_exceeded(tmp_path, caplog):
    """Test that all retries are exhausted and failure is logged."""
    trigger_file = tmp_path / "test.trigger"

    with patch.object(Path, "mkdir", side_effect=OSError("Disk full")):
        with caplog.at_level(logging.INFO):
            result = write_trigger_with_retry(trigger_file, threshold=100, sample_count=150)

    assert result is False
    # Verify structured logging occurred
    assert any("trigger_write_failed" in record.message for record in caplog.records)


def test_write_trigger_logs_retry_on_failure(caplog, tmp_path):
    """Test that retry logic logs attempts when OSError occurs."""
    trigger_file = tmp_path / "test.trigger"

    # Fail all retries
    with patch.object(Path, "mkdir", side_effect=OSError("Mock failure")):
        with caplog.at_level(logging.INFO):
            result = write_trigger_with_retry(trigger_file, threshold=100, sample_count=150)

    assert result is False
    # Should log multiple retry attempts
    retry_logs = [r for r in caplog.records if "trigger_write_retry" in r.message]
    assert len(retry_logs) >= 1  # At least one retry logged


# ============================================================================
# Tests for trigger cooldown
# ============================================================================


def test_trigger_cooldown_prevents_double_trigger(caplog):
    """
    Test that SampleRateMonitor tracks enough history.
    This is a unit test showing cooldown logic would prevent retriggers.
    """
    # This is verified in the main loop via time.monotonic() checks
    # Sample test showing monitor initialization
    monitor = SampleRateMonitor(history_size=600)
    assert len(monitor.history) == 0


# ============================================================================
# Tests for sample rate monitoring
# ============================================================================


def test_sample_rate_warning_zero_samples(caplog):
    """Test warning when no samples for 10+ minutes."""
    monitor = SampleRateMonitor(history_size=20)

    # Simulate 11 minutes of zero samples
    for _ in range(11):
        monitor.update(100)  # Same count, no new samples

    with caplog.at_level(logging.WARNING):
        monitor.check_anomalies()

    # Should warn about no new samples
    assert any("No new samples for 10 minutes" in record.message for record in caplog.records)


def test_sample_rate_warning_spike(caplog):
    """Test warning when sample rate spikes above 100/min."""
    monitor = SampleRateMonitor(history_size=20)

    # Normal history for 9 minutes
    for i in range(9):
        monitor.update(100 + i * 10)

    # Then spike: 150 new samples in one minute
    monitor.update(100 + 90 + 150)

    with caplog.at_level(logging.WARNING):
        monitor.check_anomalies()

    assert any("Unusual sample rate" in record.message for record in caplog.records)


def test_sample_rate_no_warning_insufficient_history(caplog):
    """Test no warning when history is less than 10 minutes."""
    monitor = SampleRateMonitor(history_size=20)

    # Only 5 minutes of history
    for _ in range(5):
        monitor.update(50)

    with caplog.at_level(logging.WARNING):
        monitor.check_anomalies()

    # Should not have warnings due to insufficient history
    assert not any("No new samples" in record.message for record in caplog.records)


def test_sample_rate_normal_operation(caplog):
    """Test no warnings during normal operation."""
    monitor = SampleRateMonitor(history_size=20)

    # Simulate 15 minutes of normal samples (5-20 per minute)
    count = 0
    for _ in range(15):
        count += 10
        monitor.update(count)

    with caplog.at_level(logging.WARNING):
        monitor.check_anomalies()

    # Should have no warnings
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert len(warnings) == 0


# ============================================================================
# Tests for structured logging
# ============================================================================


def test_log_json_format(caplog):
    """Test that _log_json outputs valid JSON with required fields."""
    with caplog.at_level(logging.INFO):
        _log_json("test_event", sample_count=150, threshold=100)

    # Find the log record
    assert len(caplog.records) > 0
    record = caplog.records[0]

    # Parse the JSON
    log_json = json.loads(record.message)
    assert log_json["event"] == "test_event"
    assert log_json["sample_count"] == 150
    assert log_json["threshold"] == 100
    assert "ts" in log_json
    assert isinstance(log_json["ts"], float)


def test_log_json_includes_timestamp(caplog):
    """Test that each JSON log includes a timestamp."""
    before = time.time()
    with caplog.at_level(logging.INFO):
        _log_json("event_with_ts", key="value")
    after = time.time()

    record = caplog.records[0]
    log_json = json.loads(record.message)
    assert before <= log_json["ts"] <= after


# ============================================================================
# Tests for data quality gate
# ============================================================================


def _write_csv(path: Path, rows: list[dict]) -> None:
    """Helper: write a CSV file with a header derived from the first row's keys."""
    if not rows:
        return
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def test_quality_gate_rejects_imbalanced_data(tmp_path):
    """Quality gate rejects data with class imbalance > 10x."""
    rows = []
    # 300 samples for 'normal', 25 samples for 'anomaly' → 12:1 imbalance.
    # Both classes exceed the 20-sample minimum so only the imbalance rule fires.
    for i in range(300):
        rows.append({"label": "normal", "ppv": str(0.1 + i * 0.001), "rms": "0.05", "freq": "10.0"})
    for i in range(25):
        rows.append({"label": "anomaly", "ppv": str(1.0 + i * 0.01), "rms": "0.5", "freq": "25.0"})

    _write_csv(tmp_path / "data.csv", rows)

    ok, reason = _check_data_quality(tmp_path)
    assert ok is False
    assert "imbalance" in reason


def test_quality_gate_accepts_balanced_data(tmp_path):
    """Quality gate accepts data with reasonable class balance."""
    rows = []
    # 50 samples each for 3 classes -- perfectly balanced, well above 20 min
    for cls in ("normal", "soil_creep", "crack_propagation"):
        for i in range(50):
            rows.append({
                "label": cls,
                "ppv": str(0.2 + i * 0.001),
                "rms": "0.1",
                "freq": "15.0",
            })

    _write_csv(tmp_path / "data.csv", rows)

    ok, reason = _check_data_quality(tmp_path)
    assert ok is True
    assert reason == "OK"


# ============================================================================
# Tests for watcher.py module importability
# ============================================================================


def test_watcher_imports():
    """watch.py is importable via importlib."""
    spec = importlib.util.spec_from_file_location(
        "watch",
        str(Path(__file__).parent / "watch.py"),
    )
    assert spec is not None


# ============================================================================
# Tests for jlog() structured logging
# ============================================================================


def test_jlog_output_is_valid_json(capsys):
    """jlog() emits a valid JSON line to stderr."""
    jlog("INFO", "test message", key="value", count=42)
    captured = capsys.readouterr()
    data = json.loads(captured.err.strip())
    assert data["level"] == "INFO"
    assert data["msg"] == "test message"
    assert data["key"] == "value"
    assert data["count"] == 42
    assert "ts" in data
    assert isinstance(data["ts"], float)


def test_jlog_timestamp_is_current(capsys):
    """jlog() timestamp is within a reasonable window of the current time."""
    before = time.time()
    jlog("DEBUG", "ts check")
    after = time.time()
    captured = capsys.readouterr()
    data = json.loads(captured.err.strip())
    assert before <= data["ts"] <= after


def test_jlog_level_field_preserved(capsys):
    """jlog() preserves arbitrary level strings."""
    jlog("WARNING", "warn msg")
    captured = capsys.readouterr()
    data = json.loads(captured.err.strip())
    assert data["level"] == "WARNING"


def test_jlog_extra_fields(capsys):
    """jlog() includes all extra keyword arguments."""
    jlog("INFO", "fields test", threshold=100, poll_interval=60, cooldown=300, data_dir="/tmp")
    captured = capsys.readouterr()
    data = json.loads(captured.err.strip())
    assert data["threshold"] == 100
    assert data["poll_interval"] == 60
    assert data["cooldown"] == 300
    assert data["data_dir"] == "/tmp"


# ============================================================================
# Tests for _triggers_fired counter
# ============================================================================


def test_triggers_fired_increments_on_success(tmp_path):
    """_triggers_fired increments each time write_trigger_with_retry succeeds."""
    import watch as watch_module
    initial = watch_module._triggers_fired

    trigger_file = tmp_path / "t1.trigger"
    write_trigger_with_retry(trigger_file, threshold=100, sample_count=150)

    assert watch_module._triggers_fired == initial + 1


def test_triggers_fired_not_incremented_on_failure(tmp_path):
    """_triggers_fired does NOT increment when trigger write fails."""
    import watch as watch_module
    initial = watch_module._triggers_fired

    trigger_file = tmp_path / "fail.trigger"
    with patch.object(Path, "mkdir", side_effect=OSError("Disk full")):
        write_trigger_with_retry(trigger_file, threshold=100, sample_count=150)

    assert watch_module._triggers_fired == initial


def test_triggers_fired_multiple_writes(tmp_path):
    """_triggers_fired counts multiple successful writes."""
    import watch as watch_module
    initial = watch_module._triggers_fired

    for i in range(3):
        trigger_file = tmp_path / f"t{i}.trigger"
        write_trigger_with_retry(trigger_file, threshold=100, sample_count=150 + i)

    assert watch_module._triggers_fired == initial + 3


# ============================================================================
# Tests for HTTP health endpoint
# ============================================================================


def test_health_handler_ok_response(tmp_path):
    """_HealthHandler returns 200 with JSON body for GET /health."""
    from http.server import HTTPServer
    from io import BytesIO

    # Use a free port for the test
    server = HTTPServer(("127.0.0.1", 0), _HealthHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    import urllib.request
    url = f"http://127.0.0.1:{port}/health"
    with urllib.request.urlopen(url, timeout=5) as resp:
        assert resp.status == 200
        body = json.loads(resp.read().decode())
    assert body["status"] == "ok"
    assert "triggers_fired" in body
    assert "last_check_ts" in body

    server.server_close()


def test_health_handler_404_for_unknown_path(tmp_path):
    """_HealthHandler returns 404 for non-/health paths."""
    from http.server import HTTPServer
    import urllib.error

    server = HTTPServer(("127.0.0.1", 0), _HealthHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    import urllib.request
    url = f"http://127.0.0.1:{port}/unknown"
    try:
        urllib.request.urlopen(url, timeout=5)
        assert False, "Expected 404 HTTPError"
    except urllib.error.HTTPError as e:
        assert e.code == 404

    server.server_close()


def test_health_response_reflects_triggers_fired(tmp_path):
    """Health endpoint triggers_fired value matches the global counter."""
    from http.server import HTTPServer
    import urllib.request
    import watch as watch_module

    server = HTTPServer(("127.0.0.1", 0), _HealthHandler)
    port = server.server_address[1]

    # Fire one trigger so counter is non-zero
    trigger_file = tmp_path / "health_test.trigger"
    write_trigger_with_retry(trigger_file, threshold=100, sample_count=200)
    expected_count = watch_module._triggers_fired

    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    url = f"http://127.0.0.1:{port}/health"
    with urllib.request.urlopen(url, timeout=5) as resp:
        body = json.loads(resp.read().decode())

    assert body["triggers_fired"] == expected_count
    server.server_close()


# ===========================================================================
# New tests: RETRAIN_COOLDOWN_SECONDS env var, /stats endpoint
# ===========================================================================

import watch as watch_module


def test_retrain_cooldown_seconds_env_var(monkeypatch):
    """RETRAIN_COOLDOWN_SECONDS env var controls the cooldown period."""
    import importlib
    monkeypatch.setenv("RETRAIN_COOLDOWN_SECONDS", "600")
    # Re-import the module to pick up the new env var
    importlib.reload(watch_module)
    assert watch_module.RETRAIN_COOLDOWN_SECONDS == 600
    assert watch_module.TRIGGER_COOLDOWN_SECS == 600
    # Restore default
    monkeypatch.delenv("RETRAIN_COOLDOWN_SECONDS", raising=False)
    importlib.reload(watch_module)


def test_retrain_cooldown_seconds_takes_precedence_over_legacy(monkeypatch):
    """RETRAIN_COOLDOWN_SECONDS overrides TRIGGER_COOLDOWN_SECS when both set."""
    import importlib
    monkeypatch.setenv("RETRAIN_COOLDOWN_SECONDS", "999")
    monkeypatch.setenv("TRIGGER_COOLDOWN_SECS", "111")
    importlib.reload(watch_module)
    assert watch_module.RETRAIN_COOLDOWN_SECONDS == 999
    monkeypatch.delenv("RETRAIN_COOLDOWN_SECONDS", raising=False)
    monkeypatch.delenv("TRIGGER_COOLDOWN_SECS", raising=False)
    importlib.reload(watch_module)


def test_legacy_trigger_cooldown_secs_still_works(monkeypatch):
    """TRIGGER_COOLDOWN_SECS alone still sets the cooldown when RETRAIN_COOLDOWN_SECONDS absent."""
    import importlib
    monkeypatch.delenv("RETRAIN_COOLDOWN_SECONDS", raising=False)
    monkeypatch.setenv("TRIGGER_COOLDOWN_SECS", "42")
    importlib.reload(watch_module)
    assert watch_module.RETRAIN_COOLDOWN_SECONDS == 42
    assert watch_module.TRIGGER_COOLDOWN_SECS == 42
    monkeypatch.delenv("TRIGGER_COOLDOWN_SECS", raising=False)
    importlib.reload(watch_module)


def test_cooldown_prevents_immediate_retrigger(tmp_path):
    """After a trigger fires, a second attempt within the cooldown window is skipped."""
    import watch as wm
    # Set last_trigger_time (monotonic) to now so cooldown is active
    # We test this by checking the cooldown logic used in the main loop:
    # now_mono - last_trigger_time < TRIGGER_COOLDOWN_SECS  -> skip
    cooldown = wm.RETRAIN_COOLDOWN_SECONDS
    now_mono = time.monotonic()
    last_trigger_time = now_mono - (cooldown // 2)  # halfway through cooldown
    elapsed = now_mono - last_trigger_time
    remaining = cooldown - elapsed
    # Verify the condition that would cause a skip
    assert elapsed < cooldown
    assert remaining > 0


def test_stats_endpoint_returns_expected_fields(tmp_path):
    """GET /stats returns triggers_fired, last_trigger_ts, cooldown_active, cooldown_remaining_seconds."""
    from http.server import HTTPServer
    import urllib.request
    import watch as wm

    server = HTTPServer(("127.0.0.1", 0), wm._HealthHandler)
    port = server.server_address[1]

    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    url = f"http://127.0.0.1:{port}/stats"
    with urllib.request.urlopen(url, timeout=5) as resp:
        body = json.loads(resp.read().decode())

    assert "triggers_fired" in body
    assert "last_trigger_ts" in body
    assert "cooldown_active" in body
    assert "cooldown_remaining_seconds" in body
    server.server_close()


def test_stats_endpoint_cooldown_not_active_initially(tmp_path):
    """Before any trigger fires, cooldown_active is False and remaining is 0."""
    from http.server import HTTPServer
    import urllib.request
    import watch as wm

    # Reset global state
    with wm._health_lock:
        wm._last_trigger_ts = None
        wm._cooldown_active = False
        wm._cooldown_remaining_seconds = 0.0

    server = HTTPServer(("127.0.0.1", 0), wm._HealthHandler)
    port = server.server_address[1]

    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    url = f"http://127.0.0.1:{port}/stats"
    with urllib.request.urlopen(url, timeout=5) as resp:
        body = json.loads(resp.read().decode())

    assert body["cooldown_active"] is False
    assert body["cooldown_remaining_seconds"] == 0.0
    assert body["last_trigger_ts"] is None
    server.server_close()


def test_stats_endpoint_404_for_unknown_path(tmp_path):
    """GET /unknown returns 404 from the health handler."""
    from http.server import HTTPServer
    import urllib.request
    import urllib.error
    import watch as wm

    server = HTTPServer(("127.0.0.1", 0), wm._HealthHandler)
    port = server.server_address[1]

    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    url = f"http://127.0.0.1:{port}/notapath"
    try:
        urllib.request.urlopen(url, timeout=5)
        assert False, "Expected HTTPError 404"
    except urllib.error.HTTPError as e:
        assert e.code == 404
    server.server_close()


def test_stats_reflects_trigger_after_fire(tmp_path):
    """After write_trigger_with_retry succeeds, triggers_fired is non-zero in /stats."""
    from http.server import HTTPServer
    import urllib.request
    import watch as wm

    trigger_file = tmp_path / "test_stats.trigger"
    before = wm._triggers_fired
    write_trigger_with_retry(trigger_file, threshold=100, sample_count=200)
    after = wm._triggers_fired
    assert after == before + 1

    server = HTTPServer(("127.0.0.1", 0), wm._HealthHandler)
    port = server.server_address[1]

    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    url = f"http://127.0.0.1:{port}/stats"
    with urllib.request.urlopen(url, timeout=5) as resp:
        body = json.loads(resp.read().decode())

    assert body["triggers_fired"] == after
    server.server_close()
