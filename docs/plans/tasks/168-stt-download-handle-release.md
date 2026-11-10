# 168 — Dictation download releases every file handle on close

**Status:** implemented on `fix/stt-windows-handle`
**Owners:** `agent/lib/infrastructure/stt/stt_download_pipeline.dart` (the shipped
isolate pipeline and its `close()` contract)
**Contract:** [docs/technical/local_dictation.md](../../technical/local_dictation.md)
**Predecessor:** #165 / PR403 (the writeback overlap whose two isolates own the two
handles), #166 / PR404 (the sibling failure in the same suite)
**Evidence:** PR405 run `42911356395`, job `Native dictation (windows-2025)`

## Goal

`SttWritePipeline.close()` is the handle boundary as well as the durability
boundary: when it returns, every descriptor the artifact opened is closed, so the
store can rename or delete the `.partial` in its very next statement on every
platform — including Windows, which refuses both while any handle is open.

## Locked decisions and scope

- **The pipeline changes, not the store.** The store already closes the pipeline
  in a `finally` on every failure path (`stt_model_store.dart`). The defect is
  that `close()` could return without releasing anything.
- **A kill is not a release.** Measured locally: `Isolate.kill(immediate)` plus
  the isolate's `exit` event leaves the descriptor open in the process. Only
  `closeSync()` inside the owning isolate releases it, so `close()` must ask the
  flusher and wait, not only end it.
- **No short-circuit.** A pipeline whose writer or flusher already ended still
  tears down and still rethrows its typed failure.
- No change to the write window, the flush governor, the degradation rule, the
  typed failure mapping, or the store's retry and activation logic.

## Gates

### G0 — Root cause
- [x] Reproduce the red assertion from the Windows job log and locate the handle.
- [x] Separate the test-only leak from the shipped-pipeline gap.
- [x] Prove the kill-versus-release behaviour of `dart:io` on this host.

### G1 — Implementation
- [x] `close()` always tears down, is idempotent, and awaits both isolate exits.
- [x] The flusher confirms its own `closeSync()` to the pipeline over its own
      channel (writer↔flusher flush traffic unchanged).
- [x] The flusher closes its handle on a refused flush as well.
- [x] The test that leaked a sink closes it and asserts the typed rethrow.

### G2 — Verification
- [x] `fvm dart analyze lib/infrastructure/stt test/stt` — clean.
- [x] The eight STT suites, each in its own process — all pass.
- [x] The new guard test is deterministically red against the previous `close()`
      and green with the fix (3 consecutive runs each way).
- [x] Cross-platform handle detector: Windows rename probe, Linux
      `/proc/self/fd`, macOS `lsof`.

### G3 — Delivery
- [x] Commit, push, open a non-draft PR with `type/bug`, `comp/agent`,
      `platform/windows`, and `size/small`, and wait with
      `gh run watch --exit-status --compact` until the exact-head run settles:
      run `42915706865` on `06965aeb` is `success` (23 pass, 4 skipped by path
      classification, 0 failing).

## Acceptance Criteria

- [x] Given a pipeline whose writer already ended, when `close()` is called, then
      it rethrows the recorded `SttWriteFailure`, runs the teardown once, and a
      second `close()` is a no-op.
- [x] Given a completed artifact, when `close()` returns, then the artifact can be
      renamed and deleted immediately and this process holds no descriptor on it.
- [x] Given a refused write through the in-process seam, when the caller closes
      the pipeline, then the sink is closed even though the write failed, and the
      typed failure reaches the caller through `close()` as well.
- [x] Automated coverage proves all three on macOS and Linux locally, and asserts
      the same properties on the Windows lane, where the rename/delete probe is
      the decisive form of the check.

## Definition of Done

- [x] Contracts updated: `docs/technical/local_dictation.md` owns the close
      contract; the pipeline's own doc comments state the handle guarantee.
- [x] `docs/llms.txt` indexes this task.
- [x] Public CI green on the exact head SHA `06965aeb`.
- [x] `graphify update .` after the code change.

## Current status

All gates closed on PR [#406](https://github.com/EastStarAI/sanad-agent/pull/406)
(head `06965aeb`, CI `success`). Remaining work: review and merge, both outside
this task's authorization.
