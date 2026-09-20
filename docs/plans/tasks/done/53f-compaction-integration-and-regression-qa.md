---
title: "Task 53f: Compaction Integration and Regression QA"
description: "إثبات ضغط السياق end-to-end عبر providers وtool loops وrestart والqueue والواجهة، وإغلاق أي findings دون إضافة سياسة جديدة."
status: "complete"
current_gate: "done"
priority: "critical"
depends_on: "Tasks 53b, 53c, 53d, and 53e"
file_budget: 12
---

# Task 53f: التحقق التكاملي والانحداري للـcompaction

## 1. الهدف

إثبات أن النظام المكتمل يحافظ على الهدف والتاريخ وسلامة الأدوات وحالة الواجهة عبر التشغيل الحقيقي والانقطاع وإعادة التشغيل، وأن manual وauto compaction تستخدمان العقد نفسها دون اختلافات مخفية.

هذه المهمة لا تضيف policy أو schema جديدة. أي finding يكشف نقصًا معماريًا يعيد فتح Gate المالكة في 53b–53e ويحدث لوحة الخطة.

## 2. Gate F0 — مصفوفة السيناريوهات والfixtures

- [x] تثبيت long-conversation fixtures تحتوي goal وconstraints وdecisions وfiles وtool effects وblockers وpending asks.
- [x] تثبيت provider matrix تشمل OpenAI-compatible وAnthropic-compatible وCodex Responses وOllama/local behavior عبر adapters deterministic أو fixtures آمنة.
- [x] تعريف token-pressure fixtures: تحت threshold، عندها، فوقها، huge user message، huge tool result، media، وunknown usage.
- [x] تعريف lifecycle matrix: manual، proactive auto، tool-loop auto، overflow recovery، summary failure، cancel/shutdown، وrestart.
- [x] تعريف UI matrix: started/completed/failed، manual/auto، desktop hover، mobile tap، keyboard، reconnect، وhistory hydration.
- [x] توثيق pass/fail evidence المطلوبة لكل Gate قبل تشغيل verification.

### F0 Exit

- [x] كل acceptance criterion في Plan 53 له سيناريو واحد على الأقل.
- [x] fixtures لا تستدعي provider حقيقية للمستخدم ولا تحمل أسرارًا.

## 3. Gate F1 — Engine quality and repeated compaction

- [x] تشغيل goal-retention fixtures عبر compaction واحدة وثلاث compactions متتالية.
- [x] مقارنة continuity anchors الحرجة قبل/بعد: goal، pending asks، constraints، decisions، paths/IDs، blockers، وremaining work.
- [x] إثبات أن stale facts تزال دون حذف unresolved work.
- [x] إثبات أن tail verbatim وtool pair invariants سليمة عبر providers.
- [x] إثبات redaction قبل/بعد summarizer وعدم تسريب provider-state blobs.
- [x] اختبار no-progress وrepair failure وcooldown/breaker paths.

### F1 Exit

- [x] لا fixture ناجحة تفقد anchor حرجة.
- [x] unvalidated summary لا تفعل boundary.
- [x] repeated compaction تبقى تحت target ولا تراكم summaries.

## 4. Gate F2 — Persistence, restart, and concurrency

- [x] restart بعد started وقبل summary response.
- [x] restart بعد summary وقبل activation commit.
- [x] restart بعد commit وقبل live delivery.
- [x] concurrent manual/auto claims للجلسة نفسها وفصل Session A عن Session B.
- [x] late result من operation قديمة بعد boundary أحدث.
- [x] canonical history كاملة بعد repeated compaction وprojection صحيحة من أحدث boundary.
- [x] soft rewind/fork/pagination coordination scenarios حسب حالة Tasks 47/51/52 وقت التنفيذ.

### F2 Exit

- [x] كل restart point يعيد terminal state وprojection حتمية.
- [x] لا تضيع canonical message ولا تتفعل boundary جزئية.
- [x] claim واحدة فقط تملك mutation لكل session.

## 5. Gate F3 — Runtime, tools, overflow, and queue

- [x] auto preflight قبل الدور وقبل provider call بعد tool result كبيرة.
- [x] overflow قبل أول provider event: compaction ثم retry واحدة.
- [x] overflow بعد reasoning/content/tool state: لا automatic replay.
- [x] output-cap وpayload/media errors لا تصنف context compaction خطأً.
- [x] tool result ذات side effect لا يعاد تنفيذها عبر compaction/restart.
- [x] رسائل متعددة أثناء compaction تحفظ وتنفذ FIFO مرة واحدة.
- [x] manual failure وauto failure وoverflow failure تحرر أو توقف queue وفق disposition الموثقة دون strand.
- [x] stop/shutdown/reconnect لا تنتج duplicate lifecycle أو queued work.

### F3 Exit

- [x] لا duplicate output أو tool effect أو user message.
- [x] لا session تبقى compacting بعد terminal failure/restart.
- [x] request التالية بعد success مثبتة تحت الحد المستهدف.

## 6. Gate F4 — Slash command and client parity

- [x] capabilities تعرض `/compact` فقط ضمن runtime commands ولا تعرض الأوامر الوهمية.
- [x] `/compact` في index صفر تنفذ command؛ slash في المنتصف لا تفعل ذلك.
- [x] arguments ترفض محليًا ولا تتحول إلى user message.
- [x] skills تعمل في البداية والمنتصف والنهاية ولا تتأثر command parser.
- [x] centered tile تتحول started -> completed/failed بلا duplicate.
- [x] manual/auto labels والأيقونات والsemantics صحيحة.
- [x] hover/tap/focus يعرض التفاصيل نفسها ولا يكشف summary.
- [x] navigation/reconnect/reload يعيد الحالة نفسها من history/cache.
- [x] narrow mobile layout وlarge text scale لا يسببان overflow.

### F4 Exit

- [x] live/history parity كاملة لكل lifecycle state.
- [x] composer grammar لا تخلط command وskill tokens.
- [x] accessibility والتفاعل متعدد المنصات يجتازان المصفوفة.

## 7. Gate F5 — التحليل، الاختبارات الكاملة، والتوثيق

- [x] تحليل agent وclient نظيف.
- [x] suites المركزة لكل مهام 53 ناجحة.
- [x] full fast agent/client suites ناجحة أو كل failure قديمة موثقة بدليل سابق مستقل.
- [x] daemon-backed E2E يثبت manual وauto وqueue وrestart وhistory hydration.
- [x] تحديث Graphify بعد تعديلات الكود والتحقق من عدم بقاء references للمسار القديم.
- [x] تحديث `AGENTS.md` المالكة وصفحات agent engine/technical/product/QA/MOC.
- [x] تدقيق relative links والمصطلحات والحالات في الخطة والمهام.
- [x] تسجيل الأدلة النهائية في الخطة الأم وتحديث الحالة إلى `in_review` فقط بعد إغلاق كل gates.

### F5 Exit / Definition of Done

- [x] كل معايير القبول الكلية في Plan 53 مغلقة بدليل.
- [x] compaction تحافظ على هدف الوكيل وتاريخ المستخدم عبر repeated boundaries وrestart.
- [x] manual وauto وoverflow paths تمر عبر نفس engine/persistence lifecycle.
- [x] لا توجد slash commands وهمية أو مسار ContextEngine قديم.
- [x] النظام جاهز لمراجعة بشرية نهائية قبل `complete`.

## 8. الملفات المتوقعة

- agent unit/integration/E2E tests مركزة
- client unit/widget/integration tests مركزة
- fixtures مشتركة للgoal retention والprovider behavior
- `docs/qa_maintenance/context_compaction_qa.md`
- `docs/qa_maintenance/MOC.md`
- `docs/agent_engine/context_compaction_design.md`
- `docs/agent_engine/MOC.md`
- `docs/technical/agent_runtime.md`
- `docs/technical/agent_database_schema.md`
- `docs/technical/communication_protocols.md`
- `docs/product/client_interface.md`
- ملفات `AGENTS.md` المالكة التي عدلتها المهام السابقة
- ملف المهمة والخطة الأم

## 9. سيناريو النجاح النهائي

تبدأ جلسة طويلة بهدف متعدد المراحل وتنفذ أدوات ذات نتائج كبيرة. يحدث auto compaction داخل tool loop، وتصل رسالة جديدة أثناءه فتدخل queue. تنجح summary validated وتظهر centered auto event، ثم تستمر الجولة وتنفذ الرسالة queued. بعد compaction متكررة وrestart تظل الأهداف والقيود والملفات والعمل المتبقي محفوظة، وتعرض timeline التاريخ الكامل والأحداث نفسها. بعد ذلك ينفذ المستخدم `/compact` يدويًا من بداية composer، فتظهر manual lifecycle منفصلة دون إنشاء user message، وتظل details متطابقة بعد reload.

## 10. خارج النطاق

- إضافة features جديدة ظهرت أثناء QA ولا تمنع معايير Plan 53.
- performance tuning غير المدعوم بقياسات.
- arguments أو preview أو focus لأمر `/compact`.
- حذف canonical history أو summary editing UI.

## 11. سجل التقدم

```text
Date: 2026-08-31 (independent remediation review, F0→F5)
Gate/status: 53f complete after F3 reopened 53d D0/D3
F0/F1: deterministic provider-protocol matrix (OpenAI-compatible, Anthropic-compatible, Codex Responses, Ollama/local) plus repeated goal-retention fixtures pass; no external provider or secret is used.
F2: completed boundary and interrupted started boundary survive database reopen with deterministic completed/failed projection; concurrency and session isolation pass.
F3: early durable compaction barrier, tool/replay/overflow/queue bundle 143/143. Daemon E2E proves manual lifecycle, restart hydration/causal order, proactive auto compaction, one explicitly queued follow-up executed exactly once, and only one completed lifecycle when a later attempt fails.
F4: composer/domain/mapper/timeline suite 42/42, including 44px target, hover/tap/focus parity, 280px width, and 2x text scale.
F5: agent and client analyzers clean; focused Dart formatters clean; daemon E2E 3/3; full client fast suite 1147 passed / 1 skipped; full agent fast suite 1357 passed / 12 skipped / 1 unrelated pre-existing DelegateTaskTool DI failure reproduced independently. Graphify updated (21624 nodes, 29364 edges).
Remaining scope: Plan 53 stays in_progress because 53g YAML/model-policy gates are explicitly excluded from this remediation. Adapter-native estimated wire measurement and provider-confirmed post-compaction provenance remain 53g work.
```

```text
Date: 2026-08-29
Gate/status: 53f complete (F0–F5) — gate-by-gate review re-verified
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Verification: agent analyze clean; client analyze clean; Plan 53 focused agent suite 61 passed; daemon E2E context_compaction 2/2; client focused compaction suites passed earlier in review
Findings (review): QA matrix + evidence checklist current; no ContextEngine in agent/lib; full agent fast suite still has 1 pre-existing unrelated DI failure (documented in QA). Plan 53 status remains in_review for human finalization.
Next: human review → plan complete (no commit/push unless requested)
```

Date: 2026-08-29
Reviewer: gate-by-gate Plan 53 review
Gate closed: F0–F5 (full fast suite exception documented)

```text
Date: 2026-08-29 (evening re-review)
Gate/status: 53f F0→F5 re-closed in order
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
F0: QA matrix + Plan 53 acceptance checklist mapped to scenarios
F1–F4: covered by focused suites already re-run under 53a–53e
F5: agent analyze clean; client analyze clean; Plan 53 focused agent suite 65 passed; daemon E2E 2/2; no ContextEngine in agent/lib; slash catalog /compact only
Cross-task fix during 53d D6: docs event names aligned to context_compaction.started|completed|failed
Findings: full agent fast suite still has 1 pre-existing unrelated DI failure (evolution_tracks_test DelegateTaskTool) — documented in QA
Plan 53 remains in_review for human finalization
Next: human review → plan complete (no commit/push unless requested)
```

```text
Date: 2026-08-30 (live auto-compaction regression repair)
Gate/status: F3/F4 reopened and re-closed
Evidence: a real Codex Responses request after auto-compaction contained three orphan function_call_output items; the retained-tail selector now expands across complete multi-tool batches, persisted unsafe boundaries fall back to canonical history, and lifecycle transitions mint distinct transport event_id values so completed is not deduplicated behind started
Verification: focused engine/projection/history/lifecycle suites passed (28 agent tests), client compaction-state/mapper/transport-dedup suites passed (20 tests), and agent analyzer is clean; live restart verification is recorded in the parent plan
Next: retry the blocked live turn against the repaired runtime
```

```text
Date: 2026-08-31 (post-compaction retrigger regression repair)
Gate/status: F2/F3 reopened and re-closed
Evidence: each ordinary history save replaced every canonical message row, invalidating durable boundary IDs; preflight also measured the hidden canonical head instead of the active projection
Fix: preserve the unchanged canonical row-ID prefix, measure active projection pressure, and advance repeated-compaction source ranges beyond the prior summarized range
Verification: 56 focused persistence/engine/runtime tests pass; agent analyzer clean; controlled restart healthy; the affected live session's latest boundary was conditionally rebased after a consistent database backup (516/516 referenced rows present)
Next: one live follow-up turn should run without a new compaction event
```
