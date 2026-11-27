#!/bin/bash
#
# Prove an Android release artifact set carries the contracted store identity.
#
# Single owner of the Android identity proof. Two callers use it:
#   build_signed_aab.sh            pre-flight (declared identity) and after the build
#   the Play store publication     on the artifact the release workflow built
#
# What it proves, in order, so nothing expensive runs before a cheap check fails:
#   1. android/app/build.gradle declares the expected applicationId.
#   2. The App Bundle and the universal APK exist.
#   3. The APK is signed by a key apksigner accepts, and its badging names the
#      expected package, versionName, and versionCode.
#   4. The App Bundle is JAR-signed and its signer certificate is the same one the
#      paired APK carries, so the bundle the store receives is the bundle Gradle
#      signed with the restored upload key.
#
# The AAB's own manifest is binary and unreadable without bundletool, so the
# version identity is proven on the APK Gradle emits from the same invocation -
# the same evidence the build script has always used - and Google Play proves the
# bundle identity once more when the upload returns its versionCode. What this
# script adds is that the bundle is signed by the same certificate as the APK that
# declares the contracted version, so a debug- or foreign-signed artifact stops
# here instead of at the store.
#
# Usage:
#   verify_android_release.sh --package <id> --preflight [--gradle-file <path>]
#   verify_android_release.sh --package <id> --version-name <name> --version-code <n>
#     --apk <path> --aab <path> [--gradle-file <path>] [--android-home <dir>]
#
# `--preflight` proves only the declared identity, so a build that would fail
# after Gradle never starts. Run from anywhere: paths default to this script's
# checkout.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gradle_file="$script_dir/../../android/app/build.gradle"
package_id=""
version_name=""
version_code=""
apk=""
aab=""
preflight=false

usage() {
  cat >&2 <<'USAGE'
Usage: verify_android_release.sh --package <id> --preflight [--gradle-file <path>]
       verify_android_release.sh --package <id> --version-name <name> --version-code <n>
         --apk <path> --aab <path> [--gradle-file <path>] [--android-home <dir>]

Exits non-zero when the declared identity, the APK badging, or the signing
certificate of the bundle and the APK disagree with the expected release.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --package=*) package_id="${1#*=}"; shift ;;
    --version-name=*) version_name="${1#*=}"; shift ;;
    --version-code=*) version_code="${1#*=}"; shift ;;
    --apk=*) apk="${1#*=}"; shift ;;
    --aab=*) aab="${1#*=}"; shift ;;
    --gradle-file=*) gradle_file="${1#*=}"; shift ;;
    --android-home=*) android_home="${1#*=}"; shift ;;
    --preflight) preflight=true; shift ;;
    --package|--version-name|--version-code|--apk|--aab|--gradle-file|--android-home)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage
        exit 2
      fi
      case "$1" in
        --package) package_id="$2" ;;
        --version-name) version_name="$2" ;;
        --version-code) version_code="$2" ;;
        --apk) apk="$2" ;;
        --aab) aab="$2" ;;
        --gradle-file) gradle_file="$2" ;;
        --android-home) android_home="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

test -n "$package_id" || { echo "--package is required" >&2; usage; exit 2; }
test -f "$gradle_file" || { echo "Missing Gradle file: $gradle_file" >&2; exit 2; }

# 1. The applicationId is the store identity; a mismatch would publish to another
#    listing, so it is proven from the build file rather than discovered after an
#    upload. A release build without the restored keystore already fails in Gradle.
declared_package="$(
  sed -nE 's/^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$gradle_file" | head -n 1
)"
test "$declared_package" = "$package_id" || {
  echo "Package drift: android/app/build.gradle declares '${declared_package:-none}' but the store identity is '$package_id'" >&2
  exit 1
}

if [ "$preflight" = true ]; then
  echo "Android identity pre-flight passed: ${package_id} declared by ${gradle_file}"
  exit 0
fi

test -n "$version_name" || { echo "--version-name is required" >&2; usage; exit 2; }
test -n "$version_code" || { echo "--version-code is required" >&2; usage; exit 2; }
test -n "$apk" || { echo "--apk is required" >&2; usage; exit 2; }
test -n "$aab" || { echo "--aab is required" >&2; usage; exit 2; }
[[ "$version_code" =~ ^[0-9]+$ ]] || {
  echo "--version-code must be a positive integer, got '$version_code'" >&2
  exit 2
}

# 2. Existence before tooling, so a missing artifact reads as a missing artifact.
test -s "$apk" || { echo "Missing APK: $apk" >&2; exit 1; }
test -s "$aab" || { echo "Missing App Bundle: $aab" >&2; exit 1; }

# 3. Tooling. apksigner and aapt2 ship with the Android build-tools; keytool ships
#    with the JDK apksigner itself already needs to run.
android_home="${android_home:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
build_tools="$android_home/build-tools"
test -d "$build_tools" || { echo "No Android build-tools under '$build_tools'" >&2; exit 2; }
tools="$(ls "$build_tools" | sort -V | tail -n 1)"
apksigner="$build_tools/$tools/apksigner"
aapt2="$build_tools/$tools/aapt2"
test -x "$apksigner" || { echo "Missing apksigner at $apksigner" >&2; exit 2; }
test -x "$aapt2" || { echo "Missing aapt2 at $aapt2" >&2; exit 2; }
command -v keytool >/dev/null || { echo "Missing keytool; the JDK that runs apksigner provides it" >&2; exit 2; }

# Prints the first signer certificate's SHA-256 fingerprint as bare lower-case hex,
# so the APK and the bundle can be compared byte for byte.
apk_signer() {
  "$apksigner" verify --print-certs "$1" |
    sed -nE 's/^Signer #1 certificate SHA-256 digest:[[:space:]]*([0-9a-fA-F]+).*/\1/p' |
    head -n 1 | tr 'A-F' 'a-f'
}

aab_signer() {
  keytool -printcert -jarfile "$1" 2>/dev/null |
    sed -nE 's/^[[:space:]]*SHA256:[[:space:]]*([0-9a-fA-F:]+).*/\1/p' |
    head -n 1 | tr -d ':' | tr 'A-F' 'a-f'
}

# 4. Signature integrity, then identity.
"$apksigner" verify --verbose "$apk" >/dev/null || {
  echo "The APK signature does not verify: $apk" >&2
  exit 1
}
apk_signer_sha256="$(apk_signer "$apk")"
test -n "$apk_signer_sha256" || {
  echo "Could not read the APK signer certificate: $apk" >&2
  exit 1
}
aab_signer_sha256="$(aab_signer "$aab")"
test -n "$aab_signer_sha256" || {
  echo "The App Bundle is not JAR-signed: $aab" >&2
  exit 1
}

badging="$("$aapt2" dump badging "$apk")"
badging_package="$(sed -nE "s/^package: name='([^']+)'.*/\1/p" <<<"$badging")"
badging_version_code="$(sed -nE "s/^package: .*versionCode='([^']+)'.*/\1/p" <<<"$badging")"
badging_version_name="$(sed -nE "s/^package: .*versionName='([^']+)'.*/\1/p" <<<"$badging")"

failures=()
[[ "$badging_package" == "$package_id" ]] || \
  failures+=("the APK declares package '${badging_package:-none}' instead of '$package_id'")
[[ "$badging_version_code" == "$version_code" ]] || \
  failures+=("the APK declares versionCode '${badging_version_code:-none}' instead of '$version_code'")
[[ "$badging_version_name" == "$version_name" ]] || \
  failures+=("the APK declares versionName '${badging_version_name:-none}' instead of '$version_name'")
[[ "$aab_signer_sha256" == "$apk_signer_sha256" ]] || \
  failures+=("the App Bundle is signed by ${aab_signer_sha256} but the APK by ${apk_signer_sha256}; they are not one build")
if [ "${#failures[@]}" -ne 0 ]; then
  for failure in "${failures[@]}"; do
    echo "::error::Android artifact verification failed: $failure" >&2
  done
  exit 1
fi

echo "Verified Android artifacts: ${package_id} versionName=${version_name} versionCode=${version_code} signer=${apk_signer_sha256:0:16}"
