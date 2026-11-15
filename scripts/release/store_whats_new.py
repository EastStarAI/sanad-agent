#!/usr/bin/env python3
"""The curated "What's New" text that the stores publish.

The store text is written per release and never extracted from
`release/release-notes.md`: a store listing is a short mobile summary, while the
release notes are the technical release document.

One file per language is shared by the App Store and Google Play:

  release/store-whats-new.en.txt   published as `en-US`
  release/store-whats-new.ar.txt   published as `ar`

The first line names the release version, for example `1.0.27`, so text written
for another release can never ship under the version being built. Google Play
accepts 500 characters per language and the App Store accepts 4000, so the Play
lane enforces the tighter limit. A missing file, a mismatched first line, empty
text, or text over the limit refuses the publication instead of shipping a
partial or stale listing.

Usage:
  store_whats_new.py --version 1.0.27 [--directory release] [--limit play]
"""

from __future__ import annotations

import argparse
import os
import sys

PLAY_LIMIT = 500
APP_STORE_LIMIT = 4000
LIMITS = {"play": PLAY_LIMIT, "app-store": APP_STORE_LIMIT}

# (file locale, store language code) per publishing target. The two stores share
# one file per language, so only the language codes differ.
LOCALES = (("en", "en-US"), ("ar", "ar"))
APP_STORE_LOCALES = (("en", "en-US"), ("ar", "ar-SA"))
# The files are shared, so the tighter Play limit is the only one both lanes can
# satisfy; the App Store limit is recorded for the model, not for enforcement.
SHARED_LIMIT = PLAY_LIMIT


class StoreNotesError(RuntimeError):
    pass


def path_for(directory: str, locale: str) -> str:
    return os.path.join(directory, f"store-whats-new.{locale}.txt")


def read_text(directory: str, version: str, locale: str, limit: int) -> str:
    path = path_for(directory, locale)
    if not os.path.isfile(path):
        raise StoreNotesError(f"Missing store text: {path}")
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    if not lines:
        raise StoreNotesError(f"{path} is empty")
    declared = lines[0].strip()
    if declared != version:
        raise StoreNotesError(
            f"{path} names release '{declared}' but this build is '{version}';"
            " write the store text for this release before publishing"
        )
    text = "\n".join(lines[1:]).strip()
    if not text:
        raise StoreNotesError(f"{path} names a version but has no text")
    if len(text) > limit:
        raise StoreNotesError(
            f"{path} is {len(text)} characters and the limit for this store is {limit}"
        )
    return text


def release_notes(directory: str, version: str, limit: int = PLAY_LIMIT) -> list[dict]:
    """Return the release notes resource for every published language."""
    return [
        {"language": language, "text": read_text(directory, version, locale, limit)}
        for locale, language in LOCALES
    ]


def app_store_text(directory: str, version: str, language: str) -> str:
    """Return the shared store text for one App Store localization.

    The App Store lane reads the same per-language files as the Play lane, so one
    release cannot publish two different stories. Only the language code differs
    (`ar` is published as `ar-SA`), and a localization this lane does not cover
    is refused instead of shipping English copy under another locale.
    """
    for locale, store_language in APP_STORE_LOCALES:
        if store_language == language:
            return read_text(directory, version, locale, SHARED_LIMIT)
    raise StoreNotesError(
        f"The App Store listing uses the '{language}' localization, but the shared"
        " store text covers"
        f" {', '.join(code for _, code in APP_STORE_LOCALES)} only; extend"
        " scripts/release/store_whats_new.py before releasing that locale"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--directory", default="release")
    parser.add_argument("--limit", default="play", choices=tuple(LIMITS))
    args = parser.parse_args()
    for note in release_notes(args.directory, args.version, LIMITS[args.limit]):
        print(f"{note['language']}: {len(note['text'])} characters")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except StoreNotesError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
