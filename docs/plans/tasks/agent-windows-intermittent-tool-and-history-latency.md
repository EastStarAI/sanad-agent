---
status: planned
priority: high
security_review: conditional
platforms: windows-primary, macos-baseline, linux-baseline
depends_on: sanad-dev-windows-secure-runtime-file-performance
---

# Agent Windows Intermittent Tool and Conversation-History Latency

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

- [ ] Record at least 30 cold and warm samples for a tiny `file_edit` operation.
- [ ] Record at least 30 repeated loads of one fixed conversation page.
- [ ] Record at least 30 Windows startup/readiness samples for a Home with known
      configured providers, plus macOS/Linux baselines; distinguish an early
      not-ready response from authoritative provider absence.
- [ ] Capture Agent, gateway/socket, Client, and UI timestamps using one
      correlation identifier and monotonic clocks.
- [ ] Compare an isolated fresh Home with the current managed runtime without
      copying identity, secrets, databases, or ACL-bound state.

### G1 — Locate the wait

- [ ] Separate queue/dispatch time from handler execution for workspace tools.
- [ ] Determine whether delayed commands are blocked by synchronous path/replace
      work, serialized bridge dispatch, transport backpressure, or response
      publication, and compare `file_edit` with `shell_execute`.
- [ ] Separate database query, serialization, socket transit, state mapping, and
      rendering for conversation history.
- [ ] Partition provider readiness into Agent bootstrap, provider-instance DB
      load, credential availability, catalog/model refresh, gateway dispatch,
      and Client gating; identify why the Windows path trails other platforms.
- [ ] Correlate outliers with database locks, filesystem/filter-driver events,
      garbage collection, socket reconnect/auth recovery, and concurrent tools.
- [ ] Determine whether the UI spinner measures server execution or includes
      request queueing and post-response rendering.

### G2 — Design and implementation

- [ ] Select the smallest owner-layer fix supported by G0–G1 evidence.
- [ ] Preserve fail-closed authorization, durable writes, ordered history, and
      bounded logs.
- [ ] Add deterministic regression tests and an outlier-sensitive benchmark.
- [ ] Update the owning Agent/Client technical and QA documentation.

### G3 — Verification

- [ ] Verify focused and full relevant Agent/Client suites on Windows.
- [ ] Verify macOS and Linux regression coverage.
- [ ] Demonstrate the agreed p50/p95 improvement in a fresh isolated runtime.
- [ ] Obtain security review if the fix touches authorization, persistence,
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
