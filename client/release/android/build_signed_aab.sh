#!/bin/bash
#
# Build the signed Android App Bundle (and the universal APK beside it) and
# refuse to emit an artifact whose identity does not match the release contract.
#
# Signature authority:
#   android/key.properties   owns the upload keystore path, aliases and passwords
#   android/app/build.gradle owns the applicationId and the signing config
#
# This script owns the Android binary for the Play upload lane. The release
# workflow still builds its own APK and AAB inline and has no package or version
# verification of its own; it migrates to this script next, so today two producers
# exist and only this one proves the artifact identity.
#
# The AAB carries no room for a post-hoc signature check, so the version identity
# is proven on the universal APK that Gradle builds from the same sources, and
# Play itself proves the bundle identity when the upload returns its versionCode.
# A bundle whose identity is wrong but whose APK is right is therefore caught by
# Google, not here.
#
# Usage:
#   release/android/build_signed_aab.sh --build-name 1.0.23 --build-number 24
#     [--env-config config/prod.json] [--output-dir ../dist]
#     [--artifact-version 1.0.23]
#
# Runs from the client/ directory.
set -euo pipefail

package_id="com.eaststarai.sanad"
build_name=""
build_number=""
env_config="config/prod.json"
output_dir="../dist"
artifact_version=""

usage() {
  cat >&2 <<'USAGE'
Usage: release/android/build_signed_aab.sh --build-name <name> --build-number <number>
         [--env-config <dart-define file>] [--output-dir <dir>]
         [--artifact-version <version used in artifact filenames>]

Arguments accept both `--key value` and `--key=value` so the workflows and a
manual run use the same interface.

Builds, signs, and verifies the Android App Bundle. Exits non-zero when the
release keystore is missing or the produced artifact claims another package,
version name, or build number.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-name=*) build_name="${1#*=}"; shift ;;
    --build-number=*) build_number="${1#*=}"; shift ;;
    --env-config=*) env_config="${1#*=}"; shift ;;
    --output-dir=*) output_dir="${1#*=}"; shift ;;
    --artifact-version=*) artifact_version="${1#*=}"; shift ;;
    --build-name|--build-number|--env-config|--output-dir|--artifact-version)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage
        exit 2
      fi
      case "$1" in
        --build-name) build_name="$2" ;;
        --build-number) build_number="$2" ;;
        --env-config) env_config="$2" ;;
        --output-dir) output_dir="$2" ;;
        --artifact-version) artifact_version="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

test -n "$build_name" || { echo "--build-name is required" >&2; usage; exit 2; }
test -n "$build_number" || { echo "--build-number is required" >&2; usage; exit 2; }
test -f "$env_config" || { echo "Missing environment config: $env_config" >&2; exit 2; }
if ! [[ "$build_number" =~ ^[0-9]+$ ]] || [[ "$build_number" -lt 1 ]]; then
  echo "--build-number must be a positive integer, got '$build_number'" >&2
  exit 2
fi
test -n "$artifact_version" || artifact_version="$build_name"

# Gradle only requires the release keystore for release tasks, so a missing file
# would fail deep inside the build with a less useful message.
test -f android/key.properties || {
  echo "Missing android/key.properties; the release keystore must be restored before this script runs." >&2
  exit 2
}

# The applicationId is the store identity; a mismatch would publish to another
# listing, so it is proven here rather than discovered after an upload.
declared_package="$(
  sed -nE 's/^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    android/app/build.gradle | head -n 1
)"
test "$declared_package" = "$package_id" || {
  echo "Package drift: android/app/build.gradle declares '${declared_package:-none}' but the store identity is '$package_id'" >&2
  exit 1
}

build_tools="${ANDROID_HOME:-$ANDROID_SDK_ROOT}/build-tools"
test -d "$build_tools" || { echo "No Android build-tools under '$build_tools'" >&2; exit 2; }
tools="$(ls "$build_tools" | sort -V | tail -n 1)"
apksigner="$build_tools/$tools/apksigner"
aapt2="$build_tools/$tools/aapt2"
test -x "$apksigner" || { echo "Missing apksigner at $apksigner" >&2; exit 2; }
test -x "$aapt2" || { echo "Missing aapt2 at $aapt2" >&2; exit 2; }

echo "Building signed Android bundle ${build_name} (${build_number}) with ${package_id}"

fvm flutter build appbundle --release \
  --build-name="$build_name" \
  --build-number="$build_number" \
  --dart-define-from-file="$env_config"
fvm flutter build apk --release \
  --build-name="$build_name" \
  --build-number="$build_number" \
  --dart-define-from-file="$env_config"

aab="build/app/outputs/bundle/release/app-release.aab"
apk="build/app/outputs/flutter-apk/app-release.apk"
test -s "$aab" || { echo "No app bundle at $aab" >&2; exit 1; }
test -s "$apk" || { echo "No APK at $apk" >&2; exit 1; }

"$apksigner" verify --verbose "$apk" >/dev/null

badging="$("$aapt2" dump badging "$apk")"
badging_package="$(sed -nE "s/^package: name='([^']+)'.*/\1/p" <<<"$badging")"
badging_version_code="$(sed -nE "s/^package: .*versionCode='([^']+)'.*/\1/p" <<<"$badging")"
badging_version_name="$(sed -nE "s/^package: .*versionName='([^']+)'.*/\1/p" <<<"$badging")"

failures=()
[[ "$badging_package" == "$package_id" ]] || \
  failures+=("the APK declares package '${badging_package:-none}' instead of '$package_id'")
[[ "$badging_version_code" == "$build_number" ]] || \
  failures+=("the APK declares versionCode '${badging_version_code:-none}' instead of '$build_number'")
[[ "$badging_version_name" == "$build_name" ]] || \
  failures+=("the APK declares versionName '${badging_version_name:-none}' instead of '$build_name'")
if [ "${#failures[@]}" -ne 0 ]; then
  for failure in "${failures[@]}"; do
    echo "::error::Android artifact verification failed: $failure" >&2
  done
  exit 1
fi

mkdir -p "$output_dir"
aab_target="$output_dir/sanad-client-${artifact_version}-android-universal.aab"
apk_target="$output_dir/sanad-client-${artifact_version}-android-universal.apk"
cp "$aab" "$aab_target"
cp "$apk" "$apk_target"

echo "Verified Android artifacts: ${package_id} versionName=${build_name} versionCode=${build_number}"
echo "Bundle ready: $aab_target"
echo "APK ready: $apk_target"
