---
title: "Task 77e1: Attachment Model and Policy"
status: "complete"
priority: "high"
depends_on: "77d3"
current_gate: "Complete"
remaining_estimate: "0%"
evidence_id: "77e"
evidence_fingerprint: "sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a"
---

# Task 77e1: نموذج المرفق والسياسة المركزية

## Goal

إضافة عقد typed موحد لمرفقات رسائل المستخدم وسياسة قبول مركزية تثبت حد 5 MiB لكل ملف و4 ملفات/20 MiB لكل رسالة دون إدخال bytes في الأحداث العامة.

## Locked scope

- attachment identity، الاسم الآمن، MIME، الحجم، SHA-256، kind، agent-local reference، media identity، والحالة حقول مغلقة versioned.
- `Message` تسمح attachments فقط لرسائل user وتحافظ على ترتيبها؛ النص يبقى مستقلًا.
- client wire/cache projections لا تحمل absolute path أو bytes.
- legacy user messages بلا attachments تبقى صالحة بلا migration جدولي.
- الحد `5 MiB` لكل ملف مهما كان النوع؛ `4` ملفات و`20 MiB` إجماليًا للرسالة.

## Gates

### R0 — Reference and ownership
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] تحديد المالك canonical للنموذج والسياسة بين core/interface/client cache دون duplicate authority.

### G1 — Typed model
- [x] إضافة schema/version/validation وJSON round trip.
- [x] رفض attachments على غير user message ورفض divergence أو الحقول المفتوحة.
- [x] إضافة legacy parsing بلا migration.

### G2 — Policy
- [x] إضافة constants مركزية وحدود boundary-1/boundary/boundary+1.
- [x] توحيد error codes الآمنة للحجم والعدد والإجمالي والmetadata التالفة.

### G3 — Projections and docs
- [x] إضافة safe event/history/cache projection منفصلة عن agent-local storage reference.
- [x] تحديث التصميم التقني وschema/QA المرتبطة.

## Acceptance criteria

- [x] ملف 5 MiB يقبل و`5 MiB + 1 byte` يرفض مهما كان MIME.
- [x] الرسالة الخامسة أو aggregate فوق 20 MiB ترفض حتميًا قبل execution.
- [x] JSON يحافظ على order/identity/name/MIME/size/hash دون bytes/private path.
- [x] legacy history تبقى قابلة للقراءة.

## Definition of Done

- [x] analyzer للـAgent والـClient حسب الملفات المتأثرة.
- [x] focused model/policy/cache tests ناجحة.
- [x] الوثائق وQA محدثة.
- [x] `graphify update .` ناجح.
- [x] تحديث current gate ونسبة المتبقي عند إغلاق كل بوابة.

## Progress log

### 2026-09-15 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`.
- Resolver returned `ready` for packet `77e` at the pinned OpenCode/OpenClaw revisions and fingerprint.
- Canonical ownership is locked to Agent core models and `Message`: interfaces and future client DTOs consume safe projections and cannot redefine admission policy or expose agent-local references.
- Adopted typed ordered metadata and receiver validation; rejected bytes/base64, open metadata bags, direct provider projection, and duplicate client authority.
- Remaining estimate: `75%`.
- Next gate: `G1 — Typed model`.

### 2026-09-15 — G1 complete

- Status transition: `in_progress/G1` → `in_progress/G2`.
- Added closed schema v1 for ordered user attachments with opaque attachment/media identities, safe basename, normalized MIME, byte size, lowercase SHA-256, kind, Agent-local reference, and availability.
- Durable JSON retains the local reference; immutable public JSON deliberately omits it. Unknown fields, malformed values, URL/data references, and MIME/kind divergence fail closed.
- `Message` accepts immutable ordered attachments only for user messages; legacy JSON without the field defaults to an empty list without a table migration.
- Verification: build runner succeeded; analyzer clean; 12 focused attachment/message tests passed.
- Remaining estimate: `50%`.
- Next gate: `G2 — Policy`.

### 2026-09-15 — G2 complete

- Status transition: `in_progress/G2` → `in_progress/G3`.
- `UserAttachmentPolicy` is the single receiver-authoritative owner of `5 MiB` per file, `4` attachments, and `20 MiB` aggregate limits.
- Closed safe codes cover invalid metadata, excessive count, per-file size, and aggregate size; malformed untrusted JSON maps to a generic message without echoing input.
- Boundary tests cover 5 MiB minus one, exact 5 MiB, 5 MiB plus one for image and generic MIME, exact four/exact 20 MiB, fifth file, and aggregate-over-limit rejection.
- Verification: 10 focused model/policy tests passed; analyzer clean.
- Remaining estimate: `25%`.
- Next gate: `G3 — Projections and docs`.

### 2026-09-15 — G3 complete

- Status transition: `in_progress/G3` → `complete`; Plan 77 advances to `77e2/R0`.
- Added one immutable ordered public projection for event/history/cache consumers; it preserves safe identity/name/MIME/size/hash/kind/status and excludes the Agent-local reference.
- Updated the core contract, technical design, QA ownership, task, and plan. `docs/llms.txt` already indexes both owning documents. No Client file changed, so Client analysis was not applicable.
- Verification: build runner succeeded; Agent analyzer clean; 1,364 core/capabilities/engine/interfaces tests passed with 13 skips; Graphify rebuilt 23,845 nodes, 32,808 edges, and 852 communities.
- Post-implementation parity matched packet `77e` at the pinned clean revisions without copied code or deviation.
- File budget: `10/10` tracked paths.
- Remaining estimate: `0%` for 77e1; approximately `35%` for Plan 77.
- Next task: `77e2 — Agent Attachment Store`, gate `R0`.
