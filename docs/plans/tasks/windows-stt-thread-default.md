---
title: "Windows STT CPU Thread Default"
status: planned
---

## Goal

Use the accepted Windows CPU benchmark to avoid the expensive six-thread default on supported Windows x64 hosts while preserving explicit configuration and non-Windows behavior.

## Evidence

`docs/plans/tasks/windows-stt-cpu-thermal-benchmark.md` accepted the fixed AVX2-safe 2/4/6-thread comparison. On the measured Windows CPU path, four threads met the investigator-selected interactive targets (`RTF <= 0.65`, median CPU-seconds `<= 30`) while six threads reduced median wall time by about 1.27 seconds at materially higher CPU cost and higher variability. The benchmark does not establish a temperature or package-power result.

## Scope

- Make the implicit default ABI-aware and independently testable.
- On Windows x64, cap the implicit default at four threads without oversubscribing machines with fewer than four logical processors.
- Preserve the existing six-thread wide-machine policy for non-Windows ABIs; its evidence comes from the Apple Metal path and must not be generalized to Windows CPU inference.
- Preserve explicit `stt.threads` values and the existing validation range (`1..16`).
- Update the owning technical documentation and focused tests.
- Do not change model selection, GPU policy, native build flags, runtime acquisition, or Client UI.

## Acceptance Criteria

- [ ] Windows x64 resolves `2 -> 2`, `4 -> 4`, `8 -> 4`, and `16 -> 4` for the implicit default.
- [ ] Representative macOS/Linux ABIs preserve the existing wide-machine `>=8 -> 6` behavior.
- [ ] Unknown/non-positive core counts remain safely bounded at four.
- [ ] An explicit valid `stt.threads` value still wins unchanged.
- [ ] Focused tests prove ABI behavior and configuration precedence.
- [ ] Agent analyzer and focused tests pass with bounded output.
- [ ] Documentation cites the accepted benchmark and distinguishes latency/CPU evidence from unmeasured temperature and energy.
- [ ] Graphify is updated after the code change.

## Definition of Done

- [ ] Product code, tests, and technical documentation form one focused candidate.
- [ ] No commit, push, PR, daemon restart, Home, or database change occurs without the existing authorization boundary.
- [ ] A separate DeepSeek V4.1 Flash Max reviewer accepts or rejects the candidate; corrections return to the original implementer session and re-review returns to the original reviewer session.
