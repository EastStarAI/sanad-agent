#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <linux-bundle> <version> <output.deb>" >&2
  exit 64
fi

bundle="$1"
version="$2"
output="$3"

[[ -x "$bundle/sanad-client" ]] || {
  echo "invalid Linux bundle: $bundle" >&2
  exit 66
}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$ ]] || {
  echo "invalid release version: $version" >&2
  exit 65
}
command -v dpkg-deb >/dev/null 2>&1 || {
  echo "dpkg-deb is required" >&2
  exit 69
}

debian_version="${version/-rc./~rc.}"
source_epoch="${SOURCE_DATE_EPOCH:-0}"
[[ "$source_epoch" =~ ^[0-9]+$ ]] || {
  echo "SOURCE_DATE_EPOCH must be an integer" >&2
  exit 65
}
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
root="$tmpdir/root"

install -d \
  "$root/DEBIAN" \
  "$root/opt/sanad-client" \
  "$root/usr/bin" \
  "$root/usr/share/applications" \
  "$root/usr/share/icons"
cp -a "$bundle/." "$root/opt/sanad-client/"
install -m 0644 \
  "$bundle/share/applications/com.eaststarai.sanad.desktop" \
  "$root/usr/share/applications/com.eaststarai.sanad.desktop"
cp -a "$bundle/share/icons/hicolor" "$root/usr/share/icons/"
rm -rf "$root/opt/sanad-client/share"
ln -s /opt/sanad-client/sanad-client "$root/usr/bin/sanad-client"

find "$root/opt/sanad-client" -type d -exec chmod 0755 {} +
find "$root/opt/sanad-client" -type f -exec chmod 0644 {} +
chmod 0755 "$root/opt/sanad-client/sanad-client"
find "$root/usr/share/icons" -type d -exec chmod 0755 {} +
find "$root/usr/share/icons" -type f -exec chmod 0644 {} +

installed_size="$(du -sk "$root/opt" "$root/usr" | awk '{total += $1} END {print total}')"
cat > "$root/DEBIAN/control" <<CONTROL
Package: sanad-client
Version: $debian_version
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $installed_size
Maintainer: EastStar AI <support@eaststarai.com>
Homepage: https://sanad.eaststarai.com
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libstdc++6, hicolor-icon-theme
Description: Local-first AI agent desktop client
 Sanad Client connects to local and remote Sanad Agent runtimes from a native
 Flutter desktop interface.
CONTROL
chmod 0644 "$root/DEBIAN/control"
find "$root" -exec touch -h --date="@$source_epoch" {} +

mkdir -p "$(dirname "$output")"
dpkg-deb --root-owner-group --build "$root" "$output" >/dev/null
echo "built Linux package: $output"
