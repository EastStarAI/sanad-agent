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
- The existing `sanad-dev` task must finish first so subprocess amplification is
  removed as a confounding variable. This plan does not require moving the main
  runtime or copying an existing Sanad Home.

## In scope

- End-to-end timing markers for tool request receipt, authorization, handler
  entry/exit, persistence/journaling, socket response, Client state update, and
  visible completion.
- Focused internal timing for `file_edit`: path resolution, read, replacement,
  write/flush behavior, and response encoding.
- Focused history timing: socket request, Agent query, row decoding, payload
  transfer, Client mapping/cache update, and first rendered frame.
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
- [ ] Capture Agent, gateway/socket, Client, and UI timestamps using one
      correlation identifier and monotonic clocks.
- [ ] Compare an isolated fresh Home with the current managed runtime without
      copying identity, secrets, databases, or ACL-bound state.

### G1 — Locate the wait

- [ ] Separate queue/dispatch time from handler execution for workspace tools.
- [ ] Separate database query, serialization, socket transit, state mapping, and
      rendering for conversation history.
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
- The fix remains isolated from the secure runtime file and stale lease recovery
  changes unless measurements prove a shared owner-layer cause.
