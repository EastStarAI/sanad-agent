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
  appstore_submit.py --version 1.0.27 --build-number 27
    --bundle-id com.eaststarai.sanad --expect-app-id 6794974223 [--dry-run]
    [--contract release/release-contract.json]
    [--store-copy-directory release]
    [--info-plist client/ios/Runner/Info.plist]
    [--processing-timeout-seconds 1800]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import store_whats_new

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
TOKEN_AUDIENCE = "appstoreconnect-v1"
# Apple rejects a token whose expiry is more than twenty minutes ahead. A run can
# wait far longer than that for build processing, so the token is re-minted on
# demand instead of being minted once per run.
TOKEN_LIFETIME_SECONDS = 900
TOKEN_REFRESH_MARGIN_SECONDS = 120
POLL_INITIAL_SECONDS = 15
POLL_MAX_SECONDS = 60
# App Store Connect throttles and returns 5xx under load, and the screenshot copy
# issues a burst of requests.
RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})
RETRY_ATTEMPTS = 3
RETRY_INITIAL_SECONDS = 5
RETRY_MAX_SECONDS = 60

# States in which the version's metadata can still be written and attached.
# READY_FOR_REVIEW is included because App Store Connect reports it for a version
# whose metadata is complete and only the submission is missing.
EDITABLE_VERSION_STATES = frozenset(
    {
        "PREPARE_FOR_SUBMISSION",
        "READY_FOR_REVIEW",
        "DEVELOPER_REJECTED",
        "METADATA_REJECTED",
    }
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
# A screenshot is usable only after App Store Connect finished processing it.
SCREENSHOT_COMPLETE_STATE = "COMPLETE"
SCREENSHOT_FAILED_STATE = "FAILED"
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

    The transport and the sleeping function are injected so the offline tests can
    answer requests without a network, and so every recorded request can be
    asserted on. The bearer token is minted on demand: a run can wait far longer
    than one token's lifetime for build processing, and Apple rejects a token
    whose expiry is more than twenty minutes ahead.
    """

    def __init__(
        self,
        token_factory,
        transport=urlopen_transport,
        root: str = API_ROOT,
        sleep=time.sleep,
        clock=time.monotonic,
    ):
        self._token_factory = token_factory
        self._transport = transport
        self._root = root
        self._sleep = sleep
        self._clock = clock
        self._token: str | None = None
        self._minted_at = -1e12

    def _bearer(self) -> str:
        if (
            self._clock() - self._minted_at
            >= TOKEN_LIFETIME_SECONDS - TOKEN_REFRESH_MARGIN_SECONDS
        ):
            self._token = self._token_factory()
            self._minted_at = self._clock()
        return self._token or ""

    def _request(self, method, url, headers, body):
        """Send one request, retrying throttling and transient server failures."""
        delay = RETRY_INITIAL_SECONDS
        for attempt in range(1, RETRY_ATTEMPTS + 1):
            status, raw = self._transport(method, url, headers, body)
            if status not in RETRY_STATUSES or attempt == RETRY_ATTEMPTS:
                return status, raw
            self._sleep(delay)
            delay = min(delay * 2, RETRY_MAX_SECONDS)
        raise SubmitError("unreachable")  # pragma: no cover

    def _call(self, method, path, params=None, payload=None, missing_ok=False):
        url = f"{self._root}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        headers = {"Accept": "application/json"}
        token = self._bearer()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        body = None
        if payload is not None:
            body = _compact(payload)
            headers["Content-Type"] = "application/json"
        status, raw = self._request(method, url, headers, body)
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
        # The asset URL is pre-signed and carries its own credentials, so no
        # bearer token is attached and the URL is never logged.
        status, raw = self._request(method, url, headers, body)
        if status >= 400:
            raise SubmitError(f"asset upload failed: HTTP {status} {_short(raw)}")


# --- store copy -------------------------------------------------------------


class StoreCopy:
    """App Store "What's New" per localization, read from the shared store text.

    `scripts/release/store_whats_new.py` owns the file format, the release
    binding, and the character limit for both stores. This adapter only maps the
    App Store localization codes, and it reads lazily so an Arabic listing is
    required only when the version actually carries an `ar-SA` localization.
    """

    def __init__(self, directory: str, version: str):
        self._directory = directory
        self._version = version
        self._text: dict[str, str] = {}

    def for_locale(self, locale: str) -> str:
        if locale not in self._text:
            try:
                self._text[locale] = store_whats_new.app_store_text(
                    self._directory, self._version, locale
                )
            except store_whats_new.StoreNotesError as error:
                raise SubmitError(str(error)) from error
        return self._text[locale]


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
    # The union matters: a locale that exists only on the target version must
    # still get a What's New body or fail closed, otherwise a localization the
    # owner added in App Store Connect would submit with empty store text.
    for locale in sorted(set(source_by_locale) | set(target_by_locale)):
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
            "fields[appScreenshots]": "fileName,assetDeliveryState,imageAsset",
        },
    )
    return response.get("data") or [], response.get("included") or []


def shots_of(source_set: dict, included: list[dict]) -> list[dict]:
    return [
        entry
        for entry in included
        if ((entry.get("relationships") or {}).get("appScreenshotSet") or {})
        .get("data", {})
        .get("id")
        == source_set["id"]
    ]


def assert_screenshot_assets_are_downloadable(source_localization_id: str, sets, included) -> None:
    """Prove every source screenshot can be fetched before anything is written."""
    for source_set in sets:
        shots = shots_of(source_set, included)
        for shot in shots:
            asset = shot.get("attributes", {}).get("imageAsset") or {}
            if not asset.get("templateUrl") or not asset.get("width") or not asset.get("height"):
                raise SubmitError(
                    "A source screenshot for display type"
                    f" {source_set['attributes'].get('screenshotDisplayType')} has no"
                    " downloadable image asset (video previews are not copied);"
                    " copy the App Store screenshots manually for this display type."
                )
    if not sets:
        return


def assert_copy_sources_ready(
    api: Api, source: dict | None, source_localizations: list[dict]
) -> None:
    """Read-only proof that the released version has everything this lane copies.

    A dry run is the only human checkpoint before an unattended submission, so it
    covers the review detail and the screenshot assets too, not just the plan.
    """
    if source is None:
        return
    detail = api.get(
        f"/appStoreVersions/{source['id']}/appStoreReviewDetail", missing_ok=True
    ).get("data")
    if not detail:
        raise SubmitError(
            f"Version {source['attributes'].get('versionString')} has no App Store"
            " review detail to copy; fill the review contact and notes first."
        )
    for entry in source_localizations:
        sets, included = screenshot_sets(api, entry["id"])
        assert_screenshot_assets_are_downloadable(entry["id"], sets, included)


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
        shots = shots_of(source_set, included)
        if not shots:
            continue
        if display_type in present:
            # A display type that already exists is skipped, which would silently
            # finish a half-copied set. Compare counts instead of guessing.
            copied = next(
                (
                    entry
                    for entry in target_sets
                    if entry["attributes"].get("screenshotDisplayType") == display_type
                ),
                None,
            )
            _, target_included = screenshot_sets(api, localization_id)
            existing = len(shots_of(copied, target_included)) if copied else 0
            if existing < len(shots):
                raise SubmitError(
                    f"Screenshot set {display_type} holds {existing} of the"
                    f" {len(shots)} screenshots the released version carries;"
                    " remove that set in App Store Connect and re-run, or copy it"
                    " manually."
                )
            continue
        assert_screenshot_assets_are_downloadable(source_localization_id, [source_set], included)
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


def wait_for_screenshot_assets(
    api: Api,
    localization_id: str,
    timeout_seconds: int,
    clock=time.monotonic,
    sleep=time.sleep,
    interval: float = POLL_INITIAL_SECONDS,
    max_interval: float = POLL_MAX_SECONDS,
) -> str:
    """Wait until App Store Connect finished processing the copied screenshots.

    Uploading the bytes is not enough: each asset moves through
    AWAITING_UPLOAD -> UPLOAD_COMPLETE -> COMPLETE, and submitting while one is
    still processing is rejected as "screenshot uploads in progress".
    """
    deadline = clock() + timeout_seconds
    delay = interval
    pending = "none"
    while True:
        sets, included = screenshot_sets(api, localization_id)
        if not sets or not included:
            return "none"
        states = [screenshot_state(entry) for entry in included]
        failed = [state for state in states if state == SCREENSHOT_FAILED_STATE]
        if failed:
            raise SubmitError(
                f"App Store Connect failed to process a screenshot in"
                f" localization {localization_id}; replace it before submitting."
            )
        pending = f"{states.count(SCREENSHOT_COMPLETE_STATE)}/{len(states)} complete"
        if states.count(SCREENSHOT_COMPLETE_STATE) == len(states):
            return pending
        if clock() >= deadline:
            raise SubmitError(
                "Screenshots were still processing after"
                f" {timeout_seconds}s ({pending}); submission refused because App"
                " Store Connect rejects a version whose assets are not ready."
            )
        sleep(delay)
        delay = min(delay * 2, max_interval)


def screenshot_state(entry: dict) -> str:
    delivery = (entry.get("attributes") or {}).get("assetDeliveryState") or {}
    return str(delivery.get("state") or "unknown")


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
            if state == "UNRESOLVED_ISSUES":
                raise SubmitError(
                    f"Review submission {entry['id']} has unresolved issues; resolve"
                    " them or cancel that submission in App Store Connect."
                )
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
    copy = StoreCopy(args.store_copy_directory, args.version)

    key_id = os.environ.get("APPLE_API_KEY_ID") or ""
    issuer_id = os.environ.get("APPLE_API_ISSUER_ID") or ""
    if not key_id or not issuer_id:
        raise SubmitError("Set APPLE_API_KEY_ID and APPLE_API_ISSUER_ID.")
    key = load_key(args.private_key)
    api = Api(
        lambda: access_token(key_id, issuer_id, key, signer=signer),
        transport=transport,
        sleep=sleep,
        clock=clock,
    )

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

    # A dry run is the only human checkpoint before an unattended submission, so
    # the source metadata and screenshot assets are proven readable here too.
    assert_copy_sources_ready(api, source, source_localizations)

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
    print(
        f"What's New: {len(copy.for_locale('en-US'))} characters (en-US) for"
        f" {args.version}."
    )
    changes = ensure_localizations(api, target["id"], creates, updates, args.dry_run)
    print(f"What's New changes: {', '.join(changes) or 'none'}.")
    detail_state = ensure_review_detail(
        api, target["id"], source["id"] if source else None, args.dry_run
    )
    print(f"Review detail: {detail_state}.")

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
        for locale, entry in sorted(target_by_locale.items()):
            ready = wait_for_screenshot_assets(
                api,
                entry["id"],
                args.processing_timeout_seconds,
                clock=clock,
                sleep=sleep,
            )
            print(f"Screenshots ready ({locale}): {ready}.")

    if not args.dry_run:
        state = api.get(
            f"/appStoreVersions/{target['id']}",
            {"fields[appStoreVersions]": "appStoreState"},
        )["data"]["attributes"]["appStoreState"]
        if state not in EDITABLE_VERSION_STATES:
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
    parser.add_argument("--store-copy-directory", default="release")
    parser.add_argument("--info-plist", default="client/ios/Runner/Info.plist")
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--expect-app-id", required=True)
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
