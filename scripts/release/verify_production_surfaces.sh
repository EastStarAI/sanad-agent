#!/usr/bin/env bash
#
# Verify that every version-bearing public Production surface serves the newest
# published Stable release.
#
# Read-only: no secret, no deployment, no Environment. Every request carries
# `Cache-Control: no-cache` and no cache-busting query string, so a stale
# intermediary stays observable instead of being masked by the probe itself.
#
# Usage
#   verify_production_surfaces.sh resolve --releases <releases.json>
#                                        [--github-output <file>]
#   verify_production_surfaces.sh verify  --tag <vX.Y.Z> --tag-commit <sha40>
#                                        --tag-tree <dir> --surfaces <file>
#                                        [--fixtures <dir>] [--summary-out <file>]
#
# Owners
#   scripts/release/production-surfaces.json    public hostnames and paths
#   release/release-contract.json  (at the tag) channel filenames, build, repository
#   scripts/install.sh|ps1         (at the tag) published installer bytes
#
# Exit codes
#   0  every checked surface matches, or the newest release is still a Draft
#   1  at least one surface is behind, or no published Stable release exists
#   2  usage or configuration error
set -uo pipefail

# shellcheck disable=SC1007 # CDPATH= clears an inherited CDPATH before cd; it is not an assignment.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SURFACES_FILE="$SCRIPT_DIR/production-surfaces.json"
HTTP_TIMEOUT_SECONDS="${SANAD_SURFACE_HTTP_TIMEOUT_SECONDS:-20}"

MODE=''
RELEASES_FILE=''
GITHUB_OUTPUT_FILE=''
FIXTURES_DIR=''
SUMMARY_OUT=''
TAG=''
TAG_COMMIT=''
TAG_TREE=''
WORK_DIR=''

FETCH_STATUS=''
FETCH_BODY=''
FETCH_HEADERS=''

FAILURES=0
WARNINGS=0
SURFACE_ROWS=()
CACHE_SURFACES=()
CACHE_VALUES=()

die() {
  local code="$1"
  shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'USAGE'
Verify that every version-bearing public Production surface serves the newest
published Stable release.

Usage
  verify_production_surfaces.sh resolve --releases <releases.json>
                                       [--github-output <file>]
  verify_production_surfaces.sh verify  --tag <vX.Y.Z> --tag-commit <sha40>
                                       --tag-tree <dir> --surfaces <file>
                                       [--fixtures <dir>] [--summary-out <file>]

resolve  Select the newest published Stable release from a live
         repos/{repository}/releases response, and report an open release
         window while the newest release is still a Draft.
verify   Compare every public Production surface with one immutable tag.

Exit codes
  0  every checked surface matches, or the newest release is still a Draft
  1  at least one surface is behind, or no published Stable release exists
  2  usage or configuration error
USAGE
}

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

short_commit() {
  if [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "${1:0:8}"
  else
    printf '%s' "${1:-<missing>}"
  fi
}

host_label() {
  local base="${1#*://}"
  printf '%s' "${base%/}"
}

header_value() {
  local headers="$1" wanted="$2"
  [[ -f "$headers" ]] || return 0
  awk -v wanted="$(printf '%s' "$wanted" | tr '[:upper:]' '[:lower:]')" '
    {
      line = $0
      sub(/\r$/, "", line)
      colon = index(line, ":")
      if (colon == 0) next
      if (tolower(substr(line, 1, colon - 1)) != wanted) next
      value = substr(line, colon + 1)
      sub(/^[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
      print value
    }' "$headers" | tail -n 1
}

# ---------------------------------------------------------------------------
# Result collection
# ---------------------------------------------------------------------------

add_row() {
  SURFACE_ROWS+=("$1|$2|$3|$4")
}

ok_row() {
  add_row "$1" "$2" "$3" 'ok'
}

fail_row() {
  add_row "$1" "$2" "$3" 'behind'
  FAILURES=$((FAILURES + 1))
}

warn_row() {
  add_row "$1" "$2" "$3" 'warning'
  WARNINGS=$((WARNINGS + 1))
}

cache_note() {
  CACHE_SURFACES+=("$1")
  CACHE_VALUES+=("$(header_value "$2" 'cache-control')")
}

render_summary() {
  local row surface expected observed result
  printf '### Production release surfaces: %s\n\n' "$TAG"
  printf '| Surface | Expected | Observed | Result |\n'
  printf '| --- | --- | --- | --- |\n'
  for row in ${SURFACE_ROWS[@]+"${SURFACE_ROWS[@]}"}; do
    IFS='|' read -r surface expected observed result <<<"$row"
    printf '| %s | %s | %s | %s |\n' "$surface" "$expected" "$observed" "$result"
  done
}

emit_annotations() {
  local row surface expected observed result
  for row in ${SURFACE_ROWS[@]+"${SURFACE_ROWS[@]}"}; do
    IFS='|' read -r surface expected observed result <<<"$row"
    case "$result" in
      behind)
        printf '::error::Production surface %s is behind: expected %s, observed %s\n' \
          "$surface" "$expected" "$observed"
        ;;
      warning)
        printf '::warning::Production surface %s is served as immutable: %s\n' \
          "$surface" "$observed"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

prepare_work_dir() {
  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d -t sanad-production-surfaces.XXXXXX)" ||
      die 2 'cannot create a working directory'
    trap 'rm -rf "$WORK_DIR"' EXIT
  fi
}

# fetch <fixture-id> <url>
# Leaves FETCH_STATUS, FETCH_BODY, and FETCH_HEADERS for the caller. Returns 1
# only when no HTTP response was observed; an HTTP error status returns 0 so the
# caller can report the exact status instead of a generic failure.
fetch() {
  local id="$1" url="$2" status

  case "$url" in
    *\?*) die 2 "refusing to send a cache-busting query string: $url" ;;
  esac

  FETCH_STATUS=''
  FETCH_BODY=''
  FETCH_HEADERS=''

  if [[ -n "$FIXTURES_DIR" ]]; then
    FETCH_BODY="$FIXTURES_DIR/$id/body"
    FETCH_HEADERS="$FIXTURES_DIR/$id/headers"
    [[ -f "$FETCH_BODY" ]] || die 2 "fixture $id has no body file"
    [[ -f "$FETCH_HEADERS" ]] || die 2 "fixture $id has no headers file"
    FETCH_STATUS="$(cat "$FIXTURES_DIR/$id/status" 2>/dev/null || printf '200')"
    return 0
  fi

  prepare_work_dir
  FETCH_BODY="$WORK_DIR/$id.body"
  FETCH_HEADERS="$WORK_DIR/$id.headers"
  status="$(curl --silent --show-error --max-time "$HTTP_TIMEOUT_SECONDS" --retry 2 \
    --header 'Cache-Control: no-cache' \
    --dump-header "$FETCH_HEADERS" \
    --output "$FETCH_BODY" \
    --write-out '%{http_code}' "$url")" || status=''
  if [[ -z "$status" ]]; then
    FETCH_STATUS='000'
    return 1
  fi
  FETCH_STATUS="$status"
  return 0
}

fetch_failure() {
  if [[ "$FETCH_STATUS" == '000' ]]; then
    printf 'request failed'
  else
    printf 'HTTP %s' "$FETCH_STATUS"
  fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_surfaces() {
  [[ -f "$SURFACES_FILE" ]] || die 2 "missing surface contract: $SURFACES_FILE"
  jq -e 'type == "object"' "$SURFACES_FILE" >/dev/null 2>&1 ||
    die 2 "surface contract is not a JSON object: $SURFACES_FILE"

  UPDATES_BASE="$(jq -er '.updates_base_url' "$SURFACES_FILE")" ||
    die 2 'surface contract has no updates_base_url'
  WEB_BASE="$(jq -er '.web_base_url' "$SURFACES_FILE")" ||
    die 2 'surface contract has no web_base_url'
  WEB_VERSION_PATH="$(jq -er '.web_version_path' "$SURFACES_FILE")" ||
    die 2 'surface contract has no web_version_path'
  WEB_COMMIT_PATH="$(jq -er '.web_commit_path' "$SURFACES_FILE")" ||
    die 2 'surface contract has no web_commit_path'
  DOWNLOADS_BASE="$(jq -er '.downloads_base_url' "$SURFACES_FILE")" ||
    die 2 'surface contract has no downloads_base_url'
  EDGE_BASE="$(jq -er '.edge_alias_base_url' "$SURFACES_FILE")" ||
    die 2 'surface contract has no edge_alias_base_url'

  local base
  for base in "$UPDATES_BASE" "$WEB_BASE" "$DOWNLOADS_BASE" "$EDGE_BASE"; do
    [[ "$base" == http*://* && "$base" != */ ]] ||
      die 2 "surface contract base URL must be absolute without a trailing slash: $base"
  done

  ALIAS_ROWS=()
  local row
  while IFS= read -r row; do
    [[ -n "$row" ]] && ALIAS_ROWS+=("$row")
  done < <(jq -r '.downloads_client_aliases[] | [.path, .platform, .architecture, .format] | join("|")' "$SURFACES_FILE")
  [[ "${#ALIAS_ROWS[@]}" -gt 0 ]] || die 2 'surface contract has no downloads_client_aliases'

  DOWNLOADS_INSTALLERS=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && DOWNLOADS_INSTALLERS+=("$row")
  done < <(jq -r '.downloads_installer_paths[] | . as $path | $path + "|scripts/" + ($path | split("/") | last)' "$SURFACES_FILE")
  [[ "${#DOWNLOADS_INSTALLERS[@]}" -gt 0 ]] || die 2 'surface contract has no downloads_installer_paths'

  EDGE_INSTALLERS=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && EDGE_INSTALLERS+=("$row")
  done < <(jq -r '.edge_alias_installer_paths[]' "$SURFACES_FILE")
  [[ "${#EDGE_INSTALLERS[@]}" -gt 0 ]] || die 2 'surface contract has no edge_alias_installer_paths'

  local path
  for row in "${ALIAS_ROWS[@]}"; do
    path="${row%%|*}"
    [[ "$path" == /* ]] || die 2 "client alias path must be absolute: $path"
  done
  for row in "${DOWNLOADS_INSTALLERS[@]}"; do
    path="${row%%|*}"
    [[ "$path" == /* ]] || die 2 "installer path must be absolute: $path"
  done
}

load_contract() {
  CONTRACT_FILE="$TAG_TREE/release/release-contract.json"
  [[ -f "$CONTRACT_FILE" ]] ||
    die 2 "tag tree has no release/release-contract.json: $CONTRACT_FILE"

  CONTRACT_TAG="$(jq -er '.tag' "$CONTRACT_FILE")" ||
    die 2 'release contract has no tag'
  VERSION="$(jq -er '.version' "$CONTRACT_FILE")" ||
    die 2 'release contract has no version'
  BUILD="$(jq -er '.build_number' "$CONTRACT_FILE")" ||
    die 2 'release contract has no build_number'
  REPOSITORY="$(jq -er '.repository' "$CONTRACT_FILE")" ||
    die 2 'release contract has no repository'
  MANIFEST_NAME="$(jq -er '.channels.stable_manifest' "$CONTRACT_FILE")" ||
    die 2 'release contract has no channels.stable_manifest'
  APPCAST_NAME="$(jq -er '.channels.stable_appcast' "$CONTRACT_FILE")" ||
    die 2 'release contract has no channels.stable_appcast'

  [[ "$CONTRACT_TAG" == "$TAG" ]] ||
    die 2 "release contract tag '$CONTRACT_TAG' does not match the verified tag '$TAG'"
  [[ "$VERSION" == "${TAG#v}" ]] ||
    die 2 "release contract version '$VERSION' does not match tag '$TAG'"
}

alias_filename() {
  jq -er --arg platform "$1" --arg architecture "$2" --arg format "$3" '
    [.artifacts[]
      | select(.component == "client" and .platform == $platform
          and .architecture == $architecture and .format == $format and .public == true)]
    | if length == 1 then .[0].filename
      else error("expected exactly one public Client artifact") end' "$CONTRACT_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_updates_manifest() {
  local surface expected observed observed_version observed_tag observed_commit
  surface="$(host_label "$UPDATES_BASE")/$MANIFEST_NAME"
  expected="$VERSION / $TAG / $(short_commit "$TAG_COMMIT")"

  if ! fetch updates-manifest "$UPDATES_BASE/$MANIFEST_NAME"; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi
  cache_note "$surface" "$FETCH_HEADERS"
  if [[ "$FETCH_STATUS" != '200' ]]; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi
  if ! jq -e 'type == "object"' "$FETCH_BODY" >/dev/null 2>&1; then
    fail_row "$surface" "$expected" 'response is not a JSON object'
    return 0
  fi

  observed_version="$(jq -r '.version // ""' "$FETCH_BODY")"
  observed_tag="$(jq -r '.tag // ""' "$FETCH_BODY")"
  observed_commit="$(jq -r '.commit // ""' "$FETCH_BODY")"
  observed="${observed_version:-<missing>} / ${observed_tag:-<missing>} / $(short_commit "$observed_commit")"

  if [[ "$observed_version" == "$VERSION" && "$observed_tag" == "$TAG" &&
    "$observed_commit" == "$TAG_COMMIT" ]]; then
    ok_row "$surface" "$expected" "$observed"
  else
    fail_row "$surface" "$expected" "$observed"
  fi
}

appcast_enclosures() {
  awk '
    {
      line = $0
      while (match(line, /<enclosure[^>]*>/)) {
        tag = substr(line, RSTART, RLENGTH)
        version = attribute(tag, "sparkle:version")
        short = attribute(tag, "sparkle:shortVersionString")
        print version "\t" short
        line = substr(line, RSTART + RLENGTH)
      }
    }
    function attribute(tag, name,   value) {
      if (!match(tag, name "=\"[^\"]*\"")) return ""
      return substr(tag, RSTART + length(name) + 2, RLENGTH - length(name) - 3)
    }' "$1"
}

check_updates_appcast() {
  local surface expected observed rows count versions short_versions result version short
  surface="$(host_label "$UPDATES_BASE")/$APPCAST_NAME"
  expected="shortVersionString $VERSION, version $BUILD or $VERSION+$BUILD"

  if ! fetch updates-appcast "$UPDATES_BASE/$APPCAST_NAME"; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi
  cache_note "$surface" "$FETCH_HEADERS"
  if [[ "$FETCH_STATUS" != '200' ]]; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi

  rows="$(appcast_enclosures "$FETCH_BODY")"
  count=0
  versions=''
  short_versions=''
  result='ok'
  while IFS="$(printf '\t')" read -r version short; do
    [[ -n "$version$short" ]] || continue
    count=$((count + 1))
    versions="${versions}${versions:+, }$version"
    short_versions="${short_versions}${short_versions:+, }$short"
    [[ "$short" == "$VERSION" ]] || result='behind'
    case "$version" in
      "$BUILD" | "$VERSION+$BUILD") ;;
      *) result='behind' ;;
    esac
  done <<EOF
$rows
EOF

  if [[ "$count" -eq 0 ]]; then
    fail_row "$surface" "$expected" 'no enclosure element'
    return 0
  fi
  observed="$count enclosure(s): shortVersionString ${short_versions:-<missing>} / version ${versions:-<missing>}"
  if [[ "$result" == 'ok' ]]; then
    ok_row "$surface" "$expected" "$observed"
  else
    fail_row "$surface" "$expected" "$observed"
  fi
}

check_web_version() {
  local surface expected observed observed_version observed_build
  surface="$(host_label "$WEB_BASE")$WEB_VERSION_PATH"
  expected="$VERSION / build $BUILD"

  if ! fetch web-version "$WEB_BASE$WEB_VERSION_PATH"; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi
  cache_note "$surface" "$FETCH_HEADERS"
  if [[ "$FETCH_STATUS" != '200' ]]; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi
  if ! jq -e 'type == "object"' "$FETCH_BODY" >/dev/null 2>&1; then
    fail_row "$surface" "$expected" 'response is not a JSON object'
    return 0
  fi

  observed_version="$(jq -r '.version // ""' "$FETCH_BODY")"
  observed_build="$(jq -r '.build // ""' "$FETCH_BODY")"
  observed="${observed_version:-<missing>} / build ${observed_build:-<missing>}"

  if [[ "$observed_version" == "$VERSION" && "$observed_build" == "$BUILD" ]]; then
    ok_row "$surface" "$expected" "$observed"
  else
    fail_row "$surface" "$expected" "$observed"
  fi
}

check_web_commit() {
  local surface expected observed
  surface="$(host_label "$WEB_BASE")$WEB_COMMIT_PATH"
  expected="$(short_commit "$TAG_COMMIT")"

  if ! fetch web-commit "$WEB_BASE$WEB_COMMIT_PATH"; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi
  cache_note "$surface" "$FETCH_HEADERS"
  if [[ "$FETCH_STATUS" != '200' ]]; then
    fail_row "$surface" "$expected" "$(fetch_failure)"
    return 0
  fi

  observed="$(tr -d '\r\n' <"$FETCH_BODY")"
  if [[ "$observed" == "$TAG_COMMIT" ]]; then
    ok_row "$surface" "$expected" "$(short_commit "$observed")"
  else
    fail_row "$surface" "$expected" "$(short_commit "$observed")"
  fi
}

check_downloads_installers() {
  local row path source surface expected observed expected_sha observed_sha
  for row in ${DOWNLOADS_INSTALLERS[@]+"${DOWNLOADS_INSTALLERS[@]}"}; do
    path="${row%%|*}"
    source="${row#*|}"
    surface="$(host_label "$DOWNLOADS_BASE")$path"
    if [[ ! -f "$TAG_TREE/$source" ]]; then
      fail_row "$surface" "sha256 of $source" "missing $source in the tag tree"
      continue
    fi
    expected_sha="$(sha256_file "$TAG_TREE/$source")"
    expected="sha256 ${expected_sha:0:12}"

    if ! fetch "downloads-installer-$(basename "$path")" "$DOWNLOADS_BASE$path"; then
      fail_row "$surface" "$expected" "$(fetch_failure)"
      continue
    fi
    cache_note "$surface" "$FETCH_HEADERS"
    if [[ "$FETCH_STATUS" != '200' ]]; then
      fail_row "$surface" "$expected" "$(fetch_failure)"
      continue
    fi

    observed_sha="$(sha256_file "$FETCH_BODY")"
    if [[ "$observed_sha" == "$expected_sha" ]]; then
      ok_row "$surface" "$expected" "sha256 ${observed_sha:0:12}"
    else
      fail_row "$surface" "$expected" "sha256 ${observed_sha:0:12}"
    fi
  done
}

check_client_aliases() {
  local row path platform architecture format surface expected target observed filename location
  for row in ${ALIAS_ROWS[@]+"${ALIAS_ROWS[@]}"}; do
    IFS='|' read -r path platform architecture format <<<"$row"
    surface="$(host_label "$DOWNLOADS_BASE")$path"
    filename="$(alias_filename "$platform" "$architecture" "$format")"
    if [[ -z "$filename" ]]; then
      fail_row "$surface" "one public $platform/$architecture/$format Client artifact" \
        'release contract has no matching artifact'
      continue
    fi
    target="https://github.com/$REPOSITORY/releases/download/$TAG/$filename"
    expected="302 $target"

    if ! fetch "downloads-client-$platform" "$DOWNLOADS_BASE$path"; then
      fail_row "$surface" "$expected" "$(fetch_failure)"
      continue
    fi
    cache_note "$surface" "$FETCH_HEADERS"
    location="$(header_value "$FETCH_HEADERS" 'location')"
    observed="HTTP $FETCH_STATUS ${location:-<no Location>}"

    if [[ "$FETCH_STATUS" == '302' && "$location" == "$target" ]]; then
      ok_row "$surface" "$expected" "$observed"
    else
      fail_row "$surface" "$expected" "$observed"
    fi
  done
}

check_edge_aliases() {
  local path surface expected observed location
  for path in ${EDGE_INSTALLERS[@]+"${EDGE_INSTALLERS[@]}"}; do
    surface="$(host_label "$EDGE_BASE")$path"
    expected="302 $DOWNLOADS_BASE$path"

    if ! fetch "edge-installer-$(basename "$path")" "$EDGE_BASE$path"; then
      fail_row "$surface" "$expected" "$(fetch_failure)"
      continue
    fi
    cache_note "$surface" "$FETCH_HEADERS"
    location="$(header_value "$FETCH_HEADERS" 'location')"
    observed="HTTP $FETCH_STATUS ${location:-<no Location>}"

    if [[ "$FETCH_STATUS" == '302' && "$location" == "$DOWNLOADS_BASE$path" ]]; then
      ok_row "$surface" "$expected" "$observed"
    else
      fail_row "$surface" "$expected" "$observed"
    fi
  done
}

check_cache_policy() {
  local index=0 surface value
  while [[ "$index" -lt "${#CACHE_SURFACES[@]}" ]]; do
    surface="${CACHE_SURFACES[$index]}"
    value="${CACHE_VALUES[$index]}"
    case "$value" in
      *immutable*)
        warn_row "$surface" 'mutable path must not be immutable' "$value"
        ;;
    esac
    index=$((index + 1))
  done
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

mode_resolve() {
  [[ -n "$RELEASES_FILE" ]] || die 2 'resolve requires --releases <releases.json>'
  [[ -f "$RELEASES_FILE" ]] || die 2 "missing releases JSON: $RELEASES_FILE"
  jq -e 'type == "array"' "$RELEASES_FILE" >/dev/null 2>&1 ||
    die 2 "not a GitHub releases array: $RELEASES_FILE"

  local published_count expected_tag expected_created draft_tag draft_created window
  published_count="$(jq '[.[] | select(.draft == false and .prerelease == false)] | length' "$RELEASES_FILE")"
  if [[ "$published_count" == '0' ]]; then
    printf '::error::No published Stable release exists.\n'
    exit 1
  fi

  expected_tag="$(jq -r '[.[] | select(.draft == false and .prerelease == false)]
    | sort_by(.created_at) | last | .tag_name' "$RELEASES_FILE")"
  expected_created="$(jq -r '[.[] | select(.draft == false and .prerelease == false)]
    | sort_by(.created_at) | last | .created_at' "$RELEASES_FILE")"
  if [[ ! "$expected_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '::error::The newest published release %s is not a Stable release.\n' "$expected_tag"
    exit 1
  fi

  draft_tag="$(jq -r '[.[] | select(.draft == true)] | sort_by(.created_at) | last
    | if . == null then "" else .tag_name end' "$RELEASES_FILE")"
  draft_created="$(jq -r '[.[] | select(.draft == true)] | sort_by(.created_at) | last
    | if . == null then "" else .created_at end' "$RELEASES_FILE")"

  window='closed'
  if [[ -n "$draft_created" && "$draft_created" > "$expected_created" ]]; then
    window='open'
  fi

  printf 'newest published Stable release: %s (created %s)\n' "$expected_tag" "$expected_created"
  if [[ -n "$draft_created" ]]; then
    printf 'newest Draft release: %s (created %s)\n' "$draft_tag" "$draft_created"
  fi
  printf 'release window: %s\n' "$window"

  if [[ -n "$GITHUB_OUTPUT_FILE" ]]; then
    {
      printf 'window=%s\n' "$window"
      printf 'tag=%s\n' "$expected_tag"
    } >>"$GITHUB_OUTPUT_FILE"
  fi
  exit 0
}

mode_verify() {
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die 2 "verify requires a Stable --tag vX.Y.Z, got '$TAG'"
  [[ "$TAG_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    die 2 "verify requires a 40-character --tag-commit, got '$TAG_COMMIT'"
  [[ -d "$TAG_TREE" ]] || die 2 "verify requires an extracted --tag-tree: $TAG_TREE"

  load_surfaces
  load_contract

  printf 'Verifying Production surfaces for %s (%s)\n\n' "$TAG" "$(short_commit "$TAG_COMMIT")"

  check_updates_manifest
  check_updates_appcast
  check_web_version
  check_web_commit
  check_downloads_installers
  check_client_aliases
  check_edge_aliases
  check_cache_policy

  local summary
  summary="$(render_summary)"
  printf '%s\n\n' "$summary"
  if [[ -n "$SUMMARY_OUT" ]]; then
    printf '%s\n' "$summary" >"$SUMMARY_OUT"
  fi
  emit_annotations

  if [[ "$FAILURES" -gt 0 ]]; then
    printf '%s Production surface(s) behind %s.\n' "$FAILURES" "$TAG"
    exit 1
  fi
  if [[ "$WARNINGS" -gt 0 ]]; then
    printf 'Every Production surface serves %s; %s cache-policy warning(s).\n' "$TAG" "$WARNINGS"
  else
    printf 'Every Production surface serves %s.\n' "$TAG"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

parse_resolve() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --releases)
        [[ $# -ge 2 ]] || die 2 '--releases needs a value'
        RELEASES_FILE="$2"
        shift 2
        ;;
      --github-output)
        [[ $# -ge 2 ]] || die 2 '--github-output needs a value'
        GITHUB_OUTPUT_FILE="$2"
        shift 2
        ;;
      *) die 2 "unknown resolve option: $1" ;;
    esac
  done
  mode_resolve
}

parse_verify() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || die 2 '--tag needs a value'
        TAG="$2"
        shift 2
        ;;
      --tag-commit)
        [[ $# -ge 2 ]] || die 2 '--tag-commit needs a value'
        TAG_COMMIT="$2"
        shift 2
        ;;
      --tag-tree)
        [[ $# -ge 2 ]] || die 2 '--tag-tree needs a value'
        TAG_TREE="$2"
        shift 2
        ;;
      --surfaces)
        [[ $# -ge 2 ]] || die 2 '--surfaces needs a value'
        SURFACES_FILE="$2"
        shift 2
        ;;
      --fixtures)
        [[ $# -ge 2 ]] || die 2 '--fixtures needs a value'
        FIXTURES_DIR="$2"
        shift 2
        ;;
      --summary-out)
        [[ $# -ge 2 ]] || die 2 '--summary-out needs a value'
        SUMMARY_OUT="$2"
        shift 2
        ;;
      *) die 2 "unknown verify option: $1" ;;
    esac
  done
  mode_verify
}

main() {
  MODE="${1:-}"
  case "$MODE" in
    resolve)
      shift
      parse_resolve "$@"
      ;;
    verify)
      shift
      parse_verify "$@"
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die 2 "unknown mode: ${MODE:-<none>}"
      ;;
  esac
}

main "$@"
