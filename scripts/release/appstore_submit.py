#!/usr/bin/env python3
"""Submit an already uploaded iOS build for App Store review.

The Internal TestFlight lane already builds, signs, and uploads the IPA. This
tool owns only what happens after that upload: it waits for App Store Connect to
finish processing the build, answers export compliance, reuses or creates the
`appStoreVersion`, copies the previous version's metadata (localizations, review
detail, screenshots) onto it, sets "What's New" from the curated store copy,
attaches the build, opens a review submission, submits it, and verifies
`WAITING_FOR_REVIEW`.

App Store Connect has no rollback for a submitted version, so every check that
can fail on missing or mismatched data runs before the first write. The version
is created with `releaseType: AFTER_APPROVAL`, so Apple publishes it as soon as
review passes; there is no post-approval hold to catch a mistake.

Authentication uses the App Store Connect API key with the App Manager role.
Provide it base64-encoded in `APPLE_API_KEY_BASE64` or as a path in
`APPLE_API_KEY_P8`. The key and the derived token are never printed.

Usage:
  appstore_submit.py --version 1.0.27 --build-number 27 [--dry-run]
    [--expect-app-id 6794974223] [--bundle-id com.eaststarai.sanad]
    [--contract release/release-contract.json]
    [--english-whats-new release/store-whats-new.en.txt]
    [--arabic-whats-new release/store-whats-new.ar.txt]
    [--info-plist client/ios/Runner/Info.plist]
    [--processing-timeout-seconds 1800]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
TOKEN_AUDIENCE = "appstoreconnect-v1"
# Apple rejects a token whose expiry is more than twenty minutes ahead.
TOKEN_LIFETIME_SECONDS = 900
DEFAULT_BUNDLE_ID = "com.eaststarai.sanad"
# The App Store accepts 4000 characters, Google Play 500 per language. The two
# lanes share one curated file per language, so the stricter limit is enforced.
WHATS_NEW_LIMIT = 4000
STORE_WHATS_NEW_LIMIT = 500
POLL_INITIAL_SECONDS = 15
POLL_MAX_SECONDS = 60

# States in which the version's metadata can still be written and attached.
EDITABLE_VERSION_STATES = frozenset(
    {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "METADATA_REJECTED"}
)
# States that prove this version is already on its way to the store.
SUBMITTED_VERSION_STATES = frozenset({"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE"})
# States that prove a different version is already in the review pipeline.
BLOCKING_VERSION_STATES = frozenset({"WAITING_FOR_REVIEW", "IN_REVIEW"})
# States that mean the store release already happened for that version.
RELEASED_VERSION_STATES = frozenset({"READY_FOR_SALE", "PROCESSING_FOR_APP_STORE"})
IN_FLIGHT_SUBMISSION_STATES = frozenset(
    {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES", "COMPLETING"}
)
REVIEW_DETAIL_FIELDS = (
    "contactFirstName",
    "contactLastName",
    "contactEmail",
    "contactPhone",
    "demoAccountName",
    "demoAccountPassword",
    "demoAccountRequired",
    "notes",
)
SOURCE_LOCALIZATION_FIELDS = (
    "description",
    "keywords",
    "supportUrl",
    "marketingUrl",
    "promotionalText",
)


class SubmitError(RuntimeError):
    pass


def _short(raw: bytes) -> str:
    return raw.decode("utf-8", "replace").replace("\n", " ")[:300]


def _compact(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode()


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


# --- ES256 ------------------------------------------------------------------
#
# openssl already signs with the .p8 key, but it emits the DER encoded
# ECDSA-Sig-Value. A JOSE ES256 signature is the raw 32-byte R followed by the
# raw 32-byte S, so the two integers are unpacked here instead of adding a
# crypto dependency.


def _der_length(der: bytes, index: int) -> tuple[int, int]:
    if index >= len(der):
        raise SubmitError("Truncated DER signature from openssl.")
    first = der[index]
    if first < 0x80:
        return first, index + 1
    count = first & 0x7F
    if count == 0 or count > 4 or index + count >= len(der):
        raise SubmitError("Unsupported DER length in the openssl signature.")
    return int.from_bytes(der[index + 1 : index + 1 + count], "big"), index + 1 + count


def _der_integers(der: bytes) -> tuple[int, int]:
    if not der or der[0] != 0x30:
        raise SubmitError("The openssl signature is not a DER SEQUENCE.")
    size, start = _der_length(der, 1)
    body = der[start : start + size]
    if len(body) != size:
        raise SubmitError("Truncated DER SEQUENCE in the openssl signature.")
    values = []
    index = 0
    for _ in range(2):
        if index >= len(body) or body[index] != 0x02:
            raise SubmitError("The openssl signature is missing an INTEGER.")
        length, value_start = _der_length(body, index + 1)
        values.append(int.from_bytes(body[value_start : value_start + length], "big"))
        index = value_start + length
    if index != len(body):
        raise SubmitError("The openssl signature carries trailing DER data.")
    return values[0], values[1]


def jose_signature(der: bytes, size: int = 32) -> bytes:
    """Convert a DER ECDSA signature into the fixed-width JOSE form."""
    r, s = _der_integers(der)
    try:
        return r.to_bytes(size, "big") + s.to_bytes(size, "big")
    except OverflowError as error:
        raise SubmitError("The openssl signature does not fit an ES256 curve.") from error


def openssl_sign(private_key_pem: bytes, signing_input: bytes) -> bytes:
    descriptor, path = tempfile.mkstemp(suffix=".p8")
    try:
        os.chmod(path, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(private_key_pem)
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", path],
            input=signing_input,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            raise SubmitError("openssl could not sign with the App Store Connect key.")
        return result.stdout
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def access_token(
    key_id: str,
    issuer_id: str,
    private_key_pem: bytes,
    now: float | None = None,
    lifetime: int = TOKEN_LIFETIME_SECONDS,
    signer=openssl_sign,
) -> str:
    issued = int(now if now is not None else time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {
        "iss": issuer_id,
        "iat": issued,
        "exp": issued + lifetime,
        "aud": TOKEN_AUDIENCE,
    }
    signing_input = f"{_b64url(_compact(header))}.{_b64url(_compact(claims))}"
    signature = jose_signature(signer(private_key_pem, signing_input.encode()))
    return f"{signing_input}.{_b64url(signature)}"


def load_key(private_key_path: str | None = None) -> bytes:
    encoded = os.environ.get("APPLE_API_KEY_BASE64")
    if encoded:
        return base64.b64decode(encoded)
    path = private_key_path or os.environ.get("APPLE_API_KEY_P8")
    if path:
        try:
            with open(path, "rb") as handle:
                return handle.read()
        except OSError as error:
            raise SubmitError(f"Cannot read the App Store Connect key: {error}") from error
    raise SubmitError("Set APPLE_API_KEY_BASE64 or APPLE_API_KEY_P8.")


# --- HTTP -------------------------------------------------------------------


def urlopen_transport(method: str, url: str, headers: dict, body: bytes | None):
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def urlopen_download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=180) as response:
        return response.read()


class Api:
    """Thin App Store Connect JSON:API client.

    The transport is injected so the offline tests can answer requests without a
    network, and so every recorded request can be asserted on.
    """

    def __init__(self, token: str, transport=urlopen_transport, root: str = API_ROOT):
        self._token = token
        self._transport = transport
        self._root = root

    def _call(self, method, path, params=None, payload=None, missing_ok=False):
        url = f"{self._root}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        headers = {"Accept": "application/json"}
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"
        body = None
        if payload is not None:
            body = _compact(payload)
            headers["Content-Type"] = "application/json"
        status, raw = self._transport(method, url, headers, body)
        if status == 404 and missing_ok:
            return {}
        if status >= 400:
            raise SubmitError(f"{method} {path} failed: HTTP {status} {_short(raw)}")
        return json.loads(raw) if raw else {}

    def get(self, path, params=None, missing_ok=False) -> dict:
        return self._call("GET", path, params=params, missing_ok=missing_ok)

    def post(self, path, payload) -> dict:
        return self._call("POST", path, payload=payload)

    def patch(self, path, payload) -> dict:
        return self._call("PATCH", path, payload=payload)

    def send(self, method: str, url: str, body: bytes, headers: dict) -> None:
        status, raw = self._transport(method, url, headers, body)
        if status >= 400:
            raise SubmitError(f"asset upload failed: HTTP {status} {_short(raw)}")


# --- release copy -----------------------------------------------------------


def read_store_whats_new(path: str, version: str, language: str) -> str:
    """Read one curated store copy file and prove it belongs to this release.

    The store text is curated per release instead of being extracted from
    `release/release-notes.md`: the notes explain the engineering story to
    developers, while the store copy is short, user-facing, and shared verbatim
    by the App Store and Google Play lanes. The first line binds the file to the
    release, so stale copy cannot reach a store.
    """
    if not os.path.isfile(path):
        raise SubmitError(f"Missing {language} store copy: {path}.")
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    header_index = next((index for index, line in enumerate(lines) if line.strip()), None)
    if header_index is None:
        raise SubmitError(f"{path} is empty; its first line must be '# {version}'.")
    match = re.fullmatch(r"#\s*(\d+\.\d+\.\d+)", lines[header_index].strip())
    if not match:
        raise SubmitError(
            f"{path} must start with '# {version}' so stale store copy cannot be"
            " submitted."
        )
    if match.group(1) != version:
        raise SubmitError(
            f"{path} carries the {match.group(1)} store copy but this release is"
            f" {version}; rewrite the {language} text for this release."
        )
    text = "\n".join(lines[header_index + 1 :]).strip()
    if not text:
        raise SubmitError(f"{path} carries no {language} store copy.")
    if len(text) > STORE_WHATS_NEW_LIMIT:
        raise SubmitError(
            f"{path} is {len(text)} characters; the shared store limit is"
            f" {STORE_WHATS_NEW_LIMIT} per language (App Store allows"
            f" {WHATS_NEW_LIMIT})."
        )
    return text


class StoreCopy:
    """Curated "What's New" text, loaded per locale on first use."""

    def __init__(self, english_path: str, arabic_path: str, version: str):
        self.english = read_store_whats_new(english_path, version, "en-US")
        self._arabic_path = arabic_path
        self._version = version
        self._arabic: str | None = None

    def for_locale(self, locale: str) -> str:
        if locale == "en-US":
            return self.english
        if locale == "ar-SA":
            if self._arabic is None:
                self._arabic = read_store_whats_new(
                    self._arabic_path, self._version, "ar-SA"
                )
            return self._arabic
        raise SubmitError(
            f"Store localization {locale} has no What's New source. This lane owns"
            " en-US and ar-SA only; extend it before releasing that locale."
        )

def require_no_non_exempt_encryption(path: str) -> None:
    """The lane answers export compliance, so the app must declare it."""
    try:
        with open(path, "rb") as handle:
            entitlements = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise SubmitError(f"Cannot read {path}: {error}") from error
    if entitlements.get("ITSAppUsesNonExemptEncryption") is not False:
        raise SubmitError(
            f"{path} must declare ITSAppUsesNonExemptEncryption=false;"
            " App Store Connect would otherwise wait for the answer."
        )


# --- App Store Connect steps ------------------------------------------------


def resolve_app(api: Api, bundle_id: str, expect_app_id: str) -> str:
    data = api.get(
        "/apps",
        {
            "filter[bundleId]": bundle_id,
            "fields[apps]": "name,bundleId,primaryLocale",
        },
    ).get("data") or []
    if len(data) != 1:
        raise SubmitError(
            f"Expected exactly one App Store Connect app for {bundle_id}, found {len(data)}."
        )
    app = data[0]
    if app.get("attributes", {}).get("bundleId") != bundle_id:
        raise SubmitError(
            f"App Store Connect returned bundle id {app['attributes'].get('bundleId')!r}"
            f" for {bundle_id!r}."
        )
    if expect_app_id and app["id"] != expect_app_id:
        raise SubmitError(
            f"App Store Connect app id drift: resolved {app['id']} but this release"
            f" targets {expect_app_id}."
        )
    return app["id"]


def wait_for_build(
    api: Api,
    app_id: str,
    build_number: str,
    version: str,
    timeout_seconds: int,
    clock=time.monotonic,
    sleep=time.sleep,
    interval: float = POLL_INITIAL_SECONDS,
    max_interval: float = POLL_MAX_SECONDS,
) -> dict:
    """Poll until App Store Connect finished processing the uploaded build."""
    deadline = clock() + timeout_seconds
    delay = interval
    state = "not found"
    while True:
        data = api.get(
            "/builds",
            {
                "filter[app]": app_id,
                "filter[version]": build_number,
                "filter[preReleaseVersion.platform]": "IOS",
                "filter[preReleaseVersion.version]": version,
                "include": "preReleaseVersion",
                "fields[builds]": "version,processingState,usesNonExemptEncryption,expired",
            },
        ).get("data") or []
        match = [
            entry
            for entry in data
            if entry.get("attributes", {}).get("version") == build_number
        ]
        if match:
            build = match[0]
            state = build["attributes"].get("processingState", "unknown")
            if state == "VALID":
                if build["attributes"].get("expired"):
                    raise SubmitError(f"Build {build_number} is VALID but already expired.")
                return build
            if state in {"INVALID", "FAILED"}:
                raise SubmitError(
                    f"Build {build_number} finished processing as {state};"
                    " upload a new build before submitting."
                )
        if clock() >= deadline:
            raise SubmitError(
                f"Build {build_number} of {version} did not finish processing within"
                f" {timeout_seconds}s (last state: {state})."
            )
        sleep(delay)
        delay = min(delay * 2, max_interval)


def ensure_export_compliance(api: Api, build: dict, dry_run: bool) -> str:
    declared = build["attributes"].get("usesNonExemptEncryption")
    if declared is False:
        return "declared"
    if declared is True:
        raise SubmitError(
            "Build export compliance claims non-exempt encryption; the app declares"
            " ITSAppUsesNonExemptEncryption=false."
        )
    if dry_run:
        return "planned"
    api.patch(
        f"/builds/{build['id']}",
        {
            "data": {
                "type": "builds",
                "id": build["id"],
                "attributes": {"usesNonExemptEncryption": False},
            }
        },
    )
    return "answered"


def list_versions(api: Api, app_id: str) -> list[dict]:
    return api.get(
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": "IOS",
            "limit": "200",
            "fields[appStoreVersions]": (
                "versionString,platform,appStoreState,releaseType,createdDate"
            ),
        },
    ).get("data") or []


def version_key(entry: dict) -> tuple[int, ...]:
    try:
        return tuple(int(part) for part in entry["attributes"]["versionString"].split("."))
    except (KeyError, ValueError):
        return (0,)


def assert_versions_allow_submission(versions: list[dict], target_id: str | None) -> None:
    for entry in versions:
        if entry["id"] == target_id:
            continue
        state = entry["attributes"].get("appStoreState")
        label = entry["attributes"].get("versionString")
        if state == "PENDING_DEVELOPER_RELEASE":
            raise SubmitError(
                f"Version {label} is PENDING_DEVELOPER_RELEASE. Release or remove it"
                " first: with AFTER_APPROVAL it would publish after this submission"
                " and overwrite the newer release."
            )
        if state in BLOCKING_VERSION_STATES:
            raise SubmitError(
                f"Version {label} is {state}; App Store Connect holds one submission"
                " per app at a time, so wait for that review or cancel it."
            )


def select_source_version(versions: list[dict], target_id: str | None) -> dict | None:
    """The released version whose metadata the new version inherits."""
    candidates = [
        entry
        for entry in versions
        if entry["id"] != target_id
        and entry["attributes"].get("appStoreState") in RELEASED_VERSION_STATES
    ]
    if not candidates:
        return None
    return max(candidates, key=version_key)


def ensure_version(api: Api, app_id: str, version: str, current: dict | None, dry_run: bool):
    if current is None:
        if dry_run:
            return None, "planned"
        created = api.post(
            "/appStoreVersions",
            {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": "IOS",
                        "versionString": version,
                        # Owner decision: Apple releases the approved version.
                        "releaseType": "AFTER_APPROVAL",
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )["data"]
        return created, "created"
    release_type = current["attributes"].get("releaseType")
    if release_type == "AFTER_APPROVAL":
        return current, "reused"
    if dry_run:
        return current, "planned-retarget"
    updated = api.patch(
        f"/appStoreVersions/{current['id']}",
        {
            "data": {
                "type": "appStoreVersions",
                "id": current["id"],
                "attributes": {"releaseType": "AFTER_APPROVAL"},
            }
        },
    )["data"]
    return updated, "retargeted"


def localizations(api: Api, version_id: str) -> list[dict]:
    return api.get(
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        {
            "limit": "200",
            "fields[appStoreVersionLocalizations]": "locale,whatsNew,"
            + ",".join(SOURCE_LOCALIZATION_FIELDS),
        },
    ).get("data") or []


def plan_localizations(
    target: list[dict], source: list[dict], copy: StoreCopy
) -> tuple[list[dict], list[tuple[str, str, str]]]:
    """Return the localizations to create and the ones whose What's New changed."""
    if not target and not source:
        raise SubmitError(
            "The version has no localizations and there is no released version to"
            " copy them from; add the store metadata in App Store Connect first."
        )
    source_by_locale = {entry["attributes"]["locale"]: entry for entry in source}
    target_by_locale = {entry["attributes"]["locale"]: entry for entry in target}
    creates: list[dict] = []
    updates: list[tuple[str, str, str]] = []
    for locale in sorted(source_by_locale or target_by_locale):
        text = copy.for_locale(locale)
        existing = target_by_locale.get(locale)
        if existing is None:
            attributes = {"locale": locale, "whatsNew": text}
            for field in SOURCE_LOCALIZATION_FIELDS:
                value = source_by_locale[locale]["attributes"].get(field)
                if value:
                    attributes[field] = value
            creates.append(attributes)
            continue
        if (existing["attributes"].get("whatsNew") or "") != text:
            updates.append((existing["id"], locale, text))
    return creates, updates


def ensure_localizations(
    api: Api,
    version_id: str,
    creates: list[dict],
    updates: list[tuple[str, str, str]],
    dry_run: bool,
) -> list[str]:
    performed = [f"created {entry['locale']}" for entry in creates]
    performed += [f"updated {locale}" for _, locale, _ in updates]
    if dry_run:
        return performed
    for attributes in creates:
        api.post(
            "/appStoreVersionLocalizations",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": attributes,
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        }
                    },
                }
            },
        )
    for localization_id, _, text in updates:
        api.patch(
            f"/appStoreVersionLocalizations/{localization_id}",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": localization_id,
                    "attributes": {"whatsNew": text},
                }
            },
        )
    return performed


def ensure_review_detail(
    api: Api, version_id: str, source_version_id: str | None, dry_run: bool
) -> str:
    current = api.get(f"/appStoreVersions/{version_id}/appStoreReviewDetail", missing_ok=True)
    if current.get("data"):
        return "present"
    if not source_version_id:
        raise SubmitError(
            "The version has no App Store review detail and there is no released"
            " version to copy the review contact and notes from."
        )
    source = api.get(
        f"/appStoreVersions/{source_version_id}/appStoreReviewDetail", missing_ok=True
    ).get("data")
    if not source:
        raise SubmitError(
            f"Version {source_version_id} has no review detail to copy; fill the"
            " App Store Connect review contact and notes first."
        )
    attributes = {
        field: source["attributes"][field]
        for field in REVIEW_DETAIL_FIELDS
        if source.get("attributes", {}).get(field) is not None
    }
    if dry_run:
        return "planned"
    api.post(
        "/appStoreReviewDetails",
        {
            "data": {
                "type": "appStoreReviewDetails",
                "attributes": attributes,
                "relationships": {
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    }
                },
            }
        },
    )
    return "copied"


def screenshot_sets(api: Api, localization_id: str) -> tuple[list[dict], list[dict]]:
    response = api.get(
        f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
        {
            "include": "appScreenshots",
            "limit": "50",
            "fields[appScreenshotSets]": "screenshotDisplayType",
        },
    )
    return response.get("data") or [], response.get("included") or []


def ensure_screenshots(
    api: Api,
    localization_id: str,
    source_localization_id: str | None,
    dry_run: bool,
    download=urlopen_download,
) -> list[str]:
    """Copy the previous version's screenshots, which a new version never inherits."""
    if not source_localization_id:
        return []
    target_sets, _ = screenshot_sets(api, localization_id)
    present = {entry["attributes"].get("screenshotDisplayType") for entry in target_sets}
    source_sets, included = screenshot_sets(api, source_localization_id)
    performed: list[str] = []
    for source_set in source_sets:
        display_type = source_set["attributes"].get("screenshotDisplayType")
        if display_type in present:
            continue
        shots = [
            entry
            for entry in included
            if ((entry.get("relationships") or {}).get("appScreenshotSet") or {})
            .get("data", {})
            .get("id")
            == source_set["id"]
        ]
        if not shots:
            continue
        for shot in shots:
            asset = shot.get("attributes", {}).get("imageAsset") or {}
            if not asset.get("templateUrl") or not asset.get("width") or not asset.get("height"):
                raise SubmitError(
                    "A source screenshot has no downloadable image asset; copy the"
                    " App Store screenshots manually for this display type."
                )
        performed.append(f"{display_type} ({len(shots)} screenshot(s))")
        if dry_run:
            continue
        created = api.post(
            "/appScreenshotSets",
            {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": display_type},
                    "relationships": {
                        "appStoreVersionLocalization": {
                            "data": {
                                "type": "appStoreVersionLocalizations",
                                "id": localization_id,
                            }
                        }
                    },
                }
            },
        )["data"]
        for index, shot in enumerate(shots):
            asset = shot["attributes"]["imageAsset"]
            url = (
                asset["templateUrl"]
                .replace("{w}", str(asset["width"]))
                .replace("{h}", str(asset["height"]))
            )
            payload = download(url)
            file_name = shot["attributes"].get("fileName") or f"{display_type}-{index + 1}.png"
            uploaded = api.post(
                "/appScreenshots",
                {
                    "data": {
                        "type": "appScreenshots",
                        "attributes": {"fileName": file_name, "fileSize": len(payload)},
                        "relationships": {
                            "appScreenshotSet": {
                                "data": {"type": "appScreenshotSets", "id": created["id"]}
                            }
                        },
                    }
                },
            )["data"]
            for operation in uploaded["attributes"].get("uploadOperations") or []:
                offset = operation["offset"]
                part = payload[offset : offset + operation["length"]]
                headers = {
                    header["name"]: header["value"]
                    for header in operation.get("requestHeaders") or []
                }
                api.send(operation["method"], operation["url"], part, headers)
            api.patch(
                f"/appScreenshots/{uploaded['id']}",
                {
                    "data": {
                        "type": "appScreenshots",
                        "id": uploaded["id"],
                        "attributes": {"uploaded": True},
                    }
                },
            )
    return performed


def attached_build_id(api: Api, version_id: str) -> str | None:
    data = api.get(
        f"/appStoreVersions/{version_id}",
        {"include": "build", "fields[appStoreVersions]": "appStoreState,versionString"},
    ).get("data") or {}
    relationship = (data.get("relationships") or {}).get("build") or {}
    return (relationship.get("data") or {}).get("id")


def ensure_build_attached(api: Api, version_id: str, build_id: str, dry_run: bool) -> str:
    if attached_build_id(api, version_id) == build_id:
        return "attached"
    if dry_run:
        return "planned"
    api.patch(
        f"/appStoreVersions/{version_id}",
        {
            "data": {
                "type": "appStoreVersions",
                "id": version_id,
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
    )
    return "attached"


def list_submissions(api: Api, app_id: str) -> list[dict]:
    return api.get(
        f"/apps/{app_id}/reviewSubmissions",
        {"limit": "20", "fields[reviewSubmissions]": "state,submitted"},
    ).get("data") or []


def submission_items(api: Api, submission_id: str) -> list[dict]:
    return api.get(
        f"/reviewSubmissions/{submission_id}/items",
        {
            "limit": "50",
            "include": "appStoreVersion",
            "fields[reviewSubmissionItems]": "state",
        },
    ).get("data") or []


def items_version_ids(items: list[dict]) -> set[str]:
    ids = set()
    for item in items:
        relationship = (item.get("relationships") or {}).get("appStoreVersion") or {}
        version_id = (relationship.get("data") or {}).get("id")
        if version_id:
            ids.add(version_id)
    return ids


def assert_no_foreign_submission(api: Api, app_id: str, version_id: str | None) -> None:
    """Refuse before any write when another review submission is in flight."""
    for entry in list_submissions(api, app_id):
        state = entry["attributes"].get("state")
        if state not in IN_FLIGHT_SUBMISSION_STATES:
            continue
        if version_id is not None and version_id in items_version_ids(
            submission_items(api, entry["id"])
        ):
            continue
        raise SubmitError(
            f"Review submission {entry['id']} is already {state}; App Store Connect"
            " allows one submission per app, so wait for that review or cancel it."
        )


def ensure_submission(
    api: Api, app_id: str, version_id: str, submit: bool, dry_run: bool = False
) -> tuple[str, str]:
    """Return the review submission that carries this version, submitting it once."""
    submissions = list_submissions(api, app_id)
    draft: dict | None = None
    for entry in submissions:
        state = entry["attributes"].get("state")
        if state not in IN_FLIGHT_SUBMISSION_STATES | {"READY_FOR_REVIEW"}:
            continue
        if version_id not in items_version_ids(submission_items(api, entry["id"])):
            continue
        if state != "READY_FOR_REVIEW":
            # The version is inside a submission App Store Connect already
            # accepted, which is the idempotent outcome of a re-run.
            return entry["id"], "already-submitted"
        draft = entry
    if draft is None:
        in_flight = [
            entry
            for entry in submissions
            if entry["attributes"].get("state") in IN_FLIGHT_SUBMISSION_STATES
        ]
        if in_flight:
            raise SubmitError(
                f"Review submission {in_flight[0]['id']} is already"
                f" {in_flight[0]['attributes'].get('state')}; App Store Connect allows"
                " one submission per app, so wait for it or cancel it."
            )
        draft = next(
            (
                entry
                for entry in submissions
                if entry["attributes"].get("state") == "READY_FOR_REVIEW"
            ),
            None,
        )
    if draft is None:
        if dry_run:
            return "", "would-create"
        draft = api.post(
            "/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )["data"]
    if version_id not in items_version_ids(submission_items(api, draft["id"])):
        if dry_run:
            return draft["id"], "would-add-item"
        api.post(
            "/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {"type": "reviewSubmissions", "id": draft["id"]}
                        },
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        },
                    },
                }
            },
        )
    if not submit:
        return draft["id"], "planned"
    api.patch(
        f"/reviewSubmissions/{draft['id']}",
        {
            "data": {
                "type": "reviewSubmissions",
                "id": draft["id"],
                "attributes": {"submitted": True},
            }
        },
    )
    return draft["id"], "submitted"


def verify_submission(
    api: Api,
    submission_id: str,
    version_id: str,
    sleep=time.sleep,
    attempts: int = 6,
    interval: float = 10,
) -> dict:
    """App Store Connect accepts the submission before the state settles."""
    for attempt in range(attempts):
        submission = api.get(
            f"/reviewSubmissions/{submission_id}", {"fields[reviewSubmissions]": "state"}
        ).get("data") or {}
        version = api.get(
            f"/appStoreVersions/{version_id}",
            {"fields[appStoreVersions]": "appStoreState,versionString"},
        ).get("data") or {}
        submission_state = submission.get("attributes", {}).get("state")
        version_state = version.get("attributes", {}).get("appStoreState")
        if (
            submission_state == "WAITING_FOR_REVIEW"
            and version_state == "WAITING_FOR_REVIEW"
        ):
            return {"submission": submission_state, "version": version_state}
        if attempt + 1 < attempts:
            sleep(interval)
    raise SubmitError(
        f"Submission {submission_id} did not reach WAITING_FOR_REVIEW"
        f" (submission: {submission_state}, version: {version_state})."
    )


# --- orchestration ----------------------------------------------------------


def _contract(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        raise SubmitError(f"Cannot read the release contract at {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise SubmitError(
            f"The release contract at {path} is not valid JSON: {error}"
        ) from error


def run(
    args,
    transport=urlopen_transport,
    download=urlopen_download,
    signer=openssl_sign,
    sleep=time.sleep,
    clock=time.monotonic,
) -> int:
    contract = _contract(args.contract)
    if contract.get("version") != args.version:
        raise SubmitError(
            f"Requested version {args.version} but the release contract declares"
            f" {contract.get('version')}."
        )
    if str(contract.get("build_number")) != str(args.build_number):
        raise SubmitError(
            f"Requested build {args.build_number} but the release contract declares"
            f" {contract.get('build_number')}."
        )
    require_no_non_exempt_encryption(args.info_plist)
    copy = StoreCopy(args.english_whats_new, args.arabic_whats_new, args.version)

    key_id = os.environ.get("APPLE_API_KEY_ID") or ""
    issuer_id = os.environ.get("APPLE_API_ISSUER_ID") or ""
    if not key_id or not issuer_id:
        raise SubmitError("Set APPLE_API_KEY_ID and APPLE_API_ISSUER_ID.")
    token = access_token(key_id, issuer_id, load_key(args.private_key), signer=signer)
    api = Api(token, transport=transport)

    app_id = resolve_app(api, args.bundle_id, args.expect_app_id)
    print(f"App {app_id} resolved for {args.bundle_id}.")

    build = wait_for_build(
        api,
        app_id,
        str(args.build_number),
        args.version,
        args.processing_timeout_seconds,
        clock=clock,
        sleep=sleep,
    )
    print(f"Build {args.build_number} is VALID.")

    versions = list_versions(api, app_id)
    target = next(
        (entry for entry in versions if entry["attributes"].get("versionString") == args.version),
        None,
    )
    assert_versions_allow_submission(versions, target["id"] if target else None)
    # A submission already in flight is a read-only blocking condition, so it is
    # proven before the export-compliance answer or any version write.
    assert_no_foreign_submission(api, app_id, target["id"] if target else None)
    if target is not None:
        state = target["attributes"].get("appStoreState")
        if state in SUBMITTED_VERSION_STATES:
            current_build = attached_build_id(api, target["id"])
            if current_build != build["id"]:
                raise SubmitError(
                    f"Version {args.version} is already {state} with build {current_build},"
                    f" not {args.build_number}."
                )
            print(f"Version {args.version} is already {state}; nothing to submit.")
            return 0
        if state in RELEASED_VERSION_STATES or state == "PENDING_DEVELOPER_RELEASE":
            raise SubmitError(
                f"Version {args.version} is already {state}; it cannot be submitted again."
            )
        if state not in EDITABLE_VERSION_STATES:
            raise SubmitError(
                f"Version {args.version} is {state}, which this lane does not submit from."
            )

    source = select_source_version(versions, target["id"] if target else None)
    source_localizations = localizations(api, source["id"]) if source else []
    target_localizations = localizations(api, target["id"]) if target else []
    # Every locale the listing carries gets its What's New text before the first
    # write, so a missing or stale store copy cannot leave a half-built version.
    creates, updates = plan_localizations(target_localizations, source_localizations, copy)

    # Every check above is read-only, so the first write happens only once the
    # whole plan is known to be satisfiable.
    print(f"Export compliance: {ensure_export_compliance(api, build, args.dry_run)}.")
    if target is None:
        print(
            f"Version {args.version} is missing; it would be created with"
            f" AFTER_APPROVAL and {len(creates)} copied localization(s)."
            if args.dry_run
            else f"Creating version {args.version} with AFTER_APPROVAL."
        )
        if args.dry_run:
            print("Dry run: no version, metadata, screenshot, or build was written.")
            return 0
        target, action = ensure_version(api, app_id, args.version, None, args.dry_run)
        print(f"Version {args.version} {action}.")
    else:
        target, action = ensure_version(api, app_id, args.version, target, args.dry_run)
        print(f"Version {args.version} {action}.")

    planned_locales = sorted(
        {entry["locale"] for entry in creates} | {locale for _, locale, _ in updates}
    )
    print(f"Localizations in this version: {', '.join(planned_locales) or 'none'}.")
    print(f"What's New: {len(copy.english)} characters (en-US) for {args.version}.")
    print(
        "What's New changes: "
        f"{', '.join(ensure_localizations(api, target['id'], creates, updates, args.dry_run)) or 'none'}."
    )
    print(
        "Review detail: "
        f"{ensure_review_detail(api, target['id'], source['id'] if source else None, args.dry_run)}."
    )

    # Screenshots live on the localization, and a freshly created one has none,
    # so the localization list is re-read after they are written.
    target_by_locale = {
        entry["attributes"]["locale"]: entry
        for entry in localizations(api, target["id"])
    }
    copied_sets = []
    for locale, entry in sorted(target_by_locale.items()):
        source_entry = next(
            (
                candidate
                for candidate in source_localizations
                if candidate["attributes"].get("locale") == locale
            ),
            None,
        )
        copied_sets += ensure_screenshots(
            api,
            entry["id"],
            source_entry["id"] if source_entry else None,
            args.dry_run,
            download=download,
        )
    print(f"Screenshots copied: {', '.join(copied_sets) or 'none'}.")

    if not args.dry_run:
        state = api.get(
            f"/appStoreVersions/{target['id']}",
            {"fields[appStoreVersions]": "appStoreState"},
        )["data"]["attributes"]["appStoreState"]
        if state != "PREPARE_FOR_SUBMISSION":
            raise SubmitError(
                f"Version {args.version} is {state} after the metadata copy;"
                " App Store Connect refused an editable state."
            )
    print(
        f"Build {args.build_number}: "
        f"{ensure_build_attached(api, target['id'], build['id'], args.dry_run)}."
    )

    submission_id, outcome = ensure_submission(
        api, app_id, target["id"], submit=not args.dry_run, dry_run=args.dry_run
    )
    if args.dry_run:
        print(
            "Dry run: review submission "
            f"{submission_id or '(new)'} would be {outcome}; nothing was written."
        )
        return 0
    if outcome == "already-submitted":
        print(f"Version {args.version} is already in submission {submission_id}.")
    else:
        print(f"Submission {submission_id} created.")
    states = verify_submission(api, submission_id, target["id"], sleep=sleep)
    print(
        f"Verified: submission {states['submission']}, version {states['version']}."
    )
    return 0


def parse_args(argv: list[str]):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--contract", default="release/release-contract.json")
    parser.add_argument("--english-whats-new", default="release/store-whats-new.en.txt")
    parser.add_argument("--arabic-whats-new", default="release/store-whats-new.ar.txt")
    parser.add_argument("--info-plist", default="client/ios/Runner/Info.plist")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--expect-app-id", default="")
    parser.add_argument("--private-key", default=None)
    parser.add_argument("--processing-timeout-seconds", type=int, default=1800)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    return run(parse_args(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SubmitError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
