#!/usr/bin/env python3
"""Upload a signed Android App Bundle to a Google Play track.

The Google Play Developer API has no reversible upload: once a versionCode is
accepted it is consumed for the lifetime of the package. This tool therefore
proves the identity of the bundle from the API response before it commits the
edit, so a mismatch aborts with the edit discarded instead of publishing an
unexpected build.

Tracks:

  internal, alpha, beta   testing tracks. `--status auto` resolves to
                          `completed` on internal and `draft` on alpha/beta, so
                          a closed-testing upload is never published by default.
  production              store release. The status follows `--rollout-fraction`:
                          `inProgress` with `userFraction` below 1, and `completed`
                          at exactly 1 for a full rollout. `--status` must stay
                          `auto`, so the rollout fraction alone decides how much
                          of production receives the build.

Existing releases on the target track are read first. Releases Play can hold
beside the new one are kept, so an upload never silently drops the previous
version. Play permits one active (`draft`/`inProgress`) release per track, so an
active release that cannot be kept is reported and replaced.

Every release carries the curated store text from `release/store-whats-new.*.txt`
for `en-US` and `ar`. The text is validated before any credential is loaded, so a
missing file, a text written for another version, or a text over the store limit
refuses the run instead of publishing a partial listing.

Authentication uses a service account JSON key. Provide it either as a path in
PLAY_SERVICE_ACCOUNT_JSON or base64-encoded in
PLAY_SERVICE_ACCOUNT_JSON_BASE64. The key is never printed.

Usage:
  publish_play_bundle.py --bundle <path> --package com.eaststarai.sanad
    --track internal --expect-version-code 25 --version-name 1.0.24
    [--status auto] [--rollout-fraction 0.2] [--store-notes-dir release]
    [--dry-run]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import store_whats_new

API_ROOT = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_ROOT = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"

TRACKS = ("internal", "alpha", "beta", "production")
STATUSES = ("auto", "draft", "completed")
TESTING_TRACK_STATUS = {"internal": "completed", "alpha": "draft", "beta": "draft"}


class PlayError(RuntimeError):
    """A failure that must abort the run and discard the open edit."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def load_key() -> dict:
    encoded = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON_BASE64")
    if encoded:
        return json.loads(base64.b64decode(encoded))
    path = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON")
    if path:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    raise PlayError(
        "Set PLAY_SERVICE_ACCOUNT_JSON_BASE64 or PLAY_SERVICE_ACCOUNT_JSON."
    )


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _sign(signing_input: bytes, private_key: str) -> bytes:
    # openssl can only read the key from a file. The temporary directory is
    # owner-only, the PEM is 0600, and both disappear when the call returns; only
    # a SIGKILL can leave the file behind, on an ephemeral runner that is then
    # discarded whole.
    with tempfile.TemporaryDirectory(prefix="play-signing-") as key_dir:
        os.chmod(key_dir, 0o700)
        pem_path = os.path.join(key_dir, "service-account.pem")
        with open(pem_path, "w", encoding="utf-8") as pem:
            pem.write(private_key)
        os.chmod(pem_path, 0o600)
        return subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", pem_path],
            input=signing_input,
            capture_output=True,
            check=True,
        ).stdout


def access_token(key: dict) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": key["client_email"],
        "scope": SCOPE,
        "aud": TOKEN_URL,
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = (
        f"{_b64url(json.dumps(header).encode())}."
        f"{_b64url(json.dumps(claims).encode())}"
    )
    signature = _sign(signing_input.encode(), key["private_key"])
    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": f"{signing_input}.{_b64url(signature)}",
        }
    ).encode()
    try:
        with urllib.request.urlopen(TOKEN_URL, body, timeout=60) as response:
            return json.load(response)["access_token"]
    except urllib.error.HTTPError as error:
        raise PlayError(
            f"Service account token request failed: {error.code} "
            f"{_short(error.read())}",
            status=error.code,
        ) from error
    except OSError as error:
        raise PlayError(f"Service account token request failed: {error}") from error
    except (ValueError, KeyError) as error:
        raise PlayError(
            f"Service account token response was unusable: {error}"
        ) from error


def _short(raw: bytes) -> str:
    return raw.decode("utf-8", "replace").replace("\n", " ")[:300]


def _request(token: str, url: str, method: str = "GET", payload=None, raw=None):
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if raw is not None:
        headers["Content-Type"] = "application/octet-stream"
        data = raw
    elif payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            body = response.read().decode("utf-8", "replace")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        raise PlayError(
            f"{method} {url} failed: {error.code} {_short(error.read())}",
            status=error.code,
        ) from error
    except OSError as error:
        # A refused connection, DNS failure, reset, or timeout carries no status
        # code, but it must still reach the caller as PlayError: otherwise it
        # bypasses the discard handler and leaves the edit open.
        raise PlayError(f"{method} {url} failed: {error}") from error
    except ValueError as error:
        raise PlayError(f"{method} {url} returned an unusable body: {error}") from error


def edit_id(token: str, package: str) -> str:
    return _request(token, f"{API_ROOT}/{package}/edits", "POST", {})["id"]


def discard(token: str, package: str, edit: str) -> None:
    try:
        _request(token, f"{API_ROOT}/{package}/edits/{edit}", "DELETE")
    except Exception as error:  # noqa: BLE001 - a failed discard must never mask the real error
        print(f"warning: could not discard edit {edit}: {error}", file=sys.stderr)


def upload(token: str, package: str, edit: str, bundle: str) -> dict:
    with open(bundle, "rb") as handle:
        payload = handle.read()
    return _request(
        token,
        f"{UPLOAD_ROOT}/{package}/edits/{edit}/bundles?uploadType=media",
        "POST",
        raw=payload,
    )


def resolve_release(
    track: str, status: str, rollout_fraction: float
) -> tuple[str, float | None]:
    """Return the Play release status and, for a staged rollout, its userFraction."""
    if track == "production":
        if status != "auto":
            raise ValueError(
                "the production status follows --rollout-fraction; leave --status at auto"
            )
        if rollout_fraction >= 1:
            return "completed", None
        return "inProgress", rollout_fraction
    if status == "auto":
        return TESTING_TRACK_STATUS[track], None
    return status, None


def track_releases(token: str, package: str, edit: str, track: str) -> list[dict]:
    try:
        payload = _request(token, f"{API_ROOT}/{package}/edits/{edit}/tracks/{track}")
    except PlayError as error:
        # A track that has never received a release answers 404; any other failure
        # must stop the run instead of being read as an empty track.
        if error.status == 404:
            return []
        raise
    return payload.get("releases") or []


def merge_releases(existing: list[dict], release: dict, track: str) -> list[dict]:
    """Keep the releases Play can hold beside the new one and report what is replaced."""
    entering = {int(code) for code in release["versionCodes"]}
    # Play holds at most one completed release per track, so a new completed
    # release supersedes the previous one instead of standing beside it.
    keep_completed = release.get("status") != "completed"
    kept: list[dict] = []
    replaced: list[dict] = []
    for entry in existing:
        codes = {int(code) for code in entry.get("versionCodes") or []}
        if keep_completed and entry.get("status") == "completed" and not codes & entering:
            kept.append(entry)
        else:
            replaced.append(entry)
    for entry in replaced:
        codes = ",".join(str(code) for code in entry.get("versionCodes") or [])
        print(
            f"Replacing the existing {entry.get('status') or 'unknown'} release for "
            f"versionCode(s) {codes or 'none'} on track '{track}'.",
            file=sys.stderr,
        )
    return kept + [release]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--track", required=True, choices=TRACKS)
    parser.add_argument("--expect-version-code", required=True, type=int)
    parser.add_argument("--version-name", required=True)
    parser.add_argument("--status", default="auto", choices=STATUSES)
    parser.add_argument("--rollout-fraction", default=0.2, type=float)
    parser.add_argument("--store-notes-dir", default="release")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not os.path.isfile(args.bundle):
        print(f"Bundle not found: {args.bundle}", file=sys.stderr)
        return 2
    if args.expect_version_code <= 0:
        parser.error("--expect-version-code must be a positive integer")
    if not 0 < args.rollout_fraction <= 1:
        parser.error("--rollout-fraction must be greater than 0 and at most 1")
    try:
        status, user_fraction = resolve_release(
            args.track, args.status, args.rollout_fraction
        )
    except ValueError as error:
        parser.error(str(error))

    rollout = "" if user_fraction is None else f" with userFraction {user_fraction}"
    print(f"Preparing track '{args.track}' as {status}{rollout}")

    # The store text is proven before the service account is even read, so a
    # listing problem never costs an upload or leaves an edit behind.
    notes = store_whats_new.release_notes(args.store_notes_dir, args.version_name)

    token = access_token(load_key())
    edit = edit_id(token, args.package)
    print(f"Play edit {edit} opened for {args.package}")

    try:
        uploaded = upload(token, args.package, edit, args.bundle)
        accepted = int(uploaded.get("versionCode", -1))
        print(f"Bundle accepted: versionCode={accepted} sha256={uploaded.get('sha256', '?')[:16]}…")
        if accepted != args.expect_version_code:
            raise PlayError(
                "the uploaded bundle reports versionCode "
                f"{accepted} but this release contracted {args.expect_version_code};"
                " refusing to publish a different build"
            )

        release: dict = {
            "versionCodes": [str(accepted)],
            "status": status,
            "name": f"{args.version_name} ({accepted})",
            "releaseNotes": notes,
        }
        if user_fraction is not None:
            release["userFraction"] = user_fraction
        existing = track_releases(token, args.package, edit, args.track)
        track = {
            "track": args.track,
            "releases": merge_releases(existing, release, args.track),
        }
        _request(
            token,
            f"{API_ROOT}/{args.package}/edits/{edit}/tracks/{args.track}",
            "PUT",
            track,
        )

        if args.dry_run:
            discard(token, args.package, edit)
            print(f"Dry run: track '{args.track}' was prepared and the edit discarded.")
            return 0

        committed = _request(
            token, f"{API_ROOT}/{args.package}/edits/{edit}:commit", "POST", {}
        )
        print(f"Edit committed: {committed.get('id', edit)}")
    except PlayError:
        discard(token, args.package, edit)
        raise

    verification = edit_id(token, args.package)
    try:
        tracks = _request(
            token, f"{API_ROOT}/{args.package}/edits/{verification}/tracks"
        )
    finally:
        discard(token, args.package, verification)

    for entry in tracks.get("tracks", []):
        if entry.get("track") != args.track:
            continue
        codes = [
            int(code)
            for release in entry.get("releases") or []
            for code in release.get("versionCodes") or []
        ]
        if args.expect_version_code in codes:
            print(f"Verified: track '{args.track}' now carries versionCode {codes}.")
            return 0
    raise PlayError(
        f"track '{args.track}' does not carry versionCode {args.expect_version_code}"
        " after commit"
    )


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (PlayError, store_whats_new.StoreNotesError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
