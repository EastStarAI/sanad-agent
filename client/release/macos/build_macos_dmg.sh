#!/bin/bash

set -euo pipefail

APP_NAME="Sanad"
VERSION_NAME="$(awk '/^version:/ {split($2, parts, "+"); print parts[1]}' pubspec.yaml)"
DMG_NAME="sanad-client-${VERSION_NAME}-macos-universal.dmg"
OUTPUT_DIR="build"
BUILD_PRODUCT_DIR="build/macos/Build/Products/Release"
APP_PATH="$BUILD_PRODUCT_DIR/$APP_NAME.app"
STAGING_DIR="build/dmg_staging"
ENTITLEMENTS_PATH="macos/Runner/Release.entitlements"
SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"

if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning |
      sed -n 's/.*"\(Developer ID Application: NanoSoft LY LLC ([^"]*)\)".*/\1/p' |
      head -n 1
  )"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "Developer ID Application signing identity is required." >&2
  exit 1
fi

if [ "${SANAD_SKIP_BUILD:-0}" != "1" ]; then
  fvm flutter clean
  fvm flutter pub get
  fvm flutter build macos --release --config-only \
    --dart-define-from-file="${SANAD_ENV_CONFIG:-config/prod.json}"
  xcodebuild \
    -workspace macos/Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -derivedDataPath build/macos \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO
fi
test -d "$APP_PATH"

IMPELLER_SETTING="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :FLTEnableImpeller' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
)"
if [ "$IMPELLER_SETTING" != "false" ]; then
  echo "macOS release must disable Impeller while flutter/flutter#185394 remains unresolved." >&2
  exit 1
fi

while IFS= read -r binary; do
  architectures="$(lipo -archs "$binary")"
  if [[ " $architectures " != *" arm64 "* ]] ||
    [[ " $architectures " != *" x86_64 "* ]]; then
    echo "Non-universal Mach-O in bundle: $binary ($architectures)" >&2
    exit 1
  fi
done < <(
  find "$APP_PATH" -type f -print0 |
    while IFS= read -r -d '' candidate; do
      if file "$candidate" | grep -q 'Mach-O'; then printf '%s\n' "$candidate"; fi
    done
)

while IFS= read -r nested; do
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$nested"
done < <(
  find "$APP_PATH/Contents/Frameworks" -type f -print0 |
    while IFS= read -r -d '' candidate; do
      if file "$candidate" | grep -q 'Mach-O'; then printf '%s\n' "$candidate"; fi
    done |
    awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
)
while IFS= read -r nested; do
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$nested"
done < <(
  find "$APP_PATH/Contents/Frameworks" -type d \
    \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) -print |
    awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
)

codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS_PATH" \
  --options runtime \
  --timestamp \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
while IFS= read -r binary; do
  team_identifier="$(
    codesign -dv --verbose=2 "$binary" 2>&1 |
      sed -n 's/^TeamIdentifier=//p'
  )"
  if [ "$team_identifier" != "UC2824B99G" ]; then
    echo "Unexpected signing team for nested Mach-O: $binary" >&2
    exit 1
  fi
done < <(
  find "$APP_PATH" -type f -print0 |
    while IFS= read -r -d '' candidate; do
      if file "$candidate" | grep -q 'Mach-O'; then printf '%s\n' "$candidate"; fi
    done
)

mkdir -p "$OUTPUT_DIR" "$STAGING_DIR"
find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$OUTPUT_DIR/$DMG_NAME"

create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "$APP_NAME" 175 190 \
  --icon "Applications" 425 190 \
  --hide-extension "$APP_NAME" \
  "$OUTPUT_DIR/$DMG_NAME" \
  "$STAGING_DIR"

codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$OUTPUT_DIR/$DMG_NAME"
codesign --verify --verbose=2 "$OUTPUT_DIR/$DMG_NAME"
echo "Created signed DMG: $OUTPUT_DIR/$DMG_NAME"
