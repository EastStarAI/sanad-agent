# 164 — Dictation model download throughput

**Status:** implemented on `fix/stt-download-pipeline`
**Owners:** `agent/lib/infrastructure/stt/`
**Contract:** [docs/technical/local_dictation.md](../../technical/local_dictation.md)
**Predecessor:** PR391 (the memory bound this work had to keep)

## Problem

A dictation model install was slower than the link it ran over. On the
reference 4-core host the same 874 MB catalog entry, idle machine, measured
18.5 MB/s through the shipped path against 66.1 MB/s for a read-only transfer
over the same connection: the download was capped by per-byte work on one core,
not by the network.

Two terms made up that work:

| Term | Cost (measured, reference host) |
|---|---|
| Pure-Dart SHA-256 (`package:crypto`) | 5.25 CPU-s/GB, 196 MB/s |
| Write awaited inside the reader's isolate | the socket idle for every write |

Offloading the hash into an isolate on its own did not help — same CPU per byte
and +1.35 GB RSS without backpressure — and parallel `Range` workers did not
either: 1/2/3/4 workers measured 29.4/31.0/30.1/28.4 MB/s.

## Decision

1. **Native digest** (`stt_digest.dart`): SHA-256 through `dart:ffi` into the OS
   crypto library — CommonCrypto on macOS, `libcrypto.so.3`/`libcrypto.so` on
   Linux, `bcrypt` on Windows — with the pure-Dart implementation kept as a
   fallback for a host that cannot load one. Measured 2 578 MB/s and
   0.41 CPU-s/GB, 13× the throughput for 13× less CPU, and nothing new to
   bundle or sign.
2. **Bounded write pipeline** (`stt_download_pipeline.dart`): the reader keeps
   the socket and the digest; a writer isolate owns the file handle. The reader
   waits only when `kSttWriteWindowBytes` (4 MiB) of accepted bytes are queued
   ahead of the disk, so PR391's bound holds while the read no longer idles.
3. **One connection.** Parallel ranges were rejected on measurement.

## Invariants the tests pin

| Invariant | Test |
|---|---|
| Native and pure-Dart digests are byte-identical, every chunking, including a chunk wider than the native window | `test/stt/stt_digest_test.dart` |
| The shipped digest is the native one where the OS provides it | `test/stt/stt_digest_test.dart` |
| The native digest is measurably faster: the median of five alternating paired trials stays at 2.5× the pure-Dart path | `test/stt/stt_digest_cost_test.dart` |
| The pipeline never accepts more than `kSttWriteWindowBytes` while the disk is stalled | `test/stt/stt_download_pipeline_test.dart` |
| Exactly one write is in flight, and `close()` drains what it accepted | `test/stt/stt_download_pipeline_test.dart` |
| A refused write reaches the store's typed codes (`storage_full`, otherwise `download_failed`) across the isolate boundary | `test/stt/stt_download_pipeline_test.dart` |
| The shipped default pipeline is the writer isolate | `test/stt/stt_download_pipeline_test.dart` |
| The download still stops reading when a write stalls | `test/stt/stt_install_memory_bound_test.dart` |

## Result

Apple M4, one 1 GiB artifact from a loopback origin, median of three runs after
a warm-up: **142.9 MB/s before → 1 137.6 MB/s after** (7.17 s → 0.90 s per GiB),
process CPU for the same four-install workload 40.3 s → 13.6 s. Reference host,
real catalog URL: 29.1 → 61.2 MB/s with 43.5 → 18.9 CPU-s/GB, artifact digest
and size unchanged.

## Out of scope

A native TLS client (the `dart:io` `HttpClient` tops out near 96 MB/s on the
reference host). It is the only remaining route past that ceiling and it needs a
bundled, signed library on three platforms, so it stays a separate owner
decision rather than a rider on this one.
