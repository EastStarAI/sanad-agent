---
title: "Windows STT CPU and Thermal Benchmark"
status: accepted
---

## Goal

Measure the Windows CPU-only dictation cost at 2, 4, and 6 whisper threads with one fixed model/audio/runtime contract, then identify the lowest-cost setting that preserves useful latency and returns to idle after dictation stops.

## Acceptance Record

- **Accepted.** The independent reviewer for this plan (DeepSeek V4.1 Flash Max, session `oneshot-4d7cc4db-2df6-485b-b5aa-7dd0aafbf91c`) returned **ACCEPT** on the re-review and confirmed no certified number moved across the review rounds. Its five re-review precision items and the earlier B1–B2 / W1–W7 / S1–S9 findings are applied below; the reviewer's one optional note (softening an unverifiable `certutil` attribution) is applied in the runtime row.
- **Certified evidence set:** `matrix-ar-final` — 1 unmeasured warm-up plus 3 measured decodes per thread count, all nine children exiting `0` with `model_freed=true`.
- **Identity:** model `egy-whisper-turbo-ggml-q8` (SHA-256 `a79de98911bbbbb933d5553824cf4507a8ead299f02cdffbf9fe05a80915299a`), fixture `jfk.wav` (SHA-256 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`), runtime digests as listed under *Assets and host identity*.
- **Scope boundary kept:** this plan records evidence only; the resulting product change is the separate task `docs/plans/tasks/done/windows-stt-thread-default.md`.

## Locked Scope

- Use only disposable child processes against the local AVX2-safe runtime; never load the crashing v1.0.23 release DLL.
- Do not start another Sanad daemon, Client, managed runtime, Home, or database.
- Keep model, audio, runtime DLLs, harness revision, language, and decoding options identical across thread counts.
- Separate model-load time, decode wall time, and SDK/process bootstrap overhead.
- Record CPU time rather than inferring CPU cost from wall time or fan noise.
- Do not install a hardware-monitoring driver. Report direct temperature only when a pre-existing trustworthy sensor is available; otherwise label CPU-seconds, utilization, frequency, and fan observation as thermal proxies.
- This task records evidence only; product defaults or code changes require a follow-up task based on the result.

## Benchmark Matrix

- Thread counts: `2`, `4`, `6`.
- One unmeasured warm-up per thread count.
- At least three measured decodes per thread count.
- Randomize or rotate thread-count order to reduce temperature/order bias and record the order.
- Use the same fixed audio fixture and record its exact duration, size, and SHA-256.
- Record model/runtime paths, sizes, SHA-256 values, host CPU/logical-core count, power mode, and relevant background-load baseline.

## Required Metrics

For every measured decode:

- decode wall time and real-time factor (`decode seconds / audio seconds`);
- process user CPU seconds, kernel CPU seconds, and total CPU seconds;
- average core-equivalent utilization (`CPU seconds / wall seconds`) and normalized host utilization;
- working set before decode, peak working set, and retained working set;
- exit code/native fault evidence and transcript non-emptiness (not transcript quality).

For idle behavior:

- keep the initialized harness alive after the final decode;
- sample process CPU-time deltas and working set at `0`, `5`, `15`, and `30` seconds after stop;
- prove no ongoing decode work and record whether CPU returns to the pre-decode baseline;
- dispose the harness and prove the child PID exits.

## Evidence

### Assets and host identity

| Item | Value |
|---|---|
| Runtime | local build staged in the primary checkout's `agent/native/windows-x64` (2026-11-13 20:32–20:33 local); **not** the v1.0.23 release runtime |
| Runtime backend line | `SSE3=1 SSSE3=1 AVX=1 AVX2=1 F16C=1 FMA=1 OPENMP=1 REPACK=1`, no AVX-512 feature |
| Runtime files | five DLLs: `sanad_whisper.dll` `f9af72c18e5476fc29e4577a697e8697bcf799fd5daf5b25a63a79f69c453d92`, `whisper.dll` `63e288487832abec824ff44c0508c4d1bec612e9bcce8147c0c3be87f2e3e12a`, `ggml-cpu.dll` `aa5c238f12d43adf8b0d4c4a3b34ec1eb015957f4338a289d0e8f0444a793875`, `ggml.dll` `d84b3993c7158c6e46ee30adcd5142256b0cff5028f812f17643a34d3d092fb5`, `ggml-base.dll` `8c2105d7b827b132f44431313d08a514e7f72a6c8f6756ed1ffb1a383c9a1452` — these digests were computed during the run and are **not** embedded in the session reports. What the reports prove per row is identity by file name, byte size, and mtime (`runtime.files[]` carries exactly `file`/`bytes`/`modified`) plus model and fixture bytes, so every 2/4/6 row is shown to have loaded the same five files. |
| Model | `egy-whisper-turbo-ggml-q8`, 874,208,239 bytes, SHA-256 `a79de98911bbbbb933d5553824cf4507a8ead299f02cdffbf9fe05a80915299a`, model `audio_ctx` 1500 |
| Fixture | whisper.cpp 1.9.5 `samples/jfk.wav`, 352,078 bytes, 16 kHz mono PCM16, **11.000 s** (176,000 samples), SHA-256 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e` |
| Decode contract | language `ar`, `audio_ctx` 576 (11.52 s window), `translate=false`, `no_timestamps=true`, greedy `best_of=1`, `use_gpu=0` |
| Host | Intel Core i9-9880H, 8 physical / 16 logical, 32 GB RAM (from a separate `Win32_ComputerSystem` query; `matrix.json.host` does not record memory), Windows 11 Pro build 26200, power scheme Balanced (`381b4222-f694-41f0-9685-ff5bb260df2e`), on AC |
| Temperature sensors | **not readable from the unelevated harness session**: `Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature` returns `Access denied` (`PermissionDenied`), while the kernel enumerated eight ACPI thermal zones at 21:29:25 (for example `\_TZ.PCHZ`, `\_TZ.BATZ`, `\_TZ.CHGZ`). The zones exist; what is missing is an unelevated read path. Elevation and driver installation were out of scope, so this task reports **no °C value** and does not claim the host lacks sensors. |

Window and padding corrections:

- `audio_ctx` is derived exactly as the daemon does: `ceil((176000 + 8000) / 320) = 575` frames, aligned to the 32-frame step, clamped to the 448-frame floor and the 1500-frame ceiling → **576** (11.52 s).
- The trailing pad is **0.5 s (8000 samples)**, applied by `agent/lib/infrastructure/stt/whispercpp_isolate.dart`: the daemon allocates `total = groupSamples + 8000`, passes that padded buffer to the shim, and derives `audio_ctx` from `total`. The shim's `tail_paddings_ms` parameter is accepted and **ignored** (whisper.cpp v1.9.5 has no such field), so the 1000 ms value the harness passes has no effect; the 8000-sample term is what actually reproduces the pad.
- The harness therefore matches the daemon's **window arithmetic** (576 frames) but not its buffer: it feeds the unpadded 176,000 samples, i.e. 0.5 s less audio than the daemon's 184,000-sample call. Whisper pads to the encoder window regardless, so the expected cost difference is negligible — but that is an expectation, not a measurement, and the daemon's own log line would read `samples=184000` where the harness reports `samples=176000`.

### Harness, provenance, and raw evidence

- Harness (self-contained `dart:ffi`, no product code): `windows-stt-bench/stt_bench.dart` in the retained benchmark workspace, SHA-256 `e5fb89d1b01fe8feed613c6d99b2a6599d937c3d98a9f41173a89cc69eb463e9`, mtime 21:35:04 local. Table and statistics renderers: `summarize.dart`, `analyze.dart` in the same directory.
- **Only that one harness revision is retained.** It is the revision used by the interleaved control (21:39:49–21:42:14) and by the certified headline run (21:43:44–21:47:48). The language control (21:20), `matrix-ar` (21:22:23–21:26:28) and `matrix-ar-run2` (21:29:54–21:33:58) all predate that file and their revisions were overwritten in place, so the earlier "reporting-only revision" label is **unverified** and those three matrices are treated below as corroboration only, never as certified numbers.
- `evidence/matrix-ar/matrix.json` is a post-hoc summary: it has no `report_built_at` and its `started_at` (`19:26:30.052Z`) postdates its own last session (`19:26:27.999Z`). The `session-r*.json` files are the live records; `matrix-ar-run2` and `matrix-ar-final` do carry `report_built_at`.
- Retained evidence sets under `windows-stt-bench/evidence/`: `matrix-ar-final/` (certified; `matrix.json` + 9 session reports and logs), plus `matrix-ar/`, `matrix-ar-run2/`, `interleaved-4-6/`, `ab-lang-en.json`, `ab-lang-ar.json`. `interleaved-4-6/orphaned/` holds the five session pairs left by an aborted pre-run that its `matrix.json` never listed; excluding them does not change any reported median.
- Two `<>` inputs in the command below are machine-owned and deliberately left as placeholders because they are not under the benchmark tree: `--runtime-dir <primary-checkout>/agent/native/windows-x64`, `--wav <windows-stt-evidence>/stt-04-ab/whispercpp-src/whisper.cpp-1.9.5/samples/jfk.wav`.

  ```bash
  fvm dart stt_bench.dart matrix \
    --runtime-dir <primary-checkout>/agent/native/windows-x64 \
    --model <sanad-home>/models/stt/egy-whisper-turbo-ggml-q8/ggml-egy-turbo-q8_0.bin \
    --wav <windows-stt-evidence>/stt-04-ab/whispercpp-src/whisper.cpp-1.9.5/samples/jfk.wav \
    --lang ar --iters 1 --full-idle-round 2 \
    --out-dir evidence/matrix-ar-final
  ```

  Each row is a disposable child (`dart.exe <harness> session ...`); `--order` defaults to `2,4,6|6,4,2|4,6,2`; the interleaved control used `--order "4,6+6,4+4,6"`.

### Measurement window and host power/clock events

- The real window of the retained runs is **21:20:28–21:47:47 local** (first session start `2026-11-14T19:20:28.749Z`, last session end `19:47:47.449Z`), not the 21:22–21:38 this plan previously claimed. It covers the language control (21:20), `matrix-ar` (21:22–21:26), `matrix-ar-run2` (21:29–21:34), the interleaved control (21:39–21:42) and the certified run (21:43–21:47).
- The Windows System log records host transitions inside that window: `Kernel-General 1` time change at 21:25:57 (to `2026-11-14T19:25:57.5Z` from `2026-11-13T22:35:02.1Z`) with `Kernel-Power 130/131` firmware S3 resume counters at the same second; `Kernel-General 1` again at 21:28:54; `Kernel-Power 109` + `577` and `Kernel-General 13` at 21:28:59–21:29:00 ("shutdown transition", "prepared for a system initiated reboot", "operating system is shutting down"); `Kernel-General 12` + `25` at 21:29:22 ("operating system started", "system time was initialized"); eight `Kernel-Power 125` thermal-zone enumerations and `Kernel-Power 172` at 21:29:25; then `Kernel-Power 109` + `577` and `Kernel-General 13` again at 21:32:08–21:32:09 with no matching "operating system started" record.
- What this does and does not mean. `LastBootUpTime` is `2026-11-14 20:02:15` local with ~2.1 h uptime at re-review, so **no full reboot occurred between the runs**, and the Sanad identity PIDs from 20:35/20:36 are still alive. The 21:28:59→21:29:22 sequence is a sleep/hibernate-style transition with a resume 23 s later; the 21:32:08 sequence is an initiated transition whose completion or cancellation cannot be determined from the log, and the two clock-change records mean that absolute wall-clock ordering across 21:25–21:29 is not trustworthy to the second. The transition type stays **unresolved** and is disclosed rather than explained away.
- Effect on the results, stated as a bound: `matrix-ar` and `matrix-ar-run2` straddle these events, and `matrix-ar-run2`'s 6-thread CPU median (30.23 s) sits 10–18 % below the other two runs (33.86 s certified, 36.94 s) — consistent with a thermally reset package after the 21:29:22 resume. The certified run is entirely after the transitions. The 6-thread spread must therefore be re-derived on a verified-quiet host before it is treated as a thermal property (next experiment).
- Effect on measurement integrity: none of the reported quantities depend on the wall clock. Wall time comes from `Stopwatch`, and CPU time from `GetProcessTimes` on the child's own handle, so a clock correction cannot move them; only the timestamps used to order runs are affected.
- The unexplained lease/ownership artifact at ~21:27 coincides with the 21:25:57 clock change and the 21:29:22 resume. A wall-clock jump can invalidate time-based lease checks, which is a plausible but unverified cause; process identity was unaffected.

### Headline results — certified run, measured decodes only

Each cell is an independent median over that row's three measured decodes, with min–max in parentheses.

| Threads | Decode wall s | User CPU s | Kernel CPU s | Total CPU s | RTF | Core-equivalent | Host utilization |
|---|---|---|---|---|---|---|---|
| 2 | 11.466 (11.464–11.875) | 22.86 | 0.14 | 22.891 (22.844–23.750) | 1.042 (1.042–1.080) | 1.997 (1.992–2.000) | 0.125 |
| 4 | 6.903 (6.602–9.070) | 27.27 | 0.28 | 27.547 (26.281–36.078) | 0.628 (0.600–0.825) | 3.981 (3.978–3.991) | 0.249 |
| 6 | 5.635 (4.759–7.952) | 33.27 | 0.59 | 33.859 (28.516–44.047) | 0.512 (0.433–0.723) | 5.992 (5.539–6.009) | 0.375 |

Column notes:

- Columns are **separate medians**, so user + kernel does not reproduce the total median: at 2 threads 22.86 + 0.14 = 23.00 against a 22.891 total median, because the kernel median comes from the 11.875 s decode while the total median comes from the 11.466 s decode. At 4 and 6 threads the three columns happen to add up.
- Core-equivalent is the **median of the per-decode ratios** (CPU-seconds ÷ wall seconds), not median CPU ÷ median wall; the latter would read 3.991 (4 threads) and 6.009 (6 threads).
- Host utilization = core-equivalent ÷ 16 logical processors.
- RTF = wall ÷ 11.000 s. Across the 33 certified and corroborating sessions — **excluding the aborted pre-run** (`interleaved-4-6/orphaned/`, whose 2-thread measured decode is RTF 1.224) — the measured-decode envelopes are 1.042–1.174 (2 threads), 0.587–0.825 (4 threads) and 0.433–0.723 (6 threads), matching the scope the medians use. The slowest decode inside that scope is `matrix-ar-run2`'s 2-thread **warm-up** at RTF 1.317, which is excluded from all medians.

### Marginal cost, paired per run

| Run | Provenance | Step | Wall saved | CPU added | Wall saved per added CPU-second |
|---|---|---|---|---|---|
| matrix-ar-final | certified | 2 → 4 | 4.56 s (−40 %) | +4.66 s | 0.98 |
| matrix-ar-final | certified | 4 → 6 | 1.27 s (−18 %) | +6.31 s | 0.20 |
| matrix-ar | corroboration | 2 → 4 | 5.78 s (−45 %) | +2.64 s | 2.19 |
| matrix-ar | corroboration | 4 → 6 | 0.84 s (−12 %) | +8.81 s | 0.10 |
| matrix-ar-run2 | corroboration | 2 → 4 | 6.06 s (−48 %) | +0.99 s | 6.16 |
| matrix-ar-run2 | corroboration | 4 → 6 | 1.50 s (−23 %) | +4.05 s | 0.37 |
| interleaved-4-6 | corroboration | 4 → 6 | 1.63 s (−24 %) | +4.19 s | 0.39 |

The ordering is the robust part: in **4 of 4 paired runs** 6 threads is faster than 4 and costs more CPU-seconds, and the 4 → 6 step returns 0.10–0.39 s per added CPU-second against 0.98–6.16 s for 2 → 4. The certified row is the only one whose harness revision is retained; the corroborating rows move the same direction with wider spread.

### Memory, overhead separation, and validity

Memory, certified run, median (min–max) over the three measured decodes per row:

| Metric | 2 threads | 4 threads | 6 threads |
|---|---|---|---|
| Working set before decode | 1045.9 MB (1045.7–1046.2) | 1046.2 MB (1045.9–1046.3) | 1046.4 MB (1046.0–1048.6) |
| Working set after decode (retained) | 1045.7 MB (1045.6–1046.0) | 1046.1 MB (1046.0–1046.1) | 1046.3 MB (1046.0–1048.6) |
| Peak working set | 1198.5 MB (1198.5–1198.8) | 1199.0 MB (1198.9–1199.1) | 1199.3 MB (1198.8–1201.5) |
| Working set after model free | 204.2–207.3 MB (all runs) | 204.2–207.3 MB (all runs) | 204.2–207.3 MB (all runs) |

- Peak working set is the process-lifetime high-water mark read after each decode, so it is monotonic inside a session and includes model-load pages; it is not a per-decode working-set maximum. The 6-thread maximum (1048.6 MB retained, 1201.5 MB peak) belongs to one measured decode, round 1 **position 3** (`session-r1-p3-t6`, whose own warm-up is the consecutive 1048.3/1048.5 MB with a 1201.3 MB peak); the 1046.4 MB held at the 30 s idle mark is a different 6-thread session and sits inside the same min–max, so the idle table and this table agree once the statistic is stated.
- Bootstrap: process creation→`main` **0.300–0.632 s** wall across 33 child sessions, with 0.50–0.95 CPU-seconds already consumed at `main` entry by the Dart VM.
- Loading the runtime's **five** DLLs adds 0.000–0.031 CPU-seconds. Model load (certified run) is 0.790–0.875 s wall and 0.813–0.922 CPU-seconds, and it is what pins the ~1045 MB resident model; a warm daemon pays it once, not per dictation.
- Determinism: every `ar` decode retained in the four matrices and in `ab-lang-ar` shares one transcript digest (`-650792bc6067a331`); the two `en` control decodes share a second digest (`-10baf35a6a79f64d`); every transcript in the set is non-empty. The claim is "one digest per language", not "one digest for everything".
- Warm-up discipline, stated as it is: only round 1 carries a warm-up, so **6 of the 9 measured decodes per matrix are a fresh process's first decode**. Where the round-1 warm-up and the measured decode can be compared inside one session the direction is not stable — certified run 24.844→23.750 CPU-s at 2 threads (−4.4 %), 30.109→36.078 at 4 threads (+20 %, the load-affected decode), 35.125→33.859 at 6 threads (−3.6 %); `matrix-ar-run2` −11.5 %, −4.6 %, +7.4 %. Excluding the load-affected 4-thread pair, the retained pairs span −11.5 % to +7.4 %, so **no single cold-start premium can be quantified**: the row medians carry an unquantified cold-start effect, not a per-session warm-up guarantee. The acceptance criterion is met per thread count, not per session.
- All 9 certified child processes exited `0` with `model_freed=true`; no native fault, no crash dialog, and no application-error event attributable to the benchmark, and every child PID was reaped before the parent advanced.

### Post-stop idle behavior (round 3, `0/5/15/30` s marks)

| Threads | 0 s CPU s | 0→5 s CPU s (core-eq) | 5→15 s CPU s | 15→30 s CPU s | Working set held | Exit |
|---|---|---|---|---|---|---|
| 2 | 0.000 | 0.078 (0.016) | 0.000 | 0.000 | 1045.6 MB | 0 |
| 4 | 0.000 | 0.281 (0.056) | 0.000 | 0.000 | 1046.1 MB | 0 |
| 6 | 0.000 | 0.344 (0.069) | 0.000 | 0.000 | 1046.4 MB | 0 |

Decode work stops completely: both later intervals are exactly zero CPU-seconds, and the harness's own `returns_to_baseline` flag is true. The 0.08–0.34 s consumed inside the first 5 s is **unexplained**: nothing is freed in that window by design — the harness sleeps with the model resident and calls `sanad_whisper_free` only after the 30 s marks, and the shim releases its per-call `whisper_state` inside `sanad_whisper_run`. Its scaling with thread count is consistent with OpenMP worker spin-down, but that is a hypothesis, not a measurement.

### Thermal proxies and claim boundaries

- Frequency proxy, all runs: `PercentProcessorPerformance` sampled at matrix start and after each round spans **183–200 %** of the 2.3 GHz nominal and `PercentProcessorUtility` spans **1–40 %**. The certified run alone reads 198/199/198/192 % and 14/6/7/20 %. These are round-boundary samples, not in-window samples.
- Background load is self-inclusive: `host_busy_during_decode` is `1 − idleΔ/busyΔ` over the decode interval, so it contains the benchmark's own cores. Certified measured values are 2 threads 0.154–0.175 (self ≈ 0.125), 4 threads 0.332–0.447 (self ≈ 0.249) and 6 threads 0.404–0.768 (self ≈ 0.375). Judged against per-thread self-load, the two slow decodes sit **+0.20** (4 threads) and **+0.39** (6 threads) above expectation.
- Outlier attribution, corrected: the inflated 4-thread decode is `matrix-ar-final` round 1 position 2 — wall 9.0696 s, 36.0781 CPU-s, `host_busy` **0.4473** (the 0.3541 value belongs to that session's warm-up, not to the measured decode), core-equivalent 3.9779 against 3.9808/3.9907 for its siblings, i.e. contention/spin inflation at unchanged parallelism. The inflated 6-thread decode is round 3 position 2 — 7.9524 s, 44.0469 CPU-s, `host_busy` 0.7680, core-equivalent 5.5388 against 5.9924/6.0089 (**−7.7 %**), i.e. the descheduling signature rather than the spin one. The earlier claim that both were "inflated together at stable core-equivalence" is withdrawn.
- Claim boundaries, kept explicit:
  - **Energy**: CPU-seconds per utterance (2 threads 22.9 s, 4 threads 27.5 s, 6 threads 33.9 s certified) is an *energy proxy*, not a measured joule or package-power value.
  - **Peak concurrent load**: core-equivalent × duration describes concurrency — about 2.0 cores for 11.5 s, 3.98 cores for 6.9 s, 5.99 cores for 5.6 s. 2 threads is the lowest peak load but the longest sustained burst; 4 threads roughly doubles peak concurrency for about 60 % of the wall time. Fan onset and thermal design power are not measured.
  - **Thermal**: no temperature, fan, or package-power value exists for this host in this evidence set, and the ACPI zones are unreadable without elevation. No throttling claim is made; the frequency samples bound the clock to 183–200 % of nominal at round boundaries only.

## Interpretation

- The large win is 2 → 4 threads: roughly 40–48 % less latency for 4–20 % more CPU-seconds. That is cheap in *energy* terms, not in *peak-load* terms: it doubles concurrent cores (about 2.0 → 3.98) for a shorter burst (11.5 s → 6.9 s), so whether it is "cheap" depends on which goal is named — total work per dictation, or fan onset and sustained package load, which this evidence cannot measure.
- 4 → 6 threads is a poor trade on this CPU: 12–24 % less latency for 15–31 % more CPU-seconds, close to a one-for-one percentage trade — about +4 to +9 CPU-seconds of sustained work per dictation for 0.8–1.6 s of perceived speed. It is also the row with the widest spread.
- Reproducibility, corrected. Excluding the two load-affected decodes, the per-decode CPU spread inside a run is ~3–12 % at 2 and 4 threads (certified 4.0 % and 4.8 %; widest 9.4 % and 12.0 %) and up to ~19 % at 6 threads; including those two decodes the 4-thread and 6-thread spreads reach 37 % and 54 %. Across the three full matrices the row medians move 11.3 % (2 threads: 25.48/25.20/22.89), **7.4 % (4 threads: 28.13/26.19/27.55)** and 22.2 % (6 threads: 36.94/30.23/33.86). By across-run spread **4 threads is the most stable row**, not 2 threads; the earlier "reproducible within about 5 %" and "2 threads is the most reproducible" statements are withdrawn.
- Language caveat: the fixed fixture is English speech forced through the Arabic-fine-tuned checkpoint (`--lang ar`, the daemon default). The same fixture at 4 threads costs 5.996 s / 23.92 CPU-s with `--lang en` against 7.038 s / 28.13 with `ar`. That difference is a **measured observation with no established mechanism**: no token counts were retained, and the only retained size proxy runs the other way (the `en` decode emitted 107 characters against 99 for `ar`). Absolute RTF is thus not transferable to genuine Arabic dictation; the 2/4/6 comparison stays valid because assets, options, and workload were identical and the output was deterministic.
- Confidence: CPU-seconds are directly measured and are the reliable quantity; wall time carries up to ~1.5× excursions under external load. The certified run has n = 3 per cell, and its 4-thread and 6-thread wall ranges overlap (6.602–9.070 s against 4.759–7.952 s), so the **ordering** is certified while the 1.27 s 4→6 gap is not resolved by this evidence. No temperature data exists, so nothing here supports a thermal-throttling conclusion.

## Recommendation (testable)

Decision rule for CPU-only Windows dictation on an 8-core/16-thread host and an ~11 s utterance. `T` and `C` below are **investigator-chosen illustrative thresholds**, not product requirements; the certified 4-thread row clears `T` by only 3.4 %, so any stricter product target changes the answer and the rule must be re-instantiated.

1. **Latency target `T` = median RTF ≤ 0.65** (decode no slower than 65 % of the spoken duration, i.e. ≤ 7.15 s for the 11 s fixture).
2. **Cost ceiling `C` = median ≤ 30 CPU-seconds per utterance.**
3. **Default to 4 threads** while both hold. Certified: RTF 0.628 and 27.55 CPU-s, so it passes with a 3.4 % latency margin and an 8.2 % cost margin, both measured against their thresholds.
4. **Escalate to 6 threads only if** a locked-host repeat pushes the 4-thread median RTF above 0.65, or the product sets the target at RTF ≤ 0.55 (certified 4-thread best decode is 0.600 and misses it, while the 6-thread median 0.512 meets it). Escalation relaxes `C` to ~34 CPU-seconds, because certified 6-thread cost is 33.86 CPU-s, 23 % above 4 threads.
5. **Reject 2 threads** for interactive use: certified RTF 1.042–1.080 misses `T` by ~60 % even though it is the cheapest row (22.89 CPU-s) and the lowest peak load.

Disconfirming evidence that would move the default to 6: a locked-host repeat where the 4-thread median RTF exceeds 0.65, or where the 6-thread median CPU-seconds falls to ≤ 30 while keeping its ≥ 18 % latency advantage. Neither is present in this evidence set, and neither can be produced while external host load and the 21:20–21:47 power events are uncontrolled.

Confidence limits attached to the rule: n = 3 per cell per run; ordering (6 faster than 4 faster than 2, and 2 cheaper than 4 cheaper than 6 in CPU-seconds) held in 4/4 paired runs; across-run medians 22.89–25.48 / 26.19–28.13 / 30.23–36.94 CPU-s; the 4→6 wall gap is inside the union of observed wall ranges. The rule is therefore a decision *threshold test*, not a claim that 4 threads is 1.27 s slower than 6.

`sttThreadsFor` (since replaced by the ABI-aware `defaultSttThreadsFor`) returned 6 for 8+ logical processors, and its docstring rationale is an Apple-silicon Metal curve, not this CPU-only Windows data — so on this machine the shipped default was the expensive row. Changing it is the separately tracked product task `docs/plans/tasks/done/windows-stt-thread-default.md`, which caps the Windows x64 implicit default at four threads.

## Next Recommended Experiment

1. Re-run the alternating 4-vs-6 comparison on a verified-quiet host (no background agents, no pending Windows Update transition) with in-window sampling: frequency every 500 ms during the decode plus an elevated thermal-zone read if the owner permits it, so real throttling can be separated from contention inflation.
2. Warm every session (`--warmup 1` in all rounds) and keep the emitted token count so the cold-start premium and the `en`/`ar` cost difference become bounded quantities instead of assumptions.
3. Only after (1) and (2): apply the decision rule above to decide whether Windows hosts with 8 physical cores should default to 4 threads, in a separate product task with its own before/after evidence.

## Acceptance Criteria

- [x] All 2/4/6-thread rows use byte-identical model, audio, and runtime assets.
- [x] Each **thread count** has one unmeasured warm-up plus at least three measured decodes.
- [x] Decode time, RTF, CPU-seconds, memory, and post-stop idle are reported with raw evidence.
- [x] Median and range are calculated without hiding outliers.
- [x] Thermal claims distinguish direct sensor data from proxies and observation.
- [x] The recommendation states latency gain versus CPU cost and confidence limits.
- [x] Primary daemon/Home identity remains unchanged throughout.

## Definition of Done

- [x] Exact commands/harness and raw machine-readable results are retained outside tracked source.
- [x] This plan contains a concise evidence table, interpretation, and next recommended experiment or fix.
- [x] No product code is modified.
- [x] Review findings B1–B2, W1–W7, and suggestions 1–9 are resolved in this plan, with the certified run separated from the corroborating runs.
- [x] A separate DeepSeek V4.1 Flash Max reviewer accepts or rejects the benchmark; corrections return to the original investigator session and re-review returns to the original reviewer session. Accepted in session `oneshot-4d7cc4db-2df6-485b-b5aa-7dd0aafbf91c` (see *Acceptance Record*).

## Review Correction Index

Every finding from the reviewer session `oneshot-4d7cc4db-2df6-485b-b5aa-7dd0aafbf91c` (its `review.txt` and `rereview.txt` in `results/cpu-thermal-review/` under the delegation output tree) and where it is resolved:

| Finding | Resolution |
|---|---|
| B1 window and power events | Window corrected to 21:20:28–21:47:47 with the Kernel-General/Kernel-Power series listed, `LastBootUpTime` 20:02:15 used to bound what the events can and cannot mean, and the run2 thermal reset stated; see *Measurement window and host power/clock events*. |
| B2 sensor and proxy ranges | Sensor row now reports `Access denied` plus the eight enumerated ACPI zones; frequency and utility ranges re-derived from the retained JSON (183–200 % / 1–40 % overall, 192–199 % / 6–20 % certified). |
| W1 outlier attribution | Corrected decode identified, warm-up value separated, `host_busy` declared self-inclusive with per-thread self-load, the 6-thread −7.7 % core-equivalent drop named as the descheduling signature, and the earlier "stable core-equivalence" sentence withdrawn. |
| W2 confidence and reproducibility | Spreads recomputed: 3–12 % inside a run at 2/4 threads, up to ~19 % at 6, 11.3 %/7.4 %/22.2 % across runs; 4 threads named the most stable row; the 5 % claim withdrawn. |
| W3 determinism | Restated per language: one digest for every `ar` decode, a second digest for the `en` control. |
| W4 memory table | Statistic stated (median over three measured decodes, min–max), values re-derived per row, peak defined as lifetime high-water, and the 1048.6-vs-1046.4 apparent conflict explained. |
| W5 warm-up discipline | Only round 1 is warmed; 6 of 9 measured decodes are first decodes; the warm-up/measured pairs are listed and no single cold-start premium is claimed. |
| W6 tail padding and buffer | 0.5 s / 8000-sample pad documented as the daemon's, `tail_paddings_ms` documented as ignored, and the harness's shorter 176,000-sample call disclosed. |
| W7 harness provenance | Single retained revision identified with mtime and hash; earlier revisions declared unverified; `matrix-ar/matrix.json` declared a post-hoc summary; certified vs corroborating runs separated throughout. |
| S1 column medians | Footnote added, including the 2-thread 23.00-vs-22.891 example. |
| S2 core-equivalent statistic | Declared as the median of per-decode ratios, with the alternative reading given. |
| S3 DLL count | Five DLLs named. |
| S4 bootstrap range | Corrected to 0.300–0.632 s across 33 sessions. |
| S5 idle residual | Relabelled unexplained, with the "nothing is freed in that window" reasoning. |
| S6 language causality | Causal token claim removed; observation, `text_chars` 107 vs 99, and the unretained harness revision disclosed. |
| S7 stray artifact | `session-r1-p2-t4.*` moved to `interleaved-4-6\orphaned\` with the other five orphan pairs. |
| S8 command placeholder | Named the machine-owned inputs as explicit `<primary-checkout>` / `<windows-stt-evidence>` placeholders and named the `stt-04-ab` fixture. |
| S9 host RAM and RTF range | RAM provenance stated; RTF ranges re-derived per thread count, and the slowest warm-up (1.317) named. |

Re-review follow-ups from the same reviewer session, applied above: the five full runtime digests are restored with an accurate statement of what the session reports do and do not prove; the 6-thread memory-peak decode is corrected to round 1 position 3; the contradicted cold-premium bound is withdrawn; the reviewer session id replaces the bare relative `review.txt` path; the RTF envelope is scoped to exclude the aborted pre-run; Acceptance Criterion 2 now says "each thread count"; and `T`/`C` are labelled investigator-chosen illustrative thresholds.

Cross-review precision edits (session `oneshot-0a8abe36-b671-49ae-ae89-c5d8b052c9e3`'s follow-up, applied here because this record is the citation): the certified 4-thread wall minimum is written `6.602` (raw `6.6019`) in the headline table and the confidence paragraph, and the 4-thread margins are stated against one base — 3.4 % of the 0.65 RTF threshold and 8.2 % of the 30 CPU-second threshold — so the Recommendation intro and step 3 agree. No certified number changes; both edits are display precision and a rounding fix.

## Runtime Continuity Proof

- Certified measurement window **21:20:28–21:47:47 local**; the host power/clock events inside it are disclosed in their own section above.
- Before and after all runs, `sanad-dev status` from the primary checkout reported the same identity: launcher `PID 16356 id=launcher-_aXZc8IAjny4wm7FqEs9-M_NWylY7R_r` (created 20:35:33), agent port `58085` owned by PID 8292 (created 20:36:33), the primary `<Sanad Home>`, version `1.0.24`, commit `c2fd0e40`, Client `pid=7416 vm=51038` (created 20:35:56). `.runtime-owner.json` records pid 8292 and launcher `launcher-_aXZc8IAjny4wm7FqEs9-M_NWylY7R_r`, acquired `18:36:50.228Z`, mtime 20:36:50, unchanged by the benchmark.
- `LastBootUpTime` is 20:02:15 local with ~2.1 h uptime, so the 21:28:59–21:29:22 sleep/hibernate-style transition and the 21:32:08 initiated transition did not restart the machine or the Sanad processes.
- One intermediate `sanad-dev status` at ~21:27 reported `ownership conflict (stop refused)` / `Runtime class: unverifiable` while those PIDs kept running; the next status returned to the identical managed state, and no lease file changed. It coincides with the 21:25:57 clock change and the 21:29:22 resume; a time-based lease check disturbed by the clock jump is a plausible but unverified cause, and it remains an open lease-layer question for the reviewer.
- No second daemon, Client, managed runtime, Home, or database was started. The worktree stays clean apart from this plan; only the git-ignored `agent/.dart_tool/` was regenerated by an offline `fvm dart pub get`.
