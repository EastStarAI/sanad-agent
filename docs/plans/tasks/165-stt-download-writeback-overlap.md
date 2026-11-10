# 165 — Dictation download writeback overlap

**Status:** implemented on `fix/stt-download-flush`
**Owners:** `agent/lib/infrastructure/stt/stt_download_pipeline.dart`
**Contract:** [docs/technical/local_dictation.md](../../technical/local_dictation.md)
**Predecessor:** #164 / PR402 (the per-byte cost this made visible)

## Problem

After PR402 the download's *transfer* reaches 87 % of the host's disk ceiling,
but the *install* still lands at half of it. Measured live on the owner's
reference server (Ubuntu arm64, 24.5 GB RAM, `dd … conv=fdatasync` 54.7 MB/s),
real catalog URL:

| Object | Bytes | Transfer | Final fsync | Total | Effective |
|---|---|---|---|---|---|
| `egy-whisper-turbo-ggml-f16` | 1 624 555 275 | 36.0 s (45.1 MB/s) | **23.8 s** | 59.88 s | 27.1 MB/s |
| `whisper-medium-en-ggml-q8` | 823 382 461 | 17.3 s (47.6 MB/s) | **13.1 s** | 30.40 s | 27.1 MB/s |

During the transfer the device wrote 0–12 MB/s while `Dirty` climbed linearly to
1 328 MB and `Writeback` stayed at zero; the final fsync then drained 1.13 GB at
49–52 MB/s with the network idle. The cause is not the pipeline: the writer
isolate never forces the page cache out while the artifact is arriving, and Linux
defers writeback to `dirty_expire_centisecs` (30 s) because
`dirty_background_ratio` is 10 % of 24.5 GB (2.45 GB) — far above one artifact.
So the single `flushSync()` in the writer's `close` handler pays for the whole
download as one serial tail, and the faster the transfer, the bigger the tail:
the tail grew from ~5.6 s (old, slow transfer) to 23.8 s and swallowed the gain.

## Decision

Force writeback **inside** the transfer:

1. `_writerMain` counts bytes since its last flush and calls `flushSync()`
   every `kSttFlushWindowBytes` (64 MiB) **before** it acknowledges that write,
   so the reader's window is released only after the bytes are really on the
   disk. A disk slower than the link then paces the read instead of accumulating
   a tail — the intended behaviour, and the reason no new bound is introduced.
2. `InProcessWritePipeline` applies the same cadence through its sink's
   `flush()`, before it releases the window. One shared `_FlushWindow` ledger and
   one shared `kSttFlushWindowBytes` constant serve both backends.
3. The `flushSync()` on `close` stays. Durability against a power cut is
   unchanged; it now only forces the last, sub-window tail.

Not done, deliberately: dropping the close flush (same speed, weaker durability
for a torn `.partial`), a bigger write buffer, parallel `Range` workers (already
rejected on measurement in #164), a longer timeout.

Expected on the reference server: f16 ≈ `max(36 s, 30 s)` ≈ 34–36 s (from
59.88 s) and medium-en ≈ 17.3 s (from 30.40 s), i.e. the transfer rate itself.

## Gates

### G0 — Discovery

- [x] Read the live measurement and the writer/close path it names
      (`stt_download_pipeline.dart` `_writerMain`, `stt_model_store.dart` `_transfer`).
- [x] Confirm the in-process test pipeline owns the same rule through its sink.
- [x] Confirm plan number `165` is free on `main` and in the open PR set.

### G1 — Implementation

- [x] Add `kSttFlushWindowBytes` (64 MiB) beside `kSttWriteWindowBytes`.
- [x] Flush every window in `_writerMain` before the ack, and in the in-process
      pump before the window is released, through one shared ledger.
- [x] Keep the final flush on close; typed failure for a refused flush.

### G2 — Verification

- [x] Pipeline tests: cadence (two writebacks in ten chunks over a four-chunk
      window, plus one at close), no mid-transfer flush for a short artifact,
      a refused flush typed as `SttWriteFailure`/`storage_full`, `drain` waiting
      for the forced writeback, and the shipped isolate path keeping the bytes
      on both sides of a real 64 MiB boundary.
- [x] Analyzer clean over `lib/infrastructure/stt` and `test/stt`.
- [x] The affected suites green, each in its own process: `stt_digest_test`,
      `stt_download_pipeline_test`, `stt_install_memory_bound_test`,
      `stt_install_resume_test`, `stt_model_store_test`,
      `stt_install_control_test`, `dictation_control_install_test`,
      `dictation_model_readiness_test`.
- [x] macOS loopback bench (1 GiB artifact, median of three) shows no material
      regression.
- [x] The pipeline ratio guard stays a hop-cost guard: CI showed it failing at
      0.47 because a 64 MiB transfer now ends with a forced writeback, which
      measures the runner's disk latency rather than the isolate hop. The guard
      now stops one block short of the window, and the flush cadence keeps its
      own assertions above.

### G3 — Documentation and delivery

- [x] `docs/technical/local_dictation.md`: the writeback cost, and the
      `max(network, disk)` shape of an install.
- [x] `agent/AGENTS.md`: the install invariant names the periodic flush.
- [x] Non-draft PR with `type/performance`, `comp/agent`, `comp/install-update`.

## Acceptance Criteria

- [x] Given an artifact larger than 64 MiB, when it is written, then the page
      cache is forced out once per completed 64 MiB window and once at close,
      and no write is acknowledged ahead of its flush.
- [x] Given an artifact smaller than one window, when it is installed, then no
      writeback happens before close.
- [x] Given a flush the volume refuses, when it happens, then the pipeline
      reports `SttWriteFailure` (mapping to `storage_full` for `ENOSPC`) exactly
      as a refused write does.
- [x] Given a parked flush, when `drain()` is called, then it does not return
      until the flush completes.
- [x] Given the whole affected suite set, when each file runs in its own
      process, then every test passes and the analyzer is clean.

## Definition of Done

- [x] Analyzer clean over the changed tree; focused suites green.
- [x] The owning contract and design documentation updated in the same change.
- [x] Live-server verification is deferred to the coordinator's Oracle run: this
      host cannot reproduce a writeback-bound transfer, and `~/.sanad` is out of
      scope for this change.
- [ ] Coordinator re-measures the two catalog objects on the reference server
      and closes the `max(network, disk)` expectation against a real number.

## Current status

All gates closed except the coordinator's live re-measurement. Remaining work in
this plan: none in code.
