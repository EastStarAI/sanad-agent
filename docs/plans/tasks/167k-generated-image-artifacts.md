---
title: "Task 167k: Durable Generated-Image Artifacts and References"
description: "Tool-owned generated originals with typed references, atomic persistence, integrity, fork/delete ownership, and pruning-independent retention."
status: "pending"
current_gate: "Ready for 167k-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 16
---

# Task 167k: Durable Generated-Image Artifacts and References

## 1. Goal

Persist generated originals as exact-session, tool-owned media so restart,
context pruning, and conversation navigation never make the user's only copy
depend on inline image pixels in LLM history.

## 2. Locked scope

- Extend the current Agent-owned media/storage architecture inside the resolved
  Sanad Home, reusing validation, confinement, atomic-write, and cleanup
  primitives. Do not create a general artifact/plugin subsystem.
- Generated media is owned by its session and tool completion, not by a fake
  user attachment or a client-local path.
- A typed closed reference holds opaque identity, owner identity, safe filename,
  verified MIME, dimensions, byte count, integrity hash, availability, and safe
  normalized generation metadata. Paths/bytes are not public descriptor fields.
- Add optional generated-media references alongside the existing canonical tool
  result's text/image blocks. Preserve text compatibility and legacy parsing;
  do not insert an unknown block discriminator into the v1 block vocabulary.
- Store the verified original independently of optional model-visible previews.
  Preview normalization and model base64 budgets never overwrite the original.
- Promotion/checkpoint ownership follows the existing authoritative tool-result
  transaction. Publish availability only after an owned completed reference is
  durable; partial artifacts are never exposed as successful output.
- Context pruning removes model pixels only. Retention follows owning canonical
  history/session lifecycle, not the latest-three-turn model-image window.

## 3. Invariants

- Store paths remain inside their Home boundary, with protected permissions;
  opaque IDs never grant sibling/session/filesystem authority.
- Original bytes are immutable after commit; retrieval revalidates ownership,
  size, and hash. Invalid/missing bytes yield a stable unavailable descriptor.
- Centralized original limits are distinct from inline-preview limits; no
  unbounded decode, write, or orphan scan is introduced.
- Recovery reuses an already completed artifact/reference and never calls a
  generation provider. A pre-completion unknown outcome cannot be replayed.
- Forked canonical media has independent child ownership before acceptance;
  parent deletion cannot destroy a child's retained image.
- Cleanup is idempotent and preserves artifacts owned by a suspended completed
  checkpoint. It removes interrupted writes and truly unowned promoted files.
- Generated-media descriptors in public history/events/metadata caches contain
  no original bytes, raw prompt, token, absolute path, or reusable provider URL.
  Authorized transient media byte caches remain part of the existing loader.

## 4. Gates and acceptance criteria

### G1 — Reference and persistence shape

- [ ] Typed reference validation, additive JSON round-trip, text compatibility,
      checkpoint copying, and unknown/malformed-reference handling are covered.
- [ ] Legacy result readers retain text without requiring a new block type;
      existing `view_image` inline results remain unchanged.
- [ ] Only tool-role results can own generated references; user attachments retain
      their existing role rules.

### G2 — Atomic storage and integrity

- [ ] Verified images stage privately and promote atomically into exact ownership.
- [ ] Size/pixel/format/path boundaries, hash mismatch, disk failure, cancellation,
      and incomplete promotion expose no partial successful artifact.
- [ ] Completed checkpoint/reference promotion is idempotent across restart;
      initialization distinguishes checkpoint-owned files from true orphans.
- [ ] Failure cleanup leaks neither private paths nor binary payloads.

### G3 — Retention and lifecycle

- [ ] Run existing context-image pruning past its turn/byte thresholds and assert
      the generated reference, original hash, and retrievability are unchanged.
- [ ] Fork remaps references/ownership consistently with copied tool identities;
      deleting either parent or child cannot delete the other's image.
- [ ] Session deletion and interrupted-write/orphan reconciliation are idempotent
      and bounded, with no cross-session deletion or dangling success descriptor.
- [ ] Missing/corrupt storage degrades to unavailable without regenerating.

## 5. Definition of Done

- [ ] Model, store, transaction/recovery, pruning, fork, and cleanup tests pass,
      including no-provider-call assertions during recovery and reconciliation.
- [ ] Relevant Agent analyzer and focused tests pass using FVM; code changes
      include graph maintenance.
- [ ] `docs/technical/image_generation_runtime.md`,
      `docs/technical/multimodal_tool_results_and_view_image.md`,
      `docs/technical/agent_database_schema.md`, and
      `docs/technical/session_fork_protocol.md` reflect the shipped ownership.

## 6. Success test scenario

1. Commit a generated-image fixture to a tool completion; record original hash
   and opaque reference, then restart and reopen history.
2. Prune older model-visible pixels and assert the same original remains intact.
3. Fork through that completion, delete the parent, and assert the child retains
   its independently authorized image with the same original content hash.
4. Interrupt staging/promotion and rerun reconciliation twice; assert no partial
   success, no deletion of checkpoint-owned media, and no regeneration call.
5. Delete the last owning session and assert its files/metadata are removed once.

## 7. Out of scope

Provider network calls, image-editing inputs, public file URLs, generic artifact
management, Client widgets, and changing existing `view_image` retention policy.
