---
title: "Task 160: STT Install Memory-Bound Test Stability"
description: "Make the dictation download backpressure test host-independent after it failed a pull-request run on a socket-buffer ceiling, without weakening the guarantee it pins."
status: "completed"
current_gate: "Complete"
remaining_estimate: "0%"
priority: "high"
depends_on: "Task 159; PR391 (11230022)"
---

## Goal

`agent/test/stt/stt_install_memory_bound_test.dart` either fails or passes on any
host, for reasons that belong to the transfer under test and not to the machine
running it, while still proving the PR391 guarantee: a dictation model download
keeps one chunk in flight and never holds a share of the artifact.

## Locked Decisions and Scope

- Test-only change. No production behavior, no new seam, no protocol change; the
  store's writer path stays exactly as PR391 shipped it.
- The absolute socket-buffer ceiling is not raised. It is replaced by the property
  it was standing in for: the pipeline seals while a write is pending.
- The download envelope keeps a coarse limit (half the artifact) and stops being
  charged across retries or across the atomic rename.
- The `SttWriteSink` seam asserts the sent contract directly: one write in flight.
- A retry that follows a dropped connection is pinned by its own test, because
  that shape produced the false failure (1.85 artifacts measured on CI).
- Out of scope: the hosted CDN's `Range` behavior (recorded as a documentation
  note only), the live memory runbook, and any change to install behavior.

## Gates

### G0 — Discovery

- [x] Read the failing assertions and the CI evidence for run `42741990207`
      attempt 1 (`Test agent (2/4)`, job `129585159196`).
- [x] Prove no RSS is measured anywhere in the repository; identify the two
      quantities actually asserted.
- [x] Measure the real store's envelope on a developer host and the socket
      absorption ceiling idle and under CPU load.
- [x] Reproduce the retry-driven false positive against the unmodified store.

### G1 — Implementation

- [x] Replace the fixed 300 ms settlement and `stalledQueueLimit` with a bounded
      stability wait and a growth assertion.
- [x] Count server bytes per response so a retried transfer is not charged the
      attempt it replaced.
- [x] Stop the envelope sampler when the phase leaves `downloading`.
- [x] Inject the counting sink and assert one write in flight for both the plain
      and the retried install.
- [x] Add the retry-regression test with a first response truncated at 60 %.

### G2 — Verification and Delivery

- [x] Analyzer passes for the changed file and for `agent`.
- [x] The file passes ten consecutive runs, and further runs under parallel CPU
      load.
- [x] The mutation proof fails: a read loop that stops awaiting the write must
      fail the guards, and the mutation is reverted uncommitted.
- [x] Public CI is green on the exact head commit of attempt 1, without a rerun
      (run `42745350893`, `Test agent (2/4)` pass, `All required checks pass`).
- [x] Owning documentation states the Range dependency of resume.

## Acceptance Criteria

- [x] Given a write that is held open, when the download's accepted bytes are
      sampled after the pipeline settles, then the growth across a 300 ms window
      is at most one chunk, and the artifact is never absorbed.
- [x] Given a healthy install, when the envelope is sampled, then the gap stays
      under half the artifact and the writer never sees two concurrent writes.
- [x] Given a first response that ends 40 % short, when the store retries, then
      the install completes, exactly two responses are served, and the envelope
      stays under half the artifact.
- [x] No assertion compares against a host socket constant, and no test retries or
      reruns to pass.

## Definition of Done

- [x] `fvm dart analyze` clean for `agent`.
- [x] The focused test file passes repeatedly, including under parallel CPU load.
- [x] `docs/technical/local_dictation.md` records that resume depends on the host
      honouring `Range`.
- [x] Graphify updated after the change.
- [x] Pull request opened against `main` with the task file included; not merged.
