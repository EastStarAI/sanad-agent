---
title: "Task: Contain Malformed shell_execute Output"
status: "completed"
current_gate: "complete"
---

# Task: Contain Malformed `shell_execute` Output

## Goal
Keep the Agent daemon alive when a child process writes stdout or stderr bytes
that are not valid UTF-8.

## Locked Decisions and Scope

- Preserve bounded streaming collection and existing head/tail truncation.
- Treat child output as untrusted. Decode UTF-8 lossily so valid text is
  unchanged and malformed sequences become the Unicode replacement character.
- Do not infer or transcode arbitrary legacy code pages in this focused crash
  fix.
- Cover the real `ShellExecuteTool` process boundary on Windows and POSIX.

## Gates

### G0 — Reproduction and Ownership

- [x] Map the reported `_Utf8Decoder.convertChunked` crash to
  `ShellExecuteTool._collectBoundedOutput`.
- [x] Confirm the strict decoder future can fail outside the synchronous process
  launch boundary and terminate the daemon's active execution path.

### G1 — Implementation

- [x] Use `Utf8Decoder(allowMalformed: true)` for stdout and stderr streams.
- [x] Add a cross-platform regression command that emits invalid UTF-8 followed
  by valid ASCII and assert execution returns normally.
- [x] Document malformed child-output containment in the capability runtime.

### G2 — Verification

- [x] Run the focused shell execution unit test suite.
- [x] Run `fvm dart analyze` in `agent/`.
- [x] Reproduce malformed Windows process output through the real
  `ShellExecuteTool` process boundary and confirm normal completion.
- [x] Live runtime handoff is not required: the real process boundary regression
  is sufficient, and avoiding a source switch prevents unnecessary impact on
  active sessions.
- [x] Review the final diff.
- [x] Graphify update waived by the owner because the CLI and graph are
  unavailable.

## Acceptance Criteria

- [x] Invalid child bytes no longer escape stream collection as a
  `FormatException`.
- [x] Valid bytes surrounding malformed sequences remain visible in the bounded
  tool result.
- [x] Focused automated tests and Agent analysis pass.
- [x] Process-boundary verification proves malformed output returns a normal tool
  result instead of escaping as an unhandled exception.

## Definition of Done

- [x] Source, regression coverage, design documentation, analysis, and focused
  tests are current.
- [x] Graphify maintenance was explicitly waived by the owner.
- [x] No commit is created before user review.
