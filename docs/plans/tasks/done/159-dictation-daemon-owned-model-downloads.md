# Dictation model downloads: bounded, resumable, daemon-owned

Delivered in [PR391](https://github.com/EastStarAI/sanad-agent/pull/391). Numbered 159 because PR388 landed
`158-sanad-dev-stable-web-origin.md` on `main` first.

## Goal
A dictation model install is daemon-owned, memory-bounded, resumable, and visible to
every client from `stt_status`, so closing the model sheet, switching devices, or
reconnecting never loses a running download and a second press never starts a second
writer or destroys the bytes already on disk.

## Evidence
Two studies, both read-only, both on the primary Mac agent (v1.0.22):

- `daemon-memory-v1022-study-20260909` (memory): the file sink accumulates without
  backpressure — `IOSink.add` is `void`, so while `_FileStreamConsumer` has the
  subscription paused every arriving chunk is queued in the Dart heap. Measured
  **723 MB untagged / 878 MB footprint** for the 823 MB artifact when the producer
  outruns the sink, **187 MB** with `await raf.writeFrom(chunk)`, and **180 MB** when
  paced at the owner's real 3.2 MiB/s. The owner's live series climbed **+2.2 MB/s** at
  4 % CPU while the download ran and fell **−2.25 GB** when it stopped, with RSS falling
  as the footprint rose — a write-only buffer, not a retained object graph.
- `dictation-download-and-device-switch-study-20260909` (client state): the ~160 000
  `stt_download_progress` events of one install (one per 8 KiB HTTP chunk, ~600/s)
  drive both relay and client load; the cubit rebuilds its model projection from every
  `stt_status`, which erases the in-flight install by `copyWith`-ing on the fresh
  object; the transport is not keyed by device, so A→B→A answers A's press with B's
  `model_not_installed`; and the second press's `install_in_progress` is turned into a
  client error whose reset closes the local socket, which the daemon treats as the
  install's owner leaving and deletes the partial.

## Locked decisions (owner, 2026-11-09)
1. Install lifetime is **daemon-scoped**: a download survives a sheet close, a device
   switch, and a client disconnect or restart. Only an explicit cancel command cancels
   it.
2. `stt_status` carries the in-flight install truth (`model_id`, `received_bytes`,
   `total_bytes`, `phase`, `bytes_per_second`), so any client can rebuild the bar.
3. HTTP `Range` resume plus bounded retry: keep the partial, verify size and SHA-256 at
   the end, and never delete a resumable partial on a transient error.
4. The sheet shows the model size, the real percentage, and a remaining-time estimate.
5. Priority is the download method and its resource management.

## Gates

### G0 — Inventory
- [x] Confirm the sink, progress, and ownership call sites in `agent/` and the state
      and transport call sites in `client/`.

### G1 — Agent
- [x] `stt_model_store.dart`: `RandomAccessFile.writeFrom` backpressure, `Range`
      resume that keeps the partial, bounded retry with backoff, incremental digest
      across a resumed prefix, and `storage_full` instead of a stall when the volume
      is too full.
- [x] `stt_install_control.dart`: one writer per device, join for a repeated install
      of the same model, conflict for a different one, explicit cancel, and one
      coalescing progress emitter shared by both channels.
- [x] `stt_status.install` plus the additive `phase`/`bytes_per_second` progress
      fields; `cancelInstall` command on both channels.
- [x] Install ownership no longer ends with the owning connection.

### G2 — Client
- [x] Transport and model projection keyed by device.
- [x] Install state rebuilt from `stt_status`, never wiped by it.
- [x] `install_in_progress` is state, not a failure: no reset, no socket close.
- [x] Size, percentage, and remaining time in the sheet; the row's line is real
      progress.
- [x] `dictation_event` is not logged at INFO per event.

### G3 — Verification
- [x] Agent: memory bound for a large local transfer, throttle cadence,
      join-not-duplicate, resume after interruption, low-disk refusal.
- [x] Client: A→B→A shows A ready, close/reopen keeps progress, a second press is
      impossible, `install_in_progress` cancels nothing.
- [x] Analyzers, focused suites, size ratchet.
- [ ] Live acceptance on a Test Home: bounded memory, progress survives close/reopen,
      A→B→A, interrupt and resume. **Deferred to the owner**: this branch was
      verified by automated gates only, because a live run needs a managed runtime and
      a sign-in. The runbook is `docs/qa_maintenance/dictation_download_acceptance.md`.

## Out of scope
- Parallel range downloads (measured as no gain on the owner's link, unnecessary on a
  fast one).
- Bounding `_suspendedEvents` (`session_run_orchestrator`): unrelated to this path and
  not trivially safe; recorded as a follow-up.
- A CDN, mirror, or `HF_TOKEN` headroom: the measured link, not the host, is the wall.

## Documentation
- `docs/technical/dictation_transport_protocol.md` (§2, §3, §6.6).
- `docs/technical/local_dictation.md` (model lifecycle).
- `agent/AGENTS.md`, `client/AGENTS.md`, `client/lib/features/dictation/AGENTS.md`.
- `docs/qa_maintenance/dictation_download_acceptance.md` (live acceptance runbook).

## Outcome

| Fact | Before | After |
|---|---|---|
| Heap while the sink is outrun (823 MB artifact) | 723 MB retained, 878 MB footprint | 187 MB with `await raf.writeFrom`, 180 MB paced at 3.2 MiB/s |
| Producer-to-disk gap measured against a local stalled sink (32 MiB) | 2.88 MB | 0.25 MB |
| Progress events for one install | ~160 000 (one per 8 KiB chunk, ~600/s) | ~100 (250 ms + 1 % gate, phase changes, terminal 100 %) |
| Client INFO lines for one install | 150-250 per second | 1 per run |
| Interrupted download | restarted from zero, partial deleted | resumed from `Range`, verified, renamed |
| Second press | second writer, partial destroyed | joins the running install; a different model is refused with its truth |
| Sheet reopen / device switch / socket close | progress lost, install cancelled | unchanged download, bar rebuilt from `stt_status.install` |
| Full volume | write stall for the whole artifact | `storage_full` before the first byte |

`dictation_service.dart` went from 992 to 871 lines by moving the control surface
into `dictation_control.dart`, so the file-size ratchet still holds without an
allowlist entry.
