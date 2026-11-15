---
title: "Task 438 — Development Native STT Provisioning"
issue: "https://github.com/EastStarAI/sanad-agent/issues/438"
status: planned
---

## Goal

Make a supported fresh source checkout prepare native dictation through `sanad-dev setup` or `sanad-dev run` without a manual Dart command, while keeping every preparation failure observable and dictation-only.

## Locked Scope

- `scripts/sanad_dev` owns source-run orchestration; `agent/tool/ensure_native_stt.dart` owns runtime acquisition/build/verification.
- Windows must never discard preparation diagnostics to `NUL`.
- Daemon startup must not be blocked by optional dictation preparation.
- Use a verified compatible artifact when one exists; otherwise use the pinned source/build path or report a typed prerequisite failure.
- Do not change production dictation decoding, models, or transport in this task.

## Gates

### G0 — Discovery
- [ ] Map current `setup`/`run` preparation ownership, retry behavior, logs, and tests.
- [ ] Decide the leanest compatible artifact/cache contract without duplicating release verification.

### G1 — Implementation
- [ ] Add one reusable preparation owner used by setup and run.
- [ ] Preserve a bounded durable Windows result/log and expose retryable failure state.
- [ ] Remove the dead-end Client instruction when managed preparation is available.

### G2 — Verification
- [ ] Cover ready, fresh-checkout success, missing prerequisite, failed acquisition, and no-repeat background attempts.
- [ ] Run owning analyzers and focused tests with elapsed/bounded output.
- [ ] Update the owning technical documentation and Graphify.

## Acceptance Criteria

- [ ] Given a supported fresh checkout, setup/run reaches a verified native runtime without a manual Dart invocation.
- [ ] Given an unavailable acquisition/build prerequisite, the daemon still starts and one durable typed diagnostic identifies the failed stage and retry path.
- [ ] Windows output is never redirected to `NUL`.
- [ ] Repeated run commands do not create overlapping or unbounded installer attempts.

## Definition of Done

- [ ] Implementation and docs are complete in the isolated worktree.
- [ ] Analyzer and focused tests pass.
- [ ] A separate reviewer session accepts the candidate; fixes return to the original implementer session and re-review returns to the original reviewer session.
- [ ] Stop before Ready/merge without separate authorization.
