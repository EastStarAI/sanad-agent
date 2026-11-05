#!/usr/bin/env bash
# Print the executed and skipped test counts of a machine-reporter log.
#
# Usage: test_event_counts.sh <machine-report.jsonl>
#
# A test run that fails before it writes a report still has to produce a
# readable count, so a missing or empty report is reported as zero instead of
# failing the step that is already reporting the real test failure.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <machine-report.jsonl>" >&2
  exit 2
fi

report="$1"
if [[ ! -s "$report" ]]; then
  echo "executed=0 skipped=0"
  exit 0
fi

count() {
  jq -r "$1" "$report" | wc -l | tr -d ' '
}

executed="$(count 'select(.type == "testDone" and (.hidden | not) and (.skipped | not)) | .id')"
skipped="$(count 'select(.type == "testDone" and (.hidden | not) and .skipped) | .id')"
echo "executed=$executed skipped=$skipped"
