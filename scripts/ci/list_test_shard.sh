#!/usr/bin/env bash
# Print the test files assigned to one deterministic shard of a package.
#
# Every `*_test.dart` file under <test-root>/test is assigned to exactly one
# shard by round-robin over the sorted file list, so the shards never overlap
# and never drop a file. `flutter test --total-shards/--shard-index` cannot be
# used for this: it slices the tests inside every suite, which loads and
# compiles all test files in every shard.
#
# Usage: list_test_shard.sh <test-root> <shard-index> <total-shards>
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <test-root> <shard-index> <total-shards>" >&2
  exit 2
fi

root="$1"
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

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(cd "$root" && find test -name '*_test.dart' | sort)
for position in "${!files[@]}"; do
  if (( position % total == index )); then
    printf '%s\n' "${files[$position]}"
  fi
done
