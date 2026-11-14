---
title: "Windows STT CPU and Thermal Benchmark"
status: planned
---

## Goal

Measure the Windows CPU-only dictation cost at 2, 4, and 6 whisper threads with one fixed model/audio/runtime contract, then identify the lowest-cost setting that preserves useful latency and returns to idle after dictation stops.

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

## Acceptance Criteria

- [ ] All 2/4/6-thread rows use byte-identical model, audio, and runtime assets.
- [ ] Each row has one warm-up plus at least three measured iterations.
- [ ] Decode time, RTF, CPU-seconds, memory, and post-stop idle are reported with raw evidence.
- [ ] Median and range are calculated without hiding outliers.
- [ ] Thermal claims distinguish direct sensor data from proxies and observation.
- [ ] The recommendation states latency gain versus CPU cost and confidence limits.
- [ ] Primary daemon/Home identity remains unchanged throughout.

## Definition of Done

- [ ] Exact commands/harness and raw machine-readable results are retained outside tracked source.
- [ ] This plan contains a concise evidence table, interpretation, and next recommended experiment or fix.
- [ ] No product code is modified.
- [ ] A separate DeepSeek V4.1 Flash Max reviewer accepts or rejects the benchmark; corrections return to the original investigator session and re-review returns to the original reviewer session.
