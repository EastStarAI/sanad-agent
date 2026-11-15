#!/bin/bash
#
# Upload one App Store IPA to App Store Connect.
#
# Single owner of "prove this IPA is the App Store binary the caller expects, restore
# the App Store Connect key, upload it". Both `Internal TestFlight` and the Stable
# store publication call this script, so no workflow carries its own uploader.
#
# Identity authority:
#   the caller passes the version and build it means to publish, and this script
#   proves the IPA carries exactly those values and the reviewed signing identity
#   client/release/ios/ExportOptions.plist owns the bundle identifier and team
#
# Usage (run from the repository root):
#   client/release/ios/upload_ipa.sh --ipa <path> --version <marketing> --build <number>
#     [--bundle-id <id>]
#
# The three App Store Connect values arrive through the environment and are never
# printed:
#   APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_PRIVATE_KEY_P8_BASE64
set -euo pipefail

ipa=""
version=""
build=""
bundle_id=""
team_id=""
export_options=""

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export_options="$script_dir/ExportOptions.plist"

usage() {
  cat >&2 <<'USAGE'
Usage: client/release/ios/upload_ipa.sh --ipa <path> --version <marketing> --build <number>
         [--bundle-id <id>]

Verifies the IPA carries the expected bundle identifier, marketing version, and
build number, that it is signed by the reviewed team with no get-task-allow
entitlement, then uploads it with `xcrun altool`.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ipa=*) ipa="${1#*=}"; shift ;;
    --version=*) version="${1#*=}"; shift ;;
    --build=*) build="${1#*=}"; shift ;;
    --bundle-id=*) bundle_id="${1#*=}"; shift ;;
    --ipa|--version|--build|--bundle-id)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage
        exit 2
      fi
      case "$1" in
        --ipa) ipa="$2" ;;
        --version) version="$2" ;;
        --build) build="$2" ;;
        --bundle-id) bundle_id="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

test -n "$ipa" || { echo "--ipa is required" >&2; usage; exit 2; }
test -n "$version" || { echo "--version is required" >&2; usage; exit 2; }
test -n "$build" || { echo "--build is required" >&2; usage; exit 2; }
test -s "$ipa" || { echo "IPA not found: $ipa" >&2; exit 2; }
test -f "$export_options" || { echo "Missing export options: $export_options" >&2; exit 2; }

# The reviewed bundle identity and team are read from the export options, which
# own them, instead of being restated here.
export_identity="$(plutil -convert json -o - "$export_options" | python3 -c '
import json, sys

options = json.load(sys.stdin)
profiles = options.get("provisioningProfiles") or {}
if len(profiles) != 1:
    sys.exit("Export options must name exactly one provisioning profile")
print(next(iter(profiles)))
print(options.get("teamID") or "")
')"
export_bundle_id="$(printf '%s\n' "$export_identity" | sed -n 1p)"
export_team_id="$(printf '%s\n' "$export_identity" | sed -n 2p)"
test -n "$export_bundle_id" || { echo "Export options name no bundle identifier" >&2; exit 2; }
test -n "$export_team_id" || { echo "Export options name no team" >&2; exit 2; }
bundle_id="${bundle_id:-$export_bundle_id}"
team_id="$export_team_id"

# The IPA itself must carry the identity the caller asked for. The release
# contract is the caller's authority - `release-stores.yml` proves the tag equals
# the contract before it calls this script, and `Internal TestFlight` passes its
# own build number - so a mismatch here is always a wrong binary.

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
unzip -q "$ipa" -d "$work_dir"
app="$(find "$work_dir/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "$app" || { echo "No Payload app inside $ipa" >&2; exit 1; }

ipa_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")"
ipa_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist")"
ipa_build="$(plutil -extract CFBundleVersion raw -o - "$app/Info.plist")"

test "$ipa_bundle_id" = "$bundle_id" || {
  echo "IPA bundle identifier is '$ipa_bundle_id', expected '$bundle_id'" >&2
  exit 1
}
test "$ipa_version" = "$version" || {
  echo "IPA marketing version is '$ipa_version', expected '$version'" >&2
  exit 1
}
test "$ipa_build" = "$build" || {
  echo "IPA build number is '$ipa_build', expected '$build'" >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$app"

if ! codesign -dv --verbose=4 "$app" 2>&1 | grep -Fq "TeamIdentifier=$team_id"; then
  echo "IPA is not signed by team $team_id" >&2
  codesign -dv --verbose=4 "$app" 2>&1 | grep -F 'TeamIdentifier=' >&2 || true
  exit 1
fi

# A development or ad-hoc build carries get-task-allow; an App Store build never
# does. Absent is acceptable, `true` is not.
if codesign -d --entitlements :- "$app" 2>/dev/null > "$work_dir/entitlements.plist"; then
  if python3 - "$work_dir/entitlements.plist" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[1], "rb") as handle:
        entitlements = plistlib.load(handle)
except Exception:
    sys.exit(0)

sys.exit(0 if entitlements.get("get-task-allow") is True else 1)
PY
  then
    echo "IPA carries get-task-allow; it is not an App Store distribution build" >&2
    exit 1
  fi
fi

test -n "${APPLE_API_KEY_ID:-}" || { echo "APPLE_API_KEY_ID is empty" >&2; exit 1; }
test -n "${APPLE_API_ISSUER_ID:-}" || { echo "APPLE_API_ISSUER_ID is empty" >&2; exit 1; }
test -n "${APPLE_API_PRIVATE_KEY_P8_BASE64:-}" || { echo "APPLE_API_PRIVATE_KEY_P8_BASE64 is empty" >&2; exit 1; }

key_path="$HOME/.appstoreconnect/private_keys/AuthKey_${APPLE_API_KEY_ID}.p8"
mkdir -p "$(dirname "$key_path")"
printf '%s' "$APPLE_API_PRIVATE_KEY_P8_BASE64" | base64 -D > "$key_path"
chmod 600 "$key_path"

echo "Uploading $bundle_id $version ($build) signed by team $team_id"
xcrun altool --upload-app --type ios --file "$ipa" \
  --apiKey "$APPLE_API_KEY_ID" \
  --apiIssuer "$APPLE_API_ISSUER_ID"
