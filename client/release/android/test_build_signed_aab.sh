#!/bin/bash
#
# Guards for release/android/build_signed_aab.sh. Every case must fail with its
# own guard message before any Gradle work happens, so this test stays fast and
# offline. Asserting the message, not only the exit status, proves each case
# reached the intended check instead of crashing somewhere earlier.
#
# Runs from the client/ directory.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_signed_aab.sh"
test -f "$script" || { echo "Missing $script" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/android/app"
printf 'version: 1.0.0+1\n' > "$work/config-prod.json"

expect_refusal() {
  local label="$1" expected="$2"; shift 2
  local output status=0
  output="$( cd "$work" && bash "$script" "$@" 2>&1 )" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "::error::$label: the build script accepted an invalid invocation" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" <<<"$output"; then
    echo "::error::$label: expected the guard message '$expected', but the script said: $output" >&2
    exit 1
  fi
}

# 1. Missing release keystore.
expect_refusal "missing keystore" 'Missing android/key.properties' \
  --build-name 1.0.0 --build-number 1 --env-config config-prod.json

# 2. Non-numeric build number.
expect_refusal "non-numeric build number" "--build-number must be a positive integer, got 'abc'" \
  --build-name 1.0.0 --build-number abc --env-config config-prod.json

# 3. Zero is not a store-acceptable versionCode.
expect_refusal "zero build number" "--build-number must be a positive integer, got '0'" \
  --build-name 1.0.0 --build-number 0 --env-config config-prod.json

# 4. Missing environment config.
expect_refusal "missing env config" 'Missing environment config: missing.json' \
  --build-name 1.0.0 --build-number 5 --env-config missing.json

# 5. Package drift between Gradle and the store identity.
cat > "$work/android/key.properties" <<'PROPERTIES'
storeFile=/nonexistent.jks
storePassword=x
keyPassword=x
keyAlias=x
PROPERTIES
printf 'applicationId = "com.example.other"\n' > "$work/android/app/build.gradle"
ANDROID_HOME=/nonexistent expect_refusal "package drift" \
  "Package drift: android/app/build.gradle declares 'com.example.other'" \
  --build-name 1.0.0 --build-number 2 --env-config config-prod.json

# 6. Unknown argument is refused rather than ignored.
expect_refusal "unknown argument" 'Unknown argument: --nonsense' \
  --build-name 1.0.0 --build-number 1 --nonsense

echo "build_signed_aab.sh guards passed"
