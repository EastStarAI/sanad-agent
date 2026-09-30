#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: verify_metadata_release_diff.sh <base-ref> <head-ref>" >&2
  exit 64
fi

base_ref="$1"
head_ref="$2"
git rev-parse --verify "${base_ref}^{commit}" >/dev/null
git rev-parse --verify "${head_ref}^{commit}" >/dev/null

expected_paths=$(cat <<'PATHS'
agent/CHANGELOG.md
agent/pubspec.lock
agent/pubspec.yaml
client/pubspec.lock
client/pubspec.yaml
client/release/windows/sanad_client_installer.iss
client/windows/runner/Runner.rc
docs/operations/release_and_signing.md
release/contract/pubspec.yaml
release/release-contract.json
release/release-notes.md
PATHS
)
actual_paths="$(git diff --name-only "$base_ref...$head_ref" | LC_ALL=C sort)"
if [[ "$actual_paths" != "$expected_paths" ]]; then
  echo "Release preparation is not the exact metadata-only file set." >&2
  diff -u <(printf '%s\n' "$expected_paths") <(printf '%s\n' "$actual_paths") >&2 || true
  exit 1
fi
if [[ -n "$(git diff --summary "$base_ref...$head_ref")" ]]; then
  echo "Release metadata files must not be created, renamed, deleted, or change mode." >&2
  exit 1
fi
while IFS=$'\t' read -r status path; do
  if [[ "$status" != M ]]; then
    echo "Release metadata path must be an ordinary modification: $status $path" >&2
    exit 1
  fi
done < <(git diff --name-status "$base_ref...$head_ref")
while IFS=$'\t' read -r added deleted path; do
  if [[ "$added" == - || "$deleted" == - ]]; then
    echo "Binary release metadata is forbidden: $path" >&2
    exit 1
  fi
done < <(git diff --numstat "$base_ref...$head_ref")

validate_changed_lines() {
  local path="$1"
  local line content
  local changed_count=0
  while IFS= read -r line; do
    case "$line" in
      '+++'*|'---'*|'@@'*) continue ;;
      '+'*|'-'*)
        content="${line:1}"
        changed_count=$((changed_count + 1)) ;;
      *) continue ;;
    esac
    case "$path" in
      agent/pubspec.yaml|release/contract/pubspec.yaml)
        [[ "$content" =~ ^version:\ [0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
      client/pubspec.yaml)
        [[ "$content" =~ ^version:\ [0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$ ]] ;;
      agent/pubspec.lock|client/pubspec.lock)
        [[ "$content" =~ ^[[:space:]]{4}version:\ \"[0-9]+\.[0-9]+\.[0-9]+\"$ ]] ;;
      client/release/windows/sanad_client_installer.iss)
        [[ "$content" =~ ^AppVersion=[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
      client/windows/runner/Runner.rc)
        [[ "$content" =~ ^#define\ VERSION_AS_NUMBER\ [0-9]+,[0-9]+,[0-9]+,[1-9][0-9]*$ ]] ||
          [[ "$content" =~ ^#define\ VERSION_AS_STRING\ \"[0-9]+\.[0-9]+\.[0-9]+\"$ ]] ;;
      docs/operations/release_and_signing.md)
        [[ "$content" == canonical\ installer\ sources.\ The\ current\ patch\ release\ uses\ marketing\ version* ]] ;;
      release/release-contract.json)
        [[ "$content" =~ ^[[:space:]]+\"version\":\ \"[0-9]+\.[0-9]+\.[0-9]+\",$ ]] ||
          [[ "$content" =~ ^[[:space:]]+\"build_number\":\ [1-9][0-9]*,$ ]] ||
          [[ "$content" =~ ^[[:space:]]+\"tag\":\ \"v[0-9]+\.[0-9]+\.[0-9]+\",$ ]] ||
          [[ "$content" =~ ^[[:space:]]+\"filename\":\ \"sanad-(agent|client)-[0-9]+\.[0-9]+\.[0-9]+-[a-z0-9.-]+\",?$ ]] ;;
      *)
        echo "Internal validator error for $path" >&2
        return 1 ;;
    esac || {
      echo "Unexpected release metadata change in $path: $line" >&2
      return 1
    }
  done < <(git diff --unified=0 --no-color "$base_ref...$head_ref" -- "$path")
  if ((changed_count < 2)); then
    echo "Release metadata file has no complete identity substitution: $path" >&2
    return 1
  fi
}

while IFS= read -r path; do
  case "$path" in
    agent/CHANGELOG.md|release/release-notes.md) ;;
    *) validate_changed_lines "$path" ;;
  esac
done <<< "$actual_paths"

echo "Verified exact metadata-only release preparation diff."
