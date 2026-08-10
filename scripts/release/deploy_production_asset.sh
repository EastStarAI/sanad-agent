#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
test -n "${DEPLOY_HOST:-}" && test -n "${DEPLOY_USER:-}" || {
  echo "DEPLOY_HOST and DEPLOY_USER are required." >&2
  exit 64
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
file_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then stat -c '%s' "$1"; else stat -f '%z' "$1"; fi
}
broker() { ssh "$DEPLOY_USER@$DEPLOY_HOST" "$@"; }

create_archive() {
  local source="$1" archive="$2"
  shift 2
  local -a tar_command=(tar)
  if tar --version 2>/dev/null | grep -Fq 'GNU tar'; then
    tar_command+=(--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner)
  fi
  COPYFILE_DISABLE=1 "${tar_command[@]}" -C "$source" -czf "$archive" "$@"
}

valid_kind() {
  case "$1" in static-web|static-updates|static-downloads) return 0 ;; *) return 1 ;; esac
}

publish() {
  local kind="$1" identity="$2" source="$3" archive digest bytes
  valid_kind "$kind" && [[ "$identity" =~ ^[0-9a-f]{40}$ ]] || exit 64
  source="$(realpath "$source")"
  test -d "$source" || exit 66
  archive="$(mktemp "${RUNNER_TEMP:-/tmp}/sanad-production-asset.XXXXXX")"
  cleanup() { rm -f "$archive"; }
  trap cleanup EXIT HUP INT TERM
  case "$kind" in
    static-web)
      test -s "$source/index.html" && test -s "$source/flutter_bootstrap.js" && \
        test -s "$source/favicon.svg" && test "$(tr -d '\r\n' < "$source/sanad-public-sha.txt")" = "$identity"
      create_archive "$source" "$archive" .
      ;;
    static-updates)
      test -s "$source/appcast.xml" && test -s "$source/release-manifest.json"
      create_archive "$source" "$archive" appcast.xml release-manifest.json
      ;;
    static-downloads)
      test -s "$source/install.sh" && test -s "$source/install.ps1"
      create_archive "$source" "$archive" install.sh install.ps1
      ;;
  esac
  digest="$(sha256_file "$archive")"
  bytes="$(file_size "$archive")"
  broker "upload $kind $identity $digest $bytes" < "$archive" >&2
  broker "install $kind $identity $digest" >&2
  rm -f "$archive"
  trap - EXIT HUP INT TERM
  printf '%s\n' "$digest"
}

deploy_aliases() {
  local tag="$1" manifest_digest="$2" config="$3" payload_digest bytes
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$manifest_digest" =~ ^[0-9a-f]{64}$ ]] || exit 64
  test -s "$config" || exit 66
  payload_digest="$(sha256_file "$config")"
  bytes="$(file_size "$config")"
  broker "upload-client-aliases $tag $manifest_digest $payload_digest $bytes" < "$config" >&2
  broker "deploy-client-aliases $tag $manifest_digest $payload_digest"
}

case "$ACTION" in
  publish)
    test "$#" -eq 4 || exit 64
    publish "$2" "$3" "$4"
    ;;
  previous)
    test "$#" -eq 2 && valid_kind "$2" || exit 64
    broker "previous $2"
    ;;
  hash)
    test "$#" -eq 3 && valid_kind "$2" || exit 64
    case "$2:$3" in
      static-web:index.html|static-updates:appcast.xml|static-updates:release-manifest.json|static-downloads:install.sh|static-downloads:install.ps1) ;;
      *) exit 64 ;;
    esac
    broker "hash $2 $3"
    ;;
  activate|rollback)
    test "$#" -eq 4 && valid_kind "$2" || exit 64
    [[ "$3" =~ ^[0-9a-f]{40}$ && "$4" =~ ^[0-9a-f]{64}$ ]] || exit 64
    broker "$ACTION $2 $3 $4"
    ;;
  deploy-client-aliases)
    test "$#" -eq 4 || exit 64
    deploy_aliases "$2" "$3" "$4"
    ;;
  *) exit 64 ;;
esac
