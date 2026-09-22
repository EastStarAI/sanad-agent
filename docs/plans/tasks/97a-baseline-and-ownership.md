---
title: "97a: خط الأساس وتوفيق الأعمال السابقة"
status: in-progress
current_gate: G1
remaining_estimate: "Task 97a partially established: host facts, FVM overhead (30 samples), secure write (30 samples), and static budgets frozen; full baseline ledger and remaining gates pending downstream measurement tasks"
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
- **97b (Sole Owner of Recovery & Tool Identity):** يملك استقصاء حلقة الاستئناف وإثباتها حتميًا. فحص المصدر في `agent/lib/engine/runtime/tool_execution_coordinator.dart` (الأسطر 77–130) يُظهر أن `completedResults` تفحص `containsKey(toolCall.id)` على مستوى `continuationMetadata` المشتركة دون مطابقة `model_step_id` أو اسم الأداة أو مدخلاتها أو رسالة المساعد المالكة؛ هذه فرضية سببية قوية تفسر لماذا قد تتكرر رسائل "Resuming tool call ... from checkpoint" عند تكرار معرفات الأدوات، لكنها تتطلب إثباتًا أو نفيًا حتميًا في 97b عبر اختبار استرداد منضبط قبل أي تغيير في التنفيذ.
- **97c:** استكمال التحقق من أمان وحالات حواف الكتابة الآمنة لملفات التشغيل على Windows والمنصات الأخرى.
- **97d:** موثوقية اختبارات أدوات التشغيل (`sanad-dev`) على Windows.
- **97e:** التحقق من استرداد المشغلات القديمة ودورة الحياة دون إغلاق عمليات غريبة.
- **97f:** استجابة حلقة أحداث الوكيل أثناء تنفيذ الأدوات البطيئة ومنع حجب الأوامر.
- **97g:** جاهزية المزودين وفصل حالة التحميل عن الغياب/الخطأ في شاشة الأجهزة.
- **97h:** ملكية الجلب ومنع تكرار الطلبات (`provider.usage.support` و`model.snapshot`) وضمان صفر طلبات عند تغيير الحجم أو إعادة التركيب.
- **97i:** كفاءة استدعاءات الجلسات (`get_sessions`) وحجم الصفحات (تجربة 6/10 مقابل 9/15).
- **97j:** استبدال المؤشرات المتحركة بمؤشرات ثابتة على Windows (نقطة خضراء وشارات إنجليزية) لخفض حمل GPU المستمر إلى صفر.
- **97k & 97l:** ميزانيات منع التراجع والقبول التفاعلي النهائي.

### Reconciled Merged Work
- **`a087238`:** استبدل نصوص PowerShell المساعدة بكتابة Win32 FFI مباشرة (`WindowsSecureRuntimeBackend`) مع عزل ACL للمالك فقط، وأضاف تعافي المشغلات القديمة في `runtime_doctor.dart`. وفّق الخطتين السابقتين `sanad-dev-windows-secure-runtime-file-performance.md` و`sanad-dev-stale-launcher-recovery.md`.
- **`c19bd57`:** خفض زمن بدء الجولات الطويلة عبر إدراج ذري لرسائل المستخدم في SQLite، وفحص البيانات الوصفية فقط عند القبول، وإعادة استخدام السجل الموثق برقم المراجعة دون إعادة تحليل متكررة. وفّق الخطة السابقة `agent-windows-intermittent-tool-and-history-latency.md`.

## Gates

### G0 — التحقق وخط الأساس
- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد
- [x] توثيق حذف المهمة 96 وفرعها لعدم الدقة وغياب أي تنفيذ صالح، وتحويل اللوج الخام إلى timeline محايد وreproduction لـ97b دون استعادة الملف أو افتراض تشخيصه؛ مراجعة التغييرات المدمجة a087238 وc19bd57 واختبارها دون cherry-pick أو تنفيذ مكرر.
- [x] تسجيل الجهاز وWindows وGPU/driver وFlutter/Dart المثبتين ووضع البناء وحجم البيانات والنقل؛ فصل debug-driver عن profile/release.
- [ ] قياس 30 عينة لكل حالة زمنية باردة/دافئة منفصلة، وخمول ثم مؤشر واحد ثم عدة مؤشرات، مع أحجام محادثات ثابتة.
- [ ] تثبيت p50/p95 المستهدفة وميزانية الطلبات والبيانات وCPU/GPU وزمن الاختبارات قبل التنفيذ؛ ميزانية الطلبات الناتجة عن resize/rebuild تساوي صفرًا.

### G2 — التحقق والأدلة
- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] جدول baseline مكتمل لكل سيناريو في وثيقة QA، مع بيانات مجهولة وخالية من الأسرار.
- [ ] تحديد تكلفة بدء FVM منفصلة وزمن المجموعة القديمة وأبطأ عشر حالات؛ لا بدء إصلاح دون baseline للسطح المعني.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

### What remains to close 97a

1. **Deterministic Reproduction Fixture (97b):** Establish a runnable, repeatable test fixture reproducing the checkpoint/tool-call-id resumption loop before implementation.
2. **Missing Latency & Throughput Baselines:**
   - Active tool IO event-loop lag and history load latency (p50/p95) under active tool IO (owned by 97f).
   - Provider readiness latency and loading vs absent UI states (owned by 97g).
   - Request counts and bytes across 20 resize/remount cycles (owned by 97h).
   - Session pagination request efficiency and page size comparison (6/10 vs 9/15) (owned by 97i).
3. **Hardware GPU Counter Baseline:** Measure continuous animation GPU load via interactive desktop profile binary (blocked in autonomous headless CLI; static indicator budget frozen for 97j).
4. **Pre-Existing Test Suite Baseline:** Measure old-suite duration across full test suite and document the 10 slowest test cases.
5. **Ordered Verification & Format Gate:** Run formal formatting, full analyzers, and sequential test verification ordering across all affected surfaces.
6. **Full Ledger Completion:** Transition all pending/blocked rows in `docs/qa_maintenance/windows_first_performance_qa.md` to verified measurements and close gates G0, G1, and G2 with documented evidence.

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

### 3. Verification Commands & Diagnostics (Measured Facts)
- **Agent Dart Static Analysis:** `fvm dart analyze` in `agent/` → `No issues found!` (Exit code 0).
- **Client Flutter Static Analysis:** `fvm flutter analyze` in `client/` → `No issues found! (ran in 46.9s)` (Exit code 0).
- **Focused Agent History Test:** `fvm dart test test/evolution/message_history_identity_test.dart` → 10/10 passed in 3s (Exit code 0).
- **Focused Secure Runtime File Test:** `fvm dart test test/infrastructure/sanad_dev_secure_runtime_file_test.dart` in `scripts/sanad_dev` → 6/6 passed in <1s (Exit code 0).

### 4. Pending, Blocked, and Hypothesized Evidence
- **Source-Backed Hypothesis for 97b:** `ToolExecutionCoordinator.executeToolCalls` (`agent/lib/engine/runtime/tool_execution_coordinator.dart` lines 77–130) checking `containsKey(toolCall.id)` on shared continuation metadata without matching `model_step_id` or assistant message is a strong hypothesis for the resume loop. Deterministic proof is owned by 97b.
- **User-Reported Baseline & Blocked Autonomous Metric:** User report of +15–30% CPU and 0→100% GPU with continuous animated indicator; autonomous GPU hardware counter sampling in headless CLI is marked blocked; frozen budget for static indicators established for 97j.
- **Pending Downstream Baselines:** Active tool IO event-loop lag (pending 97f), history load under active tool IO (pending 97f), provider readiness (pending 97g), request counts and pagination (pending 97i).
