#!/usr/bin/env python3
"""Offline tests for the curated store "What's New" text.

Run from the repository root:
  python3 -I scripts/release/test_store_whats_new.py
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import store_whats_new  # noqa: E402


class StoreText(unittest.TestCase):
    def setUp(self) -> None:
        self.work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.work)

    def write(self, locale: str, content: str) -> None:
        with open(
            os.path.join(self.work, f"store-whats-new.{locale}.txt"), "w", encoding="utf-8"
        ) as handle:
            handle.write(content)

    def write_release(self, version: str = "1.0.27") -> None:
        self.write("en", f"{version}\n\n- One fix.\n- Another fix.\n")
        self.write("ar", f"{version}\n\n- إصلاح أول.\n- إصلاح ثانٍ.\n")

    def test_both_languages_are_published_with_store_codes(self) -> None:
        self.write_release()
        notes = store_whats_new.release_notes(self.work, "1.0.27")
        self.assertEqual([note["language"] for note in notes], ["en-US", "ar"])
        self.assertEqual(notes[0]["text"], "- One fix.\n- Another fix.")
        self.assertEqual(notes[1]["text"], "- إصلاح أول.\n- إصلاح ثانٍ.")

    def test_missing_file_is_refused(self) -> None:
        self.write("en", "1.0.27\n\n- One fix.\n")
        with self.assertRaises(store_whats_new.StoreNotesError) as raised:
            store_whats_new.release_notes(self.work, "1.0.27")
        self.assertIn("store-whats-new.ar.txt", str(raised.exception))

    def test_empty_file_is_refused(self) -> None:
        self.write("en", "\n\n")
        self.write("ar", "1.0.27\n\n- إصلاح.\n")
        with self.assertRaises(store_whats_new.StoreNotesError) as raised:
            store_whats_new.release_notes(self.work, "1.0.27")
        self.assertIn("is empty", str(raised.exception))

    def test_text_for_another_release_is_refused(self) -> None:
        self.write_release("1.0.26")
        with self.assertRaises(store_whats_new.StoreNotesError) as raised:
            store_whats_new.release_notes(self.work, "1.0.27")
        self.assertIn("names release '1.0.26'", str(raised.exception))
        self.assertIn("this build is '1.0.27'", str(raised.exception))

    def test_version_line_without_text_is_refused(self) -> None:
        self.write("en", "1.0.27\n")
        self.write("ar", "1.0.27\n\n- إصلاح.\n")
        with self.assertRaises(store_whats_new.StoreNotesError) as raised:
            store_whats_new.release_notes(self.work, "1.0.27")
        self.assertIn("has no text", str(raised.exception))

    def test_play_limit_is_enforced(self) -> None:
        self.write("en", "1.0.27\n\n" + "- " + "x" * 500 + "\n")
        self.write("ar", "1.0.27\n\n- إصلاح.\n")
        with self.assertRaises(store_whats_new.StoreNotesError) as raised:
            store_whats_new.release_notes(self.work, "1.0.27")
        self.assertIn("the limit for this store is 500", str(raised.exception))

    def test_app_store_limit_allows_the_same_text(self) -> None:
        text = "- " + "x" * 500
        self.write("en", f"1.0.27\n\n{text}\n")
        self.write("ar", "1.0.27\n\n- إصلاح.\n")
        notes = store_whats_new.release_notes(
            self.work, "1.0.27", store_whats_new.APP_STORE_LIMIT
        )
        self.assertEqual(notes[0]["text"], text)


class RepositoryStoreText(unittest.TestCase):
    """The text committed for this release satisfies the lane it feeds."""

    def test_committed_release_text_is_publishable(self) -> None:
        directory = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))), "release")
        path = os.path.join(directory, "store-whats-new.en.txt")
        if not os.path.isfile(path):
            self.skipTest("store text is not part of this checkout")
        with open(path, encoding="utf-8") as handle:
            version = handle.readline().strip()
        notes = store_whats_new.release_notes(directory, version)
        self.assertEqual([note["language"] for note in notes], ["en-US", "ar"])
        for note in notes:
            self.assertGreater(len(note["text"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
