---
title: "Task 53b: Durable Compaction Boundary and Model Projection"
description: "حفظ compaction lifecycle بصورة ذرية وبناء model projection من أحدث boundary ناجحة مع إبقاء التاريخ الأصلي كاملًا."
status: "complete"
current_gate: "done"
priority: "critical"
depends_on: "Task 53a"
coordinates_with: "Tasks 47, 51, and 52"
file_budget: 14
---

# Task 53b: Compaction boundary دائمة وmodel projection غير هدامة

## 1. الهدف

إضافة مصدر حقيقة دائم لعمليات compaction بحيث لا تصبح أي summary فعالة إلا بعد commit ناجح، مع إبقاء canonical messages الأصلية كما هي وبناء سياق النموذج من أحدث boundary ناجحة.

## 2. Gate B0 — عقد التخزين والهوية

- [x] تدقيق schema الحالية لـsessions/messages/work items/history metadata قبل اختيار الجدول والعلاقات.
- [x] اعتماد هوية `compaction_id` و`session_id` و`source_history_revision` وsource/tail stable identities.
- [x] اعتماد lifecycle `started -> completed|failed` ومنع terminal rewrite غير idempotent.
- [x] تحديد الحقول الدائمة الدنيا:
  - trigger وstatus.
  - source range وretained-tail boundary.
  - internal validated summary.
  - provider/model route.
  - before/after/context-window metrics.
  - redacted failure reason.
  - started/completed timestamps.
- [x] تحديد retention دون تكرار canonical message payloads داخل compaction rows.
- [x] تحديد history revision/CAS المستخدمة لمنع activation فوق snapshot قديمة.
- [x] تثبيت أن timeline history وpagination لا تخفي الرسائل السابقة للـboundary.

### B0 Exit

- [x] Task 47 يمكنها paginate canonical events دون معرفة model projection internals.
- [x] Tasks 51/52 تملكان قاعدة واضحة لإبطال أو remap boundary عند soft rewind أو fork.
- [x] لا يعتمد العقد على ترتيب list في ذاكرة AgentRunner.

**Evidence:** `docs/technical/context_compaction.md` §8, `docs/technical/agent_database_schema.md` §3.2.1, `CompactionOperationRecord` + `CompactionBoundaryValidity`.

## 3. Gate B1 — Repository وmigration

- [x] إضافة migration idempotent للجداول/الحقول/indexes المطلوبة.
- [x] إضافة repository typed لبدء operation وتسجيل completed/failed outcome وقراءة أحدث boundary فعالة.
- [x] جعل claim للجلسة exclusive عبر transaction/CAS؛ عمليتان متزامنتان لا تنجحان معًا.
- [x] دعم restart عندما توجد operation في `started` بلا terminal outcome؛ تصنف interrupted/failed ولا تفعل summary.
- [x] فصل redacted user-visible failure عن diagnostic metadata الداخلية الآمنة.
- [x] منع حفظ summary أو transcript يحتمل احتواء secrets قبل مرور redaction contract.

### B1 Exit

- [x] latest successful boundary تستعاد بعد إغلاق قاعدة البيانات وفتحها.
- [x] started/failed boundary لا تغير projection.
- [x] concurrent claims تنتج فائزًا واحدًا وtyped busy/stale outcomes للبقية.

**Verification:** `fvm dart test test/evolution/compaction_boundary_repository_test.dart` — 7 passed.

## 4. Gate B2 — Active model projection

- [x] إضافة builder واحد يقرأ canonical history وأحدث successful boundary ويعيد:
  - validated internal summary واحدة.
  - retained verbatim tail.
  - كل الرسائل اللاحقة للـsnapshot.
- [x] إبقاء current system/runtime context خارج summary وإعادة تركيبه عبر `AgentContextAssembler` لكل request.
- [x] عدم إعادة internal metadata أو compaction row fields إلى provider wire.
- [x] الحفاظ على assistant tool call/tool result pairs وprovider state اللازمة داخل retained tail.
- [x] رفض projection ذات source identities مفقودة أو متعارضة بدل fallback صامت إلى ترتيب تقريبي.
- [x] ضمان repeated compaction تستخدم boundary الأحدث ولا تراكم summaries سابقة.
- [x] توفير raw canonical timeline query مستقلة لواجهة المستخدم والتدقيق.

### B2 Exit

- [x] model projection تبدأ من boundary الصحيحة، وtimeline تظل كاملة.
- [x] reload يعيد projection نفسها دون الاعتماد على mutation سابقة في AgentRunner.
- [x] summary لا تظهر كرسالة system ثانية أو user/assistant message مصطنعة.

## 5. Gate B3 — Activation transaction والتكامل مع execution state

- [x] تفعيل candidate داخل transaction تتحقق من session/source revision والclaim الحاليين.
- [x] حفظ terminal metrics وsummary ثم نشر projection revision جديدة بعد commit فقط.
- [x] persistence failure يعيد original boundary ولا يسمح بمتابعة provider request من candidate volatile.
- [x] تعريف أثر queued work وactive work item دون حذف payload أو تغيير run ownership.
- [x] جعل late completion من operation stale no-op لا تستبدل boundary أحدث.
- [x] نشر repository change مرة واحدة بعد commit كي تستهلكه interface layer في 53d/53e.

### B3 Exit

- [x] crash قبل commit لا يغير active context.
- [x] crash بعد commit يعيد نفس boundary والmetrics والprojection.
- [x] لا يمكن لsummary قديمة أو failure outcome إلغاء boundary أحدث.

## 6. Gate B4 — التحقق والتوثيق

- [x] اختبارات migration وCRUD وexclusive claim وrestart وstale CAS.
- [x] اختبارات projection للboundary الأولى والمتكررة وretained tail والرسائل اللاحقة.
- [x] اختبارات عدم حذف canonical messages وعدم ظهور summary في timeline.
- [x] اختبارات tool pairing وprovider state داخل tail.
- [x] تحديث database schema وagent runtime design وQA ownership.
- [x] مراجعة file budget قبل الإغلاق.

### B4 Exit / Definition of Done

- [x] successful boundary وحدها authoritative.
- [x] التاريخ الأصلي كامل وقابل للقراءة بعد أي عدد من compactions.
- [x] model projection قابلة للبناء من التخزين فقط بعد restart.
- [x] API المعتمدة جاهزة لاستهلاك 53c candidate و53d orchestration.

## 7. الملفات المتوقعة

- `agent/lib/evolution/db/agent_state_database.dart`
- repository/model files جديدة تحت `agent/lib/evolution/db/`
- model projection builder تحت engine/evolution owner المعتمد
- `agent/lib/evolution/session_manager.dart`
- `agent/lib/evolution/db/session_db.dart` عند الحاجة فقط دون استمرار destructive compaction
- اختبارات DB/projection مركزة
- `agent/lib/evolution/AGENTS.md`
- `agent/lib/engine/AGENTS.md`
- `docs/technical/agent_database_schema.md`
- `docs/technical/agent_runtime.md`
- QA page الخاصة بالخطة
- ملف المهمة والخطة الأم

## 8. سيناريو النجاح

تبدأ compaction ثم يتوقف daemon قبل اكتمال summary؛ بعد restart يبقى التاريخ والسياق السابقان فعالين وتظهر العملية failed/interrupted. في محاولة ثانية تنجح summary وتفعل ذريًا. بعد restart جديد تبني request من summary واحدة وtail والرسائل اللاحقة، بينما session history المعروضة ما زالت تحتوي كل الرسائل الأصلية.

## 9. خارج النطاق

- تحديد الحاجة للضغط أو تشغيل summarizer.
- provider overflow recovery.
- canonical events أو Flutter timeline.
- حذف الرسائل القديمة أو تقليل حجم DB.

## 10. سجل التقدم

```text
Date: 2026-08-31 (independent remediation review)
Gate/status: B0–B3 passed; B4 repaired and re-closed
Evidence: B1 7/7, B2 8/8, B3 4/4, combined persistence/projection suite 24/24, format check and analyzer clean
Root causes verified: `SessionDB.replaceMessages` previously recreated every row and invalidated durable range identities on ordinary append; projection eligibility previously accepted retained tool results without their owning assistant call. The current regression tests prove stable-prefix row preservation and canonical fallback for unsafe persisted boundaries.
Repair: formatted nine 53b-owned production/test files that failed the static format gate; no semantic rewrite of the existing user fixes
Next: Task 53c Gate C0
```

```text
Date: 2026-08-29
Gate/status: 53b complete (B0–B4) — gate-by-gate review re-verified + B4 doc fixes
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Files changed: compaction_boundary_repository, activation service, model_projection_builder, schema/runtime docs, evolution AGENTS, task log
Verification: compaction_boundary_repository + operation_record + restart_persistence + model_projection_builder + compaction_activation_service — 23 passed
Findings (review): B0–B3 exit criteria met in code/tests. B4 gaps fixed: agent_runtime.md still claimed no durable compaction; schema note still said history_revision “lands in B1”; CompactionOperationRecord comment still said “future” table; progress log was stuck at B2→B3 while status claimed complete. Projection metadata key stays on Message for internal ID only; OpenAI/Anthropic wire maps omit Message.metadata.
Next: Task 53c Gate C0
```

Date: 2026-08-29
Reviewer: gate-by-gate Plan 53 review
Gate closed: B0, B1, B2, B3, B4 (doc contradictions repaired)

```text
Date: 2026-08-29 (evening re-review)
Gate/status: 53b B0→B4 re-closed in order
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
B0: §8 identity/CAS/Task47-51-52 contracts present; CompactionOperationRecord + Validity helper exist
B1–B4: repository/migration/projection/activation present; focused suite 23/23 passed
Findings: no fixes required; Anthropic/OpenAI wire maps omit Message.metadata (summary marker internal-only)
Next: Task 53c Gate C0
```
