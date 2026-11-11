#!/usr/bin/env bash
# Fixture tests for scripts/release/promote_release_candidate.sh.
#
# Every case in the promotion design's test plan is exercised here without a
# network, a token, or a real runner: a fake `gh` and a fake `fvm` sit first on
# `PATH`, the candidate bytes are real files with real checksums, and the
# promotion decision is read from the script's exit status and reason.
#
# The happy path must end in `promote`; every other case must end in the
# ordinary rebuild path with the named reason.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
subject="$repo_root/scripts/release/promote_release_candidate.sh"
test -x "$subject" || {
  printf 'Missing executable %s\n' "$subject" >&2
  exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

readonly REPO='EastStarAI/sanad-agent'
readonly SHA='5456598c365d2731c47c1609824b6d561432c6c0'
readonly OTHER_SHA='8c814889d47c73b1575c6b8b09f8dca568568cf8'
readonly TAG='v1.0.23'
readonly VERSION='1.0.23'
readonly BUILD=24
readonly CHANNEL='stable'
readonly WORKFLOW_ID=325185514
readonly RUN_ID=42645260900
readonly WORKFLOW_PATH='.github/workflows/release.yml'
# A fixed instant keeps every expiry comparison deterministic.
readonly NOW_EPOCH=1794355200

passed=0
failed=0

pass_case() {
  passed=$(( passed + 1 ))
  printf 'ok   %s\n' "$1"
}

fail_case() {
  failed=$(( failed + 1 ))
  printf 'FAIL %s\n     %s\n' "$1" "$2"
}

# run_case <description> <pass|fail> <expected text> <command...>
run_case() {
  local description="$1" expectation="$2" expected_text="$3"
  shift 3
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ "$expectation" == pass ]]; then
    if (( status != 0 )); then
      fail_case "$description" "expected success, got exit $status: $output"
      return
    fi
  else
    if (( status == 0 )); then
      fail_case "$description" "expected failure, got success: $output"
      return
    fi
    if [[ "$status" == 64 ]]; then
      fail_case "$description" "expected a promotion reason, got a usage error: $output"
      return
    fi
  fi
  if [[ -n "$expected_text" && "$output" != *"$expected_text"* ]]; then
    fail_case "$description" "expected '$expected_text' in: $output"
    return
  fi
  pass_case "$description"
}

# ---------------------------------------------------------------- fake tooling

install_fake_tools() {
  local bin="$1/bin"
  mkdir -p "$bin"
  cat >"$bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
fixture="${PROMOTE_FIXTURE:?}"
if [[ -f "$fixture/api-error" ]]; then
  printf 'gh: HTTP 502 Bad Gateway\n' >&2
  exit 1
fi
case "${1:-}" in
  api)
    path=''
    for argument in "$@"; do path="$argument"; done
    case "$path" in
      *'/runs?'*)
        cat "$fixture/runs.json"
        ;;
      *'/jobs?'*)
        id="$(printf '%s' "$path" | sed -n 's|^repos/[^/]*/[^/]*/actions/runs/\([0-9]*\)/jobs.*|\1|p')"
        cat "$fixture/jobs-$id.json"
        ;;
      *'/artifacts?'*)
        id="$(printf '%s' "$path" | sed -n 's|^repos/[^/]*/[^/]*/actions/runs/\([0-9]*\)/artifacts.*|\1|p')"
        cat "$fixture/artifacts-$id.json"
        ;;
      *'/actions/workflows/'*)
        cat "$fixture/workflow.json"
        ;;
      *)
        printf 'fake gh: unexpected api path %s\n' "$path" >&2
        exit 1
        ;;
    esac
    ;;
  attestation)
    if [[ -f "$fixture/attestation-fails" ]]; then
      printf 'Error: no attestations found for this artifact\n' >&2
      exit 1
    fi
    cat "$fixture/attestation.json"
    ;;
  *)
    printf 'fake gh: unexpected command %s\n' "${1:-}" >&2
    exit 1
    ;;
esac
FAKE_GH
  cat >"$bin/fvm" <<'FAKE_FVM'
#!/usr/bin/env bash
set -euo pipefail
fixture="${PROMOTE_FIXTURE:?}"
printf '%s\n' "$*" >>"$fixture/fvm-args.log"
if [[ -f "$fixture/tool-fails" ]]; then
  printf 'Release contract error: Artifact verification failed: sanad-agent-1.0.23-linux-x64\n' >&2
  exit 2
fi
exit 0
FAKE_FVM
  chmod +x "$bin/gh" "$bin/fvm"
}

# ------------------------------------------------------------------- fixtures

new_fixture() {
  local dir
  dir="$(mktemp -d "$fixture_root/case.XXXXXX")"
  mkdir -p "$dir/dist" "$dir/agent" "$dir/release"
  install_fake_tools "$dir"
  printf '%s\n' "$dir"
}

write_contract() {
  local dir="$1"
  jq -n --arg version "$VERSION" '{
    schema_version: 1,
    version: $version,
    build_number: 24,
    tag: ("v" + $version),
    channel: "stable",
    repository: "EastStarAI/sanad-agent",
    artifacts: [
      {component: "agent", platform: "linux", architecture: "x64", format: "executable",
       filename: ("sanad-agent-" + $version + "-linux-x64"), public: true},
      {component: "client", platform: "ios", architecture: "universal", format: "ipa",
       filename: ("sanad-client-" + $version + "-ios-universal.ipa"), public: false}
    ]
  }' >"$dir/release/release-contract.json"
}

# write_manifest <dir> [tag] [channel] [commit] [version] [build]
write_manifest() {
  local dir="$1"
  local tag="${2:-$TAG}" channel="${3:-$CHANNEL}" commit="${4:-$SHA}"
  local version="${5:-$VERSION}" build="${6:-$BUILD}"
  jq -n --arg tag "$tag" --arg channel "$channel" --arg commit "$commit" \
    --arg version "$version" --argjson build "$build" '{
    schema_version: 1,
    version: $version,
    build_number: $build,
    tag: $tag,
    commit: $commit,
    channel: $channel,
    repository: "EastStarAI/sanad-agent",
    artifacts: [
      {component: "agent", platform: "linux", architecture: "x64", format: "executable",
       filename: ("sanad-agent-" + $version + "-linux-x64"), public: true,
       update_signature: "update signature"}
    ]
  }' >"$dir/dist/release-manifest.json"
}

# Reproduces what `assemble` produces: public artifact checksums plus the Appcast.
write_sums() {
  local dir="$1"
  ( cd "$dir/dist" && sha256sum "sanad-agent-$VERSION-linux-x64" appcast.xml >SHA256SUMS )
}

make_candidate() {
  local dir="$1"
  printf 'agent binary\n' >"$dir/dist/sanad-agent-$VERSION-linux-x64"
  printf 'update signature\n' >"$dir/dist/sanad-agent-$VERSION-linux-x64.update-signature"
  printf 'private ipa\n' >"$dir/dist/sanad-client-$VERSION-ios-universal.ipa"
  printf 'spdx\n' >"$dir/dist/sanad-$VERSION.spdx.json"
  printf 'appcast\n' >"$dir/dist/appcast.xml"
  mkdir -p "$dir/dist/native/linux-x64"
  printf 'library\n' >"$dir/dist/native/linux-x64/libsanad_whisper.so"
  jq -n '{native_directory: "linux-x64", files: {"libsanad_whisper.so": {}}}' \
    >"$dir/dist/stt-runtime-linux-x64.json"
  write_manifest "$dir"
  write_sums "$dir"
  write_contract "$dir"
}

# write_runs <dir> [field=value ...]
write_runs() {
  local dir="$1"
  shift
  local run_id="$RUN_ID" path="$WORKFLOW_PATH" workflow_id="$WORKFLOW_ID" event=workflow_dispatch
  local branch=main head_sha="$SHA" repository="$REPO" conclusion=success run_number=100
  local override field value
  for override in "$@"; do
    field="${override%%=*}"
    value="${override#*=}"
    case "$field" in
      run_id) run_id="$value" ;;
      path) path="$value" ;;
      workflow_id) workflow_id="$value" ;;
      event) event="$value" ;;
      branch) branch="$value" ;;
      head_sha) head_sha="$value" ;;
      repository) repository="$value" ;;
      conclusion) conclusion="$value" ;;
      run_number) run_number="$value" ;;
      *) printf 'write_runs: unknown field %s\n' "$field" >&2; exit 1 ;;
    esac
  done
  jq -n --arg id "$run_id" --arg path "$path" --arg workflow_id "$workflow_id" \
    --arg event "$event" --arg branch "$branch" --arg head_sha "$head_sha" \
    --arg repository "$repository" --arg conclusion "$conclusion" \
    --arg run_number "$run_number" '{
    total_count: 1,
    workflow_runs: [
      {id: ($id | tonumber), path: $path, workflow_id: ($workflow_id | tonumber),
       event: $event, head_branch: $branch, head_sha: $head_sha,
       head_repository: {full_name: $repository}, conclusion: $conclusion,
       run_number: ($run_number | tonumber)}
    ]
  }' >"$dir/runs.json"
}

# append_run <dir> <run_number> <conclusion> <workflow_id> <releases> ...
# Adds a second, older run whose jobs and artifact are apocryphal: it only has to
# win the sort when the newest run is rejected.
append_run() {
  local dir="$1" run_id="$2" run_number="$3"
  jq --arg id "$run_id" --arg run_number "$run_number" '
    .workflow_runs += [{
      id: ($id | tonumber), path: ".github/workflows/release.yml",
      workflow_id: 325185514, event: "workflow_dispatch", head_branch: "main",
      head_sha: "5456598c365d2731c47c1609824b6d561432c6c0",
      head_repository: {full_name: "EastStarAI/sanad-agent"},
      conclusion: "success", run_number: ($run_number | tonumber)
    }] | .total_count = (.workflow_runs | length)' \
    "$dir/runs.json" >"$dir/runs.json.tmp"
  mv "$dir/runs.json.tmp" "$dir/runs.json"
}

# write_jobs <dir> <run-id> [job=conclusion ...]
write_jobs() {
  local dir="$1" run_id="$2"
  shift 2
  local validate=success agent=success client_linux_web=success client_android=success
  local client_macos=success client_windows=success client_ios=success assemble=success
  local override field value
  for override in "$@"; do
    field="${override%%=*}"
    value="${override#*=}"
    case "$field" in
      validate) validate="$value" ;;
      agent) agent="$value" ;;
      client-linux-web) client_linux_web="$value" ;;
      client-android) client_android="$value" ;;
      client-macos) client_macos="$value" ;;
      client-windows) client_windows="$value" ;;
      client-ios) client_ios="$value" ;;
      assemble) assemble="$value" ;;
      *) printf 'write_jobs: unknown job %s\n' "$field" >&2; exit 1 ;;
    esac
  done
  jq -n --arg validate "$validate" --arg agent "$agent" \
    --arg client_linux_web "$client_linux_web" --arg client_android "$client_android" \
    --arg client_macos "$client_macos" --arg client_windows "$client_windows" \
    --arg client_ios "$client_ios" --arg assemble "$assemble" '{
    total_count: 8,
    jobs: [
      {name: "validate", conclusion: $validate},
      {name: "agent (ubuntu-24.04, linux, x64, release-build)", conclusion: $agent},
      {name: "client-linux-web", conclusion: $client_linux_web},
      {name: "client-android", conclusion: $client_android},
      {name: "client-macos", conclusion: $client_macos},
      {name: "client-windows", conclusion: $client_windows},
      {name: "client-ios", conclusion: $client_ios},
      {name: "assemble", conclusion: $assemble}
    ]
  }' >"$dir/jobs-$run_id.json"
}

# write_artifacts <dir> <run-id> [field=value ...]
write_artifacts() {
  local dir="$1" run_id="$2"
  shift 2
  local expired=false name="$CHANNEL-release-candidate" count=1
  local expires_at
  expires_at="$(jq -rn --argjson now "$NOW_EPOCH" '$now + 864000 | todate')"
  local override field value
  for override in "$@"; do
    field="${override%%=*}"
    value="${override#*=}"
    case "$field" in
      expired) expired="$value" ;;
      name) name="$value" ;;
      count) count="$value" ;;
      expires_at) expires_at="$value" ;;
      *) printf 'write_artifacts: unknown field %s\n' "$field" >&2; exit 1 ;;
    esac
  done
  jq -n --arg name "$name" --arg expires_at "$expires_at" --arg expired "$expired" \
    --argjson count "$count" '{
    total_count: $count,
    artifacts: [range(0; $count) | {
      id: (. + 1),
      name: $name,
      expired: ($expired == "true"),
      expires_at: $expires_at,
      digest: ("sha256:" + ("a" * 64))
    }]
  }' >"$dir/artifacts-$run_id.json"
}

write_workflow() {
  local dir="$1"
  jq -n --arg id "$WORKFLOW_ID" --arg path "$WORKFLOW_PATH" \
    '{id: ($id | tonumber), path: $path}' >"$dir/workflow.json"
}

# write_attestation <dir> [run-id]
write_attestation() {
  local dir="$1" run_id="${2:-$RUN_ID}"
  jq -n --arg uri "https://github.com/$REPO/actions/runs/$run_id/attempts/2" '[{
    attestation: {bundle: {}},
    verificationResult: {
      verifiedIdentity: {runnerEnvironment: "github-hosted"},
      statement: {predicate: {runDetails: {metadata: {invocationId: $uri}}}}
    }
  }]' >"$dir/attestation.json"
}

# A complete, promotable candidate: every selection and verification rule passes.
make_promotable() {
  local dir="$1" run_id="${2:-$RUN_ID}" run_number="${3:-100}"
  make_candidate "$dir"
  write_runs "$dir" run_id="$run_id" run_number="$run_number"
  write_jobs "$dir" "$run_id"
  write_artifacts "$dir" "$run_id"
  write_workflow "$dir"
  write_attestation "$dir" "$run_id"
}

select_case() {
  local description="$1" dir="$2" expectation="$3" expected_text="$4"
  shift 4
  run_case "$description" "$expectation" "$expected_text" \
    env PATH="$dir/bin:$PATH" PROMOTE_FIXTURE="$dir" \
    "$subject" select --repo "$REPO" --sha "$SHA" --channel "$CHANNEL" \
    --workflow-id "$WORKFLOW_ID" --contract "$dir/release/release-contract.json" \
    --now "$NOW_EPOCH" "$@"
}

verify_case() {
  local description="$1" dir="$2" expectation="$3" expected_text="$4"
  shift 4
  run_case "$description" "$expectation" "$expected_text" \
    env PATH="$dir/bin:$PATH" PROMOTE_FIXTURE="$dir" \
    "$subject" verify --repo "$REPO" --sha "$SHA" --channel "$CHANNEL" \
    --run-id "$RUN_ID" --tag "$TAG" --version "$VERSION" --build "$BUILD" \
    --manifest release-manifest.json --dir "$dir/dist" --agent-dir "$dir/agent" \
    --contract "$dir/release/release-contract.json" "$@"
}

verdict_case() {
  local description="$1" expectation="$2" expected_text="$3"
  shift 3
  run_case "$description" "$expectation" "$expected_text" "$subject" verdict "$@"
}

# ------------------------------------------------------------- selection cases

dir="$(new_fixture)"
make_promotable "$dir"
select_case 'select: a promotable candidate is chosen' "$dir" pass "candidate_run_id=$RUN_ID"
select_case 'select: the choice carries the artifact digest' "$dir" pass 'candidate_artifact_digest=sha256:'
run_case 'select: the workflow identity is resolved from the API when unnamed' pass "candidate_run_id=$RUN_ID" \
  env PATH="$dir/bin:$PATH" PROMOTE_FIXTURE="$dir" \
  "$subject" select --repo "$REPO" --sha "$SHA" --channel "$CHANNEL" \
  --contract "$dir/release/release-contract.json" --now "$NOW_EPOCH"

dir="$(new_fixture)"
make_candidate "$dir"
jq -n '{total_count: 0, workflow_runs: []}' >"$dir/runs.json"
write_artifacts "$dir" "$RUN_ID"
write_attestation "$dir"
select_case 'select: no candidate at all' "$dir" fail 'no successful workflow_dispatch run'

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" conclusion=failure
select_case 'select: the newest candidate concluded failure' "$dir" fail "concluded 'failure', not success"

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" conclusion=cancelled
select_case 'select: the newest candidate was cancelled' "$dir" fail "concluded 'cancelled', not success"

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" head_sha="$OTHER_SHA"
select_case 'select: the candidate was built at another commit' "$dir" fail "was built at $OTHER_SHA, not $SHA"

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" branch=feature/candidate
select_case 'select: the candidate was built on another branch' "$dir" fail "branch 'feature/candidate', not main"

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" event=push
select_case 'select: the candidate came from a push, not a dispatch' "$dir" fail "triggered by 'push', not workflow_dispatch"

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" path=.github/workflows/ci.yml
select_case 'select: the run belongs to another workflow file' "$dir" fail 'runs .github/workflows/ci.yml'

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" workflow_id=123
select_case 'select: the run belongs to another workflow id' "$dir" fail 'belongs to workflow 123'

dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" repository=someone/else
select_case 'select: the run was built in a fork' "$dir" fail 'was built in someone/else'

dir="$(new_fixture)"
make_promotable "$dir"
write_jobs "$dir" "$RUN_ID" assemble=skipped
select_case 'select: a required job was skipped in the latest attempt' "$dir" fail 'job assemble did not succeed in the latest attempt'

dir="$(new_fixture)"
make_promotable "$dir"
write_jobs "$dir" "$RUN_ID" client-ios=failure
select_case 'select: a required job failed in the latest attempt' "$dir" fail 'job client-ios did not succeed in the latest attempt'

dir="$(new_fixture)"
make_promotable "$dir"
write_jobs "$dir" "$RUN_ID" agent=failure
select_case 'select: an Agent lane failed in the latest attempt' "$dir" fail 'an Agent lane did not succeed'

dir="$(new_fixture)"
make_promotable "$dir"
write_artifacts "$dir" "$RUN_ID" count=0
select_case 'select: the candidate artifact is missing' "$dir" fail 'has no stable-release-candidate artifact'

dir="$(new_fixture)"
make_promotable "$dir"
write_artifacts "$dir" "$RUN_ID" count=2
select_case 'select: the candidate artifact is duplicated' "$dir" fail 'more than one stable-release-candidate'

dir="$(new_fixture)"
make_promotable "$dir"
jq '.total_count = 101' "$dir/artifacts-$RUN_ID.json" >"$dir/artifacts.tmp"
mv "$dir/artifacts.tmp" "$dir/artifacts-$RUN_ID.json"
select_case 'select: a paginated artifact list is ambiguous' "$dir" fail 'more artifacts than one page'

dir="$(new_fixture)"
make_promotable "$dir"
write_artifacts "$dir" "$RUN_ID" expired=true
select_case 'select: the candidate artifact is expired' "$dir" fail 'is expired'

dir="$(new_fixture)"
make_promotable "$dir"
near="$(jq -rn --argjson now "$NOW_EPOCH" '$now + 1800 | todate')"
write_artifacts "$dir" "$RUN_ID" expires_at="$near"
select_case 'select: the candidate artifact expires within the hour' "$dir" fail 'leaves no more than 3600 seconds'

dir="$(new_fixture)"
make_promotable "$dir"
printf 'boom\n' >"$dir/api-error"
select_case 'select: the API fails' "$dir" fail 'the workflow runs API is unavailable'

# The newest dispatch produced an `rc` candidate; the older one is this tag's.
dir="$(new_fixture)"
make_promotable "$dir"
write_runs "$dir" run_id=42630000001 run_number=200
write_jobs "$dir" 42630000001
write_artifacts "$dir" 42630000001 name=rc-release-candidate
append_run "$dir" "$RUN_ID" 100
write_jobs "$dir" "$RUN_ID"
write_artifacts "$dir" "$RUN_ID"
select_case 'select: the wrong-channel newest candidate is passed over' "$dir" pass "candidate_run_id=$RUN_ID"

# --------------------------------------------------------- verification cases

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
verify_case 'verify: a verified candidate passes' "$dir" pass "candidate-verified=$RUN_ID"
fvm_log="$(cat "$dir/fvm-args.log" 2>/dev/null || true)"
if [[ "$fvm_log" == *'dart run tool/release_tool.dart verify-manifest'* &&
  "$fvm_log" == *'--manifest '*release-manifest.json* &&
  "$fvm_log" == *'--artifacts '* ]]; then
  pass_case 'verify: rule 2 runs the same tool command as assemble'
else
  fail_case 'verify: rule 2 runs the same tool command as assemble' \
    "unexpected fvm invocation: $fvm_log"
fi

for mismatch in \
  "tag=v0.0.1:tag v0.0.1 is not $TAG" \
  "channel=rc:channel rc is not $CHANNEL" \
  "commit=$OTHER_SHA:commit $OTHER_SHA is not $SHA" \
  "version=9.9.9:version 9.9.9 is not $VERSION" \
  "build=99:build 99 is not $BUILD"; do
  field="${mismatch%%=*}"
  expected="${mismatch#*:}"
  dir="$(new_fixture)"
  make_candidate "$dir"
  write_attestation "$dir"
  case "$field" in
    tag) write_manifest "$dir" v0.0.1 ;;
    channel) write_manifest "$dir" "$TAG" rc ;;
    commit) write_manifest "$dir" "$TAG" "$CHANNEL" "$OTHER_SHA" ;;
    version) write_manifest "$dir" "$TAG" "$CHANNEL" "$SHA" 9.9.9 ;;
    build) write_manifest "$dir" "$TAG" "$CHANNEL" "$SHA" "$VERSION" 99 ;;
  esac
  verify_case "verify: the manifest $field does not match the tag run" "$dir" fail "$expected"
done

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'not a release\n' >"$dir/dist/release-manifest.json"
verify_case 'verify: the manifest is not JSON' "$dir" fail 'is not readable JSON'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'tampered\n' >"$dir/tool-fails"
verify_case 'verify: verify-manifest rejects the artifact set' "$dir" fail 'verify-manifest rejected the candidate'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'flipped byte\n' >"$dir/dist/sanad-agent-$VERSION-linux-x64"
verify_case 'verify: one flipped byte fails the checksum file' "$dir" fail 'does not match the candidate bytes'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'smuggled\n' >"$dir/dist/unexpected.txt"
verify_case 'verify: an unlisted file is refused' "$dir" fail 'does not account for: unexpected.txt'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'smuggled\n' >"$dir/dist/.unexpected"
verify_case 'verify: a hidden unlisted file is refused' "$dir" fail 'does not account for: .unexpected'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
mkdir "$dir/dist/scratch"
verify_case 'verify: an unexpected directory is refused' "$dir" fail 'does not account for: scratch/'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
rm "$dir/dist/sanad-$VERSION.spdx.json"
verify_case 'verify: the required SBOM may not be missing' "$dir" fail 'missing required release file'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
rm "$dir/dist/sanad-client-$VERSION-ios-universal.ipa"
verify_case 'verify: a private contract artifact may not be missing' "$dir" fail 'missing required release file'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'extra\n' >"$dir/dist/native/linux-x64/unexpected.so"
verify_case 'verify: an extra native staging file is refused' "$dir" fail 'native staging file set'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
mkdir "$dir/dist/native/unexpected-empty-directory"
verify_case 'verify: an extra native staging directory is refused' "$dir" fail 'native staging file set'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
mv "$dir/dist/sanad-$VERSION.spdx.json" "$dir/sbom.json"
ln -s "$dir/sbom.json" "$dir/dist/sanad-$VERSION.spdx.json"
verify_case 'verify: a symlink is refused' "$dir" fail 'unsafe or unaccounted files'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
rm "$dir/dist/sanad-$VERSION.spdx.json"
mkfifo "$dir/dist/sanad-$VERSION.spdx.json"
verify_case 'verify: a special file is refused' "$dir" fail 'unsafe or unaccounted files'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'unexpected signature\n' >"$dir/dist/appcast.xml.update-signature"
verify_case 'verify: an undeclared update-signature sidecar is refused' "$dir" fail 'does not account for: appcast.xml.update-signature'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
printf 'x\n' >"$dir/attestation-fails"
verify_case 'verify: a failing attestation is refused' "$dir" fail 'does not verify'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir" 42630000000
verify_case 'verify: an attestation naming another run is refused' "$dir" fail 'not candidate run'

dir="$(new_fixture)"
make_candidate "$dir"
jq -n '[{attestation: {}, verificationResult: {}}]' >"$dir/attestation.json"
verify_case 'verify: an attestation with no producing run is refused' "$dir" fail 'names no producing run'

dir="$(new_fixture)"
make_candidate "$dir"
write_attestation "$dir"
rm "$dir/release/release-contract.json"
verify_case 'verify: a missing release contract fails closed' "$dir" fail 'release contract'

# ------------------------------------------------------------- verdict cases

verdict_case 'verdict: enabled promotes a fully proved candidate' pass 'mode=promote' \
  --switch enabled --selection ok --verification ok
verdict_case 'verdict: enabled rebuilds when verification fails' pass 'mode=rebuild' \
  --switch enabled --selection ok --verification failed
verdict_case 'verdict: enabled rebuilds when selection fails' pass 'mode=rebuild' \
  --switch enabled --selection failed --verification failed
verdict_case 'verdict: shadow reports would-promote but rebuilds' pass 'verdict=would-promote' \
  --switch shadow --selection ok --verification ok
verdict_case 'verdict: shadow never promotes' pass 'mode=rebuild' \
  --switch shadow --selection ok --verification ok
verdict_case 'verdict: shadow reports would-rebuild on a failed check' pass 'verdict=would-rebuild' \
  --switch shadow --selection ok --verification failed
verdict_case 'verdict: an unset switch skips selection' pass 'verdict=skipped' \
  --switch '' --selection failed --verification failed
verdict_case 'verdict: an unset switch rebuilds' pass 'mode=rebuild' \
  --switch '' --selection failed --verification failed
verdict_case 'verdict: an unknown switch skips selection' pass 'verdict=skipped' \
  --switch Enabled --selection ok --verification ok
verdict_case 'verdict: a multiline reason is flattened' pass 'reason=flat reason' \
  --switch shadow --selection ok --verification ok --reason $'flat\nreason'

# ------------------------------------------------------------------- summary

printf '\n%s passed, %s failed\n' "$passed" "$failed"
if (( failed > 0 )); then
  exit 1
fi
