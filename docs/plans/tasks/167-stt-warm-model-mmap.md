---
plan: 167
issue: 426
branch: fix/167-stt-warm-model-mmap
status: complete
---

# 167 — Warm STT model residency claims match reality

## Goal

Make the local-dictation warm-model memory contract truthful: the daemon and the technical docs must state the residency that whisper.cpp v1.9.5 actually produces, so operators can size hosts correctly and no reader plans swap or sharing behaviour that does not exist.

## Locked decisions and scope

- **Confirmed defect (Issue #426):** the pinned native engine is whisper.cpp `1.9.5` (`agent/native/checksums.json`), which no longer exposes a `use_mmap` context parameter. Warm weights are copied into an anonymous CPU backend buffer, so the resident block is anonymous, unshareable, and unreclaimable — contradicting three code comments and `docs/technical/local_dictation.md`.
- **Out of scope:** rebuilding or repinning the native shim, changing quantization or model choice, altering `stt.model_idle_minutes`, and any change to the warm-park lifecycle. Measurements only; no behaviour change.
- **Deferred and tracked separately:** `sanad-dev switch --runtime current` cannot admit a handoff from a freshly created worktree (it reports `no source agent matches current` and aborts without mutation). Fix and investigation come after this task.
- This task changes comments and documentation only. No executable code path, default, or wire contract changes.

## Gates

### G0 — Discovery
- [x] Measure the resident block and prove it is anonymous (single `rw-p 00:00 0`, `873,553,920` bytes vs `874,208,239`-byte file, `RssFile` `20,948 kB`).
- [x] Prove the daemon never maps the model file (`grep -c <model-file> /proc/<pid>/maps` → `0`).
- [x] Confirm the pinned engine version and the absence of any `use_mmap` reference in the tracked tree.
- [x] Prove the model is not loaded at startup (lazy singleton, engine start only inside a dictation session, idle unload after `stt.model_idle_minutes`).

### G1 — Truthful contract in code and docs
- [x] Replace the mmap claims in `whispercpp_bindings.dart`, `stt_engine.dart`, and `stt_types.dart` with the measured residency statement.
- [x] Rewrite the warm-residency section of `docs/technical/local_dictation.md` with the observed footprint and the reclaim caveat.

### G2 — Verification
- [x] Agent analyzer clean (`No issues found!`).
- [x] Focused STT tests pass: 40 passed, 2 skipped, exit 0 (`dictation_service_test`, `stt_catalog_test`, `engine_availability_test`, `native_decode_window_state_test`).
- [x] Runtime migrated to this worktree (`fix/167-stt-warm-model-mmap`, agent port `58150`, Home `/home/ubuntu/.sanad-test` preserved) and verified running before the change.

### Measured outcome

- Runtime footprint change: **0 bytes**. This task corrects the contract, it does not shrink the model.
- Documented residency is now evidence-backed: ~833 MB anonymous per warm daemon (874,208,239-byte entry), zero reclaimable or shareable pages.
- Real footprint reduction is deferred: it needs a native repin to an engine that keeps weights file-backed, or a smaller quantization.

## Acceptance Criteria

- [ ] Given a warm model in the daemon, when an operator reads the code comments or the technical page, then the stated residency matches the anonymous footprint this task measured, and no text claims file-backed sharing.
- [ ] No tracked file outside the four documentation surfaces is modified.
- [ ] Analyzer and focused STT tests pass with bounded output.

## Definition of Done

- [x] `fvm dart analyze` clean in `agent/`.
- [x] Focused STT suite green (`agent/test/stt/`).
- [x] Documentation updated in the same change.
- [x] Draft pull request opened with the measured improvement level and the issue link.
- [ ] Deferred `switch` admission failure recorded for follow-up (investigation follows this task).
