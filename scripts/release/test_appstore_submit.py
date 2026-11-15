#!/usr/bin/env python3
"""Offline tests for scripts/release/appstore_submit.py.

Every test runs without a network, an App Store Connect key, or openssl. The
transport, the downloader, the signer, the clock, and the sleeping function are
all injected, so the assertions can cover the request order and prove that a
refused input never wrote anything.

Run from the repository root:
  python3 -I scripts/release/test_appstore_submit.py
"""

from __future__ import annotations

import base64
import contextlib
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import appstore_submit as lane  # noqa: E402

VERSION = "1.0.27"
BUILD = "27"
APP_ID = "6794974223"
BUNDLE_ID = "com.eaststarai.sanad"
ARABIC_TEXT = "- إجابات مباشرة."


def der_signature(r: int, s: int) -> bytes:
    def length(size: int) -> bytes:
        return bytes([size]) if size < 0x80 else bytes([0x81, size])

    def integer(value: int) -> bytes:
        raw = value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")
        return b"\x02" + length(len(raw)) + raw

    body = integer(r) + integer(s)
    return b"\x30" + length(len(body)) + body


def fake_signer(_key: bytes, _signing_input: bytes) -> bytes:
    # An ES256 signature always fits in two 32-byte integers.
    return der_signature(1, 2)


def counting_signer():
    """A signer whose signature changes per mint, so tokens are distinguishable."""

    minted = {"count": 0}

    def sign(_key: bytes, _signing_input: bytes) -> bytes:
        minted["count"] += 1
        return der_signature(1, minted["count"] + 2)

    return sign


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def version_resource(resource_id, version_string, state="READY_FOR_SALE"):
    return {
        "id": resource_id,
        "type": "appStoreVersions",
        "attributes": {
            "versionString": version_string,
            "platform": "IOS",
            "appStoreState": state,
            "releaseType": "AFTER_APPROVAL",
        },
    }


def localization_resource(resource_id, locale, whats_new=""):
    return {
        "id": resource_id,
        "type": "appStoreVersionLocalizations",
        "attributes": {
            "locale": locale,
            "whatsNew": whats_new,
            "description": "Sanad Remote",
            "keywords": "sanad,remote",
            "supportUrl": "https://sanad.eaststarai.com/support",
            "marketingUrl": None,
            "promotionalText": None,
        },
    }


def screenshot_resource(resource_id, set_id, file_name, with_asset=True):
    attributes = {"fileName": file_name, "assetDeliveryState": {"state": "COMPLETE"}}
    if with_asset:
        attributes["imageAsset"] = {
            "templateUrl": "https://assets.example/{w}x{h}.png",
            "width": 1290,
            "height": 2796,
        }
    return {
        "id": resource_id,
        "type": "appScreenshots",
        "attributes": attributes,
        "relationships": {
            "appScreenshotSet": {"data": {"id": set_id, "type": "appScreenshotSets"}}
        },
    }


class FakeAsc:
    """A small in-memory App Store Connect that records every request."""

    def __init__(
        self,
        versions=None,
        build_states=("VALID",),
        localizations=None,
        review_details=None,
        screenshot_sets=None,
        submissions=None,
        clock=None,
        reject_expired_tokens=False,
        asset_poll_states=None,
        throttle_requests=0,
    ):
        self.calls = []
        self.clock = clock or FakeClock()
        self.build_states = list(build_states)
        self.build = {
            "id": "build-27",
            "type": "builds",
            "attributes": {
                "version": BUILD,
                "processingState": "PROCESSING",
                "usesNonExemptEncryption": None,
                "expired": False,
            },
        }
        self.versions = versions if versions is not None else []
        self.localizations = localizations if localizations is not None else {}
        self.review_details = review_details if review_details is not None else {}
        self.screenshot_sets = screenshot_sets if screenshot_sets is not None else {}
        self.submissions = submissions or []
        self.build_attached = {}
        self.screenshot_uploads = []
        self.reject_expired_tokens = reject_expired_tokens
        self.asset_poll_states = list(asset_poll_states or [])
        self.throttle_requests = throttle_requests
        self.tokens = []
        self.first_seen = {}
        self.uploaded_shots = set()
        self._set_locale = {}
        self._next = 0

    # -- helpers ---------------------------------------------------------
    def _id(self, prefix):
        self._next += 1
        return f"{prefix}-{self._next}"

    def mutations(self):
        return [call for call in self.calls if call[0] != "GET"]

    def find(self, method, fragment):
        return [call for call in self.calls if call[0] == method and fragment in call[1]]

    def version(self, version_string):
        return next(
            (
                entry
                for entry in self.versions
                if entry["attributes"]["versionString"] == version_string
            ),
            None,
        )

    def _token_expired(self, headers):
        value = headers.get("Authorization", "")
        if not value.startswith("Bearer "):
            return False
        token = value.split(" ", 1)[1]
        now = self.clock()
        first = self.first_seen.setdefault(token, now)
        if token not in self.tokens:
            self.tokens.append(token)
        return now - first > lane.TOKEN_LIFETIME_SECONDS - lane.TOKEN_REFRESH_MARGIN_SECONDS

    # -- transport -------------------------------------------------------
    def handle(self, method, url, headers, body):
        parsed = urllib.parse.urlparse(url)
        path = parsed.path
        payload = json.loads(body) if body and method != "PUT" else None
        self.calls.append((method, path, payload))
        if method == "PUT":
            self.screenshot_uploads.append(path)
            return 200, b""
        if self.throttle_requests > 0 and path.startswith("/v1/"):
            self.throttle_requests -= 1
            return 429, b'{"errors":[{"detail":"rate limited"}]}'
        if self.reject_expired_tokens and self._token_expired(headers):
            return 401, b'{"errors":[{"detail":"expired token"}]}'
        status, response = self.route(method, path, payload)
        return status, json.dumps(response).encode() if response is not None else b""

    def route(self, method, path, payload):
        if path == "/v1/apps":
            return 200, {
                "data": [
                    {
                        "id": APP_ID,
                        "type": "apps",
                        "attributes": {"bundleId": BUNDLE_ID, "primaryLocale": "en-US"},
                    }
                ]
            }
        if path == "/v1/builds":
            if self.build_states:
                self.build["attributes"]["processingState"] = self.build_states.pop(0)
            return 200, {"data": [self.build]}
        if path.startswith("/v1/builds/"):
            self.build["attributes"]["usesNonExemptEncryption"] = False
            return 200, {"data": self.build}
        if path.endswith("/appStoreVersions") and method == "POST":
            created = {
                "id": self._id("version"),
                "type": "appStoreVersions",
                "attributes": {
                    "versionString": payload["data"]["attributes"]["versionString"],
                    "platform": "IOS",
                    "appStoreState": "PREPARE_FOR_SUBMISSION",
                    "releaseType": payload["data"]["attributes"]["releaseType"],
                },
            }
            self.versions.append(created)
            self.localizations[created["id"]] = []
            return 201, {"data": created}
        if path.endswith("/appStoreVersions"):
            return 200, {"data": self.versions}
        if "/appStoreVersions/" in path and path.endswith("/appStoreVersionLocalizations"):
            version_id = path.split("/")[3]
            return 200, {"data": self.localizations.get(version_id, [])}
        if path == "/v1/appStoreVersionLocalizations":
            version_id = payload["data"]["relationships"]["appStoreVersion"]["data"]["id"]
            attributes = payload["data"]["attributes"]
            created = localization_resource(
                self._id("loc"), attributes["locale"], attributes.get("whatsNew", "")
            )
            self.localizations.setdefault(version_id, []).append(created)
            return 201, {"data": created}
        if path.startswith("/v1/appStoreVersionLocalizations/"):
            localization_id = path.split("/")[3]
            if path.endswith("/appScreenshotSets"):
                return 200, self._screenshot_payload(localization_id)
            for entries in self.localizations.values():
                for entry in entries:
                    if entry["id"] == localization_id:
                        entry["attributes"].update(payload["data"]["attributes"])
                        return 200, {"data": entry}
            return 404, {"errors": [{"detail": "unknown localization"}]}
        if path == "/v1/appStoreReviewDetails":
            version_id = payload["data"]["relationships"]["appStoreVersion"]["data"]["id"]
            created = {
                "id": self._id("review-detail"),
                "type": "appStoreReviewDetails",
                "attributes": payload["data"]["attributes"],
            }
            self.review_details[version_id] = created
            return 201, {"data": created}
        if path == "/v1/appStoreScreenshotSets":
            return 201, {"data": {"id": self._id("set"), "type": "appScreenshotSets"}}
        if path == "/v1/appScreenshotSets":
            localization_id = payload["data"]["relationships"][
                "appStoreVersionLocalization"
            ]["data"]["id"]
            created = {
                "id": self._id("set"),
                "type": "appScreenshotSets",
                "attributes": {
                    "screenshotDisplayType": payload["data"]["attributes"][
                        "screenshotDisplayType"
                    ]
                },
                "relationships": {"appScreenshots": {"data": []}},
            }
            entry = self.screenshot_sets.setdefault(
                localization_id, {"data": [], "included": []}
            )
            entry["data"].append(created)
            self._set_locale[created["id"]] = localization_id
            return 201, {"data": created}
        if path == "/v1/appScreenshots" and method == "POST":
            set_id = payload["data"]["relationships"]["appScreenshotSet"]["data"]["id"]
            shot_id = self._id("shot")
            localization_id = self._set_locale.get(set_id)
            if localization_id is not None:
                entry = self.screenshot_sets.setdefault(
                    localization_id, {"data": [], "included": []}
                )
                shot = screenshot_resource(
                    shot_id,
                    set_id,
                    payload["data"]["attributes"].get("fileName") or "shot.png",
                )
                shot["attributes"]["assetDeliveryState"] = {"state": "AWAITING_UPLOAD"}
                entry["included"].append(shot)
            return 201, {
                "data": {
                    "id": shot_id,
                    "type": "appScreenshots",
                    "attributes": {
                        "uploadOperations": [
                            {
                                "method": "PUT",
                                "url": "https://assets.example/part-1",
                                "offset": 0,
                                "length": 4,
                                "requestHeaders": [{"name": "x-part", "value": "1"}],
                            }
                        ]
                    },
                }
            }
        if path.startswith("/v1/appScreenshots/"):
            shot_id = path.rsplit("/", 1)[-1]
            self.uploaded_shots.add(shot_id)
            return 200, {"data": {"id": shot_id, "type": "appScreenshots"}}
        if path.endswith("/appStoreReviewDetail"):
            version_id = path.split("/")[3]
            detail = self.review_details.get(version_id)
            if not detail:
                return 404, {"errors": [{"detail": "no review detail"}]}
            return 200, {"data": detail}
        if path.endswith("/reviewSubmissions") and method == "POST":
            created = {
                "id": self._id("submission"),
                "type": "reviewSubmissions",
                "attributes": {"state": "READY_FOR_REVIEW", "submitted": False},
            }
            self.submissions.append({"resource": created, "items": []})
            return 201, {"data": created}
        if path.endswith("/reviewSubmissions"):
            return 200, {"data": [entry["resource"] for entry in self.submissions]}
        if path == "/v1/reviewSubmissionItems":
            submission_id = payload["data"]["relationships"]["reviewSubmission"]["data"][
                "id"
            ]
            version_id = payload["data"]["relationships"]["appStoreVersion"]["data"]["id"]
            for entry in self.submissions:
                if entry["resource"]["id"] == submission_id:
                    entry["items"].append(version_id)
            return 201, {"data": {"id": self._id("item"), "type": "reviewSubmissionItems"}}
        if path.endswith("/items"):
            submission_id = path.split("/")[3]
            for entry in self.submissions:
                if entry["resource"]["id"] == submission_id:
                    return 200, {
                        "data": [
                            {
                                "id": f"item-{index}",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"id": version_id, "type": "appStoreVersions"}
                                    }
                                },
                            }
                            for index, version_id in enumerate(entry["items"])
                        ]
                    }
            return 200, {"data": []}
        if "/reviewSubmissions/" in path:
            submission_id = path.split("/")[3]
            for entry in self.submissions:
                if entry["resource"]["id"] != submission_id:
                    continue
                if method == "PATCH":
                    entry["resource"]["attributes"]["state"] = "WAITING_FOR_REVIEW"
                    entry["resource"]["attributes"]["submitted"] = True
                    for version_id in entry["items"]:
                        for version in self.versions:
                            if version["id"] == version_id:
                                version["attributes"]["appStoreState"] = "WAITING_FOR_REVIEW"
                return 200, {"data": entry["resource"]}
            return 404, {"errors": [{"detail": "unknown submission"}]}
        if "/appStoreVersions/" in path:
            version_id = path.split("/")[3]
            if method == "PATCH":
                relationships = payload["data"].get("relationships") or {}
                if "build" in relationships:
                    self.build_attached[version_id] = relationships["build"]["data"]["id"]
                attributes = payload["data"].get("attributes") or {}
                for version in self.versions:
                    if version["id"] == version_id:
                        version["attributes"].update(attributes)
                return 200, {"data": {"id": version_id, "type": "appStoreVersions"}}
            for version in self.versions:
                if version["id"] != version_id:
                    continue
                data = dict(version)
                build_id = self.build_attached.get(version_id)
                data["relationships"] = {
                    "build": {"data": {"id": build_id, "type": "builds"} if build_id else None}
                }
                return 200, {"data": data}
            return 404, {"errors": [{"detail": "unknown version"}]}
        return 404, {"errors": [{"detail": f"unhandled {method} {path}"}]}

    def _screenshot_payload(self, localization_id):
        entry = self.screenshot_sets.setdefault(
            localization_id, {"data": [], "included": []}
        )
        if (
            self.asset_poll_states
            and entry["included"]
            and any(shot["id"] in self.uploaded_shots for shot in entry["included"])
        ):
            state = self.asset_poll_states.pop(0)
            for shot in entry["included"]:
                shot["attributes"]["assetDeliveryState"] = {"state": state}
            return entry
        # Without an explicit queue, a screenshot is COMPLETE only once its bytes
        # were marked uploaded, which mirrors App Store Connect's processing.
        for shot in entry["included"]:
            if shot["id"] in self.uploaded_shots:
                shot["attributes"]["assetDeliveryState"] = {"state": "COMPLETE"}
        return entry


class LaneTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = self.directory.name
        self.clock = FakeClock()
        self.signer = counting_signer()
        self.write(
            "release/release-contract.json",
            json.dumps({"version": VERSION, "build_number": 27}),
        )
        with open(self.path("client/ios/Runner/Info.plist"), "wb") as handle:
            plistlib.dump({"ITSAppUsesNonExemptEncryption": False}, handle)
        # The shared store text is owned by scripts/release/store_whats_new.py;
        # these fixtures only mirror its on-disk format.
        self.write("release/store-whats-new.en.txt", f"{VERSION}\n\n- Live answers.\n")
        self.write("release/store-whats-new.ar.txt", f"{VERSION}\n\n{ARABIC_TEXT}\n")
        self.environment = {
            "APPLE_API_KEY_ID": "KEYID12345",
            "APPLE_API_ISSUER_ID": "issuer-uuid",
            "APPLE_API_KEY_BASE64": base64.b64encode(b"test-key-material").decode(),
        }

    # -- fixtures --------------------------------------------------------
    def path(self, relative):
        full = os.path.join(self.root, relative)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        return full

    def write(self, relative, content):
        with open(self.path(relative), "w", encoding="utf-8") as handle:
            handle.write(content)

    def args(self, *extra, dry_run=False):
        argv = [
            "--version", VERSION,
            "--build-number", BUILD,
            "--contract", self.path("release/release-contract.json"),
            "--store-copy-directory", os.path.join(self.root, "release"),
            "--info-plist", self.path("client/ios/Runner/Info.plist"),
            "--bundle-id", BUNDLE_ID,
            "--expect-app-id", APP_ID,
            *extra,
        ]
        if dry_run:
            argv.append("--dry-run")
        return lane.parse_args(argv)

    def run_lane(self, fake, args=None, clock=None, download=lambda url: b"PNG!", signer=None):
        clock = clock or self.clock
        signer = signer or self.signer
        output = io.StringIO()
        saved = dict(os.environ)
        os.environ.update(self.environment)
        try:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                lane.run(
                    args or self.args(),
                    transport=fake.handle,
                    download=download,
                    signer=signer,
                    sleep=clock.sleep,
                    clock=clock,
                )
        finally:
            os.environ.clear()
            os.environ.update(saved)
        return output.getvalue()

    def assert_refused(self, fake=None, args=None, message="", **kwargs):
        fake = fake or FakeAsc(clock=self.clock)
        with self.assertRaises(lane.SubmitError) as caught:
            self.run_lane(fake, args=args, **kwargs)
        if message:
            self.assertIn(message, str(caught.exception))
        return fake, caught.exception

    def fake_with_previous_release(self, **kwargs):
        """A released 1.0.26 listing with localizations, review detail, and shots."""
        source_shots = [
            screenshot_resource("shot-a", "set-en", "home.png"),
            screenshot_resource("shot-b", "set-en", "chat.png"),
        ]
        localizations = {
            "version-prev": [
                localization_resource("src-en", "en-US"),
                localization_resource("src-ar", "ar-SA"),
            ]
        }
        defaults = {
            "versions": [version_resource("version-prev", "1.0.26")],
            "localizations": localizations,
            "review_details": {
                "version-prev": {
                    "id": "detail-prev",
                    "type": "appStoreReviewDetails",
                    "attributes": {
                        "contactFirstName": "Release",
                        "contactLastName": "Owner",
                        "contactEmail": "release@example.invalid",
                        "contactPhone": "+10000000000",
                        "demoAccountName": "reviewer",
                        "demoAccountPassword": "super-secret-value",
                        "demoAccountRequired": True,
                        "notes": "Pair a local Agent before testing.",
                    },
                }
            },
            "screenshot_sets": {
                "src-en": {
                    "data": [
                        {
                            "id": "set-en",
                            "type": "appScreenshotSets",
                            "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                            "relationships": {
                                "appScreenshots": {
                                    "data": [
                                        {"id": shot["id"], "type": "appScreenshots"}
                                        for shot in source_shots
                                    ]
                                }
                            },
                        }
                    ],
                    "included": source_shots,
                }
            },
        }
        defaults["clock"] = self.clock
        defaults.update(kwargs)
        return FakeAsc(**defaults)


class TokenTest(LaneTest):
    def test_der_signature_is_converted_to_jose(self):
        signature = lane.jose_signature(der_signature(1, 2))
        self.assertEqual(len(signature), 64)
        self.assertEqual(signature[-1], 2)
        self.assertEqual(signature[31], 1)

    def test_non_sequence_der_is_refused(self):
        with self.assertRaises(lane.SubmitError):
            lane.jose_signature(b"\x02\x01\x01")

    def test_token_header_and_claims(self):
        token = lane.access_token("KEYID12345", "issuer-uuid", b"key", now=1000, signer=fake_signer)
        header, claims, signature = token.split(".")
        padding = "=" * (-len(header) % 4)
        decoded_header = json.loads(base64.urlsafe_b64decode(header + padding))
        decoded_claims = json.loads(base64.urlsafe_b64decode(claims + padding))
        self.assertEqual(decoded_header, {"alg": "ES256", "kid": "KEYID12345", "typ": "JWT"})
        self.assertEqual(decoded_claims["aud"], "appstoreconnect-v1")
        self.assertEqual(decoded_claims["iss"], "issuer-uuid")
        self.assertEqual(decoded_claims["exp"] - decoded_claims["iat"], 900)
        self.assertEqual(len(base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))), 64)


class StoreCopyTest(LaneTest):
    def test_arabic_is_required_only_when_the_listing_carries_it(self):
        os.unlink(self.path("release/store-whats-new.ar.txt"))
        fake = self.fake_with_previous_release()
        fake.localizations["version-prev"] = [localization_resource("src-en", "en-US")]
        output = self.run_lane(fake)
        self.assertIn("WAITING_FOR_REVIEW", output)

    def test_missing_arabic_refuses_an_arabic_listing(self):
        os.unlink(self.path("release/store-whats-new.ar.txt"))
        fake = self.fake_with_previous_release()
        self.assert_refused(fake, message="store-whats-new.ar.txt")
        self.assertEqual(fake.mutations(), [])

    def test_unknown_localization_is_refused(self):
        fake = self.fake_with_previous_release()
        fake.localizations["version-prev"].append(localization_resource("src-fr", "fr-FR"))
        self.assert_refused(fake, message="fr-FR")
        self.assertEqual(fake.mutations(), [])


class BuildTest(LaneTest):
    def test_build_processing_is_polled_until_valid(self):
        fake = self.fake_with_previous_release(
            build_states=("PROCESSING", "PROCESSING", "VALID")
        )
        output = self.run_lane(fake)
        self.assertIn(f"Build {BUILD} is VALID", output)
        polls = [call for call in fake.calls if call[1] == "/v1/builds"]
        self.assertEqual(len(polls), 3)

    def test_invalid_build_is_refused(self):
        fake = self.fake_with_previous_release(build_states=("INVALID",))
        self.assert_refused(fake, message="INVALID")

    def test_processing_timeout_is_refused(self):
        fake = self.fake_with_previous_release(build_states=("PROCESSING",))
        self.assert_refused(
            fake,
            args=self.args("--processing-timeout-seconds", "60"),
            message="did not finish processing",
        )
        self.assertEqual(fake.mutations(), [])

    def test_app_id_drift_is_refused(self):
        fake = self.fake_with_previous_release()
        self.assert_refused(
            fake,
            args=self.args("--expect-app-id", "1111111111"),
            message="app id drift",
        )

    def test_throttled_request_is_retried(self):
        fake = self.fake_with_previous_release(throttle_requests=1)
        output = self.run_lane(fake)
        self.assertIn("WAITING_FOR_REVIEW", output)
        app_calls = [call for call in fake.calls if call[1] == "/v1/apps"]
        self.assertEqual(len(app_calls), 2)


class TokenRefreshTest(LaneTest):
    def test_long_wait_never_presents_an_expired_token(self):
        # ~18.75 minutes of build processing: far past one token's lifetime.
        fake = self.fake_with_previous_release(
            build_states=tuple(["PROCESSING"] * 20 + ["VALID"]),
            reject_expired_tokens=True,
        )
        output = self.run_lane(fake)
        self.assertIn("WAITING_FOR_REVIEW", output)
        self.assertGreaterEqual(len(fake.tokens), 2)


class ContractTest(LaneTest):
    def test_version_mismatch_is_refused_before_any_write(self):
        fake = self.fake_with_previous_release()
        wrong = lane.parse_args(
            [
                "--version", "1.0.28",
                "--build-number", BUILD,
                "--contract", self.path("release/release-contract.json"),
                "--store-copy-directory", os.path.join(self.root, "release"),
                "--info-plist", self.path("client/ios/Runner/Info.plist"),
                "--bundle-id", BUNDLE_ID,
                "--expect-app-id", APP_ID,
            ]
        )
        self.assert_refused(fake, args=wrong, message="release contract declares")
        self.assertEqual(fake.calls, [])

    def test_build_number_mismatch_is_refused(self):
        wrong = lane.parse_args(
            [
                "--version", VERSION,
                "--build-number", "28",
                "--contract", self.path("release/release-contract.json"),
                "--store-copy-directory", os.path.join(self.root, "release"),
                "--info-plist", self.path("client/ios/Runner/Info.plist"),
                "--bundle-id", BUNDLE_ID,
                "--expect-app-id", APP_ID,
            ]
        )
        self.assert_refused(args=wrong, message="release contract declares")

    def test_encryption_declaration_drift_is_refused(self):
        with open(self.path("client/ios/Runner/Info.plist"), "wb") as handle:
            plistlib.dump({"ITSAppUsesNonExemptEncryption": True}, handle)
        self.assert_refused(message="ITSAppUsesNonExemptEncryption=false")
        with open(self.path("client/ios/Runner/Info.plist"), "wb") as handle:
            plistlib.dump({}, handle)
        self.assert_refused(message="ITSAppUsesNonExemptEncryption=false")

    def test_store_copy_is_required(self):
        os.unlink(self.path("release/store-whats-new.en.txt"))
        self.assert_refused(self.fake_with_previous_release(), message="Missing store text")


class SubmissionTest(LaneTest):
    def test_full_submission_reaches_waiting_for_review(self):
        fake = self.fake_with_previous_release()
        output = self.run_lane(fake)
        self.assertIn("WAITING_FOR_REVIEW", output)
        created = fake.version(VERSION)
        self.assertIsNotNone(created)
        self.assertEqual(created["attributes"]["appStoreState"], "WAITING_FOR_REVIEW")
        self.assertEqual(fake.build_attached[created["id"]], "build-27")
        self.assertEqual(len(fake.screenshot_uploads), 2)
        locales = {entry["attributes"]["locale"] for entry in fake.localizations[created["id"]]}
        self.assertEqual(locales, {"en-US", "ar-SA"})
        arabic = next(
            entry
            for entry in fake.localizations[created["id"]]
            if entry["attributes"]["locale"] == "ar-SA"
        )
        self.assertEqual(arabic["attributes"]["whatsNew"], ARABIC_TEXT)
        submitted = [
            call for call in fake.calls if call[0] == "PATCH" and "reviewSubmissions/" in call[1]
        ]
        self.assertEqual(submitted[0][2]["data"]["attributes"]["submitted"], True)

    def test_screenshot_processing_is_awaited_before_submitting(self):
        fake = self.fake_with_previous_release(
            asset_poll_states=("UPLOAD_COMPLETE", "COMPLETE")
        )
        output = self.run_lane(fake)
        self.assertIn("2/2 complete", output)
        states = [call for call in fake.calls if call[1].endswith("/appScreenshotSets")]
        self.assertGreaterEqual(len(states), 2)

    def test_screenshot_processing_timeout_is_refused(self):
        fake = self.fake_with_previous_release(
            asset_poll_states=("UPLOAD_COMPLETE", "UPLOAD_COMPLETE", "UPLOAD_COMPLETE")
        )
        self.assert_refused(
            fake,
            args=self.args("--processing-timeout-seconds", "30"),
            message="still processing",
        )

    def test_failed_screenshot_processing_is_refused(self):
        fake = self.fake_with_previous_release(asset_poll_states=("FAILED",))
        self.assert_refused(fake, message="failed to process a screenshot")

    def test_secrets_never_reach_the_log(self):
        fake = self.fake_with_previous_release()
        output = self.run_lane(fake)
        self.assertNotIn("super-secret-value", output)
        self.assertNotIn(self.environment["APPLE_API_KEY_BASE64"], output)
        self.assertNotIn("Bearer", output)

    def test_second_run_is_idempotent(self):
        fake = self.fake_with_previous_release()
        self.run_lane(fake)
        after_first = len(fake.mutations())
        output = self.run_lane(fake)
        self.assertEqual(len(fake.mutations()), after_first)
        self.assertIn("already WAITING_FOR_REVIEW", output)

    def test_dry_run_writes_nothing(self):
        fake = self.fake_with_previous_release()
        output = self.run_lane(fake, args=self.args(dry_run=True))
        self.assertEqual(fake.mutations(), [])
        self.assertIn("Dry run", output)

    def test_dry_run_on_an_existing_version_writes_nothing(self):
        fake = self.fake_with_previous_release()
        fake.versions.append(version_resource("version-target", VERSION, "PREPARE_FOR_SUBMISSION"))
        fake.localizations["version-target"] = [
            localization_resource("target-en", "en-US"),
            localization_resource("target-ar", "ar-SA"),
        ]
        output = self.run_lane(fake, args=self.args(dry_run=True))
        self.assertEqual(fake.mutations(), [])
        self.assertEqual(fake.submissions, [])
        self.assertIn("Dry run", output)

    def test_dry_run_proves_the_review_detail_is_copyable(self):
        fake = self.fake_with_previous_release(review_details={})
        self.assert_refused(
            fake, args=self.args(dry_run=True), message="no App Store review detail"
        )
        self.assertEqual(fake.mutations(), [])

    def test_dry_run_proves_the_screenshots_are_copyable(self):
        fake = self.fake_with_previous_release()
        fake.screenshot_sets["src-en"]["included"][0]["attributes"].pop("imageAsset")
        self.assert_refused(
            fake, args=self.args(dry_run=True), message="no downloadable image asset"
        )
        self.assertEqual(fake.mutations(), [])

    def test_pending_developer_release_blocks_the_lane(self):
        fake = FakeAsc(
            clock=self.clock,
            versions=[version_resource("version-prev", "1.0.26", "PENDING_DEVELOPER_RELEASE")],
        )
        self.assert_refused(fake, message="PENDING_DEVELOPER_RELEASE")
        self.assertEqual(fake.mutations(), [])

    def test_previous_version_in_review_blocks_the_lane(self):
        fake = FakeAsc(
            clock=self.clock,
            versions=[version_resource("version-prev", "1.0.26", "IN_REVIEW")],
        )
        self.assert_refused(fake, message="one submission")
        self.assertEqual(fake.mutations(), [])

    def test_another_version_in_review_submission_blocks_the_lane(self):
        fake = self.fake_with_previous_release()
        fake.submissions.append(
            {
                "resource": {
                    "id": "submission-other",
                    "type": "reviewSubmissions",
                    "attributes": {"state": "WAITING_FOR_REVIEW", "submitted": True},
                },
                "items": ["version-other"],
            }
        )
        self.assert_refused(fake, message="one submission")
        self.assertEqual([call for call in fake.calls if call[0] != "GET"], [])

    def test_unresolved_issues_submission_is_refused(self):
        fake = self.fake_with_previous_release()
        fake.versions.append(version_resource("version-target", VERSION, "PREPARE_FOR_SUBMISSION"))
        fake.localizations["version-target"] = [
            localization_resource("target-en", "en-US"),
            localization_resource("target-ar", "ar-SA"),
        ]
        fake.submissions.append(
            {
                "resource": {
                    "id": "submission-stuck",
                    "type": "reviewSubmissions",
                    "attributes": {"state": "UNRESOLVED_ISSUES", "submitted": True},
                },
                "items": ["version-target"],
            }
        )
        self.assert_refused(fake, message="unresolved issues")

    def test_existing_version_is_reused(self):
        fake = self.fake_with_previous_release()
        fake.versions.append(version_resource("version-target", VERSION, "PREPARE_FOR_SUBMISSION"))
        fake.localizations["version-target"] = [
            localization_resource("target-en", "en-US"),
            localization_resource("target-ar", "ar-SA"),
        ]
        self.run_lane(fake)
        self.assertEqual(fake.find("POST", "/v1/appStoreVersions"), [])
        self.assertEqual(fake.version(VERSION)["attributes"]["appStoreState"], "WAITING_FOR_REVIEW")

    def test_ready_for_review_version_is_accepted(self):
        fake = self.fake_with_previous_release()
        fake.versions.append(version_resource("version-target", VERSION, "READY_FOR_REVIEW"))
        fake.localizations["version-target"] = [
            localization_resource("target-en", "en-US"),
            localization_resource("target-ar", "ar-SA"),
        ]
        fake.build_attached["version-target"] = "build-27"
        fake.screenshot_sets["target-en"] = {
            "data": [
                {
                    "id": "target-set",
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                    "relationships": {
                        "appScreenshots": {
                            "data": [
                                {"id": "target-shot-a", "type": "appScreenshots"},
                                {"id": "target-shot-b", "type": "appScreenshots"},
                            ]
                        }
                    },
                }
            ],
            "included": [
                screenshot_resource("target-shot-a", "target-set", "home.png"),
                screenshot_resource("target-shot-b", "target-set", "chat.png"),
            ],
        }
        output = self.run_lane(fake)
        self.assertIn("WAITING_FOR_REVIEW", output)

    def test_target_only_arabic_localization_gets_store_text(self):
        fake = self.fake_with_previous_release()
        fake.localizations["version-prev"] = [localization_resource("src-en", "en-US")]
        fake.versions.append(version_resource("version-target", VERSION, "PREPARE_FOR_SUBMISSION"))
        fake.localizations["version-target"] = [
            localization_resource("target-en", "en-US"),
            localization_resource("target-ar", "ar-SA"),
        ]
        self.run_lane(fake)
        arabic = next(
            entry
            for entry in fake.localizations["version-target"]
            if entry["attributes"]["locale"] == "ar-SA"
        )
        self.assertEqual(arabic["attributes"]["whatsNew"], ARABIC_TEXT)

    def test_half_copied_screenshot_set_is_refused(self):
        fake = self.fake_with_previous_release()
        fake.versions.append(version_resource("version-target", VERSION, "PREPARE_FOR_SUBMISSION"))
        fake.localizations["version-target"] = [
            localization_resource("target-en", "en-US"),
            localization_resource("target-ar", "ar-SA"),
        ]
        fake.screenshot_sets["target-en"] = {
            "data": [
                {
                    "id": "target-set",
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                    "relationships": {"appScreenshots": {"data": []}},
                }
            ],
            "included": [screenshot_resource("target-shot-a", "target-set", "home.png")],
        }
        self.assert_refused(fake, message="holds 1 of the 2 screenshots")

    def test_draft_submission_is_reused(self):
        fake = self.fake_with_previous_release()
        fake.submissions.append(
            {
                "resource": {
                    "id": "submission-draft",
                    "type": "reviewSubmissions",
                    "attributes": {"state": "READY_FOR_REVIEW", "submitted": False},
                },
                "items": [],
            }
        )
        output = self.run_lane(fake)
        self.assertEqual(fake.find("POST", "/v1/reviewSubmissions"), [])
        self.assertIn("submission-draft", output)

    def test_missing_store_metadata_source_is_refused(self):
        fake = FakeAsc(clock=self.clock)  # no released version and no localizations
        self.assert_refused(fake, message="no localizations")
        self.assertEqual(fake.mutations(), [])

    def test_release_type_is_moved_to_after_approval(self):
        fake = self.fake_with_previous_release()
        target = version_resource("version-target", VERSION, "PREPARE_FOR_SUBMISSION")
        target["attributes"]["releaseType"] = "MANUAL"
        fake.versions.append(target)
        fake.localizations["version-target"] = [
            localization_resource("target-en", "en-US"),
            localization_resource("target-ar", "ar-SA"),
        ]
        fake.screenshot_sets["target-en"] = {
            "data": [
                {
                    "id": "target-set",
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                    "relationships": {"appScreenshots": {"data": []}},
                }
            ],
            "included": [
                screenshot_resource("target-shot-a", "target-set", "home.png"),
                screenshot_resource("target-shot-b", "target-set", "chat.png"),
            ],
        }
        self.run_lane(fake)
        releases = [
            call
            for call in fake.calls
            if call[0] == "PATCH"
            and call[1] == "/v1/appStoreVersions/version-target"
            and "attributes" in (call[2]["data"] or {})
        ]
        self.assertEqual(releases[0][2]["data"]["attributes"], {"releaseType": "AFTER_APPROVAL"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
