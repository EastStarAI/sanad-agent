---
title: "Task 77c2: Adapter Capability and Fallback"
status: "pending"
current_gate: "Waiting"
depends_on: "77c1"
file_budget: 10
evidence_id: "77c"
evidence_fingerprint: "sha256:2af004c77e76f850c34646defccb7fa1e87a55791873bc7337d05502b564761ad"
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
- [ ] حل packet 77c وتأكيد evidence gaps المقفلة في Plan 77.

### C1 — Capability
- [ ] إضافة getter/enum وتحديث كل adapters/wrappers/fixtures بقيمة صريحة.
- [ ] لا model-name inference أو endpoint probing.

### C2 — Text fallback
- [ ] OpenAI Chat tool messages تبقى text-only بلا `image_url`.
- [ ] Ollama/custom/missing تستخدم projection نفسها.
- [ ] rich-to-text failover لا يمس canonical history ولا يبدأ retry جديدًا.

### C3 — Verification
- [ ] sync/stream/wrapper/failover request captures ناجحة.

## Acceptance criteria

- [ ] لا base64 في أي adapter text-only.
- [ ] omission marker تظهر مرة واحدة فقط عند إسقاط image blocks.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/engine/adapters 2>&1 | tail -5`
- [ ] تحديث adapter/core contracts والخطة وسجل parity.
