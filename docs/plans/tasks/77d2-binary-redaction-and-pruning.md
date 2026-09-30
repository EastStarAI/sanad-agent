---
title: "Task 77d2: Binary Redaction and Pruning"
status: "pending"
current_gate: "Waiting"
depends_on: "77d1"
file_budget: 10
evidence_id: "77d"
evidence_fingerprint: "sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d"
---

# Task 77d2: التنقيح والتقليم

## Goal

منع binary من أسطح التشخيص/الواجهات وتطبيق تقليم 3-turn/24-MiB الحتمي بعد assistant completion.

## Locked scope

- current/incomplete loop محمية.
- exact markers من العقد التقني.
- request dumper تنقح deep copy فقط؛ events/history query/plugins نصية.

## Gates

### R0 — Evidence
- [ ] حل packet 77d وتأكيد fingerprint.

### D1 — Redaction
- [ ] recursive typed-image/data-URI redaction مع MIME/size فقط.
- [ ] event/log/plugin/history projections لا تستقبل rich blocks.

### D2 — Pruning
- [ ] completed-turn index يحفظ آخر 3 ثم يطبق 24-MiB oldest-first.
- [ ] transform idempotent وتحافظ على text/order/tool identity/error state.

### D3 — Verification
- [ ] tests للحدود، current loop، corrupt marker، repeated pruning، وعدم mutation للطلب الحي.

## Acceptance criteria

- [ ] بحث captures لا يجد base64 خارج canonical message/provider request المؤقتة.
- [ ] pruning لا تنتج orphan tool result أو تكسر replay.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/engine/llm_request_dumper_test.dart test/engine/history_image_pruner_test.dart test/interfaces 2>&1 | tail -5`
- [ ] تحديث QA/contracts والخطة وسجل parity.

