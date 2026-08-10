#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GENERATOR="$SCRIPT_DIR/generate_client_download_redirects.sh"
ROOT="$(mktemp -d -t sanad-client-redirect-test.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
mkdir "$ROOT/assets"
printf macos > "$ROOT/assets/client-macos.dmg"
printf windows > "$ROOT/assets/client-windows.exe"
printf linux > "$ROOT/assets/client-linux.deb"
printf portable > "$ROOT/assets/client-linux.tar.gz"

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
for file in "$ROOT"/assets/*; do printf '%s  %s\n' "$(sha "$file")" "$(basename "$file")"; done > "$ROOT/SHA256SUMS"

jq -n \
  --arg mac_sha "$(sha "$ROOT/assets/client-macos.dmg")" \
  --arg win_sha "$(sha "$ROOT/assets/client-windows.exe")" \
  --arg linux_sha "$(sha "$ROOT/assets/client-linux.deb")" \
  --arg linux_tar_sha "$(sha "$ROOT/assets/client-linux.tar.gz")" \
  '{schema_version:1,version:"9.8.7",tag:"v9.8.7",commit:"0123456789abcdef0123456789abcdef01234567",channel:"stable",repository:"EastStarAI/sanad-agent",artifacts:[
    {component:"client",platform:"macos",architecture:"universal",format:"dmg",filename:"client-macos.dmg",url:"https://github.com/EastStarAI/sanad-agent/releases/download/v9.8.7/client-macos.dmg",sha256:$mac_sha,size:5,public:true},
    {component:"client",platform:"windows",architecture:"x64",format:"exe",filename:"client-windows.exe",url:"https://github.com/EastStarAI/sanad-agent/releases/download/v9.8.7/client-windows.exe",sha256:$win_sha,size:7,public:true},
    {component:"client",platform:"linux",architecture:"x64",format:"deb",filename:"client-linux.deb",url:"https://github.com/EastStarAI/sanad-agent/releases/download/v9.8.7/client-linux.deb",sha256:$linux_sha,size:5,public:true},
    {component:"client",platform:"linux",architecture:"x64",format:"tar.gz",filename:"client-linux.tar.gz",url:"https://github.com/EastStarAI/sanad-agent/releases/download/v9.8.7/client-linux.tar.gz",sha256:$linux_tar_sha,size:8,public:true}
  ]}' > "$ROOT/manifest.json"

"$GENERATOR" "$ROOT/manifest.json" "$ROOT/SHA256SUMS" "$ROOT/assets" "$ROOT/redirects.conf" >/dev/null
for platform in macos windows linux; do test "$(grep -Fc "location = /client/$platform" "$ROOT/redirects.conf")" -eq 1; done
grep -Fq client-linux.deb "$ROOT/redirects.conf"
! grep -Fq client-linux.tar.gz "$ROOT/redirects.conf"
! grep -Fq sanad-agent- "$ROOT/redirects.conf"

jq '.channel = "rc"' "$ROOT/manifest.json" > "$ROOT/bad.json"
! "$GENERATOR" "$ROOT/bad.json" "$ROOT/SHA256SUMS" "$ROOT/assets" "$ROOT/bad.conf" >/dev/null 2>&1
jq '.artifacts[0].component = "agent"' "$ROOT/manifest.json" > "$ROOT/bad.json"
! "$GENERATOR" "$ROOT/bad.json" "$ROOT/SHA256SUMS" "$ROOT/assets" "$ROOT/bad.conf" >/dev/null 2>&1
jq '.artifacts[1].size = 8' "$ROOT/manifest.json" > "$ROOT/bad.json"
! "$GENERATOR" "$ROOT/bad.json" "$ROOT/SHA256SUMS" "$ROOT/assets" "$ROOT/bad.conf" >/dev/null 2>&1

echo "client-download-redirect-generator=pass"
