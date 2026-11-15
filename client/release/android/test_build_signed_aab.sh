#!/bin/bash
#
# Guards for release/android/build_signed_aab.sh. Each case must fail before any
# Gradle work happens, so this test stays fast and offline.
#
# Runs from the client/ directory.
set -euo pipefail

script="release/android/build_signed_aab.sh"
test -f "$script" || { echo "Missing $script" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/android/app"
printf 'version: 1.0.0+1\n' > "$work/config-prod.json"

expect_refusal() {
  local label="$1"; shift
  local status=0
  ( cd "$work" && bash "$OLDPWD/$script" "$@" ) >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    echo "::error::$label: the build script accepted an invalid invocation" >&2
    exit 1
  fi
}

# 1. Missing release keystore.
expect_refusal "missing keystore" --build-name 1.0.0 --build-number 1 --env-config config-prod.json

# 2. Non-numeric build number.
cat > "$work/android/key.properties" <<'PROPERTIES'
storeFile=/nonexistent.jks
storePassword=x
keyPassword=x
keyAlias=x
PROPERTIES
expect_refusal "non-numeric build number" --build-name 1.0.0 --build-number abc --env-config config-prod.json

# 3. Package drift between Gradle and the store identity.
printf 'applicationId = "com.example.other"\n' > "$work/android/app/build.gradle"
ANDROID_HOME=/nonexistent expect_refusal "package drift" \
  --build-name 1.0.0 --build-number 2 --env-config config-prod.json

# 4. Unknown argument is refused rather than ignored.
expect_refusal "unknown argument" --build-name 1.0.0 --build-number 1 --nonsense

echo "build_signed_aab.sh guards passed"
