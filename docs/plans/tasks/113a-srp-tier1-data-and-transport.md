---
title: "SRP Tier 1 — Data and Transport Host Decomposition"
description: "Decompose the three largest well-covered god-classes (session repository, socket service, conversation cache store) into cohesive owners behind unchanged public facades, with zero behavior, protocol, API, UI, or localization change."
status: in_progress
current_gate: T1-G0
remaining_estimate: 100%
base_commit: b02b9e62
tier_branch: refactor/113a-srp-tier1-data-and-transport
---

# SRP Tier 1 — Data and Transport Host Decomposition

## Goal

Reduce the three largest mixed-responsibility classes that already have strong automated
coverage to thin facades plus cohesive owners, so each behavior has exactly one owner and
the existing suites keep proving behavior is unchanged.

| Target | File | Lines | Public surface | Test coverage |
|---|---|---:|---|---|
| T1-1 | `agent/lib/evolution/db/session_db.dart` | 1,732 | `SessionDB` ≈1,650 lines, 32 public methods | 33 files / 111 references |
| T1-2 | `client/lib/infrastructure/socket/sanad_socket_service.dart` | 1,317 | one class implementing two interfaces, 32 mutable fields, 19 public methods | 45 files / 202 references |
| T1-3 | `client/lib/features/conversations/domain/stores/conversation_cache_store.dart` | 1,137 | one class, 42 public methods | 16 files / 56 references |

## Locked Decisions and Scope

- Base is `origin/main` at `b02b9e62`; this tier owns branch
  `refactor/113a-srp-tier1-data-and-transport`.
- **Extraction, not rewrite.** Moved bodies keep their logic verbatim; only ownership and
  wiring change. No opportunistic improvement of adjacent logic.
- **No behavior, protocol, payload, SQL schema, UI, or localization change.** No new
  dependency. No change to persisted state or migration behavior.
- **Public API is preserved.** Every existing class, method, constructor, and factory name
  stays reachable; a facade or forwarder keeps existing call sites and tests compiling
  unchanged.
- Ownership is one-way: owners receive dependencies through explicit constructor parameters
  or typed callbacks; no owner imports its host file to reach private state, and no two
  owners share mutable state.
- Target worktrees are separate branches created from this tier branch and merged back into
  it. Each target lands as its own commit set inside this tier's single Draft PR.
- Workers do not edit this plan file; only the orchestrator updates gates, checkboxes, and
  the remaining estimate.

## Cycle Rules (delegation and evidence)

- Implementer: `agy` (`gemini-3.8-flash-high`). Reviewer: the type designated by the user for this cycle — currently `sanad`
  (`OpenCode Go / deepseek-v4.1-flash`) — running in the same worktree after the implementer stops
  writing. The orchestrator never substitutes or infers the reviewer's type. The orchestrator
  dispatches, monitors event-first, runs the frozen full suite once per accepted candidate, and
  delivers.
- Every gate command preserves its exit code, writes stdout/stderr to one unique temporary
  log, and reports status, elapsed duration, and log path with a bounded final-five-line
  summary.
- The package full suite runs **once per target on a frozen candidate**. Do not re-run it for
  cosmetic changes; rerun only after a documented source invalidation.
- Agent-package and client-package suites are never run concurrently on this machine: the
  earlier concurrent run produced one transient failure while serial runs passed with an
  identical count.
- Report unexpected scope, design decisions, and non-blocking findings instead of silently
  absorbing them.

## Target T1-1 — Session repository decomposition

Owner file: `agent/lib/evolution/db/session_db.dart` (1,732 lines).

Co-located responsibilities to separate: session lifecycle and metadata; message history
append/read and history revision; scheduled tasks; suspended checkpoints / work items;
fork, soft-rewind, and root-user-message commits. The file already carries five supporting
value classes (`OriginatingToolCallContext`, `SoftRewindAdmissionCommit`,
`RootUserMessageCommit`, `SessionForkCommit`, `SessionForkOutcome`) that must stay reachable.

Proposed owners (names may be refined if the reviewer documents why):

- `SessionRepository` — sessions, metadata, titles, revisions.
- `SessionMessageRepository` — message append/read, history projection, tool-result records.
- `ScheduledTaskRepository` — scheduled task persistence.
- `SuspendedCheckpointRepository` — suspended checkpoints and work-item state.
- `SessionForkCommitRepository` — fork, soft-rewind, and root-user commit records.
- `SessionDB` — facade that keeps the current public surface and delegates.

### T1-1 gates

- [ ] **T1-1-A Baseline** — record line count and public-method inventory; run
      `fvm dart test test/evolution` plus the session-DB-related suites and record exact
      counts; freeze the evidence identifier for this candidate.
- [ ] **T1-1-B Extraction** — introduce the owners and reduce `SessionDB` to a facade;
      keep every public signature; no SQL text or query semantics change.
- [ ] **T1-1-C Hardening** — add one focused test per new owner that fails if the owner's
      responsibility is removed or bypassed; keep existing tests untouched.
- [ ] **T1-1-D Contracts and docs** — update `agent/lib/evolution/db/AGENTS.md` (and
      `docs/` schema documentation if a documented ownership statement changes); run
      `graphify update .`.
- [ ] **T1-1-E Verification** — `fvm dart analyze` clean; focused suites pass with counts
      at or above baseline; the agent full suite passes once on the frozen candidate.

## Target T1-2 — Socket service decomposition

Owner file: `client/lib/infrastructure/socket/sanad_socket_service.dart` (1,317 lines).

Co-located responsibilities: connection lifecycle and lifecycle state; access-token
handling; transport mode selection (cloud socket vs local WebSocket); reconnection/backoff;
device-command and tool-result emission; request/response correlation
(`emitWithResponse`); hosted attachment admission and hosted conversation media fetch;
debug hooks.

Proposed owners:

- `SocketConnectionController` — lifecycle, transport mode, token, reconnect/backoff,
  lifecycle state and debug hooks.
- `SocketCommandTransport` — emit, command senders, response correlation.
- `HostedMediaRelayClient` — hosted attachment admission and hosted conversation media.
- `SanadSocketService` — facade preserving `ISocketService`/`ISocketGateway` behavior.

### T1-2 gates

- [ ] **T1-2-A Baseline** — inventory public methods and stream surfaces; run the client
      socket/transport suites and record exact counts; freeze the evidence identifier.
- [ ] **T1-2-B Extraction** — owners introduced; public interface contracts unchanged;
      event ordering and stream shapes identical.
- [ ] **T1-2-C Hardening** — focused tests for reconnect/backoff ownership, response
      correlation, and hosted-media delegation; each fails if the behavior is removed.
- [ ] **T1-2-D Contracts and docs** — update the owning contract for this directory (and
      `client/AGENTS.md` only if a durable law changes); run `graphify update .`.
- [ ] **T1-2-E Verification** — `fvm flutter analyze` clean; focused suites pass at or
      above baseline; the client full suite passes once on the frozen candidate.

## Target T1-3 — Conversation cache store decomposition

Owner file: `client/lib/features/conversations/domain/stores/conversation_cache_store.dart`
(1,137 lines) with 42 public methods.

Co-located responsibilities: device context and cache generations; workspace mutation
projection; section loading/error state; session list and history revision projection;
draft persistence; snapshot restore.

Proposed owners:

- `WorkspaceCacheProjection` — workspace create/update/remove/refresh application.
- `SessionSectionCache` — sections, sessions, selection, loading and error flags.
- `ConversationDraftCache` — draft read/write/clear.
- `CacheGenerationGuard` — device/workspace/request generations and staleness rejection.
- `ConversationCacheStore` — facade preserving the current public surface.

### T1-3 gates

- [ ] **T1-3-A Baseline** — inventory the 42 public methods by concern; run the cache-store
      suites and record exact counts; freeze the evidence identifier.
- [ ] **T1-3-B Extraction** — owners introduced; snapshot equality, listener notification
      order, and generation invalidation unchanged.
- [ ] **T1-3-C Hardening** — focused tests per owner, including a staleness-rejection test
      that fails if the generation guard is bypassed.
- [ ] **T1-3-D Contracts and docs** — update the owning contract and any documented
      projection rule; run `graphify update .`.
- [ ] **T1-3-E Verification** — `fvm flutter analyze` clean; focused suites pass at or
      above baseline; the client full suite passes once on the frozen candidate.

## Tier gates

- [ ] **T1-X1 Integration** — each accepted target branch is merged into this tier branch
      with no lost file; `merge_validate` reports ok for any conflict-resolved file.
- [ ] **T1-X2 Tier verification** — on the frozen tier candidate: agent analyzer and suite,
      then client analyzer and suite, run serially with recorded counts.
- [ ] **T1-X3 Delivery** — accepted tier work is merged into the single SRP pull request head branch
      `feature/110-critical-priority-srp-refactoring` (PR #225) instead of opening a new pull request; that
      PR's title, body and labels are updated to describe the full diff, and its checks must be green on the
      exact pushed SHA. Ready-conversion and merge remain user-owned.
- [ ] **T1-X4 Worktree lifecycle** — per-target worktrees and branches removed after their
      work is pushed into the tier branch and CI is green.

## Acceptance Criteria

- [ ] Each of the three files keeps a single-sentence purpose and delegates every extracted
      responsibility to exactly one owner; no responsibility stays ownerless or double-owned.
- [ ] Public API: every pre-existing public member of the three files is still reachable
      with the same name and signature (facade or forwarder allowed).
- [ ] Behavior: `session_db` SQL and returned shapes, socket event ordering/stream shapes,
      and cache snapshot equality are unchanged, proven by the existing suites plus the new
      owner-level tests.
- [ ] Analyzers report no issues and both package suites pass with counts at or above the
      recorded baseline.
- [ ] No protocol, payload, UI string, or localization change; no new dependency.
- [ ] Owning contracts and `docs/` statements describe the final ownership, with stale
      statements about the old structure removed.

## Definition of Done

- [ ] All tier and target gates closed with recorded evidence (command, exit code, counts,
      duration, log path).
- [ ] Pushed into the single SRP pull request (#225) with labels, title and body reflecting the full
      diff, and CI green on the exact head SHA.
- [ ] `graphify` graph refreshed with `graphify update .` and this plan moved to
      `docs/plans/tasks/done/` with `status: completed` and `remaining_estimate: 0%` when the
      tier is accepted.
- [ ] No merge into `main`, no ready-conversion, and no protected label without explicit
      user authorization.
