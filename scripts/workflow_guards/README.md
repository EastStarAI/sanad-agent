# Sanad Workflow Guards

Bounded, tested Pure-Dart guard tooling for Sanad developer workflows. No
external packages; runs through FVM on macOS, Linux, and Windows.

## `pr_checks_watch` — bounded CI check monitor

Polls `gh pr checks <pr> --json` instead of fragile shell parsing:

```bash
fvm dart run scripts/workflow_guards/bin/pr_checks_watch.dart <pr>
```

- Interval: 5 seconds (default; `--interval <sec>`).
- Fail-fast: stops on the first failed/cancelled check.
- Maximum watch: 7 minutes (default; `--timeout <sec>`).
- Bounded output: one summary line per poll, or `--json` for a final envelope.
- Preserved exit status: `0` all reported checks passed, `1` first failure,
  `124` timeout pending, `2` usage/gh unavailable/no checks/unparseable.
- Windows-safe: `gh` is spawned directly; a `.cmd`/`.bat` override
  (`--gh <path>` or `SANAD_WORKFLOW_GH`) is routed through ComSpec with
  explicit per-argument quoting. Shell metacharacters in the executable path
  are rejected without execution.
- Handles gh's exit code `8` ("checks pending"). Empty results fail closed
  because they do not prove that required checks passed.

Example for a 90-second bounded gate:

```bash
fvm dart run scripts/workflow_guards/bin/pr_checks_watch.dart 1234 --timeout 90
```

## `merge_validate` — fail-closed merge artifact gate

Validates files resolved after a Git merge/rebase conflict before staging:

```bash
fvm dart run scripts/workflow_guards/bin/merge_validate.dart <resolved-file>...
```

- Rejects leftover conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`,
  `|||||||`) with exact line numbers.
- Rejects corrupt JSON and JSONL syntax.
- Exit codes: `0` clean, `3` markers, `4` corrupt syntax, `2` missing/usage
  (worst wins across multiple files). Use it in a `&&` chain so `git add`
  refuses a corrupt file.
- Intended as the smallest fail-closed guard: reconstruct from
  base/ours/theirs (`git show :1:<path>` / `:2:` / `:3:`) when a merge driver
  is ambiguous, then validate, then run the affected analyzer/tests before
  staging.

## Tests

```bash
cd scripts/workflow_guards && fvm dart pub get && fvm dart test
```

Tests are deterministic and need no real `gh` or network: the monitor drives a
fake `gh` executable (a Node wrapper) with embedded scenarios, and the merge
validator uses temp files.