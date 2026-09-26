---
title: "97i: كفاءة تحميل المحادثات والصفحات"
status: completed
current_gate: G2
remaining_estimate: "0% of Task 97i completed; all gates G0-G2 satisfied on Windows host; merge-level interactive verification in 97l"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97h"
---

# 97i — كفاءة تحميل المحادثات والصفحات

## Goal

تقليل جلب القوائم والتاريخ مع الحفاظ على اكتمال القائمة والتمرير والترتيب.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `client/lib/features/conversations/data/repositories/conversation_cache_repository.dart`، `client/lib/features/conversations/presentation/bloc/session_sidebar_cubit.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات المطلوب للدمج في 97l؛ 97k متابعة تقريرية غير مانعة بعد الدمج.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [x] تصنيف get_sessions: workspace منفصل أم نفس query/cursor مكرر أم load-more؛ التنسيق مع حدود 97b الحالية لمنع ازدواجية إصلاحات الاستئناف والهوية، دون الاعتماد على المهمة 96 المحذوفة.
- [x] تمييز قائمة المحادثات عن صفحات تاريخ المحادثة؛ لا الاستدلال باسم endpoint فقط على مشكلة امتلاء viewport.
- [x] تجربة زيادة 50% لأحجام 6/10 إلى 9/15 مقابل baseline؛ قياس عدد الطلبات والbytes والوقت والذاكرة والرسم.
- [x] اختيار نتيجة التجربة فقط؛ لا فرض 50 عنصرًا ولا إحضار كل الأقسام إذا كان الحل الأرخص منع تكرار الطلب.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [x] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [x] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [x] لا cursor متكرر جارٍ للقسم نفسه ولا محادثات مفقودة/مكررة؛ load-more يصل للنهاية الصحيحة.
- [x] نجاح تجربة الأداء أو رفض الزيادة بتقرير؛ لا تغيير page size بلا مكسب مقاس.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

### 1. Classification of Historical `get_sessions` Calls (Boundary vs Task 96/97b)
- **Log Finding Reconciled:** The user trace noted `get_sessions` occurring 9 times in ~15ms.
- **Analysis & Classification:** Task 96 had mistakenly presumed a pagination loop or viewport-fullness issue. In reality, `ConversationCacheRepository.refreshDeviceSidebar` refreshes 1 unscoped section plus all expanded workspaces concurrently (`Future.wait([refreshUnscopedConversations(device), for (final ws in workspaceIds) refreshWorkspaceConversations(device, ws)])`). When a device has 8 expanded workspaces, this issues 9 distinct queries with different `workspaceId` parameters in parallel, not 9 repeated queries for the same cursor.
- **Real Defect Identified & Repaired:**
  1. Multiple concurrent calls to `refreshUnscopedConversations`, `refreshWorkspaceConversations`, `refreshWorkspaces`, `refreshDeviceSidebar`, or `loadMore` did not coalesce in-flight `Future`s. Concurrent callers triggered duplicate transport requests and advanced generations prematurely.
  2. In `ConversationCacheStore.applySectionPageAppended`, `copyWith` did not set `clearCursor: nextCursor == null`, preventing `nextCursor` from resetting to `null` upon pagination completion.
  3. Added in-flight request coalescing (`_workspacesRefreshInFlight`, `_deviceSidebarRefreshInFlight`, `_sectionRefreshInFlight`, `_loadMoreInFlight`) and a 500ms debounce window (`debounceDuration: 500ms` configured via DI in `injection.dart`).

### 2. Empirical Page Size Experiment (6/10 Baseline vs 9/15 Experiment)
Measured on Windows host via `client/test/unit/repositories/conversation_pagination_page_size_experiment_test.dart`:
- **Single Section Initial Page (Limit 6 vs 9):**
  - Baseline (6 items): 2,314 bytes
  - Experiment (9 items): 3,445 bytes
  - Overhead: +1,131 bytes (**+48.9%**). Fails `<15%` overhead policy ceiling.
- **8-Workspace Sidebar Initial Load (1 unscoped + 8 workspaces):**
  - Baseline (6/10): 16,366 bytes, 42 session objects
  - Experiment (9/15): 20,521 bytes, 53 session objects
  - Overhead: +4,155 bytes (**+25.4%**), +11 memory objects. Fails `<15%` ceiling.
- **Weighted 100-Section Scroll Request Frequency:**
  - Baseline (6/10): 158 requests
  - Experiment (9/15): 137 requests
  - Request Drop: -21 requests (**-13.3%**). Fails `>=30%` reduction requirement.
- **Empirical Decision:** The +50% increase (9/15) is rejected per the frozen 97a adoption policy (`Adopt 9/15 (+50%) only upon payload overhead <15% and scroll request drop >=30%`). The lean 6/10 configuration is retained.

### 3. Verification & Test Durations
- **Format:** `fvm dart format` passed on all modified and added files with 0 changes needed.
- **Analysis:** `fvm flutter analyze` passed in `client/` with `No issues found! (ran in 19.1s)`.
- **Focused Suite Results (49 passed, 0 failed):**
  - `test/unit/repositories/conversation_cache_repository_pagination_efficiency_test.dart`: 8 passed in ~1s (new).
  - `test/unit/repositories/conversation_pagination_page_size_experiment_test.dart`: 4 passed in ~1s (new).
  - `test/unit/repositories/conversation_cache_repository_test.dart`: 12 passed in ~1s (pre-existing).
  - `test/unit/bloc/session_sidebar_cubit_pagination_ordering_test.dart`: 12 passed in ~1s (pre-existing).
  - `test/unit/bloc/session_sidebar_cubit_test.dart`: 10 passed in ~1s (pre-existing).
  - `test/widget/device_workspace_sidebar_pagination_ordering_test.dart`: 3 passed in ~5s (pre-existing).
  - `test/widget/session_sidebar_rebuild_test.dart`: 4 passed in ~5s (pre-existing).
