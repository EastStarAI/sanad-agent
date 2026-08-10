#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${1:-}"
CHECKSUMS="${2:-}"
ASSET_DIR="${3:-}"
OUTPUT="${4:-}"

test -f "$MANIFEST" && test -f "$CHECKSUMS" && test -d "$ASSET_DIR" && test -n "$OUTPUT" || {
  echo "Usage: $0 <release-manifest.json> <SHA256SUMS> <asset-directory> <output.conf>" >&2
  exit 64
}
command -v jq >/dev/null

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

repository="$(jq -er '.repository' "$MANIFEST")"
tag="$(jq -er '.tag' "$MANIFEST")"
version="$(jq -er '.version' "$MANIFEST")"
commit="$(jq -er '.commit' "$MANIFEST")"
channel="$(jq -er '.channel' "$MANIFEST")"

[[ "$repository" == EastStarAI/sanad-agent ]]
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$version" == "${tag#v}" ]]
[[ "$commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$channel" == stable ]]

manifest_sha="$(sha256_file "$MANIFEST")"
temporary="$(mktemp -t sanad-client-redirects.XXXXXX)"
trap 'rm -f "$temporary"' EXIT
{
  echo "# Generated from $repository $tag ($commit)."
  echo "# release-manifest.json sha256: $manifest_sha"
} > "$temporary"

while IFS=$'\t' read -r platform architecture format; do
  entry="$(jq -ec \
    --arg platform "$platform" --arg architecture "$architecture" --arg format "$format" \
    '[.artifacts[] | select(.component == "client" and .platform == $platform and .architecture == $architecture and .format == $format and .public == true)] | if length == 1 then .[0] else error("expected exactly one public Client artifact") end' \
    "$MANIFEST")"
  filename="$(jq -er '.filename' <<<"$entry")"
  url="$(jq -er '.url' <<<"$entry")"
  expected_sha="$(jq -er '.sha256' <<<"$entry")"
  expected_size="$(jq -er '.size' <<<"$entry")"
  expected_url="https://github.com/$repository/releases/download/$tag/$filename"
  [[ "$url" == "$expected_url" ]]
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]]
  [[ "$expected_size" =~ ^[1-9][0-9]*$ ]]
  asset="$ASSET_DIR/$filename"
  test -f "$asset"
  [[ "$(wc -c < "$asset" | tr -d ' ')" == "$expected_size" ]]
  [[ "$(sha256_file "$asset")" == "$expected_sha" ]]
  [[ "$(awk -v file="$filename" '$2 == file {print $1}' "$CHECKSUMS")" == "$expected_sha" ]]
  [[ "$(awk -v file="$filename" '$2 == file {count++} END {print count+0}' "$CHECKSUMS")" == 1 ]]
  printf 'location = /client/%s { return 302 %s; }\n' "$platform" "$url" >> "$temporary"
done <<'PLATFORMS'
macos	universal	dmg
windows	x64	exe
linux	x64	deb
PLATFORMS

install -m 0644 "$temporary" "$OUTPUT"
echo "client-download-redirects=verified tag=$tag manifest_sha256=$manifest_sha"
