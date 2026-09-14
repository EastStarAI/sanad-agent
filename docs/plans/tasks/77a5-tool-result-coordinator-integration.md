---
title: "Task 77a5: Tool Result Coordinator Integration"
status: "pending"
current_gate: "Waiting"
depends_on: "77a4"
file_budget: 10
evidence_id: "77a"
evidence_fingerprint: "sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43"
---

# Task 77a5: دمج النتيجة في Coordinator

## Goal

إزالة الحد الانتقالي النصي وجعل coordinator/output guard/history callbacks تعمل على النتيجة typed مع projection نصية آمنة.

## Locked scope

- حذف `Future<String> execute` بعد إثبات عدم وجود implementation إنتاجية.
- text budget تطبق على text blocks؛ image count/base64 budgets مستقلة وبترتيب tool calls.
- events/plugins تحصل على `displayText` فقط.

## Gates

### R0 — Evidence
- [ ] حل packet 77a وتأكيد fingerprint.

### A1 — Final boundary
- [ ] جعل `BaseTool.execute` typed وحذف bridge الانتقالية.
- [ ] فحص source يثبت غياب implementations نصية إنتاجية.

### A2 — Coordinator and guard
- [ ] دعم sequential/parallel/error/batch typed results.
- [ ] إلحاق `Message.toolResult` واحدة لكل tool-call id.
- [ ] منع implicit `toString` والbinary في callbacks/checkpoint previews.

### A3 — Contracts and verification
- [ ] تحديث capabilities/tools وengine/runtime contracts.
- [ ] analyzer واختبارات coordinator والregistry والنصوص ناجحة.

## Acceptance criteria

- [ ] لا يفترض حد الأداة أو coordinator أن النتيجة String.
- [ ] text-only regression متطابقة، وimage budget لا تمر عبر character guard.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/capabilities test/engine/tool_execution_coordinator_test.dart 2>&1 | tail -5`
- [ ] تحديث العقود والخطة وreference parity.
