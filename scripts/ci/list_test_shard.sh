#!/usr/bin/env bash
# Print the test files assigned to one deterministic shard of a package.
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
# deleted. Those suites are never placed in a shard; `--isolated` prints them
# so a single runner can execute them alone.
#
# Usage: list_test_shard.sh <test-root> <shard-index> <total-shards>
#        list_test_shard.sh <test-root> --isolated
set -euo pipefail

if [[ $# -ne 3 && $# -ne 2 ]]; then
  echo "usage: $0 <test-root> <shard-index> <total-shards>" >&2
  echo "       $0 <test-root> --isolated" >&2
  exit 2
fi

root="$1"

isolated_files() {
  (cd "$root" && grep -rlF 'Directory.current = ' test 2>/dev/null || true)
}

if [[ "$2" == "--isolated" ]]; then
  isolated_files
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
