---
title: "Task 77I2: Model-aware OpenAI-compatible tool-image projection"
status: "complete"
current_gate: "complete — Go accepted; other providers require separate live evidence"
remaining_estimate: "0%"
depends_on: "77c1;77c2;77I"
---

# Goal

Extend Plan 77 to deliver canonical tool images to image-capable OpenAI-compatible Chat Completions models, starting with OpenCode Go, without changing canonical history or native Responses/Anthropic codecs.

## Authorized scope and design

- Work in the existing Plan 77 worktree and selected test Home only. No primary mutations, source switch, commits, pushes, deployment, new stack, or resource cleanup.
- Use exact provider/model catalog `modalities.input` evidence. Unknown, malformed and text-only metadata fails closed; never infer vision from a name or learn capability from rejection. Endpoint overrides do not inherit catalog authority for unrelated hosts. Ollama's distinct native protocol is not automatically enabled.
- Shared canonical wire codec validates existing image blocks and creates standard user-role image_url blocks. Tool messages keep scalar summaries and original call IDs.
- Emit one provenance-labelled synthetic image message after the complete contiguous tool-result batch, never between parallel results. Synthetic context is outbound only, not a user-authored instruction or persisted user turn. Preserve image/block order, errors, pruning, replay and issuer-scoped reasoning.
- Sync/stream use the same builder and resolve the effective model override, not only configured default. Do not fetch capability metadata on text-only requests.
- Native Codex/Anthropic support is unchanged. Unsupported projections retain the current omission marker for compatibility; the docs must explain it is local fallback rather than observed provider rejection.

## Gates

### G0 — Scope and reference design (closed)
- [x] User explicitly authorizes expanding Plan 77 and implementation/testing.
- [x] Verify OpenCode reference synthetic-user projection and distinguish image-input capability from native tool-media support.
- [x] Update parent plan/current contracts and mark prior 77c2 acceptance as historical baseline, not a prohibition on supported image input.

### G1 — Red tests
- [x] Exact catalog positive/negative/malformed/provider-scoped model metadata.
- [x] Captured Go sync/stream request includes image context and no omission marker for supported model; old source fails this assertion.
- [x] Unknown/text-only, custom endpoint, model overrides and immutable history covered.
- [x] Parallel batch grouping, mixed tools, replay/pruned images, invalid blocks and reasoning replay covered.

### G2 — Implementation and verification
- [x] Reuse one validated image codec and one shared request projection.
- [x] Model capability lookup and endpoint boundary fail closed; no unnecessary lookup without images.
- [x] Analyzer and focused codec/model/adapter/runtime tests pass; broad tests selected by actual blast radius.
- [x] Owning contracts and technical/QA docs updated; graph and diff checks pass.

### G3 — Actual provider acceptance
- [x] Privacy-safe controlled request through configured Go endpoint with exact model includes image and describes blind visual fixture correctly.
- [x] Matched test runtime invokes view_image and the same Go model reads actual pixels; no duplicate send after ambiguous delivery.
- [x] Codex/Anthropic regression checks remain green; distinguish live-tested routes from untested inheritance.
- [x] Report test runtime ownership and any independent primary anomaly honestly; no primary repair.

## Definition of Done

All gates backed by evidence; remaining estimate updated at each gate closure. No provider success based solely on its self-report. No secret, identity, image payload or private path in tracked evidence. Plan 77/77g2 remain open until their separate acceptance conditions pass.

## G0 evidence

See [D3 investigation](77i-opencode-go-vision-investigation.md). Existing v1 implementation deliberately blocked all Chat Completions tool images; the approved change replaces that overly broad policy with model-aware wire projection.

## Closure evidence

- G1: production-shaped fixture ran against old source: 7 passed and 3 failed specifically because supported requests had no synthetic image context. After implementation all 16 new tests pass, including exact metadata, unrelated/same-host-wrong-product endpoints, parallel batches, incomplete pairing, immutable history, overrides, replay/pruning, malformed input and issuer-scoped reasoning.
- G2: Agent analyzer clean; adapter/model/pruning/redaction suites 142 passed; runner/checkpoint/provider-composition suites 95 passed. Full normal fast suite: 2175 passed, 14 skipped, no failures. An initial harness run injected one global state root and broke fixture-owned isolation, producing unrelated database/config failures; rerunning with inherited Home overrides removed restored the standard per-fixture isolation and passed. No production behavior was changed to mask those failures.
- Graph update passed; final public/private diff checks passed. Closest adapter contract and technical/QA documentation updated.
- G3: selected managed test Agent restarted officially, preserving test Home; selected native Client used an explicit VM selector. New conversation chose OpenCode Go / deepseek-v4-flash-vision-exp. One view_image invocation returned the existing controlled PNG; without shape/color hints the model correctly described a red square, blue circle and green triangle on white. A distinct follow-up in the accepted conversation confirmed wire capture, not a retry of an ambiguous send.
- Actual sanitized Go requests show 1 then 2 image_redacted parts, each image/png and 1766 decoded bytes, with scalar tool results followed by synthetic user image context; no tool omission marker, HTTP 200, no request error. Image_redacted is the diagnostic sanitizer representation of outbound image_url, not a missing payload. System memory can quote the old omission marker; only tool-role fallback is tested.
- Final test runtime: managed, 2 Clients, cross-owned 0, unverifiable 0. No lifecycle action targeted primary or peer runtimes. Previously observed independent primary lease/PID anomaly remains outside scope; exact primary identity preservation is not claimed and no primary repair was attempted.
- Codex/Anthropic regression suites passed; no new live Anthropic acceptance is claimed. User will add an Anthropic provider to the selected test environment for a separate live check. Other OpenAI-compatible routes benefit only with exact evidence and owned endpoint; inherited code is not proof of their live acceptance.
- Task 77I2 completed, remaining 0%. Parent Plan 77/77I/77g2 acceptance remains independently open. No commit/push, source switch or deployment performed; selected test environment remains running.
