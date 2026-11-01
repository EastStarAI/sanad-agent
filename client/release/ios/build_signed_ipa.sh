#!/bin/bash
#
# Build the signed App Store IPA and refuse to emit one that cannot claim the
# Portal authentication return.
#
# Signature and entitlement authority:
#   release/ios/ExportOptions.plist  owns the reviewed provisioning profile name
#                                    and the signing style
#   ios/Runner/Runner.entitlements   owns the Associated Domains the app claims
#
# Both the Internal TestFlight workflow and the private release workflow call
# this script so a single place decides how an iOS binary is produced. Never
# archive with --no-codesign and export separately: that export re-signs the app
# from the profile alone, drops the app's own CODE_SIGN_ENTITLEMENTS, and ships
# an IPA without com.apple.developer.associated-domains even when the profile
# grants it.
#
# Usage:
#   release/ios/build_signed_ipa.sh --build-name 1.0.20 --build-number 24
#     [--env-config config/prod.json] [--export-options release/ios/ExportOptions.plist]
#
# Runs from the client/ directory.
set -euo pipefail

build_name=""
build_number=""
env_config="config/prod.json"
export_options="release/ios/ExportOptions.plist"

usage() {
  cat >&2 <<'USAGE'
Usage: release/ios/build_signed_ipa.sh --build-name <name> --build-number <number>
         [--env-config <dart-define file>] [--export-options <plist>]

Arguments accept both `--key value` and `--key=value` so the workflows and a
manual run use the same interface.

Builds, signs, exports, and verifies the iOS IPA. Exits non-zero when the
exported app cannot claim the Portal callback Universal Link.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-name=*) build_name="${1#*=}"; shift ;;
    --build-number=*) build_number="${1#*=}"; shift ;;
    --env-config=*) env_config="${1#*=}"; shift ;;
    --export-options=*) export_options="${1#*=}"; shift ;;
    --build-name|--build-number|--env-config|--export-options)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage
        exit 2
      fi
      case "$1" in
        --build-name) build_name="$2" ;;
        --build-number) build_number="$2" ;;
        --env-config) env_config="$2" ;;
        --export-options) export_options="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

test -n "$build_name" || { echo "--build-name is required" >&2; usage; exit 2; }
test -n "$build_number" || { echo "--build-number is required" >&2; usage; exit 2; }
test -f "$export_options" || { echo "Missing export options: $export_options" >&2; exit 2; }
test -f "$env_config" || { echo "Missing environment config: $env_config" >&2; exit 2; }

# The reviewed profile name is read from the export options, never restated here.
expected_profile="$(python3 -c '
import plistlib, sys

with open(sys.argv[1], "rb") as handle:
    options = plistlib.load(handle)
profiles = options.get("provisioningProfiles") or {}
if len(profiles) != 1:
    sys.exit("Export options must name exactly one provisioning profile")
print(next(iter(profiles.values())))
' "$export_options")"

echo "Building signed IPA ${build_name} (${build_number}) with profile: ${expected_profile}"

# 1) Generate the Flutter artifacts, including the AOT snapshot, without signing.
fvm flutter build ios --release --no-codesign \
  --build-name="$build_name" \
  --build-number="$build_number" \
  --dart-define-from-file="$env_config"

# 2) Archive with explicit manual signing. Automatic signing would ask the
# runner for a development account and fail, and an unsigned archive would drop
# the app's own entitlements on export. The profile name comes from the export
# options and the team stays whatever the Xcode project declares.
rm -rf build/ios/archive/Runner.xcarchive
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/ios/archive/Runner.xcarchive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$expected_profile" \
  archive

archive="build/ios/archive/Runner.xcarchive"
test -d "$archive" || { echo "Missing archive: $archive" >&2; exit 1; }

# 3) Export the archive with the reviewed export options.
rm -rf build/ios/ipa
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath build/ios/ipa \
  -exportOptionsPlist "$export_options"

ipa="$(find build/ios/ipa -maxdepth 1 -name '*.ipa' -print -quit)"
test -n "$ipa" || { echo "No IPA was exported" >&2; exit 1; }

check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
unzip -q "$ipa" -d "$check_dir"
app="$(find "$check_dir/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "$app" || { echo "No Payload app inside $ipa" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements :- "$app" > "$check_dir/signed-entitlements.plist" 2>/dev/null
security cms -D -i "$app/embedded.mobileprovision" > "$check_dir/embedded-profile.plist"

python3 - "$check_dir/signed-entitlements.plist" \
  "$check_dir/embedded-profile.plist" \
  "ios/Runner/Runner.entitlements" \
  "$expected_profile" <<'PY'
import plistlib
import sys

signed_path, embedded_path, requested_path, expected_profile = sys.argv[1:5]


def load(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)


claimed = set(load(signed_path).get("com.apple.developer.associated-domains") or [])
requested = set(
    load(requested_path).get("com.apple.developer.associated-domains") or []
)
embedded = load(embedded_path)
granted = embedded.get("Entitlements", {}).get(
    "com.apple.developer.associated-domains"
)

failures = []

if not requested:
    failures.append(
        f"ios/Runner/Runner.entitlements claims no Associated Domains hosts"
    )

missing = sorted(requested - claimed)
if missing:
    failures.append(
        "the signed app does not claim " + ", ".join(missing)
        + " (the export dropped the app's CODE_SIGN_ENTITLEMENTS; build a signed"
        " archive instead of a --no-codesign one)"
    )

if granted is None:
    failures.append(
        "the embedded provisioning profile grants no Associated Domains;"
        " regenerate it after enabling the App ID capability"
    )

embedded_name = embedded.get("Name")
if embedded_name != expected_profile:
    failures.append(
        f"the app is signed with {embedded_name!r} instead of the"
        f" {expected_profile!r} profile named by the export options"
    )

if failures:
    for failure in failures:
        print(f"::error::iOS IPA verification failed: {failure}", file=sys.stderr)
    sys.exit(1)

print(
    "Verified IPA: profile %r, claimed hosts: %s"
    % (embedded_name, ", ".join(sorted(claimed)))
)
PY

echo "Signed IPA ready: $ipa"
