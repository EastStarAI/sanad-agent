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
## `verify` — bounded verification runner

Runs any verification command, bounds console output, measures elapsed wall time, captures full logs to an untracked temp file, and preserves child exit status:

```bash
fvm dart run scripts/workflow_guards/bin/verify.dart [--tail <n>] [--] <command> [args...]
```

- Bounded console: prints only the final `--tail` lines of stdout (default 5) plus a 1-line summary with elapsed time, exit code, and log path.
- Error section: on failure, also prints the final `--tail` lines of stderr.
- Full log capture: the complete stdout and stderr are written to a unique file in the system temp directory (or `--log-dir`).
- Preserved exit status: returns the exact exit code of the child process (`0`, failure code, etc.) or `2` on usage/spawn errors.
- JSON output: pass `--json` to output a structured JSON envelope.
- Windows-safe: direct execution where possible, shell routing with strict metacharacter validation for `.cmd`/`.bat` wrappers.

## Wiki lint guard coverage

The suite also regression-covers the repository wiki lint guard,
`scripts/lint_wiki.dart` (`test/wiki_lint_test.dart`):

```bash
cd scripts/workflow_guards && fvm dart test test/wiki_lint_test.dart
```

It drives the real script against a temporary sandbox and proves that:

- dependency link trees Flutter generates below
  `*/flutter/ephemeral/.plugin_symlinks/` and
  `*/Flutter/ephemeral/.symlinks/` never count as repository contracts;
- real repository contracts stay discoverable and must still be indexed in
  `docs/llms.txt`, even when their path merely resembles the exclusion;
- frontmatter, index, and link checks on real pages still fail closed.

Run `fvm flutter pub get` in `client/` first to reproduce the actual generated
paths in the checkout.

## Tests

```bash
cd scripts/workflow_guards && fvm dart pub get && fvm dart test
```

Tests are deterministic and need no real `gh` or network: the monitor drives a
fake `gh` executable (a Node wrapper) with embedded scenarios, and the merge
validator uses temp files.