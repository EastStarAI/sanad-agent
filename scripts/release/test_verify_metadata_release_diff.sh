#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
validator="$repo_root/scripts/release/verify_metadata_release_diff.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
git init -q
git config user.name "Sanad Release Test"
git config user.email "release-test@example.invalid"

write_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

write_file agent/CHANGELOG.md $'## 1.0.6\n\n- Old release.'
write_file agent/pubspec.lock $'  sanad_release_contract:\n    version: "1.0.6"'
write_file agent/pubspec.yaml 'version: 1.0.6'
write_file client/pubspec.lock $'  sanad_release_contract:\n    version: "1.0.6"'
write_file client/pubspec.yaml 'version: 1.0.6+7'
write_file client/release/windows/sanad_client_installer.iss $'AppVersion=1.0.6\nAppPublisher=EastStar AI'
write_file client/windows/runner/Runner.rc $'#define VERSION_AS_NUMBER 1,0,6,7\n#define VERSION_AS_STRING "1.0.6"'
write_file docs/operations/release_and_signing.md 'canonical installer sources. The current patch release uses marketing version `1.0.6` and build number `7`.'
write_file release/contract/pubspec.yaml 'version: 1.0.6'
write_file release/release-contract.json $'{\n  "version": "1.0.6",\n  "build_number": 7,\n  "tag": "v1.0.6",\n  "filename": "sanad-agent-1.0.6-linux-x64"\n}'
write_file release/release-notes.md '# Sanad 1.0.6'
git add .
git commit -qm baseline
base="$(git rev-parse HEAD)"

sed -i.bak 's/1\.0\.6/1.0.7/g; s/+7/+8/g' agent/pubspec.lock agent/pubspec.yaml client/pubspec.lock client/pubspec.yaml client/release/windows/sanad_client_installer.iss client/windows/runner/Runner.rc docs/operations/release_and_signing.md release/contract/pubspec.yaml release/release-contract.json release/release-notes.md
find . -name '*.bak' -delete
sed -i.bak 's/1,0,6,7/1,0,7,8/' client/windows/runner/Runner.rc
sed -i.bak 's/"build_number": 7/"build_number": 8/' release/release-contract.json
find . -name '*.bak' -delete
write_file agent/CHANGELOG.md $'## 1.0.7\n\n- New release.\n\n## 1.0.6\n\n- Old release.'
git add .
git commit -qm metadata-release
head="$(git rev-parse HEAD)"
"$validator" "$base" "$head" >/dev/null

printf '\nAppPublisher=Unexpected Publisher\n' >> client/release/windows/sanad_client_installer.iss
git add .
git commit -qm forbidden-line
if "$validator" "$base" HEAD >/dev/null 2>&1; then
  echo "Validator accepted a forbidden installer line." >&2
  exit 1
fi

git reset --hard -q "$head"
write_file unrelated.txt 'not release metadata'
git add .
git commit -qm unrelated-path
if "$validator" "$base" HEAD >/dev/null 2>&1; then
  echo "Validator accepted an unrelated path." >&2
  exit 1
fi

echo "Metadata-only release diff validator tests passed."
