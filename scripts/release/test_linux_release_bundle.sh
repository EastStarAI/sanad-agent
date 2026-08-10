#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <sanad-client-*.tar.gz>" >&2
  exit 64
fi

archive="$1"
if [[ ! -f "$archive" ]]; then
  echo "archive not found: $archive" >&2
  exit 66
fi

for command in dbus-run-session objdump tar timeout; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 69
  }
done

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

tar -xzf "$archive" -C "$tmpdir"
bundle_dir="$tmpdir/bundle"
exe="$bundle_dir/sanad-client"

if [[ ! -x "$exe" ]]; then
  echo "missing executable: $exe" >&2
  exit 1
fi

shopt -s nullglob
binaries=("$exe" "$bundle_dir"/lib/*.so)
for path in "${binaries[@]}"; do
  symbols="$(objdump -T "$path" 2>/dev/null || true)"
  if grep -q 'g_once_init_enter_pointer' <<<"$symbols"; then
    echo "forbidden GLib symbol requirement found in $path" >&2
    exit 1
  fi
done

required=(
  "$bundle_dir/lib/libflutter_linux_gtk.so"
  "$bundle_dir/lib/libapp.so"
  "$bundle_dir/data/icudtl.dat"
)
for path in "${required[@]}"; do
  [[ -e "$path" ]] || {
    echo "missing bundled runtime file: $path" >&2
    exit 1
  }
done

runner=()
if command -v xvfb-run >/dev/null 2>&1; then
  runner=(xvfb-run -a)
elif [[ -z "${DISPLAY:-}" ]]; then
  echo "xvfb-run is required when no display is available" >&2
  exit 69
fi

mkdir -p "$tmpdir/home" "$tmpdir/config" "$tmpdir/cache" "$tmpdir/data"
stdout="$tmpdir/smoke.stdout"
stderr="$tmpdir/smoke.stderr"
set +e
timeout --signal=TERM --kill-after=5s 8s \
  env \
    HOME="$tmpdir/home" \
    XDG_CONFIG_HOME="$tmpdir/config" \
    XDG_CACHE_HOME="$tmpdir/cache" \
    XDG_DATA_HOME="$tmpdir/data" \
  dbus-run-session -- "${runner[@]}" "$exe" >"$stdout" 2>"$stderr"
status=$?
set -e

if [[ $status -ne 124 ]]; then
  echo "sanad-client did not remain alive for the release smoke window (exit $status)" >&2
  cat "$stderr" >&2 || true
  exit 1
fi

if grep -Eq 'symbol lookup error|undefined symbol|error while loading shared libraries' "$stderr"; then
  echo "sanad-client reported a dynamic-linker failure" >&2
  cat "$stderr" >&2
  exit 1
fi

echo "linux release smoke passed: $archive"
