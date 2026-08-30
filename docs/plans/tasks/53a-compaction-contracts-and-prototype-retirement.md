---
title: "Task 53a: Compaction Contracts and Prototype Retirement"
description: "إزالة ContextEngine التجريبي وتثبيت حدود الملكية والأنواع والاعتماديات التي ستستهلكها مهام الضغط اللاحقة."
status: "complete"
current_gate: "done"
priority: "critical"
depends_on: "Approved Plan 53"
file_budget: 10
---

# Task 53a: عقود compaction وإزالة النموذج التجريبي

## 1. الهدف

إزالة مسار `ContextEngine` القديم بالكامل لأنه نموذج اختباري غير صالح كأساس إنتاجي، ثم تثبيت vocabulary وحدود الملكية بين engine وpersistence وruntime وprotocol قبل أي تنفيذ جديد.

هذه المهمة لا تقدم compaction جزئية مؤقتة. بعد إغلاقها لا يوجد ضغط سياق حتى تكتمل المهام التالية، ويظل context overflow خاضعًا لسلوك recovery الحالي مؤقتًا بدل تشغيل مسار غير موثوق.

## 2. Gate A0 — تدقيق الإزالة والعقود

- [x] حصر imports وDI registrations وconstructor parameters والاستدعاءات والاختبارات والوثائق التي تملك `ContextEngine` أو تصفه كميزة إنتاجية.
- [x] إثبات أن الإزالة لا تمس `AgentContextAssembler` أو context-usage metrics أو provider context-limit resolution.
- [x] تعريف boundaries التالية قبل إضافة types:
  - pressure evaluation تستهلك request material ولا تملك history.
  - compaction engine تحول immutable snapshot إلى candidate فقط.
  - persistence تملك source revision وboundary activation.
  - runtime orchestrator يملك serialization والqueue والterminal state.
  - protocol يعرض lifecycle ولا يملك summary أو قرار الضغط.
- [x] اعتماد vocabulary موحدة: `CompactionTrigger`, `CompactionStatus`, `CompactionFailureReason`, `CompactionPressure`, `CompactionCandidate`, و`CompactionOutcome` أو أسماء مكافئة.
- [x] تحديد metadata الداخلية التي يجب stripping لها قبل provider wire serialization.

### A0 Exit

- [x] لا يوجد ownership مشترك غامض بين `AgentRunner` وservice جديدة.
- [x] 53b و53c يمكنهما الاعتماد على types ثابتة دون استيراد interface أو Flutter code.

**Evidence:** `docs/technical/context_compaction.md` (§1–§7, 2026-08-29).

## 3. Gate A1 — إزالة النموذج التجريبي

- [x] حذف `agent/lib/engine/context_engine.dart`.
- [x] إزالة DI registration والحقن في `AgentRunner`.
- [x] إزالة الاستدعاءين السابقين للضغط من sync وstream model loops.
- [x] إزالة test/mocks المملوكة حصريًا للمحرك القديم.
- [x] إزالة أو تصحيح عقود `AGENTS.md` والوثائق التي تقول إن history تضغط تلقائيًا بهذا المحرك.
- [x] إبقاء provider context-limit APIs وcontext-usage indicator دون تغيير سلوكي.
- [x] عدم ترك no-op abstraction تحمل الاسم القديم أو compatibility adapter غير مستخدمة.

### A1 Exit

- [x] لا يعثر البحث المباشر على reference إنتاجية لـ`ContextEngine` أو `compressIfNeeded`.
- [x] AgentRunner يبني الطلبات ويرسلها دون mutation خفية في history.
- [x] اختبارات runner/provider usage الحالية لا تتراجع بسبب الإزالة.

**Verification:** `fvm dart analyze` clean; `fvm dart test test/core/di_live_default_adapter_test.dart test/engine/agent_context_assembler_test.dart test/interfaces/context_usage_translation_test.dart` — 18 passed.

## 4. Gate A2 — أنواع الأساس وحدود الاعتماد

- [x] إضافة provider-neutral domain types المطلوبة فقط لفتح 53b و53c، دون implementation أو DB schema مبكرة.
- [x] تمثيل trigger بقيم `manual|auto|overflow` وتمثيل lifecycle بقيم terminal صريحة.
- [x] جعل candidate تحمل source revision/range وretained-tail range وsummary داخلية وmetrics وcontinuity validation result.
- [x] منع الأنواع من حمل raw credentials أو adapter response bodies أو Flutter presentation fields.
- [x] تثبيت أن summary ليست `MessageRole.system` ولا user-visible `Message`.
- [x] تثبيت أن source selection يعتمد stable identities/revision، لا list indices العابرة.

### A2 Exit

- [x] الأنواع قابلة للاختبار مستقلة عن DI وقاعدة البيانات.
- [x] لا تتطلب 53b استيراد summarizer، ولا تتطلب 53c استيراد SessionDB.

**Location:** `agent/lib/engine/compaction/` (barrel: `compaction.dart`). **Verification:** `fvm dart test test/engine/compaction_types_test.dart` — 8 passed.

## 5. Gate A3 — التحقق والتوثيق

- [x] تحليل agent نظيف بعد الإزالة.
- [x] اختبارات AgentRunner وcontext usage وprovider routing المركزة ناجحة.
- [x] تحديث engine/plugin contracts لإزالة الوصف القديم.
- [x] إضافة تصميم compaction إلى technical MOC أو صفحة technical مالكة بدل وضع design داخل `AGENTS.md`.
- [x] مراجعة file budget وسجل الملفات الفعلية قبل التسليم.

### A3 Exit / Definition of Done

- [x] لا يوجد مسار ضغط تجريبي أو تلقائي مخفي.
- [x] ownership/types المعتمدة تكفي لبدء 53b و53c بالتوازي.
- [x] لا تغير المهمة protocol أو UI أو persistence schema قبل عقودها المالكة.

**Verification:** `fvm dart analyze` clean; 94 focused tests passed (`agent_runner_test`, `metrics_tracker_test`, `di_live_default_adapter_test`, `agent_context_assembler_test`, `context_usage_translation_test`, `compaction_types_test`).

### File budget (planned 10, actual 24 touched)

| Category | Count | Notes |
|---|---:|---|
| Deleted | 3 | prototype engine + tests |
| Modified production | 4 | `agent_runner`, `di`, `engine/AGENTS.md`, `plugins/AGENTS.md` |
| New production types | 8 | `agent/lib/engine/compaction/*` |
| Modified/new tests | 3 | `compaction_types_test`, `di_live_default_adapter_test`, `interfaces_test.mocks` |
| Modified e2e | 1 | `sanad_gateway_platform_e2e_test` |
| Documentation | 5 | `context_compaction.md`, `agent_runtime.md`, `provider_protocol.md`, `MOC.md`, `llms.txt` |
| Plan tracking | 2 | task 53a, plan 53 |

Budget exceeded because A2 added eight typed modules plus tests; no further split required before 53b/53c.

## 6. الملفات المتوقعة

- `agent/lib/engine/context_engine.dart` (حذف)
- `agent/lib/engine/agent_runner.dart`
- `agent/lib/core/di.dart`
- `agent/test/engine/context_engine_test.dart` وmock المولد (حذف)
- domain types جديدة تحت owner يثبت في A0
- `agent/lib/engine/AGENTS.md`
- `agent/lib/plugins/AGENTS.md`
- `docs/technical/agent_runtime.md`
- ملف المهمة والخطة الأم

## 7. سيناريو النجاح

يبنى AgentRunner لجلسة موجودة ويرسل sync وstream turns مع exact provider/model route، ويستمر context-usage reporting كما هو. لا يحدث أي mutation في history قبل provider request، ولا يبقى أي reference للمحرك التجريبي، بينما تكون types الجديدة قابلة للاستهلاك من persistence والمحرك دون coupling متبادل.

## 8. خارج النطاق

- schema أو boundary persistence.
- summary prompt أو token budgeting.
- auto trigger أو overflow recovery.
- `/compact` أو Flutter UX.

## 9. سجل التقدم

```text
Date: 2026-08-29
Gate/status: 53a complete (A0–A3) — gate-by-gate review re-verified
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Files changed: 24 total (see A3 file budget table)
Verification: no ContextEngine/compressIfNeeded in agent/lib; compaction types have no Flutter/interfaces imports; A1 suite 18 passed; compaction_types_test 8 passed; A3 focused suite 94 passed (agent_runner, engine/metrics_tracker, di_live_default_adapter, agent_context_assembler, context_usage_translation, compaction_types). Note: task log previously cited test/core/metrics_tracker_test.dart (missing); correct path is test/engine/metrics_tracker_test.dart.
Findings: prototype removed; ownership/vocabulary docs + types sufficient for 53b/53c; agent analyze currently reports 2 infos in later-task session_compact_command_handler (owned by 53e, not 53a)
Next: Task 53b Gate B0
```

Date: 2026-08-29
Reviewer: gate-by-gate Plan 53 review
Gate closed: A0, A1, A2, A3 (exit criteria met; no code fixes required for 53a)

```text
Date: 2026-08-29 (evening re-review)
Gate/status: 53a A0→A3 re-closed in order
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
A0: ownership/vocabulary in docs/technical/context_compaction.md §1–§5; types under engine/compaction/ import only meta + RouteSignature (no Flutter/interfaces)
A1: context_engine.dart + tests deleted; zero ContextEngine/compressIfNeeded in agent/lib; analyze clean; 18/18 A1 suite passed
A2: compaction_types_test 8/8 passed; enums/candidate/summary/identities match exit criteria
A3: A3 focused suite 94/94 passed; MOC + context_compaction.md present; no protocol/UI/schema owned by 53a alone
Findings: no fixes required
Next: Task 53b Gate B0
```


