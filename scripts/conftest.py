"""
Shared pytest fixtures and early-import guards for the scripts test suite.

data_augmentation_report.py replaces sys.stdout with a UTF-8 TextIOWrapper on
Windows at module-import time.  If that import happens while pytest's capsys
fixture has installed its temporary capture buffer as sys.stdout, the
TextIOWrapper binds to that buffer.  When capsys tears down and closes the
buffer, all subsequent sys.stdout / tempfile operations raise
"I/O operation on closed file".

Fix: import data_augmentation_report exactly once here, patching out the
problematic sys.stdout replacement so the real stdout is never disturbed.
Because conftest.py is imported before any test module, sys.modules already
contains the cached (unmodified) module by the time test files are collected.
"""
import sys
from unittest.mock import patch

# Patch sys.platform to a non-win32 value during the one-time import so the
# `if sys.platform == "win32":` branch in data_augmentation_report is skipped.
# We do NOT call os.uname() or any Linux-only API here — just skip the block.
import importlib
import types

# Temporarily inject a stub for the win32 branch guard.
_saved_platform = sys.platform
sys.platform = "linux_ci_stub"
try:
    import data_augmentation_report  # noqa: F401  — cache in sys.modules
    import health_check               # noqa: F401  — same win32 stdout-replace issue
    import pipeline_status            # noqa: F401  — same win32 stdout-replace guard
finally:
    sys.platform = _saved_platform
