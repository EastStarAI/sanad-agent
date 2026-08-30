---
title: "Task 53d: Auto-Compaction Orchestration and Overflow Recovery"
description: "ربط المحرك والتخزين بالـrun lifecycle مع preflight داخل tool loop، overflow recovery محدودة، queue آمنة، وقفل لكل جلسة."
status: "complete"
current_gate: "done"
priority: "critical"
depends_on: "Tasks 53b and 53c"
coordinates_with: "Tasks 34, 40, and 50"
file_budget: 15
---

# Task 53d: Orchestration تلقائية واستعادة context overflow

## 1. الهدف

جعل compaction عملية authoritative داخل session runtime: تكتشف الضغط قبل provider call، تعمل بأمان داخل tool loop، تتعافى مرة واحدة من overflow المؤكد، وتمنع تداخل الرسائل أو checkpoints أو العمليات المتزامنة.

## 2. Gate D0 — lifecycle وoperation ownership

- [x] اعتماد state transition للجلسة `idle|running -> compacting -> terminal disposition` دون إنشاء source of truth منافس لـSessionRunOrchestrator.
- [x] تحديد compaction operation identity وsource revision والroute والtrigger قبل أي await.
- [x] ربط exclusive claim بـsession، مع stale/duplicate/idempotent outcomes.
- [x] تعريف الفرق بين:
  - manual idle compaction.
  - proactive auto compaction عند model boundary.
  - reactive overflow compaction قبل أي provider output.
- [x] تحديد cancellation/shutdown/restart behavior دون الاعتماد على volatile Future وحدها.
- [x] تحديد queue barrier: snapshot تجمد قبل الرسائل المقبولة أثناء compaction، والرسائل الجديدة تبقى durable queued work.

### D0 Exit

- [x] لا يمكن لrun وmanual compaction امتلاك mutation متعارضة.
- [x] auto compaction داخل run تحفظ نفس work item/run/generation authority حيث يلزم الاستكمال.
- [x] incoming admission لا تفقد الرسائل ولا تدخلها في summary الجارية.

## 3. Gate D1 — prospective preflight في كل model boundary

- [x] نقل ترتيب model call إلى pipeline تبني exact route وsystem/runtime context وtools وplugin-adjusted request material قبل pressure decision.
- [x] منع تنفيذ plugin hooks مرتين أو تراكم mutation منها عند إعادة بناء request بعد compaction.
- [x] تشغيل pressure evaluation قبل أول provider call للدور.
- [x] إعادة التقييم قبل كل provider call بعد tool results أو steer continuation.
- [x] استخدام latest confirmed provider input usage للتحقق بعد كل response دون جمع tool rounds.
- [x] بعد compaction ناجحة، إعادة تحميل projection من repository وإعادة بناء request كاملة ثم قياسها قبل الإرسال.
- [x] دعم bounded passes فقط عندما أثبت re-measurement تقدمًا وما زالت request فوق target.

### D1 Exit

- [x] tool result كبيرة لا تصل إلى provider قبل preflight التالية.
- [x] request تحت threshold لا تستدعي summarizer.
- [x] successful compaction لا تستخدم history list قديمة أو effective request سبقت activation.

## 4. Gate D2 — checkpoints وturn identity وsteering

- [x] استبدال أي اعتماد compaction على `_currentTurnStartIndex` بstable source identities/revision.
- [x] حفظ checkpoint قبل/بعد boundary بصورة تجعل resume يختار canonical projection الصحيحة.
- [x] عدم جعل compaction تغير model-step identity لprovider response لم تبدأ بعد دون تسجيل transition صريح.
- [x] ضمان أن pending steer قبل snapshot تعامل وفق owner الحالي، وأن steer تصل أثناء compaction لا تدمج داخل summary غير مقصودة.
- [x] إعادة بناء resume history من persistence لا من length محفوظة قبل compaction.
- [x] late checkpoint من projection قديمة لا يعطل boundary أو work item أحدث.

### D2 Exit

- [x] restart قبل/أثناء/بعد activation لا ينتج invalid checkpoint history length.
- [x] steering وtool continuation لا تضيع ولا تكرر عبر boundary.
- [x] side-effect tool results المكتملة تبقى في tail أو summary anchors ولا تعاد تنفيذها بسبب compaction.

## 5. Gate D3 — queue أثناء compaction

- [x] manual `/compact` لا تقبل إلا في idle؛ busy run تعيد typed `session_busy` بلا queue للأمر.
- [x] أثناء started compaction، user messages العادية تقبل عبر durable admission الحالية كqueued work مع request IDs الأصلية.
- [x] لا تبث user-message acceptance كأنها بدأت run قبل إزالة compaction barrier.
- [x] terminal successful activation يحرر barrier ثم يدفع أقدم queued work FIFO على projection الجديدة.
- [x] manual failure يحرر barrier ويصرف queue على original projection إذا كانت request قابلة للإرسال.
- [x] auto/overflow failure يحدد typed blocked أو safe-drain disposition بدل ترك queue معلقة.
- [x] رسالة Stop أو shutdown لا تحذف queued user text المقبول.

### D3 Exit

- [x] رسالتان تصلان أثناء compaction تنفذان مرة واحدة وبالترتيب فور terminal disposition.
- [x] duplicate acceptance/reconnect لا ينشئ queued work إضافية.
- [x] failure/restart لا يتركان session compacting أو queue stranded.

## 6. Gate D4 — provider overflow recovery

- [x] توسيع classifier لأنماط context overflow الموثقة دون خلط output-cap errors أو payload/media limits غير القابلة للضغط.
- [x] إخراج context overflow من fatal change-provider-only path إلى transition compaction typed.
- [x] إذا لم يبدأ reasoning/content/tool/provider-state event، تشغيل overflow compaction ثم retry واحدة فقط بعد successful re-measurement.
- [x] إذا بدأ أي durable/visible provider output، منع automatic replay والانتقال إلى recovery واضحة متوافقة مع Task 34.
- [x] إذا overflow حدثت داخل summarizer، تقليل/تقسيم summary input bounded أو إنهاء failure؛ لا recursive compaction loop.
- [x] تحديث context window من provider error فقط عند وجود limit صريحة موثوقة، دون تخمين تصغير النافذة.
- [x] منع network/rate-limit retry counters من مشاركة budget مع compaction recovery.

### D4 Exit

- [x] proactive miss واحدة تتعافى بضغط وrequest واحدة جديدة بلا duplicate output.
- [x] overflow ثانية أو no-progress تصبح terminal typed ولا تدور.
- [x] output-cap error لا يحذف history ولا يشغل compaction بلا داعٍ.

## 7. Gate D5 — anti-thrashing والمراقبة

- [x] حفظ/استعادة cooldown وno-progress streak وawaiting-real-usage state عند الحاجة.
- [x] عدم إعادة proactive compaction فورًا بعد boundary بناء على rough estimate وحدها قبل verdict حقيقية، إلا إذا request rebuilt ما زالت فوق hard limit.
- [x] breaker يوقف auto attempts المتكررة ويعرض recovery قابلة للتحكم دون تعطيل manual `/compact` لاحقًا.
- [x] logging lifecycle والقياسات فقط دون summary أو user/tool contents.
- [x] compaction في Session A لا تؤثر على route أو usage أو lock في Session B.

### D5 Exit

- [x] repeated no-progress لا ينتج loop أو provider flood.
- [x] manual force لاحقة تستطيع المحاولة بعد زوال سبب failure وفق policy المعتمدة.

## 8. Gate D6 — canonical lifecycle contract

- [x] تعريف command/outcome/event payloads التي سيستهلكها 53e:
  - command `compact`.
  - started/completed/failed lifecycle.
  - trigger manual/auto/overflow.
  - compaction/session/request identities.
  - safe metrics وtyped failure.
- [x] ضمان live delivery وhistory query يعيدان event identity نفسها.
- [x] عدم تضمين internal summary أو source transcript أو secrets في payload.
- [x] تعريف busy/in-progress/stale outcomes كresponses typed لا user messages.

### D6 Exit

- [x] Flutter لا تحتاج تفسير logs أو assistant messages لمعرفة lifecycle.
- [x] contract مستقرة ويمكن أن يبنى 53e دون تغيير engine policy.

## 9. Gate D7 — التحقق والتوثيق

- [x] اختبارات preflight الأولي وكل tool-loop boundary.
- [x] اختبارات queue FIFO وfailure/restart/duplicate admission أثناء compaction.
- [x] اختبارات checkpoint/steer/tool replay عبر activation.
- [x] اختبارات provider overflow قبل وبعد أول event، والretry الواحدة، والno-progress.
- [x] اختبارات concurrency بين manual/auto وجلستين.
- [x] تحديث engine/interfaces contracts ووثائق runtime/protocol/recovery/QA.
- [x] مراجعة file budget قبل الإغلاق.

### D7 Exit / Definition of Done

- [x] auto-compaction تعمل استباقيًا وداخل tool loop وتبني request من boundary محفوظة.
- [x] overflow recovery محدودة ولا تكرر visible output أو tool effect.
- [x] queued messages أثناء compaction لا تضيع وتبدأ FIFO بعد terminal outcome.
- [x] command/event contract جاهزة لـ53e.

## 10. الملفات المتوقعة

- `agent/lib/engine/agent_runner.dart`
- collaborators جديدة محدودة تحت `agent/lib/engine/runtime/`
- `agent/lib/interfaces/runtime/session_run_orchestrator.dart`
- `agent/lib/interfaces/runtime/session_turn_executor.dart`
- work admission/queue repository owners عند الحاجة
- `agent/lib/core/provider_runtime/runtime_failure_reason.dart`
- canonical protocol/bridge types
- اختبارات engine/interfaces/recovery مركزة
- `agent/lib/engine/AGENTS.md`
- `agent/lib/interfaces/AGENTS.md`
- `docs/technical/agent_runtime.md`
- `docs/technical/communication_protocols.md`
- `docs/qa_maintenance/context_compaction_qa.md`
- ملف المهمة والخطة الأم

## 11. سيناريو النجاح

تضيف أداة نتيجة كبيرة تجعل request التالية فوق threshold. قبل provider call يبدأ auto compaction ويعرض lifecycle started. تصل رسالتان جديدتان أثناء العملية فتحفظان queued. تنجح boundary وتستعاد projection من DB ويثبت أنها تحت target، ثم تستكمل run الحالية بأمان وتنفذ الرسالتان مرة واحدة FIFO. بعد restart تظهر lifecycle نفسها ولا يعاد أي tool effect.

## 12. خارج النطاق

- composer parsing أو timeline widgets.
- arguments لأمر `/compact`.
- تعديل long-term memory.
- partial-stream replay بعد بدء provider output.

## 13. سجل التقدم

```text
Date: 2026-08-29
Gate/status: 53d complete (D0–D7) — gate-by-gate review closed with D3 admission fix
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Verification: compaction_coordinator/overflow/preflight/checkpoint + queue + handle_compact + runtime_failure_reason focused suites passed (69 in combined run)
Findings (review): D3 bug — in-memory compacting barrier returned session_busy instead of compaction_in_progress; fixed and test updated. D6 protocol section added to docs/technical/context_compaction.md §9. Overflow recovery intercepts contextOverflow before fatal disposition when stream has not started.
Next: Task 53e Gate E0
```

Date: 2026-08-29
Reviewer: gate-by-gate Plan 53 review
Gate closed: D0–D7

```text
Date: 2026-08-29 (evening re-review)
Gate/status: 53d D0→D7 re-closed in order
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Verification: compaction_coordinator/overflow/preflight/checkpoint + queue + handle_compact + runtime_failure_reason — 69 passed (correct path: test/interfaces/runtime/handle_compact_command_test.dart)
Fix: D6 docs in context_compaction.md used underscore event names; aligned to wire `context_compaction.started|completed|failed` matching canonical_events + Flutter mapper
Findings: D3 admission order correct (busy vs compacting); queue during compacting via isSessionCompacting; overflow recovery gated on !streamStarted + one retry
Next: Task 53e Gate E0
```

