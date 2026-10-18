---
title: "Task 77b1: Image Policy Worker"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
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
- [x] حل packet 77b وقراءة mandatory image-policy sources.

### B1 — Dependency and policy
- [x] إضافة dependency وثوابت مركزية وclosed failures.
- [x] magic sniffing وstatic-frame validation قبل result construction.

### B2 — Worker
- [x] isolate worker مع semaphore=2 وkillable timeout=15s.
- [x] original preservation وlow/auto/high no-enlarge behavior.
- [x] لا temp files في success/error/timeout.

### B3 — Boundary tests
- [x] boundary-1/equal/+1 لكل حد واختبارات alpha/opaque/misleading extension/animation.

## Acceptance criteria

- [x] worker تعيد bytes/MIME/dimensions صادقة أو typed failure فقط.
- [x] event loop يبقى responsive ولا يتجاوز التزامن 2.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities/image_policy_test.dart test/capabilities/image_worker_test.dart 2>&1 | tail -5`
- [x] تحديث capabilities contract والوثائق وسجل parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/B1`.
- Resolver: `status=ready`, task `77b`; fingerprint matched `sha256:649b8758bdef850c34646defccb7fa1e87a55791873bc7337d05502b564761ad`.
- Mandatory findings adopted: magic sniffing, independent encoded/decoded/dimension limits, static-only frames, bounded CPU concurrency, and artifact-free in-memory normalization.
- Ownership: this worker accepts bytes only; path resolution and authorization remain owned by 77b2.
- Remaining estimate: `75%`.
- Next gate: `B1 — Dependency and policy`.

### 2026-09-14 — B1 complete

- Status transition: `B1` → `B2`.
- Dependency: added `image: ^4.9.1`; lock resolution is captured by the owning package lockfile.
- Policy: centralized all locked byte, pixel, edge, base64, detail, timeout, concurrency, and encoder values.
- Validation: PNG/JPEG/WebP magic sniffing, static-frame metadata, dimensions, pixels, and compact closed failures precede result construction.
- Focused verification: 8 policy/worker tests passed.
- Remaining estimate: `45%`.
- Next gate: `B2 — Worker`.

### 2026-09-14 — B2 complete

- Status transition: `B2` → `B3`.
- Worker: processing runs in killable isolates behind one process-wide FIFO semaphore capped at 2; timeout kills the isolate and releases the permit.
- Detail behavior: `original` preserves verified source bytes; low/auto/high never enlarge and resize to 768/2048/4096 only when required.
- Encoding: transparent pixels select PNG level 6; opaque normalization selects JPEG quality 85; MIME and dimensions describe returned bytes.
- Artifacts: the worker is byte-only and performs no filesystem writes in any path.
- Remaining estimate: `20%`.
- Next gate: `B3 — Boundary tests`.

### 2026-09-14 — B3 and task complete

- Status transition: `B3` → `complete`; Plan 77 advances to `77b2/R0`.
- Boundary evidence: boundary-1/equal/+1 assertions cover input bytes, hard edge, decoded pixels, and base64 payload arithmetic.
- Behavior evidence: focused tests cover truthful original preservation, no-enlarge behavior, alpha/opaque normalization, deceptive/corrupt bytes, over-limit dimensions, animation rejection, timeout kill, event-loop responsiveness, and concurrent admission.
- Verification: 8 focused tests passed; analyzer clean; Graphify rebuilt.
- Documentation: capability contract and owning technical design updated; post-implementation evidence parity has no deviations.
- File budget: 10 changed tracked paths, exactly at the task limit.
- Remaining estimate: `0%`.
- Next task: `77b2 — Secure View Image Catalog`.

