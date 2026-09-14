---
title: "Task 77c2: Adapter Capability and Fallback"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
depends_on: "77c1"
file_budget: 10
evidence_id: "77c"
evidence_fingerprint: "sha256:2af004c77e76f850df9ab9b0abe23409cdcf470ecd3831c08cfc62c66823f85c"
---

# Task 77c2: Capability والـFallback النصية

## Goal

إضافة capability مغلقة لكل adapter وضمان fallback نصية حتمية في OpenAI Chat/Ollama/custom/missing وعند failover.

## Locked scope

- capability قيمتان فقط، وwrappers تفوضها.
- Responses/Anthropic rich؛ كل adapter أخرى text-only افتراضيًا.
- suffix ثابت مرة واحدة، provider-facing فقط، ولا retry/failover بسبب degradation.

## Gates

### R0 — Evidence
- [x] حل packet 77c وتأكيد evidence gaps المقفلة في Plan 77.

### C1 — Capability
- [x] إضافة getter/enum وتحديث كل adapters/wrappers/fixtures بقيمة صريحة.
- [x] لا model-name inference أو endpoint probing.

### C2 — Text fallback
- [x] OpenAI Chat tool messages تبقى text-only بلا `image_url`.
- [x] Ollama/custom/missing تستخدم projection نفسها.
- [x] rich-to-text failover لا يمس canonical history ولا يبدأ retry جديدًا.

### C3 — Verification
- [x] sync/stream/wrapper/failover request captures ناجحة.

## Acceptance criteria

- [x] لا base64 في أي adapter text-only.
- [x] omission marker تظهر مرة واحدة فقط عند إسقاط image blocks.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/engine/adapters 2>&1 | tail -5`
- [x] تحديث adapter/core contracts والخطة وسجل parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/C1`.
- Resolver: packet `77c` returned `ready`; corrected the stale task fingerprint to resolver authority `sha256:2af004c77e76f850df9ab9b0abe23409cdcf470ecd3831c08cfc62c66823f85c`.
- Re-inspected every mandatory codec/fallback source and focused request assertion at the pinned Hermes/OpenClaw revisions; both source licenses remain MIT.
- Closed evidence gaps using Plan 77's locked policy: protocol-declared capability with a conservative text-only default and an adapter getter as the future explicit override seam; active-route projection handles failover without mutating canonical history or learning support from failures.
- Adopted deterministic identity-preserving fallback and dedicated protocol projection; rejected model-name inference, endpoint probing, universal multipart payloads, and retry-triggered degradation.
- Remaining estimate: `75%`.
- Next gate: `C1 — Capability`.

### 2026-09-14 — C1 complete

- Added the closed `ToolResultMediaCapability` contract with a conservative `textOnly` default and an explicit capability-provider seam.
- Codex Responses and Anthropic declare `imageToolResults`; the deterministic E2E fixture carries an explicit configurable value; the rate-limit wrapper delegates the exact inner capability.
- Standard OpenAI Chat, Ollama/custom, mock, missing, and unknown adapters resolve to the protocol-safe text-only default without model-name inference or endpoint probing.
- Focused capability/wrapper coverage passed; analyzer remained clean.
- Remaining estimate: `50%`.
- Next gate: `C2 — Text fallback`.

### 2026-09-14 — C2 complete

- Standard OpenAI-compatible Chat now projects image-bearing typed tool results to `displayText` plus the exact omission marker, while retaining the original `tool_call_id` and a scalar text wire shape.
- Ollama and custom OpenAI-compatible routes inherit the same conservative projection; missing/unknown routes remain text-only by capability and never expose image bytes.
- The projection is detached and recomputed for the active adapter. A captured rich-to-text route change preserved byte-for-byte canonical serialized history, emitted no base64 on the text route, and did not trigger a degradation retry.
- The omission marker is idempotent and appears exactly once.
- Remaining estimate: `25%`.
- Next gate: `C3 — Verification`.

### 2026-09-14 — C3 complete / task complete

- Exact request captures prove rich Responses output followed by OpenAI-compatible sync/stream text fallback from the same immutable canonical history.
- Capability coverage includes rich protocols, conservative text-only adapters, explicit fixture configuration, and exact transparent-wrapper delegation.
- Final analyzer passed with no issues; the required adapter-directory suite passed all `51` tests.
- `graphify update .` completed (`23,673` nodes, `32,575` edges, `850` communities); the known zero-node data-file warning was non-blocking.
- Adapter contract, task/plan state, and post-implementation parity record were updated. Tracked task scope is `10/10` paths.
- Remaining estimate: `0%`.
- Next task: `77d1 — Atomic Result Durability`, gate `R0`.
