#!/usr/bin/env bash
# Select and verify the release candidate a tag run may promote instead of
# rebuilding it.
#
# A release is built twice today: once by a `workflow_dispatch` validation run
# on `main`, and again by the tag run. The tag run therefore publishes bytes the
# validation run never proved, while the bytes it did prove - signed, notarized,
# tested, manifested, SBOM-ed and attested on the same commit, the same workflow
# file and the same release contract - are thrown away. Promotion publishes the
# proved bytes.
#
# Every rejection here is a non-zero exit carrying exactly one
# `promotion-reason: ` line on stderr. The caller turns that into the ordinary
# rebuild path, so an unreadable API, an unexpected response shape, a missing
# artifact, a failed attestation, or a defect in this script can only ever cost
# the saving. It cannot publish an unverified byte.
#
# Commands
#   select   Apply the selection rules and print the chosen candidate. Fails
#            closed with a reason when no candidate can be proved.
#   verify   Apply the verification rules to a downloaded candidate. Every rule
#            is independent; the first failure ends the command.
#   verdict  Map the rollout switch and the two outcomes to the mode the tag run
#            must use. Pure: reads no network, writes nothing but its verdict.
#
# Dependencies: bash, gh, jq, sha256sum, fvm. No secret is read: the caller
# supplies the workflow token through `GH_TOKEN`.
#
# `verify` runs `tool/release_tool.dart`, so the caller must have resolved the
# Agent dependencies first (`fvm flutter pub get` in `agent/`, exactly as the
# `assemble` job does).
#
# This script stays compatible with bash 3.2 so the fixture suite can run on a
# developer machine as well as on the Ubuntu runner.

set -euo pipefail

readonly DEFAULT_WORKFLOW_PATH='.github/workflows/release.yml'
readonly DEFAULT_CONTRACT='release/release-contract.json'
readonly DEFAULT_AGENT_DIR='agent'
# Signing Environments accept only `main`, so a candidate can only carry
# `refs/heads/main` provenance. Pinning it here is what stops a tag-run or
# branch-run attestation from being accepted as candidate evidence.
readonly SIGNER_REF='refs/heads/main'
readonly RUNS_PER_PAGE=20
# The candidate artifact expires 14 days after it is made, which is the whole
# promotion window. Requiring an hour of headroom keeps a promotion from
# downloading a candidate that expires mid-job.
readonly DEFAULT_MIN_REMAINING_SECONDS=3600
# Jobs every promotable candidate must have run and passed. `agent` is the
# matrix job, so it is counted separately from the contract.
readonly REQUIRED_JOBS='validate client-linux-web client-android client-macos client-windows client-ios assemble'

REPO=''
SHA=''
CHANNEL=''
WORKFLOW_PATH="$DEFAULT_WORKFLOW_PATH"
WORKFLOW_ID=''
DIR=''
RUN_ID=''
TAG=''
VERSION=''
BUILD=''
MANIFEST=''
ARTIFACT_VERSION=''
CONTRACT="$DEFAULT_CONTRACT"
AGENT_DIR="$DEFAULT_AGENT_DIR"
MIN_REMAINING_SECONDS="$DEFAULT_MIN_REMAINING_SECONDS"
NOW=''
SWITCH=''
SWITCH_SET=false
SELECTION=''
VERIFICATION=''
REASON_TEXT=''
WORK_DIR=''

cleanup() { [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"; }

reason() { printf 'promotion-reason: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*" >&2; }
die() {
  reason "$*"
  exit 1
}
usage_error() {
  printf 'promote_release_candidate: %s\n' "$*" >&2
  exit 64
}
usage() {
  cat >&2 <<'USAGE'
Usage:
  promote_release_candidate.sh select --repo OWNER/REPO --sha COMMIT --channel stable|rc
      [--workflow-path PATH] [--workflow-id ID] [--contract FILE]
      [--min-remaining-seconds N] [--now EPOCH]
  promote_release_candidate.sh verify --repo OWNER/REPO --sha COMMIT --channel stable|rc
      --run-id ID --tag TAG --version X.Y.Z --build N --manifest FILE --dir DIR
      [--artifact-version V] [--workflow-path PATH] [--contract FILE]
      [--agent-dir DIR]
  promote_release_candidate.sh verdict --switch VALUE --selection ok|failed
      --verification ok|failed [--reason TEXT]
USAGE
  exit 64
}

require_value() {
  (( $# >= 2 )) || usage_error "missing value for $1"
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --repo) require_value "$@"; REPO="$2"; shift 2 ;;
      --sha) require_value "$@"; SHA="$2"; shift 2 ;;
      --channel) require_value "$@"; CHANNEL="$2"; shift 2 ;;
      --workflow-path) require_value "$@"; WORKFLOW_PATH="$2"; shift 2 ;;
      --workflow-id) require_value "$@"; WORKFLOW_ID="$2"; shift 2 ;;
      --dir) require_value "$@"; DIR="$2"; shift 2 ;;
      --run-id) require_value "$@"; RUN_ID="$2"; shift 2 ;;
      --tag) require_value "$@"; TAG="$2"; shift 2 ;;
      --version) require_value "$@"; VERSION="$2"; shift 2 ;;
      --build) require_value "$@"; BUILD="$2"; shift 2 ;;
      --manifest) require_value "$@"; MANIFEST="$2"; shift 2 ;;
      --artifact-version) require_value "$@"; ARTIFACT_VERSION="$2"; shift 2 ;;
      --contract) require_value "$@"; CONTRACT="$2"; shift 2 ;;
      --agent-dir) require_value "$@"; AGENT_DIR="$2"; shift 2 ;;
      --min-remaining-seconds) require_value "$@"; MIN_REMAINING_SECONDS="$2"; shift 2 ;;
      --now) require_value "$@"; NOW="$2"; shift 2 ;;
      --switch) require_value "$@"; SWITCH="$2"; SWITCH_SET=true; shift 2 ;;
      --selection) require_value "$@"; SELECTION="$2"; shift 2 ;;
      --verification) require_value "$@"; VERIFICATION="$2"; shift 2 ;;
      --reason) require_value "$@"; REASON_TEXT="$2"; shift 2 ;;
      -h | --help) usage ;;
      *) usage_error "unknown option $1" ;;
    esac
  done
}

require_release_identity() {
  [[ -n "$REPO" ]] || usage_error '--repo is required'
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    usage_error '--repo must be OWNER/REPO'
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] ||
    usage_error '--sha must be a full 40-character commit id'
  [[ "$CHANNEL" == stable || "$CHANNEL" == rc ]] ||
    usage_error '--channel must be stable or rc'
  [[ "$WORKFLOW_PATH" =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] ||
    usage_error '--workflow-path must be a workflow file under .github/workflows'
}

# One API read. Any transport, authentication, rate-limit or HTTP failure is a
# failed check, never an empty result.
api() {
  local path="$1"
  gh api --method GET -H 'Accept: application/vnd.github+json' "$path"
}

# True when the newline-separated haystack contains the needle as a whole line.
contains_line() {
  [[ $'\n'"$2"$'\n' == *$'\n'"$1"$'\n'* ]]
}

# The Agent lane count is a property of the release contract, not a number this
# script may restate: the contract is the single declaration of the release
# matrix, and `release-security` already fails when it drifts from the workflow.
expected_agent_lanes() {
  [[ -f "$CONTRACT" ]] ||
    die "the release contract $CONTRACT is unavailable, so the Agent lanes cannot be bounded"
  local lanes
  lanes="$(jq -r '[.artifacts[]? | select(.component == "agent")] | length' "$CONTRACT")" ||
    die "the release contract $CONTRACT is not readable JSON"
  [[ "$lanes" =~ ^[1-9][0-9]*$ ]] ||
    die "the release contract $CONTRACT declares no Agent artifact"
  printf '%s\n' "$lanes"
}

resolve_workflow_id() {
  if [[ -n "$WORKFLOW_ID" ]]; then
    [[ "$WORKFLOW_ID" =~ ^[1-9][0-9]*$ ]] || die '--workflow-id must be numeric'
    printf '%s\n' "$WORKFLOW_ID"
    return 0
  fi
  local resolved
  resolved="$(api "repos/$REPO/actions/workflows/${WORKFLOW_PATH##*/}" | jq -r '.id // empty')" ||
    die "cannot read the workflow identity of $WORKFLOW_PATH"
  [[ "$resolved" =~ ^[1-9][0-9]*$ ]] ||
    die "the API returned no workflow identity for $WORKFLOW_PATH"
  printf '%s\n' "$resolved"
}

# An ISO-8601 UTC timestamp as an epoch second. `gh` renders that format and
# `jq` parses it, so this stays portable off the runner as well.
epoch_of() {
  jq -rn --arg value "$1" '$value | fromdateiso8601' 2>/dev/null ||
    die "cannot read the timestamp '$1'"
}

# Rule 3: every job that produces, signs, notarizes, tests, manifests or
# attests the candidate succeeded in the run's latest attempt. One deterministic
# message, or nothing.
job_failure_reason() {
  local jobs_table="$1"
  local lanes="$2"
  printf '%s\n' "$jobs_table" | awk -F'\t' \
    -v required="$REQUIRED_JOBS" -v lanes="$lanes" '
    BEGIN {
      count = split(required, wanted, " ")
      for (i = 1; i <= count; i++) { seen[wanted[i]] = 0; failed[wanted[i]] = 0 }
    }
    {
      name = $1
      conclusion = $2
      if (name == "agent" || index(name, "agent (") == 1) {
        agent_total++
        if (conclusion != "success") agent_failed++
      }
      if (name in seen) {
        seen[name]++
        if (conclusion != "success") failed[name]++
      }
    }
    END {
      if (agent_total == "") agent_total = 0
      if (agent_failed == "") agent_failed = 0
      message = ""
      for (i = 1; i <= count; i++) {
        if (failed[wanted[i]] > 0 && message == "") {
          message = "job " wanted[i] " did not succeed in the latest attempt"
        }
      }
      if (agent_failed > 0 && message == "") {
        message = "an Agent lane did not succeed in the latest attempt"
      }
      for (i = 1; i <= count; i++) {
        if (seen[wanted[i]] == 0 && message == "") {
          message = "the latest attempt has no " wanted[i] " job"
        } else if (seen[wanted[i]] > 1 && message == "") {
          message = "the latest attempt runs " wanted[i] " more than once"
        }
      }
      if (message == "" && agent_total != lanes) {
        message = "the latest attempt has " agent_total " Agent lanes, not " lanes
      }
      print message
    }'
}

cmd_select() {
  require_release_identity
  local workflow_id agent_lanes
  workflow_id="$(resolve_workflow_id)"
  agent_lanes="$(expected_agent_lanes)"

  local runs_json
  runs_json="$(api "repos/$REPO/actions/workflows/${WORKFLOW_PATH##*/}/runs?event=workflow_dispatch&branch=main&head_sha=$SHA&status=success&per_page=$RUNS_PER_PAGE")" ||
    die 'the workflow runs API is unavailable'
  jq -e '.workflow_runs | type == "array"' >/dev/null <<<"$runs_json" ||
    die 'the workflow runs API returned an unexpected response'

  # Rule 1: newest first, at most three. The API returns the most recent runs
  # first; sorting by run number keeps that true for every page size.
  local candidates candidate_count
  candidates="$(jq -r '
    [.workflow_runs[]?] | sort_by(.run_number) | reverse | .[0:3] | .[] |
    [
      (.id // 0),
      (.path // ""),
      (.workflow_id // 0),
      (.event // ""),
      (.head_branch // ""),
      (.head_sha // ""),
      (.head_repository.full_name // ""),
      (.conclusion // "")
    ] | join("\u001f")' <<<"$runs_json")" ||
    die 'the workflow runs response is unreadable'
  candidate_count="$(grep -c . <<<"$candidates" || true)"
  (( candidate_count > 0 )) ||
    die "no successful workflow_dispatch run of $WORKFLOW_PATH exists for $SHA"

  local now="$NOW"
  if [[ -z "$now" ]]; then
    now="$(date -u +%s)" || die 'the runner clock is unreadable'
  fi
  [[ "$now" =~ ^[0-9]+$ ]] || usage_error '--now must be an epoch second'
  [[ "$MIN_REMAINING_SECONDS" =~ ^[0-9]+$ ]] ||
    usage_error '--min-remaining-seconds must be a number of seconds'
  local deadline=$(( now + MIN_REMAINING_SECONDS ))

  local artifact_name="$CHANNEL-release-candidate"
  local failures='' entry
  local id path candidate_workflow event branch head repository conclusion
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    IFS=$'\x1f' read -r id path candidate_workflow event branch head repository conclusion <<<"$entry"
    if [[ "$path" != "$WORKFLOW_PATH" ]]; then
      failures+="run $id runs $path, not $WORKFLOW_PATH; "
      continue
    fi
    if [[ "$candidate_workflow" != "$workflow_id" ]]; then
      failures+="run $id belongs to workflow $candidate_workflow, not $workflow_id; "
      continue
    fi
    if [[ "$repository" != "$REPO" ]]; then
      failures+="run $id was built in $repository, not $REPO; "
      continue
    fi
    if [[ "$branch" != main ]]; then
      failures+="run $id was built on branch '$branch', not main; "
      continue
    fi
    if [[ "$event" != workflow_dispatch ]]; then
      failures+="run $id was triggered by '$event', not workflow_dispatch; "
      continue
    fi
    if [[ "$head" != "$SHA" ]]; then
      failures+="run $id was built at $head, not $SHA; "
      continue
    fi
    if [[ "$conclusion" != success ]]; then
      failures+="run $id concluded '$conclusion', not success; "
      continue
    fi

    local jobs_json jobs_table jobs_reason
    jobs_json="$(api "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100")" ||
      { failures+="run $id: the jobs API is unavailable; "; continue; }
    jq -e '.jobs | type == "array"' >/dev/null <<<"$jobs_json" ||
      { failures+="run $id: the jobs API returned an unexpected response; "; continue; }
    jq -e '(.total_count // 0) <= 100' >/dev/null <<<"$jobs_json" ||
      { failures+="run $id: the jobs API returned more jobs than one page; "; continue; }
    jobs_table="$(jq -r '.jobs[]? | [(.name // ""), (.conclusion // "")] | @tsv' <<<"$jobs_json")" ||
      { failures+="run $id: the jobs response is unreadable; "; continue; }
    jobs_reason="$(job_failure_reason "$jobs_table" "$agent_lanes")" ||
      { failures+="run $id: the jobs response is unreadable; "; continue; }
    if [[ -n "$jobs_reason" ]]; then
      failures+="run $id: $jobs_reason; "
      continue
    fi

    local artifacts_json artifact_fields
    artifacts_json="$(api "repos/$REPO/actions/runs/$id/artifacts?per_page=100")" ||
      { failures+="run $id: the artifacts API is unavailable; "; continue; }
    jq -e '.artifacts | type == "array"' >/dev/null <<<"$artifacts_json" ||
      { failures+="run $id: the artifacts API returned an unexpected response; "; continue; }
    artifact_fields="$(jq -r --arg name "$artifact_name" '
      [.artifacts[]? | select(.name == $name)]
      | if length == 0 then "missing"
        elif length > 1 then "duplicate"
        else (.[0] | [(.expired // false), (.expires_at // ""), (.digest // "")] | @tsv)
        end' <<<"$artifacts_json")" ||
      { failures+="run $id: the artifacts response is unreadable; "; continue; }
    case "$artifact_fields" in
      missing)
        failures+="run $id has no $artifact_name artifact; "
        continue
        ;;
      duplicate)
        failures+="run $id carries more than one $artifact_name artifact; "
        continue
        ;;
    esac

    local expired expires_at digest
    IFS=$'\t' read -r expired expires_at digest <<<"$artifact_fields"
    if [[ "$expired" != false ]]; then
      failures+="run $id: $artifact_name is expired; "
      continue
    fi
    local expires_epoch
    expires_epoch="$(epoch_of "$expires_at")"
    if (( expires_epoch <= deadline )); then
      failures+="run $id: $artifact_name expires at $expires_at, which leaves no more than $MIN_REMAINING_SECONDS seconds; "
      continue
    fi
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      { failures+="run $id: $artifact_name reports no digest; "; continue; }

    printf 'candidate_run_id=%s\ncandidate_artifact_digest=%s\ncandidate_artifact_expires_at=%s\n' \
      "$id" "$digest" "$expires_at"
    return 0
  done <<<"$candidates"

  die "no promotable candidate among the newest $candidate_count runs for $SHA: ${failures%; }"
}

# Filenames the release assembly writes that `SHA256SUMS` cannot cover: the
# private iOS IPA and the Android AAB (contract artifacts that are not public),
# and the per-target dictation runtime metadata each Agent lane stages. All of
# them are part of the candidate and none of them is published.
contract_metadata_filenames() {
  [[ -f "$CONTRACT" ]] ||
    die "the release contract $CONTRACT is unavailable, so the candidate file set cannot be bounded"
  jq -r --arg marketing "$VERSION" --arg release "$ARTIFACT_VERSION" '
    [
      (.artifacts[]? | select(.public != true) | (.filename // "") |
        split($marketing) | join($release)),
      (.artifacts[]? | select(.component == "agent") |
        "stt-runtime-\(.platform)-\(.architecture).json")
    ] | .[] | select(length > 0)' "$CONTRACT" ||
    die "the release contract $CONTRACT is not readable JSON"
}

summarize_log() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//' | tail -c 400
}

cmd_verify() {
  require_release_identity
  [[ -n "$DIR" ]] || usage_error '--dir is required'
  [[ -n "$RUN_ID" && "$RUN_ID" =~ ^[1-9][0-9]*$ ]] || usage_error '--run-id must be numeric'
  [[ -n "$MANIFEST" ]] || usage_error '--manifest is required'
  [[ -n "$TAG" ]] || usage_error '--tag is required'
  [[ -n "$VERSION" ]] || usage_error '--version is required'
  [[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || usage_error '--build must be a positive integer'
  if [[ -z "$ARTIFACT_VERSION" ]]; then
    ARTIFACT_VERSION="${TAG#v}"
  fi

  local dist
  dist="$(cd "$DIR" 2>/dev/null && pwd)" || die "the artifact directory $DIR is unavailable"
  local manifest_path="$dist/$MANIFEST"
  [[ -f "$manifest_path" ]] || die "the candidate has no $MANIFEST"

  # 1. Release identity. A dispatch run's `release_tag` input is not in the API,
  # but it is fixed inside the manifest the candidate was built with, so these
  # five fields together prove this is the candidate for *this* tag.
  local identity_error
  identity_error="$(jq -r \
    --arg tag "$TAG" --arg channel "$CHANNEL" --arg commit "$SHA" \
    --arg version "$VERSION" --argjson build "$BUILD" '
    [
      (if .tag == $tag then empty else "tag \(.tag // "missing") is not \($tag)" end),
      (if .channel == $channel then empty else "channel \(.channel // "missing") is not \($channel)" end),
      (if .commit == $commit then empty else "commit \(.commit // "missing") is not \($commit)" end),
      (if .version == $version then empty else "version \(.version // "missing") is not \($version)" end),
      (if .build_number == $build then empty else "build \(.build_number // "missing") is not \($build)" end)
    ] | join("; ")' "$manifest_path")" ||
    die "$MANIFEST is not readable JSON"
  if [[ -n "$identity_error" ]]; then
    die "the candidate is not the release for $TAG: $identity_error"
  fi

  # 2. The artifact set still satisfies the release contract at this commit,
  # using the same tool and command the `assemble` job ran.
  [[ -d "$AGENT_DIR" ]] || die "the Agent tool directory $AGENT_DIR is unavailable"
  local tool_log
  if ! tool_log="$(cd "$AGENT_DIR" && fvm dart run tool/release_tool.dart verify-manifest \
    --manifest "$manifest_path" --artifacts "$dist" 2>&1)"; then
    die "verify-manifest rejected the candidate: $(summarize_log "$tool_log")"
  fi

  # 3a. Every declared byte is present and unchanged.
  local sums_log
  if ! sums_log="$(cd "$dist" && sha256sum -c --strict SHA256SUMS 2>&1)"; then
    die "SHA256SUMS does not match the candidate bytes: $(summarize_log "$sums_log")"
  fi

  # 3b. Nothing beyond the release is in the directory. `assemble` writes more
  # than `SHA256SUMS` can cover: the manifest, the SBOM and the Appcast are
  # metadata, each update-signature sidecar belongs to a listed artifact, and
  # the contract adds the artifacts it does not publish plus one dictation
  # runtime descriptor per Agent target. `native/` is the staged runtime the
  # Agent lanes upload; nothing under it is published, checksummed or attested.
  # Any other file or directory is refused, which can only cost the saving.
  local listed_names sidecars contract_metadata allowed_extra
  listed_names="$(awk '{ sub(/^[0-9a-f]+[ \t]+\*?/, ""); print }' "$dist/SHA256SUMS")" ||
    die 'SHA256SUMS is unreadable'
  sidecars="$(printf '%s\n' "$listed_names" | sed 's/$/.update-signature/')" ||
    die 'SHA256SUMS is unreadable'
  contract_metadata="$(contract_metadata_filenames)"
  allowed_extra="SHA256SUMS"$'\n'"$MANIFEST"$'\n'"sanad-$ARTIFACT_VERSION.spdx.json"
  if [[ -n "$sidecars" ]]; then
    allowed_extra="$allowed_extra"$'\n'"$sidecars"
  fi
  if [[ -n "$contract_metadata" ]]; then
    allowed_extra="$allowed_extra"$'\n'"$contract_metadata"
  fi

  local entry name unexpected=''
  local unexpected_count=0
  for entry in "$dist"/*; do
    [[ -e "$entry" ]] || continue
    name="${entry##*/}"
    if [[ -d "$entry" ]]; then
      [[ "$name" == native ]] || {
        unexpected+="${unexpected:+, }$name/"
        unexpected_count=$(( unexpected_count + 1 ))
      }
      continue
    fi
    contains_line "$name" "$listed_names" && continue
    contains_line "$name" "$allowed_extra" && continue
    unexpected+="${unexpected:+, }$name"
    unexpected_count=$(( unexpected_count + 1 ))
  done
  if (( unexpected_count > 0 )); then
    die "the candidate carries files the release does not account for: $unexpected"
  fi

  # 4. Every attested subject is attested by *this* candidate run, for this
  # workflow, ref and commit, on hosted runners.
  local -a subjects=()
  local pattern
  for pattern in "$dist"/sanad-* "$dist"/release-manifest*.json "$dist"/appcast*.xml "$dist"/SHA256SUMS; do
    [[ -f "$pattern" ]] || continue
    subjects+=("$pattern")
  done
  (( ${#subjects[@]} > 0 )) ||
    die 'the candidate carries no attested subject to verify'

  WORK_DIR="$(mktemp -d)"
  local attestation_error="$WORK_DIR/attestation.err"
  local subject verified=0 attestation_log run_uris run_uri
  for subject in "${subjects[@]}"; do
    if ! attestation_log="$(gh attestation verify "$subject" \
      --repo "$REPO" \
      --signer-workflow "$REPO/$WORKFLOW_PATH" \
      --source-ref "$SIGNER_REF" \
      --source-digest "$SHA" \
      --deny-self-hosted-runners \
      --format json 2>"$attestation_error")"; then
      die "the attestation of ${subject##*/} does not verify: $(summarize_log "$(cat "$attestation_error")")"
    fi
    run_uris="$(jq -r '
      [.[]? | .verificationResult |
        (.runInvocationURI // .statement.predicate.runDetails.metadata.invocationId // empty)]
      | unique | .[]' <<<"$attestation_log")" ||
      die "the attestation of ${subject##*/} is not readable JSON"
    if [[ -z "$run_uris" ]]; then
      die "the attestation of ${subject##*/} names no producing run"
    fi
    while IFS= read -r run_uri; do
      [[ -n "$run_uri" ]] || continue
      if [[ "$run_uri" != *"/actions/runs/$RUN_ID/attempts/"* ]]; then
        die "the attestation of ${subject##*/} names $run_uri, not candidate run $RUN_ID"
      fi
    done <<<"$run_uris"
    verified=$(( verified + 1 ))
  done

  note "verified candidate run $RUN_ID for $TAG: $verified attested subjects, $(grep -c . "$dist/SHA256SUMS") checksummed files"
  printf 'candidate-verified=%s\n' "$RUN_ID"
}

cmd_verdict() {
  [[ "$SWITCH_SET" == true ]] || usage_error '--switch is required'
  [[ "$SELECTION" == ok || "$SELECTION" == failed ]] ||
    usage_error '--selection must be ok or failed'
  [[ "$VERIFICATION" == ok || "$VERIFICATION" == failed ]] ||
    usage_error '--verification must be ok or failed'

  local verdict mode default_reason
  case "$SWITCH" in
    enabled)
      if [[ "$SELECTION" == ok && "$VERIFICATION" == ok ]]; then
        verdict=promote
        mode=promote
        default_reason='the validated candidate passed every selection and verification rule'
      else
        verdict=rebuild
        mode=rebuild
        default_reason='the validated candidate could not be proved, so the tag run rebuilds it'
      fi
      ;;
    shadow)
      mode=rebuild
      if [[ "$SELECTION" == ok && "$VERIFICATION" == ok ]]; then
        verdict=would-promote
        default_reason='shadow mode: the validated candidate passed every selection and verification rule'
      else
        verdict=would-rebuild
        default_reason='shadow mode: the validated candidate could not be proved'
      fi
      ;;
    *)
      verdict=skipped
      mode=rebuild
      default_reason="RELEASE_CANDIDATE_PROMOTION is '${SWITCH:-unset}', so the tag run rebuilds"
      ;;
  esac

  local text="$REASON_TEXT"
  if [[ -z "$text" ]]; then
    text="$default_reason"
  fi
  text="$(printf '%s' "$text" | tr '\r\n' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/  */ /g')"
  printf 'verdict=%s\nmode=%s\nreason=%s\n' "$verdict" "$mode" "${text:-$default_reason}"
}

main() {
  (( $# > 0 )) || usage
  local command="$1"
  shift
  parse_arguments "$@"
  trap cleanup EXIT
  case "$command" in
    select) cmd_select ;;
    verify) cmd_verify ;;
    verdict) cmd_verdict ;;
    -h | --help | help) usage ;;
    *) usage_error "unknown command $command" ;;
  esac
}

main "$@"
