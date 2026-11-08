#!/usr/bin/env bash
#
# Fixture coverage for scripts/release/verify_production_surfaces.sh. The suite
# is offline: every surface response is a recorded fixture directory, so it
# proves the verifier's identity comparisons, the Draft release window, the
# cache-policy warning, and the no-cache-busting request contract without
# touching Production.
set -uo pipefail

# shellcheck disable=SC1007 # CDPATH= clears an inherited CDPATH before cd; it is not an assignment.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERIFIER="$SCRIPT_DIR/verify_production_surfaces.sh"
SURFACES="$SCRIPT_DIR/production-surfaces.json"

ROOT="$(mktemp -d -t sanad-surface-verifier-test.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

TAG='v9.8.7'
VERSION='9.8.7'
BUILD='42'
COMMIT='0123456789abcdef0123456789abcdef01234567'
REPOSITORY='EastStarAI/sanad-agent'
FIXTURES="$ROOT/fixtures"
TAG_TREE="$ROOT/tag-tree"
SUMMARY="$ROOT/summary.md"
OUTPUTS="$ROOT/github-output.txt"

DOWNLOADS_BASE="$(jq -er '.downloads_base_url' "$SURFACES")" || exit 1
EDGE_BASE="$(jq -er '.edge_alias_base_url' "$SURFACES")" || exit 1
UPDATES_BASE="$(jq -er '.updates_base_url' "$SURFACES")" || exit 1
WEB_BASE="$(jq -er '.web_base_url' "$SURFACES")" || exit 1

INSTALLER_SH='#!/usr/bin/env bash
# Sanad installer fixture 9.8.7
'
INSTALLER_PS1='# Sanad installer fixture 9.8.7
'

host_of() {
  printf '%s' "${1#*://}"
}

CASES=0
FAILED_CASES=0
VERIFY_STATUS=0
VERIFY_OUTPUT=''

pass_case() {
  CASES=$((CASES + 1))
  printf 'ok   %s\n' "$1"
}

fail_case() {
  CASES=$((CASES + 1))
  FAILED_CASES=$((FAILED_CASES + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
  if [[ -n "$VERIFY_OUTPUT" ]]; then
    printf '--- verifier output ---\n%s\n--- end ---\n' "$VERIFY_OUTPUT"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

write_tag_tree() {
  mkdir -p "$TAG_TREE/release" "$TAG_TREE/scripts"
  jq -n \
    --arg tag "$TAG" \
    --arg version "$VERSION" \
    --argjson build "$BUILD" \
    --arg repository "$REPOSITORY" '
    {
      schema_version: 1,
      version: $version,
      build_number: $build,
      tag: $tag,
      channel: "stable",
      channels: {
        stable_manifest: "release-manifest.json",
        stable_appcast: "appcast.xml",
        rc_manifest: "release-manifest-rc.json",
        rc_appcast: "appcast-rc.xml"
      },
      repository: $repository,
      artifacts: [
        {
          component: "client", platform: "macos", architecture: "universal",
          format: "dmg", public: true,
          filename: ("sanad-client-" + $version + "-macos-universal.dmg")
        },
        {
          component: "client", platform: "windows", architecture: "x64",
          format: "exe", public: true,
          filename: ("sanad-client-" + $version + "-windows-x64.exe")
        },
        {
          component: "client", platform: "linux", architecture: "x64",
          format: "deb", public: true,
          filename: ("sanad-client-" + $version + "-linux-x64.deb")
        }
      ]
    }' >"$TAG_TREE/release/release-contract.json"
  printf '%s' "$INSTALLER_SH" >"$TAG_TREE/scripts/install.sh"
  printf '%s' "$INSTALLER_PS1" >"$TAG_TREE/scripts/install.ps1"
}

fixture() { # <id> <status> [cache-control]  (body on stdin)
  local id="$1" status="$2" cache="${3:-}"
  mkdir -p "$FIXTURES/$id"
  printf '%s\n' "$status" >"$FIXTURES/$id/status"
  : >"$FIXTURES/$id/headers"
  if [[ -n "$cache" ]]; then
    printf 'Cache-Control: %s\r\n' "$cache" >"$FIXTURES/$id/headers"
  fi
  cat >"$FIXTURES/$id/body"
}

redirect_fixture() { # <id> <location> [cache-control]
  local id="$1" location="$2" cache="${3:-}"
  mkdir -p "$FIXTURES/$id"
  printf '302\n' >"$FIXTURES/$id/status"
  {
    printf 'Location: %s\r\n' "$location"
    if [[ -n "$cache" ]]; then
      printf 'Cache-Control: %s\r\n' "$cache"
    fi
  } >"$FIXTURES/$id/headers"
  : >"$FIXTURES/$id/body"
}

client_filename() { # <platform> <architecture> <format>
  jq -er --arg platform "$1" --arg architecture "$2" --arg format "$3" '
    .artifacts[]
    | select(.component == "client" and .platform == $platform
        and .architecture == $architecture and .format == $format)
    | .filename' "$TAG_TREE/release/release-contract.json"
}

reset_fixtures() {
  rm -rf "$FIXTURES"
  mkdir -p "$FIXTURES"

  fixture updates-manifest 200 'no-store' <<JSON
{"schema_version":1,"version":"$VERSION","tag":"$TAG","commit":"$COMMIT","channel":"stable"}
JSON

  fixture updates-appcast 200 'no-store' <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>Version $VERSION</title>
      <enclosure url="https://github.com/$REPOSITORY/releases/download/$TAG/$(client_filename macos universal dmg)" length="1" type="application/octet-stream" sparkle:os="macos" sparkle:version="$BUILD" sparkle:shortVersionString="$VERSION" sparkle:edSignature="signature" />
      <enclosure url="https://github.com/$REPOSITORY/releases/download/$TAG/$(client_filename windows x64 exe)" length="2" type="application/octet-stream" sparkle:os="windows" sparkle:version="$VERSION+$BUILD" sparkle:shortVersionString="$VERSION" sparkle:dsaSignature="signature" />
    </item>
  </channel>
</rss>
XML

  fixture web-version 200 'no-cache, no-store, must-revalidate' <<JSON
{"version":"$VERSION","build":$BUILD}
JSON

  printf '%s\n' "$COMMIT" | fixture web-commit 200 'no-cache'
  fixture downloads-installer-install.sh 200 'public, max-age=600' <"$TAG_TREE/scripts/install.sh"
  fixture downloads-installer-install.ps1 200 'public, max-age=600' <"$TAG_TREE/scripts/install.ps1"

  redirect_fixture downloads-client-macos \
    "https://github.com/$REPOSITORY/releases/download/$TAG/$(client_filename macos universal dmg)"
  redirect_fixture downloads-client-windows \
    "https://github.com/$REPOSITORY/releases/download/$TAG/$(client_filename windows x64 exe)"
  redirect_fixture downloads-client-linux \
    "https://github.com/$REPOSITORY/releases/download/$TAG/$(client_filename linux x64 deb)"

  redirect_fixture edge-installer-install.sh "$DOWNLOADS_BASE/install.sh"
  redirect_fixture edge-installer-install.ps1 "$DOWNLOADS_BASE/install.ps1"
}

releases_fixture() { # <path> <newest-draft: yes|no>
  jq -n --arg draft "$2" '
    [
      {
        tag_name: "v9.8.7",
        draft: ($draft == "yes"),
        prerelease: false,
        created_at: "2026-11-08T19:37:14Z",
        published_at: (if $draft == "yes" then null else "2026-11-08T20:07:03Z" end)
      },
      {
        tag_name: "v9.8.8-rc.1",
        draft: false,
        prerelease: true,
        created_at: "2026-11-09T06:00:00Z",
        published_at: "2026-11-09T06:10:00Z"
      },
      {
        tag_name: "v9.8.6",
        draft: false,
        prerelease: false,
        created_at: "2026-10-23T01:03:24Z",
        published_at: "2026-10-23T01:24:00Z"
      }
    ]' >"$1"
}

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

run_verify() {
  rm -f "$SUMMARY"
  VERIFY_OUTPUT="$("$VERIFIER" verify \
    --tag "$TAG" \
    --tag-commit "$COMMIT" \
    --tag-tree "$TAG_TREE" \
    --surfaces "$SURFACES" \
    --fixtures "$FIXTURES" \
    --summary-out "$SUMMARY" 2>&1)"
  VERIFY_STATUS=$?
}

count_of() { # <pattern>
  printf '%s\n' "$VERIFY_OUTPUT" | grep -c "$1"
}

expect_pass() { # <case-name>
  local case_name="$1" errors
  run_verify
  if [[ "$VERIFY_STATUS" != '0' ]]; then
    fail_case "$case_name" "expected exit 0, got $VERIFY_STATUS"
    return 0
  fi
  errors="$(count_of '^::error::')"
  if [[ "$errors" != '0' ]]; then
    fail_case "$case_name" "expected no ::error:: annotation, got $errors"
    return 0
  fi
  pass_case "$case_name"
}

expect_behind() { # <case-name> <surface>
  local case_name="$1" surface="$2" errors
  run_verify
  if [[ "$VERIFY_STATUS" != '1' ]]; then
    fail_case "$case_name" "expected exit 1, got $VERIFY_STATUS"
    return 0
  fi
  errors="$(count_of '^::error::')"
  if [[ "$errors" != '1' ]]; then
    fail_case "$case_name" "expected exactly one ::error:: annotation, got $errors"
    return 0
  fi
  if ! printf '%s\n' "$VERIFY_OUTPUT" | grep -Fq "::error::Production surface $surface is behind"; then
    fail_case "$case_name" "no ::error:: annotation for $surface"
    return 0
  fi
  if ! printf '%s\n' "$VERIFY_OUTPUT" | grep -Fq "| $surface |"; then
    fail_case "$case_name" "summary table has no row for $surface"
    return 0
  fi
  pass_case "$case_name"
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

write_tag_tree

# 1. Every surface serves the tagged release.
reset_fixtures
expect_pass 'passes when every surface serves the tagged release'
if [[ "$VERIFY_STATUS" == '0' ]] && [[ -f "$SUMMARY" ]] && [[ "$(grep -c '| ok |' "$SUMMARY")" == '11' ]]; then
  pass_case 'writes one ok row per Production surface'
else
  fail_case 'writes one ok row per Production surface' 'expected 11 ok rows in the summary'
fi
if [[ "$VERIFY_STATUS" == '0' ]] && [[ "$(count_of '| warning |$')" != '0' ]]; then
  fail_case 'does not warn when no surface is immutable' 'unexpected cache-policy warning'
else
  pass_case 'does not warn when no surface is immutable'
fi

# 2. Release manifest identity.
reset_fixtures
fixture updates-manifest 200 'no-store' <<JSON
{"schema_version":1,"version":"9.8.6","tag":"$TAG","commit":"$COMMIT","channel":"stable"}
JSON
expect_behind 'fails when the manifest version is behind' "$(host_of "$UPDATES_BASE")/release-manifest.json"

reset_fixtures
fixture updates-manifest 200 'no-store' <<JSON
{"schema_version":1,"version":"$VERSION","tag":"v9.8.6","commit":"$COMMIT","channel":"stable"}
JSON
expect_behind 'fails when the manifest tag is behind' "$(host_of "$UPDATES_BASE")/release-manifest.json"

reset_fixtures
fixture updates-manifest 200 'no-store' <<JSON
{"schema_version":1,"version":"$VERSION","tag":"$TAG","commit":"1111111111111111111111111111111111111111","channel":"stable"}
JSON
expect_behind 'fails when the manifest commit is behind' "$(host_of "$UPDATES_BASE")/release-manifest.json"

# 3. Appcast identity.
reset_fixtures
fixture updates-appcast 200 'no-store' <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <enclosure url="https://github.com/$REPOSITORY/releases/download/$TAG/$(client_filename macos universal dmg)" length="1" type="application/octet-stream" sparkle:os="macos" sparkle:version="$BUILD" sparkle:shortVersionString="9.8.6" sparkle:edSignature="signature" />
      <enclosure url="https://github.com/$REPOSITORY/releases/download/$TAG/$(client_filename windows x64 exe)" length="2" type="application/octet-stream" sparkle:os="windows" sparkle:version="$VERSION+$BUILD" sparkle:shortVersionString="9.8.6" sparkle:dsaSignature="signature" />
    </item>
  </channel>
</rss>
XML
expect_behind 'fails when the appcast shortVersionString is behind' "$(host_of "$UPDATES_BASE")/appcast.xml"

# 4. Web shell markers.
reset_fixtures
fixture web-version 200 'no-cache' <<JSON
{"version":"9.8.6","build":$BUILD}
JSON
expect_behind 'fails when the Web version marker is behind' "$(host_of "$WEB_BASE")/version.json"

reset_fixtures
printf '%s\n' '2222222222222222222222222222222222222222' | fixture web-commit 200 'no-cache'
expect_behind 'fails when the Web source marker is behind' "$(host_of "$WEB_BASE")/sanad-public-sha.txt"

# 5. Installer bytes.
reset_fixtures
printf '%s\n' '#!/usr/bin/env bash' '# previous release' | fixture downloads-installer-install.sh 200 'public, max-age=600'
expect_behind 'fails when the published installer bytes are behind' "$(host_of "$DOWNLOADS_BASE")/install.sh"

# 6. Client convenience aliases and the edge aliases.
reset_fixtures
redirect_fixture downloads-client-macos \
  "https://github.com/$REPOSITORY/releases/download/v9.8.6/$(client_filename macos universal dmg)"
expect_behind 'fails when a Client alias still targets the previous tag' "$(host_of "$DOWNLOADS_BASE")/client/macos"

reset_fixtures
redirect_fixture edge-installer-install.sh "$DOWNLOADS_BASE/install.ps1"
expect_behind 'fails when an edge installer alias targets the wrong path' "$(host_of "$EDGE_BASE")/install.sh"

# 7. Mutable content declared immutable is a warning, never a failure.
reset_fixtures
fixture downloads-installer-install.sh 200 'public, max-age=31536000, immutable' <"$TAG_TREE/scripts/install.sh"
fixture downloads-installer-install.ps1 200 'public, max-age=31536000, immutable' <"$TAG_TREE/scripts/install.ps1"
run_verify
if [[ "$VERIFY_STATUS" != '0' ]]; then
  fail_case 'warns without failing when mutable content is immutable' "expected exit 0, got $VERIFY_STATUS"
elif [[ "$(count_of '^::warning::')" != '2' ]]; then
  fail_case 'warns without failing when mutable content is immutable' 'expected two ::warning:: annotations'
elif [[ "$(count_of '| warning |$')" != '2' ]]; then
  fail_case 'warns without failing when mutable content is immutable' 'expected two warning rows'
else
  pass_case 'warns without failing when mutable content is immutable'
fi

# 8. Release window resolution.
RELEASES="$ROOT/releases.json"
releases_fixture "$RELEASES" no
rm -f "$OUTPUTS"
VERIFY_OUTPUT="$("$VERIFIER" resolve --releases "$RELEASES" --github-output "$OUTPUTS" 2>&1)"
VERIFY_STATUS=$?
if [[ "$VERIFY_STATUS" == '0' ]] && grep -Fq 'release window: closed' <<<"$VERIFY_OUTPUT" &&
  grep -Fq 'tag=v9.8.7' "$OUTPUTS" && grep -Fq 'window=closed' "$OUTPUTS"; then
  pass_case 'resolves the newest published Stable release and ignores RCs'
else
  fail_case 'resolves the newest published Stable release and ignores RCs' 'unexpected resolve output'
fi

releases_fixture "$RELEASES" yes
rm -f "$OUTPUTS"
VERIFY_OUTPUT="$("$VERIFIER" resolve --releases "$RELEASES" --github-output "$OUTPUTS" 2>&1)"
VERIFY_STATUS=$?
if [[ "$VERIFY_STATUS" == '0' ]] && grep -Fq 'release window: open' <<<"$VERIFY_OUTPUT" &&
  grep -Fq 'newest Draft release: v9.8.7' <<<"$VERIFY_OUTPUT" && grep -Fq 'window=open' "$OUTPUTS"; then
  pass_case 'reports an open release window while the newest release is a Draft'
else
  fail_case 'reports an open release window while the newest release is a Draft' 'unexpected resolve output'
fi

jq -n '[{tag_name:"v9.8.7",draft:true,prerelease:false,created_at:"2026-11-08T19:37:14Z",published_at:null}]' >"$RELEASES"
VERIFY_OUTPUT="$("$VERIFIER" resolve --releases "$RELEASES" 2>&1)"
VERIFY_STATUS=$?
if [[ "$VERIFY_STATUS" == '1' ]] && grep -Fq '::error::No published Stable release exists.' <<<"$VERIFY_OUTPUT"; then
  pass_case 'fails when no published Stable release exists'
else
  fail_case 'fails when no published Stable release exists' "expected exit 1, got $VERIFY_STATUS"
fi

# 9. Request contract: no cache busting, explicit no-cache request header.
if grep -Fq -- "--header 'Cache-Control: no-cache'" "$VERIFIER" &&
  ! grep -Fq -- '--location' "$VERIFIER" &&
  ! grep -Eq '\?(source|release|rollback)=' "$VERIFIER"; then
  pass_case 'sends Cache-Control: no-cache and never cache-busts'
else
  fail_case 'sends Cache-Control: no-cache and never cache-busts' 'request contract changed'
fi

if jq -e 'has("updates_base_url") and has("downloads_base_url") and has("web_base_url") and has("edge_alias_base_url")' "$SURFACES" >/dev/null; then
  pass_case 'keeps public hostnames in the surface contract'
else
  fail_case 'keeps public hostnames in the surface contract' 'surface contract is incomplete'
fi

printf '\n%s case(s), %s failure(s)\n' "$CASES" "$FAILED_CASES"
if [[ "$FAILED_CASES" -gt 0 ]]; then
  exit 1
fi
echo 'production-surface-verifier=pass'
