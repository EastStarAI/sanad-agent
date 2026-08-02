#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOSITORY_ROOT="$(cd "$CLIENT_ROOT/.." && pwd)"
VERSION_NAME="$(awk '/^version:/ {split($2, parts, "+"); print parts[1]}' "$CLIENT_ROOT/pubspec.yaml")"
DMG_PATH="$CLIENT_ROOT/build/sanad-client-${VERSION_NAME}-macos-universal.dmg"

cd "$REPOSITORY_ROOT/agent"
fvm dart run tool/release_tool.dart validate-contract --repo-root ..

cd "$CLIENT_ROOT"
"$SCRIPT_DIR/build_macos_dmg.sh"
"$SCRIPT_DIR/notarize_macos.sh" "$DMG_PATH"

if [ -n "${SPARKLE_ED25519_PRIVATE_KEY_PATH:-}" ]; then
  if [ ! -f "$SPARKLE_ED25519_PRIVATE_KEY_PATH" ]; then
    echo "Sparkle EdDSA private key file is missing." >&2
    exit 1
  fi
  SIGN_OUTPUT="$(
    macos/Pods/Sparkle/bin/sign_update \
      --ed-key-file "$SPARKLE_ED25519_PRIVATE_KEY_PATH" \
      "$DMG_PATH"
  )"
else
  SIGN_OUTPUT="$(fvm dart run auto_updater:sign_update "$DMG_PATH")"
fi
SIGNATURE="$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
if [ -z "$SIGNATURE" ]; then
  echo "Sparkle EdDSA signing failed." >&2
  exit 1
fi
printf '%s\n' "$SIGNATURE" > "$DMG_PATH.update-signature"
chmod 600 "$DMG_PATH.update-signature"
echo "Prepared signed, notarized, and update-signed macOS artifact."
