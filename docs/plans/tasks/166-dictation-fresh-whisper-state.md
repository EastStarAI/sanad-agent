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
- [x] Compare baseline first-call decode time with after-change warm averages over
      at least ten calls for 448 and 544; require no unexplained regression above
      ~3% and unchanged peak RSS.

### G3 — Documentation and delivery

- [x] Update the Agent contract and local-dictation design with the fresh-state
      invariant and its stale-padding reason.
- [x] Update Graphify after source changes; `git diff --check` passes and
      documentation lint adds no errors beyond the two pre-existing
      `origin/main` frontmatter failures.
- [ ] Commit, push, open a non-draft PR with `type/bug` and `comp/agent`, and wait
      for every required check on the exact head without merging.

## Performance result

Mac arm64, shipped q8 model and production Metal/flash setting. Before is the
untouched `9d6e2cd9` first call in a fresh process; after is one unmeasured warm-up
plus ten measured fresh-state calls.

| Clip / window | Before decode | After warm mean | Change | First-call peak RSS before → after |
|---|---:|---:|---:|---:|
| 4.87 s / 448 | 372 ms | 285.3 ms | -23.3% | 1266.8 → 1280.2 MiB (+1.1%) |
| 10.23 s / 544 | 394 ms | 393.1 ms | -0.2% | 1285.1 → 1285.0 MiB |

The after-build ten-call peak was 1293.2 MiB. State creation is included; no
decode regression or material residency increase was measured.

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
- [x] The C exports and Dart FFI signatures remain byte-for-byte compatible.
- [x] Mac 448/544 decode time stays within ~3% of baseline and peak RSS is
      unchanged within measurement noise.

## Definition of Done

- [x] Focused analyzer and test processes pass with bounded output.
- [x] Design, contract, plan, and graph match the implementation.
- [ ] The PR contains local q8 run instructions and measured performance evidence.
- [ ] Required CI checks are green on the reported head; PR remains unmerged.
