#!/usr/bin/env bash
# Print the test files assigned to one deterministic shard of a package, the
# CWD-sensitive suites, or the macOS platform subset.
#
# Every `*_test.dart` file under <test-root>/test is assigned to exactly one
# shard by round-robin over the sorted file list, so the shards never overlap
# and never drop a file. `flutter test --total-shards/--shard-index` cannot be
# used for this: it slices the tests inside every suite, which loads and
# compiles all test files in every shard.
#
# A suite that assigns the process working directory cannot share a runner:
# every suite in a `dart test` process shares that directory, so a child
# process started by another suite fails while the directory is held or
# deleted. Those suites are never placed in a shard or in the macOS subset;
# `--isolated` prints them so a single runner can execute them alone.
#
# `--platform-macos` prints the platform-sensitive subset a macOS release lane
# runs once the whole suite lives on Linux and on the post-merge macOS workflow
# (`docs/operations/continuous_integration.md` owns the model). It is the one
# source of truth for that selection, so the release lanes and the post-merge
# workflow can never disagree about what macOS proves.
#
# Usage: list_test_shard.sh <test-root> <shard-index> <total-shards>
#        list_test_shard.sh <test-root> --isolated
#        list_test_shard.sh <test-root> --platform-macos
set -euo pipefail

if [[ $# -ne 3 && $# -ne 2 ]]; then
  echo "usage: $0 <test-root> <shard-index> <total-shards>" >&2
  echo "       $0 <test-root> --isolated" >&2
  echo "       $0 <test-root> --platform-macos" >&2
  exit 2
fi

root="$1"

isolated_files() {
  (cd "$root" && grep -rlF 'Directory.current = ' test 2>/dev/null || true)
}

# Suites whose behavior depends on the macOS host — real Keychain and file
# credential stores, launchd service management, POSIX permissions and atomic
# rollback, file locks and Home ownership, native dictation, build-tool paths —
# plus the process and filesystem owners that use POSIX-only primitives. The
# directory entries are whole subtrees; the single files are the owners that sit
# directly under a directory the rest of the suite shares.
macos_platform_files() {
  (
    cd "$root" || exit 1
    {
      for directory in core/auth core/setup core/sanad_home stt tool guards; do
        find "test/$directory" -name '*_test.dart' 2>/dev/null || true
      done
      for file in \
        test/core/agent_secret_store_test.dart \
        test/core/auth_test.dart \
        test/core/cli_path_manager_test.dart \
        test/core/config_test.dart \
        test/capabilities/process_tree_controller_test.dart \
        test/capabilities/shell_execute_tool_test.dart \
        test/capabilities/shell_execute_cancellation_test.dart \
        test/evolution/attachment_store_test.dart \
        test/evolution/file_memory_store_test.dart \
        test/interfaces/server_sanad_gateway_platform_security_test.dart \
        test/cli/cli_vault_open_policy_test.dart; do
        if [[ -f "$file" ]]; then
          printf '%s\n' "$file"
        fi
      done
    } | sort -u
  )
}

if [[ "$2" == "--isolated" ]]; then
  isolated_files
  exit 0
fi

if [[ "$2" == "--platform-macos" ]]; then
  isolated="$(isolated_files)"
  while IFS= read -r file; do
    if [[ -n "$isolated" ]] && grep -qxF "$file" <<< "$isolated"; then
      continue
    fi
    printf '%s\n' "$file"
  done < <(macos_platform_files)
  exit 0
fi

index="$2"
total="$3"

if ! [[ "$index" =~ ^[0-9]+$ && "$total" =~ ^[1-9][0-9]*$ ]]; then
  echo "shard index and total shards must be integers" >&2
  exit 2
fi
if (( index >= total )); then
  echo "shard index $index is outside 0..$((total - 1))" >&2
  exit 2
fi

isolated="$(isolated_files)"
files=()
while IFS= read -r file; do
  if [[ -n "$isolated" ]] && grep -qxF "$file" <<< "$isolated"; then
    continue
  fi
  files+=("$file")
done < <(cd "$root" && find test -name '*_test.dart' | sort)

for position in "${!files[@]}"; do
  if (( position % total == index )); then
    printf '%s\n' "${files[$position]}"
  fi
done
