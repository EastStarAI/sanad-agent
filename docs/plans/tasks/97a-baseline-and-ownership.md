---
title: "97a: خط الأساس وتوفيق الأعمال السابقة"
status: completed
current_gate: G2
remaining_estimate: "0% (Task 97a completed; available baselines and the recovery reproduction are recorded, budgets are frozen, and explicitly pending/blocked per-surface measurements remain mandatory in their downstream owners)"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "none"
---

# 97a — خط الأساس وتوفيق الأعمال السابقة

## Goal

تثبيت قياس Windows قابل للتكرار وملاك التغييرات قبل أي تحسين.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/qa_maintenance/windows_first_performance_qa.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

### Ownership Reconciliation & Boundaries
- **Task 96 المحذوفة:** وثيقة غير دقيقة وفرعها حُذفا لغياب التنفيذ الصالح؛ لا يُستعاد أي منهما.
- **97b (Sole Owner of Recovery & Tool Identity Repair):** يملك تنفيذ إصلاح حلقة الاستئناف. في 97a، تم إنشاء وتشغيل اختبار إعادة إنتاج حتمي منضبط في `agent/test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` أثبت بالدليل القاطع أن `ToolExecutionCoordinator.executeToolCalls` يفحص `containsKey(toolCall.id)` على مستوى `continuationMetadata` المشتركة دون مطابقة `model_step_id` أو اسم الأداة أو مدخلاتها أو رسالة المساعد، مما يعيد استخدام النتيجة المخزنة ويتجاوز التنفيذ عند تكرار المعرف، مسببًا الحلقة غير المنتهية.
- **97c:** استكمال التحقق من أمان وحالات حواف الكتابة الآمنة لملفات التشغيل على Windows والمنصات الأخرى.
- **97d:** موثوقية اختبارات أدوات التشغيل (`sanad-dev`) على Windows.
- **97e:** التحقق من استرداد المشغلات القديمة ودورة الحياة دون إغلاق عمليات غريبة.
- **97f:** استجابة حلقة أحداث الوكيل أثناء تنفيذ الأدوات البطيئة ومنع حجب الأوامر (ميزانية p50 < 50 ms، p95 < 200 ms).
- **97g:** جاهزية المزودين وفصل حالة التحميل عن الغياب/الخطأ في شاشة الأجهزة (عرض التحميل خلال 50 ms ومنع وميض الغياب).
- **97h:** ملكية الجلب ومنع تكرار الطلبات (`provider.usage.support` و`model.snapshot`) وضمان صفر طلبات إضافية عبر 20 دورة لتغيير الحجم أو إعادة التركيب.
- **97i:** كفاءة استدعاءات الجلسات (`get_sessions`) ومنع التكرار خلال نافذة 500ms، وتجربة حجم الصفحات (6/10 مقابل 9/15).
- **97j:** استبدال المؤشرات المتحركة بمؤشرات ثابتة على Windows (نقطة خضراء وشارات إنجليزية) لخفض حمل GPU المستمر إلى صفر (0%).
- **97k & 97l:** ميزانيات منع التراجع والقبول التفاعلي النهائي.

### Reconciled Merged Work
- **`a087238`:** استبدل نصوص PowerShell المساعدة بكتابة Win32 FFI مباشرة (`WindowsSecureRuntimeBackend`) مع عزل ACL للمالك فقط، وأضاف تعافي المشغلات القديمة في `runtime_doctor.dart`. وفّق الخطتين السابقتين `sanad-dev-windows-secure-runtime-file-performance.md` و`sanad-dev-stale-launcher-recovery.md`.
- **`c19bd57`:** خفض زمن بدء الجولات الطويلة عبر إدراج ذري لرسائل المستخدم في SQLite، وفحص البيانات الوصفية فقط عند القبول، وإعادة استخدام السجل الموثق برقم المراجعة دون إعادة تحليل متكررة. وفّق الخطة السابقة `agent-windows-intermittent-tool-and-history-latency.md`.

## Gates

### G0 — التحقق وخط الأساس
- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد
- [x] توثيق حذف المهمة 96 وفرعها لعدم الدقة وغياب أي تنفيذ صالح، وتحويل اللوج الخام إلى timeline محايد وreproduction لـ97b دون استعادة الملف أو افتراض تشخيصه؛ مراجعة التغييرات المدمجة a087238 وc19bd57 واختبارها دون cherry-pick أو تنفيذ مكرر.
- [x] تسجيل الجهاز وWindows وGPU/driver وFlutter/Dart المثبتين ووضع البناء وحجم البيانات والنقل؛ فصل debug-driver عن profile/release.
- [x] قياس 30 عينة منفصلة للـFVM والكتابة الآمنة، وتسجيل مدد المجموعات والاختبارات الأبطأ؛ تصنيف قياسات UI/الأداة غير المتاحة كـpending أو blocked وإلزام مالك كل سطح بقياس baseline قبل تعديل تنفيذه.
- [x] تثبيت p50/p95 المستهدفة وميزانية الطلبات والبيانات وCPU/GPU وزمن الاختبارات قبل التنفيذ؛ ميزانية الطلبات الناتجة عن resize/rebuild تساوي صفرًا، ولا تُعامل الميزانية المستهدفة كقياس baseline فعلي.

### G2 — التحقق والأدلة
- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [x] تسجيل before/current المتاح للأعمال المدمجة وفق `docs/qa_maintenance/windows_first_performance_qa.md`، وفصل زمن المجموعات القديمة والاختبار الجديد؛ تبقى after وقياسات الأسطح المؤجلة لدى 97b–97l ولا تُغلق مبكرًا.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [x] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [x] جدول baseline يصنف كل سيناريو بوضوح كقياس فعلي أو دليل تاريخي/مبلغ عنه أو pending/blocked، مع بيانات مجهولة وخالية من الأسرار.
- [x] تحديد تكلفة بدء FVM منفصلة وزمن المجموعة القديمة وأبطأ عشر حالات؛ لا بدء إصلاح دون baseline للسطح المعني.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

### Transition to Downstream Implementation Tasks (97b–97l)

The central ledger, available measurements, recovery reproduction fixture, and numeric acceptance budgets are established in 97a. Each downstream owner must still capture any row marked pending before changing that surface and must produce its matched after evidence:
1. **97b (Recovery Loop & Tool Identity):** Consumes `agent/test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` to implement model-step/turn scoped tool checkpoint validation.
2. **97c (Secure Runtime Verification):** Hardens Win32 FFI atomic runtime writes and validates edge cases and cross-platform POSIX behavior.
3. **97d (Windows Test Reliability):** Resolves test environment flakiness and establishes deterministic testing baselines.
4. **97e (Lifecycle & Stale Launcher Recovery):** Verifies orphan launcher detection and fail-closed state isolation.
5. **97f (Agent Event Loop Responsiveness):** Unblocks microtask processing during file/tool execution against the frozen budget (`p50 < 50 ms, p95 < 200 ms`).
6. **97g (Provider Readiness & Loading State):** Eliminates false absent flashes and meets the 50 ms distinct loading state budget.
7. **97h (Request Deduplication & Ownership):** Implements in-flight request coalescing to meet the 0 extra fetches on resize/remount budget.
8. **97i (Session Pagination Efficiency):** Coalesces rapid session calls and validates the 9/15 page size experiment.
9. **97j (Windows Static Activity Indicators):** Replaces spinning indicators with static chips and green dots to achieve 0% continuous GPU animation load.
10. **97k & 97l (Regression Budgets & Final Interactive Verification):** Compares before/after results and executes interactive E2E validation via `sanad-dev`.

## Evidence

### 1. Host and Platform Identity (Measured Facts)
- **OS:** Windows 11 Pro 64-bit (Build 26200)
- **CPU:** Intel(R) Core(TM) i9-9880H @ 2.30GHz (8C/16T)
- **GPU 1 (Discrete):** NVIDIA Quadro T1000 (Driver: 32.0.15.9595)
- **GPU 2 (Integrated):** Intel(R) UHD Graphics 630 (Driver: 31.0.101.2140)
- **Flutter:** 3.47.0 (stable channel)
- **Dart:** 3.13.0 (stable, windows_x64)
- **Isolated Home:** `%USERPROFILE%\.sanad-test` (verified stopped with 0 clients via single pre-run `sanad-dev status` probe)

### 2. Measured Baseline Metrics (30 Samples Each)
- **FVM Process Startup Overhead vs Direct Dart (30 samples each, measured via PowerShell Stopwatch loop):**
  - Direct Dart: Min 1004 ms, Median (p50) 1010 ms, Avg 1062.07 ms, p90 1029 ms, p95 1425 ms, Max 2079 ms. Direct Dart comparison invoked the Dart SDK binary cached under `%USERPROFILE%\fvm\versions\3.47.0\bin\dart.bat` solely as an isolated diagnostic comparison to measure Windows batch-wrapper overhead; it does not replace the global repository FVM law.
  - FVM Dart: Min 5023 ms, Median (p50) 5051 ms, Avg 5083.37 ms, p90 5065 ms, p95 5067 ms, Max 6052 ms.
  - **FVM Startup Overhead Delta (p50):** `+4041 ms` (isolates Windows batch-wrapper overhead for test command timeouts).
- **Secure Runtime File Atomic Write (Win32 FFI a087238, measured via sequential atomic write Stopwatch loop):**
  - Historical PowerShell baseline: `>12,000 ms`
  - Current Cold Write: `34.38 ms`
  - Current Warm Writes (30 samples): Min 3.82 ms, Median (p50) 4.63 ms, Avg 5.07 ms, p90 6.10 ms, p95 8.54 ms, Max 9.55 ms.
  - Target Budget: `<2,000 ms median`. Status: **Passed (99.9% reduction from historical PowerShell baseline; meets <2,000 ms budget with >1,990 ms headroom)**.

### 3. Deterministic Reproduction Fixture (Task 97b Prerequisite)
- **Test File:** `agent/test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart`
- **Command:** `fvm dart test test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart`
- **Result:** `00:00 +1: All tests passed!` (Exit code 0).
- **Finding:** Proved deterministically that `ToolExecutionCoordinator.executeToolCalls` consumes completed results from `continuationMetadata` using only `toolCall.id`, causing tool execution to be bypassed when a subsequent model step repeats an ID (for example `shell_execute_0`). This establishes the stale-reuse mechanism observed repeatedly in the user logs; the fixture does not claim to replay the entire ~15-iteration trace.

### 4. Pre-Existing Test Suite Durations & Ten Slowest Cases
- **Suite Durations:**
  - `scripts/sanad_dev`: 2,521 ms (2.52s) — 156 passed, 18 skipped.
  - `agent/test/evolution`: 58,703 ms (58.7s) — 255 passed.
  - `agent/test/engine`: 12,543 ms (12.54s).
  - Reproduction test: <1,000 ms (1 passed).
- **Top 10 Slowest Test Cases (Measured via `--reporter json`):**

| Rank | Test Case Name | Suite / File | Duration |
|---|---|---|---|
| 1 | `daemon-backed readiness precedes deferred terminal prune` | `agent/test/evolution` | 19,568 ms |
| 2 | `migration batches large session sets without exceeding SQLite variable limit` | `agent/test/evolution` | 12,425 ms |
| 3 | `FileMemoryStore replace and remove operate on substring matches` | `agent/test/evolution` | 7,550 ms |
| 4 | `concurrent writers on separate handles commit without lock failures` | `agent/test/evolution` | 4,839 ms |
| 5 | `FileMemoryStore overflow reports inventory and repeated failures terminate` | `agent/test/evolution` | 4,568 ms |
| 6 | `FileMemoryStore ambiguous match returns bounded content previews, not indices` | `agent/test/evolution` | 4,464 ms |
| 7 | `FileMemoryStore batch frees capacity and commits final state in one operation` | `agent/test/evolution` | 4,452 ms |
| 8 | `FileMemoryStore successful mutation and explicit reset clear failure budget` | `agent/test/evolution` | 4,332 ms |
| 9 | `FileMemoryStore explicit read returns live entries without an absolute path` | `agent/test/evolution` | 4,072 ms |
| 10 | `FileMemoryStore stale cooperating stores reload under lock before writing` | `agent/test/evolution` | 3,982 ms |

### 5. Ordered Verification Commands & Diagnostics (Measured Facts)
- **Code Format Check:** `fvm dart format --output=none --set-exit-if-changed test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` → `0 changed` (Exit code 0).
- **Agent Dart Static Analysis:** `fvm dart analyze` in `agent/` → `No issues found!` (Exit code 0).
- **Sanad-dev Dart Static Analysis:** `fvm dart analyze` in `scripts/sanad_dev` → `No issues found!` (Exit code 0).
- **Client Flutter Static Analysis:** `fvm flutter analyze` in `client/` → `No issues found! (ran in 7.5s)` (Exit code 0).
- **Focused Agent Reproduction Test:** `fvm dart test test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` → 1/1 passed in <1s (Exit code 0).
- **Focused Agent History Test:** `fvm dart test test/evolution/message_history_identity_test.dart` → 10/10 passed in 4s (Exit code 0).
- **Focused Secure Runtime File Test:** `fvm dart test test/infrastructure/sanad_dev_secure_runtime_file_test.dart` in `scripts/sanad_dev` → 6/6 passed in <1s (Exit code 0).
- **Fast Test Suite (Sanad Dev):** `fvm dart test` in `scripts/sanad_dev` → 156 passed, 18 skipped in 2.52s (Exit code 0).

### 6. Frozen Numeric Performance Budgets (Measured or Invariant-Justified)
- **P01 (UI Activity Ticker GPU Load):** `0%` continuous animation GPU load on Windows (static chips and green dot in 97j).
- **P02 (Extra Fetches across Resize/Rebuild):** Exactly `0` extra Agent fetches across 20 resize/rebuild cycles for unchanged logical resources.
- **P03 (Simultaneous Equivalent Requests):** Exactly `1` in-flight request per logical resource key (`100%` request deduplication).
- **P04/P05 (Request Coalescing & Pagination):** Exactly `1` fetch per workspace section/cursor; `0` redundant duplicate calls within 500ms debounce.
- **P06 (Event Loop Lag during Slow Tool Execution):** Event loop lag `p50 < 50 ms, p95 < 200 ms`; independent query completes before slow tool terminal result.
- **History Load Latency:** Idle history load `p50 < 10 ms, p95 < 25 ms`; Tool-active history load `p50 < 20 ms, p95 < 50 ms` (zero read lock contention).
- **P08 (Provider Readiness & UI Loading State):** Distinct loading state visible within `50 ms`; `0` false absent flashes; startup resolution `p50 < 500 ms, p95 < 1,500 ms`.
- **Page Size Adoption Policy:** Adopt `9/15` (+50%) only upon payload overhead `<15%` and scroll request frequency drop `>=30%`.
- **P10 (Secure Runtime File Atomic Write):** `<2,000 ms median` (Measured `4.63 ms` p50, passed with `>1,990 ms` headroom).
- **FVM Process Startup Overhead:** Isolated `+4041 ms` p50 delta for test runner timeouts on Windows.
