---
title: "Task 77b1: Image Policy Worker"
status: "pending"
current_gate: "Waiting"
depends_on: "77a5"
file_budget: 10
evidence_id: "77b"
evidence_fingerprint: "sha256:649b8758bdef850c34646defccb7fa1e87a55791873bc7337d05502b564761ad"
---

# Task 77b1: سياسة الصور والـWorker

## Goal

تنفيذ primitive مستقلة تفحص وتفك وترسم وتعيد ترميز صورة محلية وفق الحدود المقفلة دون filesystem side effects أو حجب event loop.

## Locked scope

- `image: ^4.9.1`؛ PNG/JPEG/WebP ثابتة فقط.
- input 20 MiB، 40M pixels، edge 7900، base64 4 MiB، timeout 15s، concurrency 2.
- detail edges 768/2048/4096/original؛ JPEG 85 أو PNG 6 عند normalization.

## Gates

### R0 — Evidence
- [ ] حل packet 77b وقراءة mandatory image-policy sources.

### B1 — Dependency and policy
- [ ] إضافة dependency وثوابت مركزية وclosed failures.
- [ ] magic sniffing وstatic-frame validation قبل result construction.

### B2 — Worker
- [ ] isolate worker مع semaphore=2 وkillable timeout=15s.
- [ ] original preservation وlow/auto/high no-enlarge behavior.
- [ ] لا temp files في success/error/timeout.

### B3 — Boundary tests
- [ ] boundary-1/equal/+1 لكل حد واختبارات alpha/opaque/misleading extension/animation.

## Acceptance criteria

- [ ] worker تعيد bytes/MIME/dimensions صادقة أو typed failure فقط.
- [ ] event loop يبقى responsive ولا يتجاوز التزامن 2.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/capabilities/image_policy_test.dart test/capabilities/image_worker_test.dart 2>&1 | tail -5`
- [ ] تحديث capabilities contract والوثائق وسجل parity.

