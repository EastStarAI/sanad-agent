#!/usr/bin/env python3
"""Upload a signed Android App Bundle to a Google Play track.

The Google Play Developer API has no reversible upload: once a versionCode is
accepted it is consumed for the lifetime of the package. This tool therefore
proves the identity of the bundle from the API response before it commits the
edit, so a mismatch aborts with the edit discarded instead of publishing an
unexpected build.

Authentication uses a service account JSON key. Provide it either as a path in
PLAY_SERVICE_ACCOUNT_JSON or base64-encoded in
PLAY_SERVICE_ACCOUNT_JSON_BASE64. The key is never printed.

Usage:
  publish_play_bundle.py --bundle <path> --package com.eaststarai.sanad
    --track internal --expect-version-code 25 [--version-name 1.0.24]
    [--status completed] [--dry-run]
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

API_ROOT = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_ROOT = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"


class PlayError(RuntimeError):
    pass


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
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=True) as pem:
        pem.write(key["private_key"])
        pem.flush()
        signature = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", pem.name],
            input=signing_input.encode(),
            capture_output=True,
            check=True,
        ).stdout
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
            f"{_short(error.read())}"
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
        raise PlayError(f"{method} {url} failed: {error.code} {_short(error.read())}") from error


def edit_id(token: str, package: str) -> str:
    return _request(token, f"{API_ROOT}/{package}/edits", "POST", {})["id"]


def discard(token: str, package: str, edit: str) -> None:
    try:
        _request(token, f"{API_ROOT}/{package}/edits/{edit}", "DELETE")
    except PlayError as error:
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--track", required=True)
    parser.add_argument("--expect-version-code", required=True, type=int)
    parser.add_argument("--version-name", default="")
    parser.add_argument("--status", default="completed")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not os.path.isfile(args.bundle):
        print(f"Bundle not found: {args.bundle}", file=sys.stderr)
        return 2

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

        release = {
            "versionCodes": [str(accepted)],
            "status": args.status,
        }
        if args.version_name:
            release["name"] = f"{args.version_name} ({accepted})"
        track = {"track": args.track, "releases": [release]}
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
    except PlayError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
