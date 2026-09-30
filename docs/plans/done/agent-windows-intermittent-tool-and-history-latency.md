---
status: superseded
closure_reason: remaining-work-transferred-not-certified-complete
superseded_by: docs/plans/97-windows-first-agent-client-performance.md
current_gate: closed-transferred
priority: high
security_review: conditional
platforms: windows-primary, macos-baseline, linux-baseline
depends_on: sanad-dev-windows-secure-runtime-file-performance
---

# Agent Windows Intermittent Tool and Conversation-History Latency

## Closure and transfer to Plan 97

**Closed as superseded, not completed.** This file is a historical evidence record,
not an active execution queue. All previously unchecked items (23 entries)
are transferred to the successor owners below. Checked items retain their
historical meaning; no unverified acceptance or security result is marked passed.
The successor owns the complete original obligations, including negative cases,
security review, documentation and delivery reconciliation, not only a summary.
Archived under docs/plans/done with superseded status; references point to this record or its Plan 97 successor. No independent work remains here.

| Original outstanding scope | New execution owner |
|---|---|
| G0 — samples/correlation/isolated baseline | [97a](docs/plans/tasks/97a-baseline-and-ownership.md) |
| G1 — partition tool/transport/history waits | [97f](docs/plans/tasks/97f-agent-responsiveness.md) |
| G1 — provider hydration and readiness partition | [97g](docs/plans/tasks/97g-readiness-and-loading.md) |
| G2 — owner-layer fixes, deterministic regressions, documentation | [97f](docs/plans/tasks/97f-agent-responsiveness.md) |
| G2 — provider/UI readiness corrections | [97g](docs/plans/tasks/97g-readiness-and-loading.md) |
| G3 + DoD — Windows targets, security where applicable, final platform/interactive evidence | [97k](docs/plans/tasks/97k-regression-budgets-and-report.md) |
| G3 + DoD — live responsiveness and configured-provider acceptance | [97l](docs/plans/tasks/97l-interactive-final-acceptance.md) |

## Historical plan and evidence (non-executable)

The following goals, gates and acceptance statements describe the original task.
`Transferred` entries are preserved requirements now owned by the table above;
they are not open checkboxes in this retired plan. Historical commands and merge
instructions do not authorize new execution or duplicate delivery.



## Goal

Identify and remove intermittent multi-second latency in otherwise lightweight
Agent and Client operations on Windows without weakening tool authorization,
workspace path checks, persistence durability, socket ordering, or process-tree
containment.

## Evidence and boundary

- On the affected Windows runtime, lightweight tool UI indicators such as
  `file_edit` commonly remain active for two seconds or more, while the same
  operation appears immediate on Linux and macOS.
- Loading the same conversation history varies from less than one second to
  roughly 3–10 seconds without corresponding CPU, memory, or disk saturation.
- `FileEditHandler` performs in-process path resolution, file read/replace/write,
  and result encoding. It does not start PowerShell, Dart, or `sanad-dev` child
  processes.
- Conversation history uses a distinct Client socket and Agent-owned persistence
  path. These observations do not share the repeated PowerShell mechanism fixed
  by `sanad-dev-windows-secure-runtime-file-performance`.
- A cloud-origin command sent while `file_edit` was executing was not logged as
  received until the tool completed and the model loop continued. The same
  starvation has not been observed during `shell_execute`. `file_edit` itself is
  also visibly slow on Windows. Treat tool duration and transport/event-loop
  responsiveness as separate measurements with a potentially shared owner.
- During a Windows isolated-Home launch, the Client requested
  `provider.runtime_check` at `19:58:08.478` and displayed **Provider setup
  required** before provider instances finished hydrating. Instance listing
  arrived only at `19:58:13.417`; a subsequent test of the configured default
  provider completed successfully at `19:59:16.916`. The copied database held
  four provider instances and the UI later showed all four as `READY`, proving
  that the initial empty/not-ready presentation was premature rather than an
  actually unconfigured Home.
- Treat delayed Agent provider-readiness/list hydration on Windows as the
  high-priority root problem. Client-side readiness gating is a secondary race
  to harden after Agent timing is partitioned; it must not mask slow Agent
  startup or silently assume that an early empty result is authoritative.
- The existing `sanad-dev` task must finish first so subprocess amplification is
  removed as a confounding variable. This plan does not require moving the main
  runtime or copying an existing Sanad Home.

## In scope

- End-to-end timing markers for tool request receipt, authorization, handler
  entry/exit, persistence/journaling, socket response, Client state update, and
  visible completion.
- Transport responsiveness while a deliberately slow workspace handler runs:
  local and cloud commands must be received/logged and independent lightweight
  queries must complete without waiting for that tool's terminal result.
- Focused internal timing for `file_edit`: path resolution, read, replacement,
  write/flush behavior, and response encoding.
- Focused history timing: socket request, Agent query, row decoding, payload
  transfer, Client mapping/cache update, and first rendered frame.
- Provider startup/readiness timing: database/provider-instance hydration,
  credential resolution, model/catalog readiness, runtime-check request and
  response, instance-list response, and the Client decision to show setup.
- Windows-specific filesystem, database-lock, antivirus/filter-driver, socket,
  timer, and event-loop hypotheses, compared with macOS/Linux baselines.
- Cold/warm distributions and concurrent-session effects rather than one-off
  averages.

## Out of scope

- Disabling durability, authorization, Job Object containment, path validation,
  or conversation ordering to improve benchmark numbers.
- Runtime source switching as a diagnostic shortcut. Use a fresh isolated Home
  and worktree runtime unless an explicitly authorized switch is later proven
  necessary.
- Folding speculative Agent/Client changes into the secure-runtime-file PR.

## Gates

### G0 — Reproduce and partition

- **Transferred to Plan 97:** Record at least 30 cold and warm samples for a tiny `file_edit` operation.
- **Transferred to Plan 97:** Record at least 30 repeated loads of one fixed conversation page.
- **Transferred to Plan 97:** Record at least 30 Windows startup/readiness samples for a Home with known
      configured providers, plus macOS/Linux baselines; distinguish an early
      not-ready response from authoritative provider absence.
- **Transferred to Plan 97:** Capture Agent, gateway/socket, Client, and UI timestamps using one
      correlation identifier and monotonic clocks.
- **Transferred to Plan 97:** Compare an isolated fresh Home with the current managed runtime without
      copying identity, secrets, databases, or ACL-bound state.

### G1 — Locate the wait

- **Transferred to Plan 97:** Separate queue/dispatch time from handler execution for workspace tools.
- **Transferred to Plan 97:** Determine whether delayed commands are blocked by synchronous path/replace
      work, serialized bridge dispatch, transport backpressure, or response
      publication, and compare `file_edit` with `shell_execute`.
- **Transferred to Plan 97:** Separate database query, serialization, socket transit, state mapping, and
      rendering for conversation history.
- **Transferred to Plan 97:** Partition provider readiness into Agent bootstrap, provider-instance DB
      load, credential availability, catalog/model refresh, gateway dispatch,
      and Client gating; identify why the Windows path trails other platforms.
- **Transferred to Plan 97:** Correlate outliers with database locks, filesystem/filter-driver events,
      garbage collection, socket reconnect/auth recovery, and concurrent tools.
- **Transferred to Plan 97:** Determine whether the UI spinner measures server execution or includes
      request queueing and post-response rendering.

### G2 — Design and implementation

- **Transferred to Plan 97:** Select the smallest owner-layer fix supported by G0–G1 evidence.
- **Transferred to Plan 97:** Preserve fail-closed authorization, durable writes, ordered history, and
      bounded logs.
- **Transferred to Plan 97:** Add deterministic regression tests and an outlier-sensitive benchmark.
- **Transferred to Plan 97:** Update the owning Agent/Client technical and QA documentation.

### G3 — Verification

- **Transferred to Plan 97:** Verify focused and full relevant Agent/Client suites on Windows.
- **Transferred to Plan 97:** Verify macOS and Linux regression coverage.
- **Transferred to Plan 97:** Demonstrate the agreed p50/p95 improvement in a fresh isolated runtime.
- **Transferred to Plan 97:** Obtain security review if the fix touches authorization, persistence,
      socket authentication, or process containment.

## Definition of done

- Timing evidence identifies the dominant wait rather than inferring it from the
  UI spinner.
- Lightweight tools and repeated history loads meet explicit p50/p95 targets on
  Windows with no security or durability regression.
- Local and cloud command receipt remains responsive during a slow workspace
  tool; an independent lightweight query is not serialized behind tool
  completion, and the regression is covered deterministically.
- A Windows Home with configured, usable providers never presents them as absent
  because readiness hydration is still in progress; Agent readiness meets the
  agreed p50/p95 target and the Client distinguishes loading from authoritative
  empty/not-ready state.
- The fix remains isolated from the secure runtime file and stale lease recovery
  changes unless measurements prove a shared owner-layer cause.
