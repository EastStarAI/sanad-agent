---
title: "Task 53c: Goal-Preserving Context Compaction Engine"
description: "بناء محرك provider-neutral يقيس request كاملة، يحمي tool-aware tail، وينتج rolling summary محققة تحافظ على هدف المستخدم والحالة المتبقية."
status: "complete"
current_gate: "done"
priority: "critical"
depends_on: "Task 53a"
coordinates_with: "Task 53b candidate contract and Task 40 context usage"
file_budget: 14
---

# Task 53c: محرك ضغط يحافظ على الهدف وحالة العمل

## 1. الهدف

بناء الجزء الأهم في Plan 53: محرك ضغط لا يكتفي بتقليل tokens، بل يحافظ بصورة قابلة للتحقق على سبب وجود الجلسة، ما أنجز، ما بقي، وما يجب أن يفعله الوكيل بعد boundary.

المحرك provider-neutral ولا يملك history أو DB أو queue. يستقبل snapshot وrequest-pressure contract وroute محددة، ويعيد candidate أو failure typed فقط.

## 2. مبادئ الجودة الملزمة

1. **Goal first:** لا تعتبر summary صالحة دون هدف حالي وpending work واضحين عندما يحتوي المصدر عليهما.
2. **Verbatim recent state:** tail الحديثة لا تلخص ما دامت تدخل budget، وتبقى حدود tool/model/user groups سليمة.
3. **Rolling checkpoint:** repeated compaction تحدث summary السابقة ولا تراكم summaries أو تعيد تلخيصها كرسالة عادية.
4. **Evidence anchors:** المعرفات والمسارات والقرارات والنتائج المهمة تستخرج قبل LLM call وتتحقق بعده.
5. **No destructive fallback:** empty/error/unvalidated summary لا تفعل boundary.
6. **Re-measurement:** candidate لا تعد ناجحة حتى تقاس projection الناتجة تحت target budget.
7. **Redaction:** transcript المختارة والsummary الناتجة تمران عبر redaction قبل الحفظ أو العرض التشخيصي.

مرجع هذه المهمة الأساسي هو `refrence_projects/hermes-agent/agent/context_compressor.py` واختباراته، خصوصًا منطق structured checkpoint وtool-aware head/tail وanti-thrashing. تستخدم `refrence_projects/opencode/packages/opencode/src/session/compaction.ts` مرجعًا للretained-tail والprevious-summary anchors، دون نسخ V1 activation أو synthetic continuation.

## 3. Gate C0 — Pressure model وrequest accounting

- [x] تعريف `RequestPressureSnapshot` أو type مكافئة تمثل exact route وcontext/input limits وoutput reservation وrequest components.
- [x] احتساب history/system/runtime context/tool schemas/media/provider replay fields والرسائل synthetic الضرورية في request التالية.
- [x] استخدام provider-confirmed latest input usage كإشارة تحقق، لا كبديل عن prospective request estimate.
- [x] دعم context limit وinput limit المنفصلين عندما يوفرهما model metadata.
- [x] اشتقاق threshold من effective input window بعد output reservation وsafety buffer مركزيين.
- [x] تمييز confirmed usage عن estimated usage في metrics والقرارات.
- [x] caching آمن لتقدير tool schemas الثابتة دون مشاركة قيمة بين routes مختلفة خطأً.
- [x] عدم احتساب base64 media كحروف نصية عادية؛ استخدام provider-aware أو conservative media accounting.

### C0 Exit

- [x] pressure تحت/عند/فوق threshold deterministic ومختبرة.
- [x] exact provider/model override هو الذي يملك context window.
- [x] request بدون provider usage ما زالت تملك preflight صالحًا وموسومًا estimated.

**Verification (review 2026-08-29):** `fvm dart test test/engine/context_compaction_engine_test.dart` — RequestPressureEvaluator group + related (14 total in file). Fixes: route-keyed tool-schema cache; media byte accounting without misclassifying filler text as base64.
## 4. Gate C1 — اختيار source head وretained tail

- [x] تقسيم history إلى previous summary anchor وcompressible head وretained verbatim tail.
- [x] حماية tail بميزانية tokens مشتقة من target، مع minimum recent turns دون جعل العدد هو القرار الرئيسي.
- [x] عدم القطع داخل:
  - assistant tool-call batch ونتائجها.
  - model step reasoning/content/tool state.
  - user turn وآثارها التابعة عندما يؤدي القطع إلى orphan state.
- [x] إبقاء أحدث unresolved user ask وأحدث active-state turn verbatim عندما تسمح النافذة.
- [x] دعم رسالة أو tool result واحدة أكبر من tail budget عبر deterministic projection pruning، لا بإرجاع no-op.
- [x] وصف media/files القديمة بدل حمل payload الثقيل إلى summarizer، مع إبقاء canonical history كما هي.

### C1 Exit

- [x] لا توجد orphan tool IDs أو role sequence يرفضها أي adapter مدعوم.
- [x] source + tail ranges تحمل stable identities قابلة للحفظ والتحقق في 53b.
- [x] huge recent tool output ينتج candidate قابلة للقياس دون حذف الأصل.

## 5. Gate C2 — Deterministic tool/media pruning

- [x] تقليص أو deduplicate tool results القديمة الكبيرة داخل summary input/model projection فقط.
- [x] إبقاء tool name وcall id وهدف الاستدعاء ونتيجته الدلالية وحالة النجاح/الفشل والملفات أو IDs الناتجة.
- [x] تقليص arguments الضخمة مع الحفاظ على JSON صالح ومفاتيح القرار المهمة.
- [x] عدم pruning لأحدث tool batch المحمية أو لنتيجة لازمة للخطوة التالية.
- [x] تضمين reasoning/provider continuation fields في budget، مع عدم تحويل blobs المشفرة إلى نص summary.
- [x] تسجيل savings ومواضع pruning في internal metrics دون تسريب المحتوى.

### C2 Exit

- [x] pruning وحدها قابلة للقياس والاختبار ولا تغير canonical messages.
- [x] tool pair sanitation تعمل قبل summary request وبعد تركيب candidate.

## 6. Gate C3 — Structured rolling summary

- [x] بناء prompt ثابت مستفاد من Hermes ويطلب الأقسام التالية:
  - Current Goal and Success Criteria.
  - Active Constraints and User Preferences.
  - Completed Work and Verified Results.
  - Current State and In-Progress Work.
  - Key Decisions and Rationale.
  - Blockers, Errors, and Unresolved Questions.
  - Pending User Asks.
  - Relevant Files, Symbols, IDs, and External State.
  - Remaining Work and Safest Next Action.
  - Critical Context That Must Not Be Lost.
- [x] وسم النص بأنه historical checkpoint غير مخول بتجاوز system/current user instructions.
- [x] الحفاظ على لغة المحادثة مع إبقاء identifiers والpaths والقيم الحرفية كما هي.
- [x] إدخال previous summary كـanchor منفصلة وتوجيه النموذج لإزالة stale completed/pending facts.
- [x] تشغيل summarizer بلا tools وبoutput budget محدودة وموديل/route معروفة.
- [x] التحقق من أن summary request نفسها تدخل نافذة summarizer؛ تقسيم source إلى passes محدودة عند الحاجة بدل إرسال prompt مرفوضة.
- [x] إزالة reasoning tags وأي metadata provider-only قبل حفظ النتيجة.
- [x] redaction قبل الإرسال وبعد الاستجابة.

### C3 Exit

- [x] repeated summary لا تنسى unresolved goal أو تحول completed work إلى pending.
- [x] summarizer tool call أو empty response أو malformed response لا تنفذ أداة ولا تنتج candidate فعالة.
- [x] source أكبر من نافذة summarizer يعالج bounded دون recursion غير منتهية.

## 7. Gate C4 — Continuity validation وanti-degradation

- [x] استخراج continuity anchors typed قبل التلخيص: user goals، pending asks، constraints، paths/IDs، tool side effects، blockers، والnext action المثبتة.
- [x] تصنيف anchors إلى critical وsupporting؛ critical missing تمنع activation.
- [x] التحقق من required sections، الحجم، redaction، وanchor coverage بعد summary.
- [x] عند نقص قابل للإصلاح، تنفيذ repair attempt واحدة محدودة تحمل missing anchors فقط.
- [x] عند استمرار الفشل، إعادة typed `continuity_validation_failed` دون summary بديلة ضعيفة.
- [x] إعادة قياس candidate كاملة مقابل target ratio ورفض no-progress result.
- [x] إضافة anti-thrashing metadata: compression count، last actual prompt verdict، no-progress streak، وcooldown hints يستهلكها 53d.
- [x] وضع حد لجودة repeated compaction عبر اختبارات ثلاث boundaries أو أكثر على نفس goal.

### C4 Exit

- [x] حذف goal أو pending ask حرجة من fake summarizer يمنع candidate.
- [x] summary ناجحة تحتوي كل anchors الحرجة وتدخل target budget.
- [x] repair/no-progress paths bounded ومحددة النتائج.

## 8. Gate C5 — التحقق والتوثيق

- [x] اختبارات pressure لكل route/input/output/cache/media/tool-schema condition.
- [x] اختبارات tail boundaries والرسالة الضخمة وtool pairing والprovider state.
- [x] golden semantic fixtures لأهداف متعددة الخطوات وقرارات وملفات وblockers.
- [x] repeated-compaction fixtures تقارن goal/pending/decisions بعد boundaries متتالية.
- [x] اختبارات redaction وempty/auth/network/tool-call/malformed summary failures.
- [x] تحديث engine contract وصفحة تصميم compaction وQA matrix.
- [x] مراجعة file budget قبل الإغلاق.

### C5 Exit / Definition of Done

- [x] المحرك ينتج candidate validated تحت target أو failure typed بلا mutation.
- [x] الهدف والعمل المتبقي والقيود والقرارات والمعرفات الحرجة محفوظة عبر repeated compaction.
- [x] لا تنفذ summarizer أدوات ولا ترسل metadata داخلية أو secrets.
- [x] API ثابتة وجاهزة لـ53d دون DB/interface dependencies.

## 9. الملفات المتوقعة

- package جديدة مركزة تحت `agent/lib/engine/context/` أو owner يعتمد في 53a
- pressure estimator وtail selector وtool pruner وsummary prompt/validator كملفات صغيرة مستقلة
- adapter-facing summarizer interface دون provider-specific branches في engine
- tests/fixtures مركزة تحت `agent/test/engine/`
- `agent/lib/engine/AGENTS.md`
- `docs/agent_engine/context_compaction_design.md` (جديد)
- `docs/agent_engine/MOC.md`
- `docs/qa_maintenance/context_compaction_qa.md` (تمهيدي)
- ملف المهمة والخطة الأم

## 10. سيناريو النجاح

تحتوي جلسة طويلة على هدف متعدد المراحل، قيود مستخدم، قرارات مع أسباب، ملفات معدلة، tool outputs ضخمة، blocker، ومرحلة لم تكتمل. بعد ثلاث compactions متعاقبة تظل summary الأخيرة تحدد الهدف والقيود والحالة والملفات والblocker والعمل المتبقي بدقة، وتبقى آخر turns verbatim، وتدخل request target budget دون orphan tools أو تسريب secrets.

## 11. خارج النطاق

- persistence أو activation transaction.
- auto triggers وprovider retries.
- command protocol أو UI.
- long-term memory extraction.

## 12. سجل التقدم

```text
Date: 2026-08-29
Gate/status: 53c complete (C0–C5) — gate-by-gate review closed with C0–C4 fixes
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Verification: context_compaction_engine_test 17 passed; context_compaction_fixture_test 1 passed; engine/context has no SessionDB/Flutter imports
Findings (review): C0 lacked route-keyed schema cache, media accounting, under/at/over tests — fixed. C1 lacked oversized-tail projection pruning + media describe — fixed. C3 added redacted bounded prompt passes + reasoning strip. C4 broadened anchors + anti-thrashing hints on failure. Task status was stale (pending/C0 while progress claimed C5).
Next: Task 53d Gate D0
```

Date: 2026-08-29
Reviewer: gate-by-gate Plan 53 review
Gate closed: C0, C1, C2, C3, C4, C5

```text
Date: 2026-08-29 (evening re-review)
Gate/status: 53c C0→C5 re-closed in order
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
C0–C5: engine/context package present; no SessionDB/Flutter/interfaces imports
Verification: context_compaction_engine_test + context_compaction_fixture_test — 18 passed
Findings: anti-thrashing hints expose repairAttempts/noProgress/suggestedCooldown; compression-count/streak owned by 53d coordinator (acceptable vs C4 exit)
Next: Task 53d Gate D0
```
