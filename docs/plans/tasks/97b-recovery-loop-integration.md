---
title: "97b: حلقة الاستئناف وهوية نتائج الأدوات"
status: completed
current_gate: G2
remaining_estimate: "0% (Task 97b completed: model-step-scoped tool-result reuse implemented and verified with deterministic regressions on this Windows host)"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
---

# 97b — حلقة الاستئناف وهوية نتائج الأدوات

## Goal

إيقاف عدم التقدم بعد استئناف rate-limit دون إعادة تنفيذ آثار جانبية مكتملة.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `agent/lib/engine/runtime/tool_execution_coordinator.dart`، `agent/lib/engine/runtime/continuation_checkpoint_coordinator.dart`، `agent/lib/engine/agent_runner.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات المطلوب للدمج في 97l؛ 97k متابعة تقريرية غير مانعة بعد الدمج.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Root cause (confirmed deterministically in 97a, fixed here)

`ToolExecutionCoordinator.executeToolCalls` reused `completed_tool_results` keyed
only by the provider tool-call id. A genuinely new model step that repeated the
id (for example `shell_execute_0`) silently consumed the prior step's checkpoint
result and never executed — producing the observed non-progress loop.

## Repair (design/invariants)

- **Model-step ownership tag:** every persisted `completed_tool_outputs` record is
  tagged with the owning `model_step_id` (via `ContinuationCheckpointCoordinator.saveCheckpoint`).
- **Causal reuse gate:** a completed result is returned only when the causal
  model step, tool name, and structured arguments match. A new step that reuses a provider id
  therefore executes once. Legacy untagged durable records (pre-scoping) fall back
  to durable id-based reuse to preserve recovery semantics.
- **Purge on fresh execution:** when a tool id is genuinely (re)executed, its
  prior-step result/output is purged at the moment it is marked `currently_executing`,
  so a crash during that execution is never masked by an older step's completed outcome.
- Invariants preserved: crash/restart safety, HistoryHealer association,
  notice/retry deadline restoration, Stop behavior, side-effect non-replay,
  durability, event ordering, and security.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [x] امتلاك المشكلة مباشرة بعد حذف المهمة 96 غير الدقيقة: تحويل اللوج الخام إلى fixture منقح وإعادة إنتاج حتمية، ثم إثبات أو رفض فرضية أن نتائج checkpoint المتراكمة والمفهرسة بـ`toolCall.id` وحده تُعاد عبر model steps جديدة عند تكرار IDs.
- [x] اختبار معرف أداة مكرر عبر خطوتي نموذج وعبر جولتين وبـarguments مختلفة؛ التفريق بين استدعاء جديد وإعادة تشغيل checkpoint نفسه.
- [x] التحقق من التاريخ وHistoryHealer وربط النتيجة برسالة المساعد الصحيحة واستعادة notice/retry deadline؛ الاستجابة 200 ليست rate-limit مستمرًا.
- [x] محاكاة restart أثناء الانتظار وأثناء أداة ذات أثر جانبي وبعد حفظ النتيجة، والتحقق من Stop ومنع مضاعفة الاستدعاءات.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [x] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [x] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [x] كل استدعاء جديد ينفذ مرة، وcheckpoint المكتمل يعاد استخدامه لنفس الاستدعاء فقط.
- [x] لا دورة طلبات متكررة بلا تقدم في السيناريو؛ لا إخفاء الخلل بحد تعسفي يوقف عملًا مشروعًا.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence (Windows host: i9-9880H, Win 11 Build 26200, Flutter 3.47.0 / Dart 3.13.0)

### Implementation surface
- `agent/lib/engine/runtime/continuation_checkpoint_coordinator.dart`:
  `saveCheckpoint` tags each persisted tool-output record with the owning
  `model_step_id`; new `removeCompletedToolCallIds` support; new
  `completedToolOutputFor` and `isCompletedResultForCausalToolCall` helpers.
- `agent/lib/engine/runtime/tool_execution_coordinator.dart`: causal (model-step +
  tool-name + structured-arguments) reuse gate; legacy-untagged and no-model-step fallback to durable
  id-based reuse; purge of prior-step result/output before marking an id
  `currently_executing` in sequential and parallel execution.
- `agent/test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart`:
  converted from the 97a reproduction fixture into the 97b regression suite
  (5 deterministic tests) asserting the repaired behavior and recovery scenarios.

### Verification commands and results
- `fvm dart analyze lib/engine/runtime` → `No issues found!` (exit 0).
- `fvm dart test test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` → 5/5 passed (exit 0).
- Focused owning suites (combined) → agent_runner + history_healer + session_checkpoint_persistence + session_restart_checkpoint: 89 passed, 0 failed (exit 0).
- Focused owning suites (combined) → deferred_tool_result + runtime_state_repositories + persisted_runtime_state_repository + authoritative_session_state_repository + tool_terminal_record: 93 passed, 0 failed (exit 0).
- Single final Agent full suite after all G5 iteration: `fvm dart test` → 1811 passed, 26 skipped, 0 failed in 2m43s (exit 0).

### Timings (measured on this Windows host, FVM process startup overhead +~4.04s p50 from 97a)
- Pre-change reproduction/owning baseline (97a): reproduction fixture <1s; agent/test/engine suite 12.54s; FVM bootstrap delta +4041 ms.
- New-test file wall time: `fvm dart test test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` → total 6603 ms (≈5.0s FVM bootstrap + ≈1.6s 5 tests).
- Post-change focused old-suite wall time: `fvm dart test test/engine/agent_runner_test.dart` → total 9065 ms (incl. bootstrap). No unexplained old-suite regression detected in the focused owner files exercised.

### Residual risk
- Cross-step reuse of a **deferred** (`sanad_dev_switch`) descriptor is still gated
  only by requester session/tool-call id; this is the existing requester-bound
  contract and the switch operation is one-shot, so reused-ids for deferred tools
  are not observable in practice. Out of scope for 97b.
- A legacy long-lived checkpoint written before 97b whose records were never tagged
  is treated as durable id-based reuse; this preserves recovery but does not add
  per-step scoping to pre-fix durable state. New writes are always tagged.
- The final Agent full suite passed after G5 iteration. Merge-required interactive and cross-platform recovery acceptance remains owned by 97l; 97k is a non-blocking post-merge reporting follow-up.