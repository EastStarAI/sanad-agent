#!/usr/bin/env python3
"""Offline unit tests for scripts/release/publish_play_bundle.py.

Every transport is patched, so the suite runs with no network and no
credentials. The store's own behaviour is represented by fake responses.

Run from the repository root:
  python3 -I scripts/release/test_publish_play_bundle.py
"""

from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import publish_play_bundle as play  # noqa: E402


class FakeResponse:
    def __init__(self, body: bytes) -> None:
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *exc_info) -> bool:
        return False


def http_error(status: int, body: bytes = b'{"error": {"message": "denied"}}') -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "https://androidpublisher.googleapis.com/test", status, "error", {}, io.BytesIO(body)
    )


class TransportErrorsBecomePlayErrors(unittest.TestCase):
    """A transport failure must reach the discard handler instead of escaping it."""

    def test_connection_error_is_mapped(self) -> None:
        failure = urllib.error.URLError(ConnectionRefusedError(61, "Connection refused"))
        with mock.patch.object(play.urllib.request, "urlopen", side_effect=failure):
            with self.assertRaises(play.PlayError) as raised:
                play._request("token", "https://example.invalid/edits")
        self.assertIn("Connection refused", str(raised.exception))
        self.assertIsNone(raised.exception.status)

    def test_timeout_is_mapped(self) -> None:
        with mock.patch.object(play.urllib.request, "urlopen", side_effect=TimeoutError("timed out")):
            with self.assertRaises(play.PlayError) as raised:
                play._request("token", "https://example.invalid/edits")
        self.assertIn("timed out", str(raised.exception))

    def test_http_status_is_preserved(self) -> None:
        with mock.patch.object(play.urllib.request, "urlopen", side_effect=http_error(403)):
            with self.assertRaises(play.PlayError) as raised:
                play._request("token", "https://example.invalid/edits")
        self.assertEqual(raised.exception.status, 403)
        self.assertIn("403", str(raised.exception))
        self.assertIn("denied", str(raised.exception))

    def test_unusable_body_is_mapped(self) -> None:
        with mock.patch.object(play.urllib.request, "urlopen", return_value=FakeResponse(b"<html>")):
            with self.assertRaises(play.PlayError) as raised:
                play._request("token", "https://example.invalid/edits")
        self.assertIn("unusable body", str(raised.exception))

    def test_missing_track_is_read_as_empty(self) -> None:
        with mock.patch.object(play, "_request", side_effect=play.PlayError("missing", status=404)):
            self.assertEqual(play.track_releases("token", "pkg", "edit", "alpha"), [])

    def test_other_track_failures_are_not_swallowed(self) -> None:
        with mock.patch.object(play, "_request", side_effect=play.PlayError("denied", status=403)):
            with self.assertRaises(play.PlayError):
                play.track_releases("token", "pkg", "edit", "alpha")


class DiscardNeverMasks(unittest.TestCase):
    """A failed discard is a warning, never a replacement for the original error."""

    def test_discard_reports_a_store_failure(self) -> None:
        with mock.patch.object(play, "_request", side_effect=play.PlayError("denied", status=500)):
            with mock.patch.object(sys, "stderr", new=io.StringIO()) as stderr:
                play.discard("token", "pkg", "edit-1")
        self.assertIn("could not discard edit edit-1", stderr.getvalue())
        self.assertIn("denied", stderr.getvalue())

    def test_discard_reports_a_transport_failure(self) -> None:
        with mock.patch.object(play, "_request", side_effect=urllib.error.URLError("unreachable")):
            with mock.patch.object(sys, "stderr", new=io.StringIO()) as stderr:
                play.discard("token", "pkg", "edit-2")
        self.assertIn("could not discard edit edit-2", stderr.getvalue())
        self.assertIn("unreachable", stderr.getvalue())


class ReleaseStatusSelection(unittest.TestCase):
    def test_testing_tracks_keep_safe_defaults(self) -> None:
        self.assertEqual(play.resolve_release("internal", "auto", 0.2), ("completed", None))
        self.assertEqual(play.resolve_release("alpha", "auto", 0.2), ("draft", None))
        self.assertEqual(play.resolve_release("beta", "auto", 0.2), ("draft", None))

    def test_testing_tracks_accept_an_explicit_status(self) -> None:
        self.assertEqual(play.resolve_release("alpha", "completed", 0.2), ("completed", None))
        self.assertEqual(play.resolve_release("internal", "draft", 0.2), ("draft", None))

    def test_production_stages_a_fraction(self) -> None:
        self.assertEqual(play.resolve_release("production", "auto", 0.2), ("inProgress", 0.2))

    def test_production_completes_at_full_rollout(self) -> None:
        self.assertEqual(play.resolve_release("production", "auto", 1), ("completed", None))

    def test_production_refuses_a_hand_set_status(self) -> None:
        with self.assertRaises(ValueError):
            play.resolve_release("production", "completed", 0.5)


class ReleaseRetention(unittest.TestCase):
    def release(self, status: str, *codes: int) -> dict:
        return {"status": status, "versionCodes": [str(code) for code in codes]}

    def test_completed_releases_are_kept(self) -> None:
        existing = [self.release("completed", 17)]
        merged = play.merge_releases(existing, self.release("draft", 27), "production")
        self.assertEqual([entry["versionCodes"] for entry in merged], [["17"], ["27"]])

    def test_active_release_is_reported_not_dropped_silently(self) -> None:
        existing = [self.release("inProgress", 21)]
        with mock.patch.object(sys, "stderr", new=io.StringIO()) as stderr:
            merged = play.merge_releases(existing, self.release("draft", 27), "beta")
        self.assertEqual([entry["versionCodes"] for entry in merged], [["27"]])
        self.assertIn("Replacing the existing inProgress release", stderr.getvalue())
        self.assertIn("21", stderr.getvalue())

    def test_same_version_code_does_not_appear_twice(self) -> None:
        existing = [self.release("completed", 27)]
        with mock.patch.object(sys, "stderr", new=io.StringIO()) as stderr:
            merged = play.merge_releases(existing, self.release("inProgress", 27), "production")
        self.assertEqual([entry["versionCodes"] for entry in merged], [["27"]])
        self.assertEqual(merged[0]["status"], "inProgress")
        self.assertIn("Replacing the existing completed release", stderr.getvalue())


class CommandLineGuards(unittest.TestCase):
    """The callable path passes free-form strings, so argparse is the last guard."""

    def setUp(self) -> None:
        handle = tempfile.NamedTemporaryFile(suffix=".aab", delete=False)
        handle.write(b"bundle")
        handle.close()
        self.bundle = handle.name
        self.addCleanup(os.unlink, self.bundle)

    def main(self, *extra: str) -> int:
        argv = ["publish_play_bundle.py", "--bundle", self.bundle, "--package", "com.eaststarai.sanad"]
        argv += list(extra)
        with mock.patch.object(sys, "argv", argv):
            with mock.patch.object(sys, "stderr", new=io.StringIO()):
                return play.main()

    def test_unknown_track_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.main("--track", "staging", "--expect-version-code", "27")
        self.assertEqual(raised.exception.code, 2)

    def test_unknown_status_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.main("--track", "internal", "--status", "halted", "--expect-version-code", "27")
        self.assertEqual(raised.exception.code, 2)

    def test_zero_rollout_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.main("--track", "production", "--rollout-fraction", "0", "--expect-version-code", "27")
        self.assertEqual(raised.exception.code, 2)

    def test_rollout_above_one_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.main("--track", "production", "--rollout-fraction", "1.5", "--expect-version-code", "27")
        self.assertEqual(raised.exception.code, 2)

    def test_production_with_an_explicit_status_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.main(
                "--track", "production", "--status", "completed", "--expect-version-code", "27"
            )
        self.assertEqual(raised.exception.code, 2)

    def test_non_positive_version_code_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.main("--track", "internal", "--expect-version-code", "0")
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
