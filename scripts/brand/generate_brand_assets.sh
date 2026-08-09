#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLIENT="$ROOT/client"
BRAND="$ROOT/docs/assets/brand"
DELIVERABLES="$BRAND/deliverables"
SANAD_PRIMARY='#60A5FA'
SANAD_DARK='#0A0A0A'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for command in ruby sips ffmpeg fvm; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

mkdir -p "$DELIVERABLES"

# Compose every square mark from the approved vector. The 80% composition
# matches the supplied proportion references; adaptive/maskable artwork uses a
# deliberately smaller 62.5% safe-area composition.
ruby - "$BRAND/sanad-mark.svg" "$BRAND/sanad-app-icon-source.svg" \
  "$SANAD_PRIMARY" '#ffffff' "$SANAD_DARK" 104 247 3.185242 <<'RUBY'
source, output, source_color, foreground, background, x, y, scale = ARGV
svg = File.read(source)
svg.sub!(/<svg\b[^>]*>/m, '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">')
svg.gsub!(Regexp.new(Regexp.escape(source_color), Regexp::IGNORECASE), foreground)
svg.sub!(/(<g id="Layer_1-2"[^>]*>)/, %(<g transform="translate(#{x} #{y}) scale(#{scale})">\n    \\1))
svg.sub!(/<\/svg>\s*\z/, "  </g>\n</svg>\n")
File.write(
  output,
  svg.sub(
    /(<svg\b[^>]*>)/,
    "\\1\n  <rect width=\"1024\" height=\"1024\" fill=\"#{background}\"/>",
  ),
)
RUBY

ruby - "$BRAND/sanad-mark.svg" "$TMP/sanad-mark-square.svg" \
  "$SANAD_PRIMARY" "$SANAD_PRIMARY" none 104 247 3.185242 <<'RUBY'
source, output, source_color, foreground, background, x, y, scale = ARGV
svg = File.read(source)
svg.sub!(/<svg\b[^>]*>/m, '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">')
svg.gsub!(Regexp.new(Regexp.escape(source_color), Regexp::IGNORECASE), foreground)
background_node = background == 'none' ? '' : %(<rect width="1024" height="1024" fill="#{background}"/>\n  )
svg.sub!(/(<g id="Layer_1-2"[^>]*>)/, %(#{background_node}<g transform="translate(#{x} #{y}) scale(#{scale})">\n    \\1))
svg.sub!(/<\/svg>\s*\z/, "  </g>\n</svg>\n")
File.write(output, svg)
RUBY

ruby - "$BRAND/sanad-mark.svg" "$BRAND/sanad-adaptive-foreground-source.svg" \
  "$SANAD_PRIMARY" '#ffffff' none 192 304 2.498536 <<'RUBY'
source, output, source_color, foreground, background, x, y, scale = ARGV
svg = File.read(source)
svg.sub!(/<svg\b[^>]*>/m, '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">')
svg.gsub!(Regexp.new(Regexp.escape(source_color), Regexp::IGNORECASE), foreground)
svg.sub!(/(<g id="Layer_1-2"[^>]*>)/, %(<g transform="translate(#{x} #{y}) scale(#{scale})">\n    \\1))
svg.sub!(/<\/svg>\s*\z/, "  </g>\n</svg>\n")
File.write(output, svg)
RUBY

ruby - "$BRAND/sanad-mark.svg" "$TMP/sanad-maskable.svg" \
  "$SANAD_PRIMARY" '#ffffff' "$SANAD_DARK" 192 304 2.498536 <<'RUBY'
source, output, source_color, foreground, background, x, y, scale = ARGV
svg = File.read(source)
svg.sub!(/<svg\b[^>]*>/m, '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">')
svg.gsub!(Regexp.new(Regexp.escape(source_color), Regexp::IGNORECASE), foreground)
svg.sub!(/(<g id="Layer_1-2"[^>]*>)/, %(<rect width="1024" height="1024" fill="#{background}"/>\n  <g transform="translate(#{x} #{y}) scale(#{scale})">\n    \\1))
svg.sub!(/<\/svg>\s*\z/, "  </g>\n</svg>\n")
File.write(output, svg)
RUBY

render_png() {
  local source="$1"
  local output="$2"
  sips -s format png "$source" --out "$output" >/dev/null
}

resize_png() {
  local source="$1"
  local size="$2"
  local output="$3"
  cp "$source" "$output"
  sips -z "$size" "$size" "$output" >/dev/null
}

render_png "$BRAND/sanad-app-icon-source.svg" "$BRAND/sanad-app-icon-1024.png"
render_png "$TMP/sanad-mark-square.svg" "$TMP/sanad-mark-square.png"
render_png "$BRAND/sanad-adaptive-foreground-source.svg" "$BRAND/sanad-adaptive-foreground-1024.png"
render_png "$TMP/sanad-maskable.svg" "$TMP/sanad-maskable.png"
render_png "$BRAND/sanad-wordmark-horizontal.svg" "$TMP/sanad-wordmark-horizontal.png"

cp "$BRAND/sanad-app-icon-1024.png" "$CLIENT/assets/app-logo.png"
cp "$TMP/sanad-mark-square.png" "$CLIENT/assets/sanad_mark.png"
cp "$BRAND/sanad-adaptive-foreground-1024.png" "$CLIENT/assets/sanad_adaptive_foreground.png"

# flutter_launcher_icons owns Android legacy/adaptive, iOS, macOS, Windows,
# and standard Web outputs. Platform-specific corrections follow generation.
(
  cd "$CLIENT"
  fvm dart run flutter_launcher_icons
)

# Android 13 monochrome uses the same safe-area vector foreground.
for xml in "$CLIENT"/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher*.xml; do
  [[ -f "$xml" ]] || continue
  ruby -i -pe 'gsub(%r{</adaptive-icon>}, "    <monochrome android:drawable=\"@drawable/ic_launcher_foreground\" />\n</adaptive-icon>") unless $_.include?("monochrome")' "$xml"
done

# The launcher package currently emits one Windows frame. Rebuild the ICO from
# the same master with the full Windows size matrix.
(
  cd "$CLIENT"
  fvm dart run tool/generate_windows_icon.dart \
    ../docs/assets/brand/sanad-app-icon-1024.png \
    windows/runner/resources/app_icon.ico
)

# Web maskable icons need a larger safety inset than standard launcher icons.
resize_png "$TMP/sanad-maskable.png" 192 "$CLIENT/web/icons/Icon-maskable-192.png"
resize_png "$TMP/sanad-maskable.png" 512 "$CLIENT/web/icons/Icon-maskable-512.png"
resize_png "$BRAND/sanad-app-icon-1024.png" 16 "$CLIENT/web/favicon-16.png"
resize_png "$BRAND/sanad-app-icon-1024.png" 32 "$CLIENT/web/favicon-32.png"
resize_png "$BRAND/sanad-app-icon-1024.png" 48 "$CLIENT/web/favicon.png"
cp "$CLIENT/windows/runner/resources/app_icon.ico" "$CLIENT/web/favicon.ico"

# Linux desktop packaging consumes a standard hicolor set and desktop entry.
for size in 16 24 32 48 64 128 256 512; do
  destination="$CLIENT/linux/assets/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$destination"
  resize_png "$BRAND/sanad-app-icon-1024.png" "$size" "$destination/com.eaststarai.sanad.png"
done

# Review-ready handoff assets for live surfaces owned by SANAD-11/13.
resize_png "$BRAND/sanad-app-icon-1024.png" 512 "$DELIVERABLES/discord-server-icon-512.png"
resize_png "$BRAND/sanad-app-icon-1024.png" 180 "$DELIVERABLES/sanad-apple-touch-icon-180.png"
resize_png "$BRAND/sanad-app-icon-1024.png" 512 "$DELIVERABLES/sanad-product-icon-512.png"
resize_png "$BRAND/sanad-app-icon-1024.png" 32 "$DELIVERABLES/sanad-favicon-32.png"
cp "$CLIENT/web/favicon.ico" "$DELIVERABLES/sanad-favicon.ico"

ffmpeg -v error -f lavfi -i color=c=white:s=1280x640 -i "$TMP/sanad-wordmark-horizontal.png" \
  -filter_complex '[1:v]scale=960:-1[logo];[0:v][logo]overlay=(W-w)/2:(H-h)/2' \
  -frames:v 1 -y "$DELIVERABLES/github-repository-social-preview-1280x640.png"
ffmpeg -v error -f lavfi -i color=c=white:s=1200x630 -i "$TMP/sanad-wordmark-horizontal.png" \
  -filter_complex '[1:v]scale=900:-1[logo];[0:v][logo]overlay=(W-w)/2:(H-h)/2' \
  -frames:v 1 -y "$DELIVERABLES/sanad-product-social-card-1200x630.png"
ffmpeg -v error -f lavfi -i color=c=0x0A0A0A:s=960x540 -i "$BRAND/sanad-adaptive-foreground-1024.png" \
  -filter_complex '[1:v]scale=620:620[mark];[0:v][mark]overlay=(W-w)/2:(H-h)/2' \
  -frames:v 1 -y "$DELIVERABLES/discord-server-banner-960x540.png"

echo "Generated canonical Sanad brand assets."
