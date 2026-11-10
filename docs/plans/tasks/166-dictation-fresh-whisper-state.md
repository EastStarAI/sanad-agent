# Task 166 — Fresh whisper state per dictation decode

**Status:** active — G0–G2 complete, G3 delivery pending, ~10% remaining
**Owner:** `agent/native/whispercpp/sanad_whisper.c`
**Contract:** [docs/technical/local_dictation.md](../../technical/local_dictation.md)
**Predecessor:** task 163 / PR401 (derived decode windows)

## Goal

Keep shared whisper model weights warm while giving every decode a fresh
`whisper_state`, so a smaller `audio_ctx` can never read padded encoder or
cross-attention data retained by a preceding larger window.

## Locked decisions and scope

1. Load the pinned whisper.cpp v1.9.5 model context without its implicit state,
   allocate one state inside each `sanad_whisper_run`, and free it on every exit
   path after calling `whisper_full_with_state` and the `_from_state` result
   accessors.
2. Keep the exported C ABI and Dart bindings unchanged.
3. Keep the derived window, greedy candidate count, repetition guard, model
   residency, flash-attention setting, and pinned whisper.cpp version unchanged.
4. The q8 transcript regression reads its model from `SANAD_STT_Q8_MODEL` and
   skips clearly when absent; CI model caching is deferred and workflows are out
   of scope.
5. Follow-up: move to the first tagged whisper.cpp release containing upstream
   PR #4127, then reconsider whether state reuse is worth restoring behind the
   same regression.

## Gates

### G0 — Discovery

- [x] Reproduce `544 → 448` and `1500 → 448` corruption on the reused warm state.
- [x] Prove fresh state gives byte-equal transcripts over the fixed sequences and
      20 random window orders.
- [x] Confirm task number 166 is free on `origin/main` and in open pull requests.
- [x] Lock option A; reject an untagged upstream patch for this release.

### G1 — Native implementation and regression

- [x] Change the shim to a no-state model context plus one fail-safe fresh state
      per decode without changing its exported ABI.
- [x] Add the q8 native regression for `448 → 544 → 448` and `1500 → 448`, with a
      non-empty known transcript hash and byte equality.
- [x] Extend static native-builder coverage to pin the state lifecycle and
      `_from_state` accessors.

### G2 — Verification and performance

- [x] Build the shipped macOS native runtime from pinned whisper.cpp v1.9.5.
- [x] Run the q8 regression and each affected test file in its own process.
- [x] Analyze `lib/infrastructure/stt test/stt` with no issues.
- [x] Compare baseline and after-change warm averages over at least ten calls
      for 448 and 544; the cost must stay within the approved ~+11 ms state
      construction budget with unchanged first-call peak RSS.

### G3 — Documentation and delivery

- [x] Update the Agent contract and local-dictation design with the fresh-state
      invariant and its stale-padding reason.
- [x] Update Graphify after source changes; `git diff --check` passes and
      documentation lint adds no errors beyond the two pre-existing
      `origin/main` frontmatter failures.
- [ ] Commit, push, open a non-draft PR with `type/bug` and `comp/agent`, and wait
      for every required check on the exact head without merging.

## Performance result

Mac arm64, shipped q8 model, production Metal/flash setting, measured by the
independent reviewer. The baseline is the `origin/main` shim decoding the same
window repeatedly, which the stale-padding defect does not affect; first calls
were measured in five fresh processes per row.

| Clip / window | Before warm mean | After warm mean | Change | Before → after first call (median) |
|---|---:|---:|---:|---:|
| 4.87 s / 448 | 274.8 ms | 285.5 ms | +10.7 ms (+3.9%) | 277 → 287 ms |
| 10.23 s / 544 | 383.3 ms | 393.2 ms | +9.9 ms (+2.6%) | 386 → 396 ms |

First-call peak RSS is unchanged (~1060–1065 MiB both builds); 11-call runs
retain 6–14 MiB more through the allocator. The cost is about +10 ms per decode
for state construction, within the study's approved +11 ms budget.

**Verdict: BETTER-EXISTS-DEFERRED.** Upstream whisper.cpp PR #4127 removes the
defect at zero cost with state reuse but is not yet in a tagged release; follow-up
5 adopts the first tag that contains it.

## Acceptance Criteria

- [x] Given the q8 fixture, `448 → 544 → 448` returns the same final short
      transcript bytes as a fresh 448 reference.
- [x] Given the q8 fixture, `1500 → 448` returns the same final short transcript
      bytes as that reference.
- [x] The reference transcript is non-empty and matches its pinned SHA-256, so
      equal failures cannot pass.
- [x] Model weights remain shared and warm while no implicit or reusable
      `whisper_state` remains attached to the context.
- [x] Every decode failure and success frees its state exactly once.
- [x] Load allocates and frees one probe state, so a state that cannot be
      allocated fails the load (and reaches the CPU fallback) rather than every
      later decode.
- [x] The C exports and Dart FFI signatures remain byte-for-byte compatible.
- [x] Mac 448/544 decode cost stays within the approved ~+11 ms budget and peak RSS is
      unchanged within measurement noise.

## Definition of Done

- [x] Focused analyzer and test processes pass with bounded output.
- [x] Design, contract, plan, and graph match the implementation.
- [ ] The PR contains local q8 run instructions and measured performance evidence.
- [ ] Required CI checks are green on the reported head; PR remains unmerged.
