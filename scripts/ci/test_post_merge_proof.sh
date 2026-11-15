#!/usr/bin/env bash
# Fixture harness for the post-merge proof selector in Public CI.
#
# `classify` decides whether the `push` run of Public CI re-tests every lane or
# only the complement of lanes a proof run already proved. That decision is a
# correctness boundary, so it is exercised here against the real code: the
# selector functions and the `push` caller are extracted from
# `.github/workflows/ci.yml` and run with a fake `gh` that answers from a JSON
# fixture. Nothing is re-implemented, so a behaviour change in the workflow is
# either covered by a fixture or fails the extraction check below.
#
# Two proof sources exist because the merge path is a repository setting:
#
#   A. a successful `merge_group` run for the pushed commit (the merge queue);
#   B. the merged pull request's own final successful `pull_request` run, when
#      the pushed tree equals the pull-request head's tree and the pushed
#      commit's parent is an ancestor of that head (strict, "up to date" merges).
#
# Anything else must leave every lane enabled, so each mismatch case expects
# `complement=false` and no proven lane.
#
# Usage: scripts/ci/test_post_merge_proof.sh [case-name ...]
# Exit:  0 every selected case passed, 1 a case failed, 2 the harness or the
#        workflow shape changed under it.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
workflow="$root/.github/workflows/ci.yml"
fixtures="$script_dir/fixtures/post_merge_proof/cases.json"
repository="EastStarAI/sanad-agent"

for tool in jq git sed awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "post-merge proof harness: $tool is required" >&2
    exit 2
  }
done

temp="$(mktemp -d "${TMPDIR:-/tmp}/sanad-proof.XXXXXX")" || exit 2
trap 'rm -rf "$temp"' EXIT

# ---- Extract the selector and its caller from the workflow -----------------
first_line() {
  local pattern="$1"
  grep -nE "$pattern" "$workflow" | head -1 | cut -d: -f1
}

start="$(first_line '^          collect_proven_lanes\(\) \{$')"
# The caller marker is a literal grep pattern, so it must not expand here.
# shellcheck disable=SC2016
caller="$(first_line '^          if \[\[ "\$EVENT_NAME" == push \]\]; then$')"
if [[ -z "$start" || -z "$caller" ]]; then
  echo "post-merge proof harness: the selector is no longer where it is expected in .github/workflows/ci.yml." >&2
  exit 2
fi
end="$(awk -v s="$caller" 'NR > s && $0 == "          fi" { print NR; exit }' "$workflow")"
if [[ -z "$end" ]] || (( start >= caller )) || (( caller >= end )); then
  echo "post-merge proof harness: the push caller in .github/workflows/ci.yml has an unexpected shape." >&2
  exit 2
fi

selector="$temp/selector.sh"
sed -n "${start},${end}p" "$workflow" >"$selector"
for marker in \
  'prove_from_merge_queue() {' \
  'prove_from_merged_pull_request() {' \
  'if prove_from_merge_queue; then' \
  'elif prove_from_merged_pull_request; then' \
  'proven=" "'; do
  if ! grep -qF -- "$marker" "$selector"; then
    echo "post-merge proof harness: the workflow lost '$marker'; update this harness with the new shape." >&2
    exit 2
  fi
done

# ---- Fake `gh` ------------------------------------------------------------
mkdir -p "$temp/bin"
fake_gh="$temp/bin/gh"
cat >"$fake_gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Answers `gh api <url> [--paginate] [--jq <filter>]` from the case fixture.
set -uo pipefail
url=""
jq_filter=""
while (( $# > 0 )); do
  case "$1" in
    api | --paginate) shift ;;
    --jq) jq_filter="${2:-}"; shift 2 ;;
    --jq=*) jq_filter="${1#--jq=}"; shift ;;
    --method | --header | -H | --hostname) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ -z "${SANAD_PROOF_FIXTURE:-}" ]]; then
  echo "fake gh: SANAD_PROOF_FIXTURE is unset" >&2
  exit 2
fi
route="$(jq -c --arg u "$url" '[.routes[] | select(.match as $m | $u | test($m))] | first // empty' \
  "$SANAD_PROOF_FIXTURE")"
if [[ -z "$route" ]]; then
  echo "fake gh: no fixture route for '$url'" >&2
  exit 1
fi
if [[ "$(jq -r '.error // false' <<<"$route")" == "true" ]]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
body="$(jq -c '.body' <<<"$route")"
if [[ -n "$jq_filter" ]]; then
  jq -r "$jq_filter" <<<"$body"
else
  jq -c . <<<"$body"
fi
FAKE_GH
chmod +x "$fake_gh"

# ---- Git fixture ----------------------------------------------------------
# The selector resolves the pushed commit's tree and parent with `git`, so the
# fixture is a real repository with three shapes: a pull-request head, a squash
# commit that carries the head's tree on top of the base (what a strict merge
# produces), and a squash commit with different content.
repo="$temp/repo"
fatal() {
  echo "post-merge proof harness: $1" >&2
  exit 2
}
mkdir -p "$repo" || fatal "could not create the fixture repository"
git -C "$repo" -c init.defaultBranch=main init -q . || fatal "git init failed"
git -C "$repo" config user.email "ci-guard@sanad.invalid" || fatal "git config failed"
git -C "$repo" config user.name "CI guard" || fatal "git config failed"
printf 'base\n' >"$repo/base.txt" || fatal "could not write the base file"
git -C "$repo" add -A || fatal "git add failed"
git -C "$repo" commit -q -m base || fatal "git commit failed"
base_sha="$(git -C "$repo" rev-parse HEAD)" || fatal "could not read the base commit"
git -C "$repo" checkout -q -b pr-head || fatal "git checkout failed"
printf 'head\n' >"$repo/head.txt" || fatal "could not write the head file"
git -C "$repo" add -A || fatal "git add failed"
git -C "$repo" commit -q -m head || fatal "git commit failed"
head_sha="$(git -C "$repo" rev-parse HEAD)" || fatal "could not read the head commit"
head_tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')" || fatal "could not read the head tree"
same_sha="$(printf 'squash\n' | git -C "$repo" commit-tree "$head_tree" -p "$base_sha")" ||
  fatal "could not create the matching squash commit"
git -C "$repo" checkout -q "$base_sha" || fatal "git checkout failed"
printf 'diff\n' >"$repo/diff.txt" || fatal "could not write the diverging file"
git -C "$repo" add -A || fatal "git add failed"
diff_tree="$(git -C "$repo" write-tree)" || fatal "could not write the diverging tree"
diff_sha="$(printf 'squash\n' | git -C "$repo" commit-tree "$diff_tree" -p "$base_sha")" ||
  fatal "could not create the diverging squash commit"

# ---- Run the cases --------------------------------------------------------
if [[ ! -r "$fixtures" ]]; then
  echo "post-merge proof harness: missing fixtures at ${fixtures#"$root"/}" >&2
  exit 2
fi
total_cases="$(jq '.cases | length' "$fixtures")"
if (( total_cases == 0 )); then
  echo "post-merge proof harness: no cases in ${fixtures#"$root"/}" >&2
  exit 2
fi

selected=()
for (( i = 0; i < total_cases; i++ )); do
  if (( $# == 0 )) || [[ " $* " == *" $(jq -r ".cases[$i].name" "$fixtures") "* ]]; then
    selected+=("$i")
  fi
done
if (( ${#selected[@]} == 0 )); then
  echo "post-merge proof harness: no case matched the requested names" >&2
  exit 2
fi

normalize() {
  tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ *$//'
}

passed=0
failed=0
for index in "${selected[@]}"; do
  rendered="$temp/case.json"
  jq -c ".cases[$index]" "$fixtures" |
    sed -e "s/__BASE__/$base_sha/g" \
      -e "s/__HEAD_TREE__/$head_tree/g" \
      -e "s/__HEAD__/$head_sha/g" \
      -e "s/__SAME__/$same_sha/g" \
      -e "s/__DIFF_TREE__/$diff_tree/g" \
      -e "s/__DIFF__/$diff_sha/g" >"$rendered"

  name="$(jq -r '.name' "$rendered")"
  sha="$(jq -r '.sha' "$rendered")"
  expected_complement="$(jq -r '.expect.complement' "$rendered")"
  expected_proof="$(jq -r '.expect.proof // ""' "$rendered")"
  expected_proven="$(normalize "$(jq -r '.expect.proven // ""' "$rendered")")"

  mkdir -p "$temp/runner"
  actual="$(
    cd "$repo" || exit 2
    PATH="$temp/bin:$PATH" \
      SANAD_PROOF_FIXTURE="$rendered" \
      SELECTOR="$selector" \
      GITHUB_REPOSITORY="$repository" \
      GITHUB_SHA="$sha" \
      RUNNER_TEMP="$temp/runner" \
      EVENT_NAME=push \
      bash -c '
        # `set -e` is deliberately absent: the workflow calls these functions
        # from `if` conditions, where bash disables errexit for the whole call
        # tree, so this is the effective behaviour there too.
        set -uo pipefail
        complement=false
        proof=""
        proven=" "
        source "$SELECTOR"
        printf "complement=%s\nproof=%s\nproven=%s\n" "$complement" "$proof" "$proven"
      ' 2>"$temp/runner/stderr.log"
  )"
  run_status=$?

  actual_complement="$(sed -n 's/^complement=//p' <<<"$actual")"
  actual_proof="$(sed -n 's/^proof=//p' <<<"$actual")"
  actual_proven="$(normalize "$(sed -n 's/^proven=//p' <<<"$actual")")"

  reason=""
  if (( run_status != 0 )); then
    reason="the caller exited $run_status"
  elif [[ "$actual_complement" != "$expected_complement" ]]; then
    reason="complement=$actual_complement, expected $expected_complement"
  elif [[ "$actual_proof" != "$expected_proof" ]]; then
    reason="proof='$actual_proof', expected '$expected_proof'"
  elif [[ "$actual_proven" != "$expected_proven" ]]; then
    reason="proven='$actual_proven', expected '$expected_proven'"
  elif [[ "$expected_complement" != "true" && -n "$actual_proven" ]]; then
    reason="proven='$actual_proven' without a proof"
  fi

  if [[ -z "$reason" ]]; then
    passed=$((passed + 1))
    echo "ok    $name — $(jq -r '.description' "$rendered")"
  else
    failed=$((failed + 1))
    echo "FAIL  $name — $reason"
    if [[ -s "$temp/runner/stderr.log" ]]; then
      sed 's/^/        /' "$temp/runner/stderr.log"
    fi
  fi
done

total=$((passed + failed))
if (( failed > 0 )); then
  echo "post-merge proof selector: $passed/$total cases passed" >&2
  exit 1
fi
echo "post-merge proof selector: $passed/$total cases passed"
