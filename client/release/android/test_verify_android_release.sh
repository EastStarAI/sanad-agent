#!/bin/bash
#
# Guards for release/android/verify_android_release.sh, the single owner of the
# Android store identity proof. Every case here fails before any signing tool runs,
# so the test stays offline and fast. Asserting the message, not only the exit
# status, proves each case reached the intended check instead of failing earlier.
#
# Runs from the client/ directory.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/verify_android_release.sh"
test -f "$script" || { echo "Missing $script" >&2; exit 1; }
repo_gradle="$(cd "$script_dir/../.." && pwd)/android/app/build.gradle"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/android/app"
printf 'version: 1.0.0+1\n' > "$work/config-prod.json"
printf 'applicationId = "com.eaststarai.sanad"\n' > "$work/android/app/build.gradle"
printf 'apky\n' > "$work/app.apk"
printf 'aaby\n' > "$work/app.aab"

expect_refusal() {
  local label="$1" expected="$2"; shift 2
  local output status=0
  output="$( cd "$work" && bash "$script" "$@" 2>&1 )" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "::error::$label: the verification script accepted an invalid invocation" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" <<<"$output"; then
    echo "::error::$label: expected the guard message '$expected', but the script said: $output" >&2
    exit 1
  fi
}

# 1. The committed Gradle file must carry the store identity the release publishes,
#    so a renamed applicationId fails here instead of at Google Play.
bash "$script" --package com.eaststarai.sanad --preflight --gradle-file "$repo_gradle" >/dev/null || {
  echo "::error::the committed android/app/build.gradle does not declare com.eaststarai.sanad" >&2
  exit 1
}

# 2. Package drift between Gradle and the store identity.
printf 'applicationId = "com.example.other"\n' > "$work/android/app/build.gradle"
expect_refusal "package drift" \
  "Package drift: android/app/build.gradle declares 'com.example.other' but the store identity is 'com.eaststarai.sanad'" \
  --package com.eaststarai.sanad --preflight --gradle-file android/app/build.gradle
printf 'applicationId = "com.eaststarai.sanad"\n' > "$work/android/app/build.gradle"

# 3. The store identity is not optional.
expect_refusal "missing package" '--package is required' --preflight

# 4. A missing build file is reported as such rather than read as an empty identity.
expect_refusal "missing gradle file" 'Missing Gradle file: android/app/missing.gradle' \
  --package com.eaststarai.sanad --preflight --gradle-file android/app/missing.gradle

# 5. Artifacts are proven to exist before any tooling is probed.
expect_refusal "missing APK" 'Missing APK: missing.apk' \
  --package com.eaststarai.sanad --version-name 1.0.0 --version-code 1 \
  --apk missing.apk --aab app.aab --gradle-file android/app/build.gradle
expect_refusal "missing App Bundle" 'Missing App Bundle: missing.aab' \
  --package com.eaststarai.sanad --version-name 1.0.0 --version-code 1 \
  --apk app.apk --aab missing.aab --gradle-file android/app/build.gradle

# 6. An unusable Android SDK reports the missing build-tools, not a signing error.
expect_refusal "unusable Android SDK" "No Android build-tools under '/nonexistent/build-tools'" \
  --package com.eaststarai.sanad --version-name 1.0.0 --version-code 1 \
  --apk app.apk --aab app.aab --gradle-file android/app/build.gradle \
  --android-home /nonexistent

# 7. A non-numeric versionCode is refused rather than uploaded as-is.
expect_refusal "non-numeric version code" "--version-code must be a positive integer, got 'abc'" \
  --package com.eaststarai.sanad --version-name 1.0.0 --version-code abc \
  --apk app.apk --aab app.aab --gradle-file android/app/build.gradle

# 8. Unknown arguments are refused rather than silently ignored.
expect_refusal "unknown argument" 'Unknown argument: --nonsense' \
  --package com.eaststarai.sanad --preflight --nonsense

echo "verify_android_release.sh guards passed"
