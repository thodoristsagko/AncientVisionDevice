#!/usr/bin/env python3
"""Tests for health_check.py."""

import unittest
import sys
import time
from unittest.mock import patch, MagicMock, mock_open
from pathlib import Path
import urllib.error
import socket

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent))

from health_check import ServiceCheck, format_latency, main


class TestServiceCheck(unittest.TestCase):
    """Tests for ServiceCheck class."""

    def test_check_http_success(self):
        """Test successful HTTP check."""
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_response = MagicMock()
            mock_response.status = 200
            mock_urlopen.return_value = mock_response

            check = ServiceCheck("test", url="http://localhost:8000/health")
            result = check.check()

            self.assertTrue(result)
            self.assertEqual(check.status, "[UP]")
            self.assertIsNotNone(check.latency)
            self.assertTrue(check.latency >= 0)

    def test_check_http_failure(self):
        """Test failed HTTP check."""
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_urlopen.side_effect = urllib.error.URLError("Connection refused")

            check = ServiceCheck("test", url="http://localhost:8000/health")
            result = check.check()

            self.assertFalse(result)
            self.assertEqual(check.status, "[DOWN]")
            self.assertIsNone(check.latency)

    def test_check_http_timeout(self):
        """Test HTTP timeout."""
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_urlopen.side_effect = socket.timeout()

            check = ServiceCheck("test", url="http://localhost:8000/health", timeout=1.0)
            result = check.check()

            self.assertFalse(result)
            self.assertEqual(check.status, "[DOWN]")
            self.assertIn("Timeout", check.note)

    def test_check_http_non_200_status(self):
        """Test HTTP non-200 status."""
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_response = MagicMock()
            mock_response.status = 500
            mock_urlopen.return_value = mock_response

            check = ServiceCheck("test", url="http://localhost:8000/health")
            result = check.check()

            self.assertFalse(result)
            self.assertEqual(check.status, "[DOWN]")

    def test_check_file_exists(self):
        """Test file existence check."""
        with patch('pathlib.Path.exists') as mock_exists:
            with patch('pathlib.Path.is_dir') as mock_is_dir:
                mock_exists.return_value = True
                mock_is_dir.return_value = False

                check = ServiceCheck("test", file_path="./data/.retrain_trigger")
                result = check.check()

                self.assertTrue(result)
                self.assertEqual(check.status, "[PRESENT]")

    def test_check_file_not_exists(self):
        """Test file not found."""
        with patch('pathlib.Path.exists') as mock_exists:
            mock_exists.return_value = False

            check = ServiceCheck("test", file_path="./data/.retrain_trigger")
            result = check.check()

            self.assertFalse(result)
            self.assertEqual(check.status, "[ABSENT]")

    def test_check_directory_exists(self):
        """Test directory with .tflite files."""
        with patch('pathlib.Path.exists') as mock_exists:
            with patch('pathlib.Path.is_dir') as mock_is_dir:
                with patch('pathlib.Path.glob') as mock_glob:
                    mock_exists.return_value = True
                    mock_is_dir.return_value = True
                    mock_glob.return_value = ["file1.tflite", "file2.tflite"]

                    check = ServiceCheck("test", file_path="./app/assets/ml")
                    result = check.check()

                    self.assertTrue(result)
                    self.assertEqual(check.status, "[PRESENT]")
                    self.assertIn("2 .tflite files", check.note)


class TestFormatLatency(unittest.TestCase):
    """Tests for format_latency function."""

    def test_format_latency_with_value(self):
        """Test formatting latency with a value."""
        result = format_latency(45.5)
        self.assertEqual(result, "46ms")

    def test_format_latency_with_none(self):
        """Test formatting latency with None."""
        result = format_latency(None)
        self.assertEqual(result, "-")

    def test_format_latency_zero(self):
        """Test formatting zero latency."""
        result = format_latency(0.0)
        self.assertEqual(result, "0ms")


class TestMain(unittest.TestCase):
    """Tests for main function."""

    @patch('health_check.ServiceCheck.check')
    @patch('sys.argv', ['health_check.py', '--timeout', '2.0'])
    def test_main_all_healthy(self, mock_check):
        """Test main with all services healthy."""
        mock_check.return_value = True

        with patch('health_check.print_status_table'):
            result = main()

        self.assertEqual(result, 0)

    @patch('health_check.ServiceCheck.check')
    @patch('sys.argv', ['health_check.py'])
    def test_main_with_failures(self, mock_check):
        """Test main with service failures."""
        # Fail data-collector (critical service)
        mock_check.side_effect = [False, True, True, True, False, True]

        with patch('health_check.print_status_table'):
            result = main()

        self.assertEqual(result, 1)

    @patch('health_check.ServiceCheck.check')
    @patch('sys.argv', ['health_check.py'])
    def test_main_non_critical_failure(self, mock_check):
        """Test main with non-critical service failure."""
        # Fail prometheus (non-critical)
        mock_check.side_effect = [True, False, True, True, False, True]

        with patch('health_check.print_status_table'):
            result = main()

        self.assertEqual(result, 0)


if __name__ == "__main__":
    unittest.main()
