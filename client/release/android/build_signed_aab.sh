#!/bin/bash
#
# Build the signed Android App Bundle (and the universal APK beside it) and
# refuse to emit an artifact whose identity does not match the release contract.
#
# Signature authority:
#   android/key.properties   owns the upload keystore path, aliases and passwords
#   android/app/build.gradle owns the applicationId and the signing config
#
# The identity proof itself belongs to release/android/verify_android_release.sh,
# which the Play store publication also runs on the artifact a release already
# built. This script calls it twice: a pre-flight before Gradle so a wrong package
# never costs a build, and the full proof afterwards.
#
# The release workflow still builds its own APK and AAB inline; the store
# publication reuses that artifact instead of rebuilding, and proves it with the
# same shared script this one uses.
#
# Usage:
#   release/android/build_signed_aab.sh --build-name 1.0.23 --build-number 24
#     [--env-config config/prod.json] [--output-dir ../dist]
#     [--artifact-version 1.0.23]
#
# Runs from the client/ directory.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify_script="$script_dir/verify_android_release.sh"
test -f "$verify_script" || { echo "Missing $verify_script" >&2; exit 2; }

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
# listing, so it is proven before Gradle rather than discovered after a build.
gradle_file="android/app/build.gradle"
bash "$verify_script" --package "$package_id" --preflight --gradle-file "$gradle_file"

android_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
test -n "$android_home" || {
  echo "ANDROID_HOME is not set; the Android SDK is required to build the bundle." >&2
  exit 2
}

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

# Identity, badging, and the shared signer certificate of both artifacts.
bash "$verify_script" \
  --package "$package_id" \
  --version-name "$build_name" \
  --version-code "$build_number" \
  --apk "$apk" \
  --aab "$aab" \
  --gradle-file "$gradle_file" \
  --android-home "$android_home"

mkdir -p "$output_dir"
aab_target="$output_dir/sanad-client-${artifact_version}-android-universal.aab"
apk_target="$output_dir/sanad-client-${artifact_version}-android-universal.apk"
cp "$aab" "$aab_target"
cp "$apk" "$apk_target"

echo "Bundle ready: $aab_target"
echo "APK ready: $apk_target"
