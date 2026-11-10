# 165 — Dictation download writeback overlap

**Status:** implemented on `fix/stt-download-flush`
**Owners:** `agent/lib/infrastructure/stt/stt_download_pipeline.dart`
**Contract:** [docs/technical/local_dictation.md](../../technical/local_dictation.md)
**Predecessor:** #164 / PR402 (the per-byte cost this made visible)

## Problem

After PR402 the download's *transfer* reached 87 % of the host's disk ceiling,
but the *install* still landed at half of it. Measured live on the owner's
reference server (Ubuntu arm64, 24.5 GB RAM, `dd … conv=fdatasync` 54.7 MB/s),
real catalog URL:

| Object | Bytes | Transfer | Final fsync | Total | Effective |
|---|---|---|---|---|---|
| `egy-whisper-turbo-ggml-f16` | 1 624 555 275 | 36.0 s (45.1 MB/s) | **23.8 s** | 59.88 s | 27.1 MB/s |
| `whisper-medium-en-ggml-q8` | 823 382 461 | 17.3 s (47.6 MB/s) | **13.1 s** | 30.40 s | 27.1 MB/s |

During the transfer the device wrote 0–12 MB/s while `Dirty` climbed linearly to
1 328 MB and `Writeback` stayed at zero; the final fsync then drained 1.13 GB at
49–52 MB/s with the network idle. Nothing in the writer's per-chunk path forced
the page cache out, so Linux deferred writeback to `dirty_expire_centisecs`
(30 s) — `dirty_background_ratio` is 10 % of 24.5 GB (2.45 GB) and was never
reached — and the single `flushSync()` in the writer's `close` handler paid for
the whole artifact.

## Decision

Force writeback **inside** the transfer, and never on the writer's thread.

1. **A second isolate owns writeback.** `_flusherMain` opens its own handle of
   the same path (append mode, so it can never truncate the artifact) and runs
   `flushSync()` when told. Two isolates are two OS threads, which is what the
   overlap needs: an fsync and a write are both blocking syscalls on the calling
   isolate's thread, and a second *async* `flush()` on the writer's own handle is
   not an option either — `RandomAccessFile` refuses two concurrent operations on
   one handle (`An async operation is currently pending`), and its async service
   is the same one a write waits on. `fsync` on any descriptor flushes the file's
   dirty pages, so no handle handoff is needed; the writer's own handle still
   performs the final flush, so durability is unchanged.
2. **`_FlushGovernor` is the one rule both pipelines obey.** A flush is due every
   `kSttFlushWindowBytes` (64 MiB) of written bytes; a request that arrives while
   one is running is coalesced into one remembered request, never a queue; and
   the writer may not run more than **two windows ahead of the last completed**
   flush (`canAccept`), which caps the dirty page cache at ~128 MiB whatever the
   artifact size and turns a disk slower than the link into read backpressure.
3. **`InProcessWritePipeline` mirrors the rule** — the flush is started and not
   awaited, and the same bound stops the pump — so the cadence, the bound, the
   coalescing and the failure typing are all asserted on the seam unit tests
   drive. Its sink holds two handles for the same reason.
4. **Close is the durability boundary.** Writes are drained, a running flush is
   awaited, and the remainder is forced on the writer's handle; a refused flush
   is the same typed `SttWriteFailure` (`storage_full` for `ENOSPC`) a refused
   write is.

Rejected: a synchronous `flushSync()` in the writer (the first review round — it
keeps the end-to-end at `network + disk`, measured 34.4 s against 31.9 s), a
one-copy handoff of the piece (`TransferableTypedData.fromList` in the reader,
`materialize()` in the writer, replacing the copy-before-send pair: measured
28.0 CPU-s/GB against 27.6 and 32.18 s against 31.85 s on the same host and URL,
i.e. noise, so it was dropped rather than kept), a bigger write buffer, parallel
`Range` workers (#164), a longer timeout.

## Result (reference server, real f16 URL, interleaved, median of 3)

Shipped `SttModelStore.install` path, AOT linux-arm64 build of the same bench,
scratch dir outside the Sanad Home:

| Build | End to end | Transfer | Tail | Peak `Dirty` | CPU-s/GB |
|---|---|---|---|---|---|
| close-only flush (`origin/main`) | 59.12 s (26.2 MB/s) | 28.9 s | 30.2 s | 1 500 MB | 27.1 |
| synchronous 64 MiB flush (first round) | 34.37 s (44.8 MB/s) | 34.3 s | 0.06 s | 58 MB | 27.2 |
| **asynchronous flush (this design)** | **31.85 s (48.6 MB/s)** | 30.6 s | 1.27 s | **66 MB** | 27.6 |

Target was ≈ `max(network, disk)` ≈ 34–36 s and peak `Dirty` ≤ ~150 MB: the
overlap lands at 31.85 s — `max(30.6 s read, 29.7 s disk)` — with 66 MB of dirty
page cache instead of 1.5 GB, and CPU per byte unchanged (the fsync is I/O wait).

## Gates

### G0 — Discovery

- [x] Read the live measurement and the writer/close path it names
      (`stt_download_pipeline.dart` `_writerMain`, `stt_model_store.dart` `_transfer`).
- [x] Confirm the in-process test pipeline owns the same rule through its sink.
- [x] Confirm plan number `165` is free on `main` and in the open PR set.

### G1 — Implementation

- [x] `kSttFlushWindowBytes` (64 MiB) beside `kSttWriteWindowBytes`.
- [x] `_FlushGovernor`: cadence, coalescing, two-window bound, idle/abandon.
- [x] Flusher isolate with its own handle; writer keeps writing while it runs.
- [x] Close: drain writes → await a running flush → final `flushSync()`; typed
      failure for a refused flush on both pipelines.

### G2 — Verification

- [x] Pipeline tests: cadence (two writebacks in ten chunks over a four-chunk
      window, plus one at close), no mid-transfer flush for a short artifact,
      the writer keeps writing while a flush is parked, the two-window bound
      stops the reader, coalescing (one running + one remembered, no re-arm for
      bytes already covered), close waiting for a running flush, a refused flush
      typed as `SttWriteFailure`/`storage_full`, and the shipped isolate path
      keeping every byte in order across repeated writebacks.
- [x] Analyzer clean over `lib/infrastructure/stt` and `test/stt`.
- [x] The affected suites green, each in its own process: `stt_digest_test`,
      `stt_download_pipeline_test`, `stt_install_memory_bound_test`,
      `stt_install_resume_test`, `stt_model_store_test`,
      `stt_install_control_test`, `dictation_control_install_test`,
      `dictation_model_readiness_test`.
- [x] Reference-server AOT measurement of all three builds (§Result).
- [x] The pipeline ratio guard stays a hop-cost guard: it now transfers one block
      under the writeback window, because the first head measured the runner's
      fsync latency instead of the isolate hop (0.47 against its `> 0.5` bound).

### G3 — Documentation and delivery

- [x] `docs/technical/local_dictation.md`: the writeback cost, the two-isolate
      shape, and the three-build table.
- [x] `agent/AGENTS.md`: the install invariant names the flusher isolate, the
      two-window bound, the coalescing and the close/flush failure law.
- [x] Non-draft PR with `type/performance`, `comp/agent`, `comp/install-update`.

## Acceptance Criteria

- [x] Given an artifact larger than 64 MiB, when it is written, then writeback is
      forced once per completed window and once at close, and the writer keeps
      writing while a flush runs.
- [x] Given more than two windows of unflushed bytes, when the writer would
      exceed the bound, then it stops acknowledging until a flush completes.
- [x] Given a flush already running, when more windows are written, then exactly
      one further request is remembered and only issued if still needed.
- [x] Given an artifact smaller than one window, when it is installed, then no
      writeback happens before close.
- [x] Given a flush the volume refuses, when it happens, then the pipeline
      reports `SttWriteFailure` (mapping to `storage_full` for `ENOSPC`).
- [x] Given a parked flush, when `close()` is called, then it does not return
      until that flush and the final flush complete.
- [x] Given the real f16 URL on the reference server, when the shipped pipeline
      installs it, then the end to end is within `max(network, disk)` and peak
      `Dirty` stays under 150 MB.

## Definition of Done

- [x] Analyzer clean over the changed tree; focused suites green.
- [x] The owning contract and design documentation updated in the same change.
- [x] Live verification on the reference server (read-only GET, scratch dir
      outside the Sanad Home, service untouched).
- [ ] Merge decision stays with the maintainer: the PR is opened green, not merged.

## Current status

All gates closed. The PR is open, green on its exact head, and unmerged by
instruction.
