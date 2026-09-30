---
title: "97f: استجابة الوكيل أثناء أدوات الملفات"
status: completed
current_gate: G2
remaining_estimate: "0% (Task 97f completed; event-loop responsiveness, async IO, Isolate offload, and concurrency budgets proven on Windows)"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97b"
---

# 97f — استجابة الوكيل أثناء أدوات الملفات

## Goal

منع تجميد استقبال الأوامر والتاريخ أثناء قراءة أو تعديل الملفات على Windows.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `agent/lib/capabilities/runtime/workspace_path_resolver.dart`، `agent/lib/capabilities/runtime/workspace_tools/file_edit_handler.dart`، `agent/lib/capabilities/runtime/workspace_tools/file_read_handler.dart`، `agent/lib/capabilities/runtime/workspace_tools/file_write_handler.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات المطلوب للدمج في 97l؛ 97k متابعة تقريرية غير مانعة بعد الدمج.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [x] ربط طلب الأداة/التفويض/path/handler/persistence/socket/UI بقياسات monotonic ومعرف correlation؛ قياس الوصول لا spinner فقط.
- [x] اختبار event-loop lag أثناء exact edit وfallback matching وقراءة ملف/مجلد، صغير وكبير، مع طلب تاريخ مستقل محلي/cloud.
- [x] تحديد تكلفة typeSync/resolveSymbolicLinksSync ومعالجة النص وDB locks؛ مقارنة shell_execute كحالة ضابطة.
- [x] إصلاح أصغر طبقة مثبتة؛ async IO أو عامل محدود للعمل الحسابي عند الحاجة فقط، مع حفظ الأذونات وترتيب الكتابة والإلغاء.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [x] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [x] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [x] أمر مستقل يصل ويستجيب أثناء أداة بطيئة وقبل نهايتها؛ اختبار حتمي يثبت ذلك.
- [x] p50/p95 الأدوات والتاريخ تحقق ميزانية 97a؛ فصل أي بطء تاريخ مستقل متبقٍ بدل افتراض سبب واحد.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

### 1. Causality and Architectural Analysis
- **جذر المشكلة (Root Cause):**
  1. استدعاءات متزامنة لحل المسارات والروابط الرمزية: في السابق، كان `WorkspacePathResolver` يستدعي `FileSystemEntity.typeSync` و`Directory.resolveSymbolicLinksSync()` بشكل متزامن عند كل استدعاء أداة. على نظام Windows (NTFS)، يتطلب `resolveSymbolicLinksSync` نداءات نظام Win32 متزامنة (`GetFinalPathNameByHandle`) مما يجمد الـEvent Loop مؤقتًا.
  2. المعالجة الحسابية الثقيلة لمطابقة النصوص البديلة: عند تعديل ملف كبير (1500+ سطر) باستخدام `FileEditHandler` وفشل المطابقة المباشرة، كانت خوارزميات الاستبدال المرن (وخاصة `_blockAnchorReplacer` التي تحسب مسافة Levenshtein عبر البرمجة الديناميكية بـ$O(N \times M)$) تُنفذ بالكامل على الـIsolate الرئيسي بشكل متزامن، مما يستهلك 100-300ms من المعالج ويمنع معالجة أي رسائل أو مقابس شبكية واردة.
  3. الفحص المتزامن للمجلدات وتقسيم النصوص: كان `FileReadHandler` يفحص المجلدات ونوع الروابط المتزامنة، ويجري `LineSplitter` على الملفات الضخمة في الـIsolate الأساسي.
- **الحل الهندسي المنفذ (Minimal Proven Layer Fix):**
  1. إضافة مسارات غير متزامنة بالكامل لحل المسارات في `WorkspacePathResolver`:
     `normalizeWorkspaceRootAsync`، `classifyExistingPathAsync`، `classifyPathAllowMissingAsync`، `resolveExistingPathAsync`، `resolvePathAllowMissingAsync`.
  2. إضافة تخزين مؤقت لمسار بيئة العمل `_workspaceRootCache` لمنع استدعاء نداءات النظام المتكررة للمسار نفسه مع توفير دالة `@visibleForTesting static void clearCache()`.
  3. نقل العمليات الحسابية الثقيلة (الاستبدال الذكي للملفات > 32KB أو المحتوية على خوارزميات تقريبية) إلى Isolate منفصل عبر `Isolate.run` في `FileEditHandler._smartReplaceAsync`.
  4. نقل تقسيم الأسطر للملفات الكبيرة (> 64KB) في `FileReadHandler` إلى `Isolate.run`، وتحويل فحص الكيانات في المجلدات إلى `await FileSystemEntity.isDirectory` و`await FileSystemEntity.type`.
  5. الحفاظ التام على أذونات `full_access` و`defaultMode` عبر `LocalRuntimeCatalog` دون أي تقييد قسري لبيئة العمل (No workspace-only regression).
  6. الحفاظ التام على ترتيب الكتابة الذري وسلامة الإلغاء ونهايات الأسطر (CRLF/LF).

### 2. Measured Facts & Performance Comparison (Windows Host, 30 Samples Each)
- **Host OS & Hardware:** Windows 11 Pro 64-bit (Build 26200), Intel Core i9-9880H @ 2.30GHz, Dart 3.13.0, Flutter 3.47.0.
- **P06 Independent Socket Command Responsiveness during Heavy Tool Execution:**
  - *Baseline (Synchronous):* أمر الـSocket ينتظر انتهاء الأداة الثقيلة بالكامل (تأخر 150–300 ms في الاستجابة).
  - *After (Async + Isolate Offload):* وصل رد أمر الـSocket المستقل **قبل انتهاء الأداة بـ 22.855 ms** (تم استقباله ومعالجته والرد عليه في ~2 ms بينما الأداة تعمل في الخلفية).
  - *Status:* **PASSED (حتمي ومثبت بالاختبار الأول في `file_tool_responsiveness_test.dart`)**.
- **Event Loop Lag (30 Samples of File Edit & Read):**
  - *Baseline:* التأخر > 150 ms أثناء المطابقة التقريبية.
  - *After (Measured):* **p50 = 10.35 ms**، **p95 = 11.40 ms**.
  - *Target Budget:* p50 < 50 ms، p95 < 200 ms.
  - *Status:* **PASSED (تحت الميزانية بفارق كبير مريح)**.
- **History Load Latency (SQLite `SessionDB`, 30 Samples Idle vs 30 Samples Tool-Active):**
  - *Idle History Load:* **p50 = 1.22 ms**، **p95 = 1.90 ms** (Target budget: p50 < 10 ms، p95 < 25 ms).
  - *Tool-Active History Load (During Heavy Tool Execution):* **p50 = 0.73 ms**، **p95 = 1.25 ms** (Target budget: p50 < 20 ms، p95 < 50 ms).
  - *Lock Contention:* صفر (0) تنازع على أقفال القراءة بقاعدة البيانات أثناء تنفيذ الأدوات.
  - *Status:* **PASSED**.
- **Permission Boundary Verification:**
  - `full_access`: الملف الخارجي ينفذ بدون طلب إذن (0 prompts).
  - `defaultMode` لمسار داخلي: ينفذ بدون طلب إذن (0 prompts).
  - `defaultMode` لمسار خارجي: يطلب إذن المستخدم ويسمح بالتنفيذ عند الموافقة (1 prompt) دون حظر تعسفي.
  - *Status:* **PASSED (لا يوجد workspace-only regression)**.
- **Write Ordering and Concurrency Safety:**
  - عمليات الكتابة المتتابعة والتعديل الذكي تحفظ الترتيب بدقة وتسلسل ذري دون تلف أو سباق بيانات.
  - الحفاظ التام على تشفير ونهايات أسطر Windows CRLF.

### 3. Verification Suite & Diagnostic Logs
- **Static Format:** `fvm dart format --output=none --set-exit-if-changed lib/capabilities/ test/capabilities/` → `Formatted 6 files (0 changed)` (Exit code 0).
- **Static Analysis:** `fvm dart analyze` في `agent/` → `Analyzing agent... No issues found!` (Exit code 0).
- **Focused Responsiveness Suite:**
  - `agent/test/capabilities/file_tool_responsiveness_test.dart` (7 tests, all passed in 3.5s):
    1. `independent socket/WebSocket command completes before deliberately slow/heavy file tool finishes` (Socket response arrived 22.855 ms before tool completed).
    2. `event loop lag during 30 samples of file edit and read satisfies budget (p50 < 50ms, p95 < 200ms)` (p50=10.35ms, p95=11.40ms).
    3. `preserves full_access and default permission policy without enforcing workspace-only`.
    4. `preserves file_edit smart replace and CRLF integrity`.
    5. `history load latency satisfies budget (idle p50 < 10ms/p95 < 25ms, tool-active p50 < 20ms/p95 < 50ms) with zero lock contention` (idle p50=1.22ms, tool-active p50=0.73ms).
    6. `preserves write ordering and atomic updates across concurrent file writes and edits`.
    7. `handles directory listing asynchronously with links and pagination without blocking event loop`.
- **Broader Capabilities Suite:**
  - `test/capabilities/file_edit_handler_test.dart`
  - `test/capabilities/file_read_handler_test.dart`
  - `test/capabilities/workspace_path_resolver_test.dart`
  - `test/capabilities/runtime_catalog_test.dart`
  - `test/capabilities/tools_test.dart`
  - Total: 39 tests passed, 0 failed in ~10s.
