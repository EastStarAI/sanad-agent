#!/usr/bin/env python3
"""The curated "What's New" text that the stores publish.

The store text is written per release and never extracted from
`release/release-notes.md`: a store listing is a short mobile summary, while the
release notes are the technical release document.

One file per language is shared by the App Store and Google Play:

  release/store-whats-new.en.txt   published as `en-US` on both stores
  release/store-whats-new.ar.txt   published as `ar` (Google Play) or `ar-SA`
                                   (App Store), which names its own languages

The first line names the release version, for example `1.0.27`, so text written
for another release can never ship under the version being built. Google Play
accepts 500 characters per language and the App Store accepts 4000, so the Play
lane enforces the tighter limit. A missing file, a mismatched first line, empty
text, or text over the limit refuses the publication instead of shipping a
partial or stale listing.

Usage:
  store_whats_new.py --version 1.0.27 [--directory release] [--limit play]
  store_whats_new.py --version 1.0.27 --limit app-store --json
"""

from __future__ import annotations

import argparse
import json
import os
import sys

PLAY_LIMIT = 500
APP_STORE_LIMIT = 4000
LIMITS = {"play": PLAY_LIMIT, "app-store": APP_STORE_LIMIT}

# (file locale, store language code) per store target
LOCALES = {
    "play": (("en", "en-US"), ("ar", "ar")),
    "app-store": (("en", "en-US"), ("ar", "ar-SA")),
}


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


def release_notes(
    directory: str, version: str, limit: int = PLAY_LIMIT, target: str = "play"
) -> list[dict]:
    """Return the release notes resource for every published language."""
    return [
        {"language": language, "text": read_text(directory, version, locale, limit)}
        for locale, language in LOCALES[target]
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--directory", default="release")
    parser.add_argument("--limit", default="play", choices=tuple(LIMITS))
    parser.add_argument(
        "--json",
        action="store_true",
        help="print one object keyed by the store language code",
    )
    args = parser.parse_args()
    # `--limit` names the store, and each store names its own languages.
    notes = release_notes(args.directory, args.version, LIMITS[args.limit], args.limit)
    if args.json:
        print(json.dumps({note["language"]: note["text"] for note in notes}))
        return 0
    for note in notes:
        print(f"{note['language']}: {len(note['text'])} characters")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except StoreNotesError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
