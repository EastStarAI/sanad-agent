---
title: "Task 77e2: Agent Attachment Store"
status: "complete"
priority: "high"
depends_on: "77e1"
current_gate: "Complete"
remaining_estimate: "0%"
evidence_id: "77e"
evidence_fingerprint: "sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a"
---

# Task 77e2: مخزن المرفقات المملوك للوكيل

## Goal

إنشاء مخزن محمي داخل Sanad Home يقبل ملفات محلية أو منقولة، يثبتها ذرّيًا تحت session ownership، ويعيد agent-local references صالحة للأدوات دون كشفها للعميل العام.

## Locked scope

- agent هو storage/path authority؛ client cache لا يملك الملفات.
- partial write يستخدم ملفًا خاصًا مؤقتًا ثم size/hash/content validation ثم atomic promotion.
- filename وMIME المرسلان advisory؛ الاسم ينظف ولا يحدد مسار التخزين.
- user attachment grant محدود بالمرفق والجلسة ولا يساوي workspace/full access.
- attachment يبقى ما دامت رسالته موجودة؛ session deletion وorphan cleanup يحذفانه حتميًا.
- remote recursive folders خارج النطاق.

## Gates

### R0 — Evidence and filesystem contract
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] مراجعة Sanad Home وpermission/path contracts المالكة.

### G1 — Private staging
- [x] إضافة create/write/commit/cancel API bounded دون path injection.
- [x] تطبيق 5 MiB authoritative ceiling وSHA-256 وsafe-name/content inspection.
- [x] ضمان owner-only permissions حيث يدعم النظام.

### G2 — Durable ownership and cleanup
- [x] ربط attachment بالجلسة والرسالة دون orphan race.
- [x] تنظيف partial timeout/cancel/failure وsession deletion.
- [x] منع cross-session identity reuse.

### G3 — Tool path bridge
- [x] إنتاج agent-local path/reference لا يظهر في events/logs.
- [x] تمكين أدوات القراءة و`view_image` من استخدام grant المحدودة فقط.

## Acceptance criteria

- [x] interrupted/invalid/hash-mismatch upload لا يترك ملفًا معتمدًا أو partial دائمًا.
- [x] traversal واسم خبيث وMIME كاذب لا يغير storage root أو النوع المتحقق.
- [x] مرفق جلسة لا يقرأ من جلسة أخرى.
- [x] حذف الجلسة يزيل الملفات والmetadata idempotently.

## Definition of Done

- [x] `fvm dart analyze` ناجح.
- [x] focused store/path/permission/cleanup tests ناجحة.
- [x] اختبارات Windows/macOS/Linux path semantics ممثلة.
- [x] وثائق الحماية وQA محدثة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-09-15 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`.
- Packet `77e` resolved `ready` at the pinned clean OpenCode/OpenClaw revisions.
- The Agent state-home boundary owns session-scoped attachment bytes and durable ownership; `Message` owns only admitted typed metadata, while interfaces receive the path-free projection.
- Fixed-root opaque storage names, bounded owner-only partials, verified atomic promotion, and idempotent lifecycle cleanup are locked. Caller filename/MIME/path values are never storage authority.
- Remaining estimate: `75%`.
- Next gate: `G1 — Private staging`.

### 2026-09-15 — G1 complete

- Added bounded create/write/commit/cancel staging beneath the fixed state-home root. Generated UUIDs own every path; safe names are metadata only.
- Streaming enforces 5 MiB before writes. Commit recomputes size/SHA-256, inspects content, atomically promotes, and enforces 0700/0600 on Unix-like systems.
- Remaining estimate: `50%`; next gate: `G2`.

### 2026-09-15 — G2 complete

- Added durable same-session message ownership with an insert trigger, database rollback cleanup, startup partial/promoted/message-orphan cleanup, and idempotent session deletion through `SessionManager`.
- Replacement-safe ownership does not cascade merely because a message row is transiently rewritten; explicit orphan reconciliation removes bytes after the message ceases to exist.
- Remaining estimate: `25%`; next gate: `G3`.

### 2026-09-15 — G3 complete

- Exact `(session_id, attachment_id)` resolution is the sole bridge from an opaque Agent-local reference to the canonical payload path. It grants no sibling, workspace, or cross-session access and emits no event/log payload.
- Verification: Agent analyzer clean; 653 evolution/interfaces tests passed; focused store suite covers six staging, ownership, path, permission, and cleanup scenarios; Graphify rebuilt 23,900 nodes, 32,891 edges, and 898 communities.
- Pinned reference trees remained clean and post-implementation parity matched packet `77e` without copied code or deviation.
- File budget: `10/10` tracked paths.
- Status transition: `in_progress/G3` → `complete`; remaining estimate `0%`.
- Next task: `77e3 — Attachment Gateway and Client Admission`, gate `R0`.
