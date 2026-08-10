#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != --install ) ]]; then
  echo "usage: $0 <sanad-client-*.deb> [--install]" >&2
  exit 64
fi

deb="$1"
install_smoke="${2:-}"
[[ -f "$deb" ]] || { echo "package not found: $deb" >&2; exit 66; }
for command in dbus-run-session dpkg-deb objdump tar timeout; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 69
  }
done

[[ "$(dpkg-deb -f "$deb" Package)" == sanad-client ]]
[[ "$(dpkg-deb -f "$deb" Architecture)" == amd64 ]]
[[ "$(dpkg-deb -f "$deb" Version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(~rc\.[1-9][0-9]*)?$ ]]

tmpdir="$(mktemp -d)"
installed=false
cleanup() {
  if [[ "$installed" == true ]]; then
    sudo dpkg --purge sanad-client >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

dpkg-deb -x "$deb" "$tmpdir/root"
exe="$tmpdir/root/opt/sanad-client/sanad-client"
[[ -x "$exe" ]]
[[ "$(readlink "$tmpdir/root/usr/bin/sanad-client")" == /opt/sanad-client/sanad-client ]]
[[ -f "$tmpdir/root/usr/share/applications/com.eaststarai.sanad.desktop" ]]
for size in 16 24 32 48 64 128 256 512; do
  [[ -f "$tmpdir/root/usr/share/icons/hicolor/${size}x${size}/apps/com.eaststarai.sanad.png" ]]
done

for path in "$exe" "$tmpdir/root"/opt/sanad-client/lib/*.so; do
  symbols="$(objdump -T "$path" 2>/dev/null || true)"
  ! grep -q g_once_init_enter_pointer <<<"$symbols"
done

run_smoke() {
  local target="$1"
  local runner=()
  if command -v xvfb-run >/dev/null 2>&1; then
    runner=(xvfb-run -a)
  elif [[ -z "${DISPLAY:-}" ]]; then
    echo "xvfb-run is required when no display is available" >&2
    return 69
  fi
  mkdir -p "$tmpdir/home" "$tmpdir/config" "$tmpdir/cache" "$tmpdir/data"
  set +e
  timeout --signal=TERM --kill-after=5s 8s env \
    HOME="$tmpdir/home" \
    XDG_CONFIG_HOME="$tmpdir/config" \
    XDG_CACHE_HOME="$tmpdir/cache" \
    XDG_DATA_HOME="$tmpdir/data" \
    dbus-run-session -- "${runner[@]}" "$target" \
    >"$tmpdir/smoke.stdout" 2>"$tmpdir/smoke.stderr"
  local status=$?
  set -e
  if [[ $status -ne 124 ]] || grep -Eq \
    'symbol lookup error|undefined symbol|error while loading shared libraries' \
    "$tmpdir/smoke.stderr"; then
    cat "$tmpdir/smoke.stderr" >&2 || true
    return 1
  fi
}

run_smoke "$exe"

if [[ "$install_smoke" == --install ]]; then
  command -v sudo >/dev/null 2>&1 || { echo "sudo is required" >&2; exit 69; }
  ! dpkg-query -W -f='${Status}' sanad-client 2>/dev/null | grep -q 'install ok installed'
  sudo dpkg -i "$deb" >/dev/null
  installed=true
  [[ -x /usr/bin/sanad-client ]]
  run_smoke /usr/bin/sanad-client
  sudo dpkg --purge sanad-client >/dev/null
  installed=false
  [[ ! -e /usr/bin/sanad-client ]]
  [[ ! -e /opt/sanad-client ]]
fi

echo "linux DEB smoke passed: $deb"
