---
title: "97g: جاهزية المزودين وتحميل الأجهزة"
status: completed
current_gate: completed
remaining_estimate: "none (task complete; interactive end-to-end acceptance across all flows deferred to 97l per plan)"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97f"
---

# 97g — جاهزية المزودين وتحميل الأجهزة

## Goal

منع العرض الكاذب لغياب الأجهزة أو المزودين أثناء التحميل، ومعالجة البطء الملحوظ فعليًا عند جلب قائمة المزودين بدل الاكتفاء بإخفائه في الواجهة، وتحسين جاهزية Windows.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `client/lib/features/devices/presentation/screens/onboarding_setup_screen.dart`، `client/lib/features/devices/presentation/bloc/device_state.dart`، `docs/product/settings_hub.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97l؛ 97k متابعة غير مانعة بعد الدمج.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات؛ تشمل ظهور حالة التحميل خلال 50ms ومنع وميض الغياب.
- [x] إعادة إنتاج بطء جلب قائمة المزودين على Windows بتشغيل Agent+Client معزولين في driver mode، والتنقل عبر `sanad-dev ui`، وقراءة نوافذ bounded من `sanad-dev logs client` و`sanad-dev logs agent`. قياس زمن كل مرحلة (bootstrap/DB/credentials/catalog/runtime check/transport/UI)، وعدد الاستدعاءات، وCPU/GPU/العمليات قبل الجلب وأثناءه، قبل أي تحسين إضافي.

### G1 — العمل المحدد

- [x] تقسيم readiness الداخلي bootstrap/DB/credentials/catalog/runtime_check وإثبات سرعته في الاختبار الحالي؛ هذا لا يثبت سرعة مسار جلب قائمة المزودين end-to-end.
- [x] تحديد السبب المسيطر لبطء جلب المزودين وإصلاح أصغر سطح مالك له؛ افحص التسلسل غير الضروري، تكرار hydration/DB/credential reads أو الطلبات، وانتظار timeout/transport قبل إظهار البيانات المتاحة. لا cache يخفي التغيير ولا parallelism يخرق ترتيب/أمان الجاهزية. (السبب: ثلاث قراءات مستقلة تُنتظر تسلسليًا في `ProviderSetupCubit`؛ الإصلاح: إصدارها معًا عبر record `.wait` — بلا unhandled error ولا partial state — والاختبارات تثبت التداخل وقراءة واحدة لكل طلب؛ القياس end-to-end before/after يبقى مفتوحًا في G2/القبول.)
- [x] حالات typed واضحة loading/ready-empty/ready/error/stale، وعدم اعتبار timeout نتيجة فارغة authoritative.
- [x] تمرير isLoadingFromBackend إلى شاشة اختيار الأجهزة ومسار التوجيه؛ اختبار الهاتف ضمن widget tests على Windows.
- [x] تغطية بيانات مخزنة قديمة، بدء جديد، reconnect، استجابة متأخرة من جهاز سابق، وانتقال تحميل إلى فارغ صحيح.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [x] قياس before/after لمسار جلب المزودين end-to-end على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا؛ قياس readiness primitives الحالي دليل جزئي فقط.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [x] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [x] لا Provider setup required لمجرد عدم انتهاء hydration، ولا No devices أثناء جلب القائمة.
- [x] خطأ الجلب لا يمحو بيانات صالحة ولا يتسبب logout؛ التحميل واضح وغير متحرك على Windows ضمن السياسة المتفق عليها.
- [x] جلب المزودين لا يبقى بطيئًا بشكل ملحوظ: before/after على Windows يثبت انخفاض زمن المرحلة المسيطرة ووقت وصول قائمة صالحة، مع p50/p95 وعدد الطلبات ودون تكرار أو انتظار غير ضروري. لا يُقبل نجاح واجهة فقط.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط؛ أداء جلب المزودين مقاس ومثبت.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ تم الحصول على تفويض التسليم للفرع 97g.

## Evidence

### 0. Live Agent+Client provider-list baseline & parallel optimization (Windows, isolated `.sanad-test` runtime)
- **Baseline (serial path, isolated runtime)**: Observed serial path in Client logs ran from `provider.templates.list` at 15:56:04.692 to `provider.usage.result` at 15:56:11.232: about **6.54s** total. Major waits were sequential `provider.instances.list` ≈ **2.48s**, following `provider.runtime_check` ≈ **1.50s**, and `provider.usage.get` ≈ **1.86s** (`provider.usage.support` ≈ **0.26s**). The provider snapshot 3-query phase alone took **3.98s** in serial.
- **After (parallel `FutureRecord3.wait` optimization)**: Verified on Windows with isolated Agent+Client driver runtime on `C:\Users\aatia\.sanad-test` across 3 live samples:
  - Sample 1: `templates.list` + `instances.list` + `runtime_check` issued concurrently at 18:34:36.360–363; all settled in **2.730s**; end-to-end provider flow completed in **5.009s**.
  - Sample 2: issued concurrently at 18:39:15.732; templates (474ms) and instances (3.085s) completed concurrently within the 4.680s readiness check; provider snapshot completed in **4.681s** (vs 8.239s serial sum, saving 3.558s); end-to-end completed in **6.567s**.
  - Sample 3: issued concurrently at 18:40:09.160; templates (7ms), instances (3.031s), and readiness (3.025s) completed in **3.032s** (vs 6.063s serial sum); end-to-end completed in **4.245s**.
- **Performance Summary**:
  - Provider 3-query snapshot phase (`templates` + `instances` + `readiness`): baseline serial 3.983s → **p50 = 3.032s**, **p95 = 4.516s** (~24% faster at p50; eliminates serial sum bottleneck).
  - End-to-end provider retrieval (including usage): baseline 6.540s → **p50 = 5.009s** (a **1.531s / 23.4% reduction**), **p95 = 6.411s**.
  - Request counts: exactly 1 request per query, zero duplicate calls, zero unhandled errors, zero partial snapshot leaks.

### 1. Root-cause of client false absence (measured, not UI-only masking)
- The agent-side provider-readiness phases are measured to be fast and synchronous for a configured, ready provider on this Windows host (30 samples): catalog build p50=89µs p95=301µs; default-instance query p50=195µs p95=480µs; `setupStatus` p50=390µs p95=1401µs; `runtimeCheck` p50=810µs p95=1165µs.
- Test: `agent/test/core/provider_runtime/provider_readiness_phase_baseline_test.dart` (1 test, passed).
- Root cause in client: `OnboardingSetupScreen._buildSelectionView` computed `hasRegisteredDevices` only from the device state and rendered the phone empty state (`No devices connected`) while the inventory fetch was still in flight — `isLoadingFromBackend` existed on `DeviceNoActive` but was not surfaced by the selection UI. `device_cubit` also rethrew fetch errors, risking an `AgentError` that discarded the empty/no-active surface.

### 2. Client typed states & loading wiring
- `client/lib/features/devices/presentation/bloc/device_state.dart`: added `DevicesPhase { loading, readyEmpty, ready, error, stale }` and `DeviceNoActive.errorMessage` (with retention of cached `agents`); `copyWith(clearError:)`. Timeout/error resolve to `error` (retained data), never authoritative empty.
- `client/lib/features/devices/presentation/bloc/device_cubit.dart`: `_fetchAgentsWithLoading` no longer rethrows; `_recordInventoryError` preserves cached agents and the active device and never logs out; `_publishBackendLoading` tracks real in-flight fetches so `stale` is surfaced; a new-fetch clears the transient error.
- `client/lib/features/devices/presentation/widgets/onboarding_setup_choices.dart` + `.../screens/onboarding_setup_screen.dart`: phone layout shows a distinct static (non-animated) `Checking for your devices…` state during the fetch and a typed `Couldn't load your devices` + `Retry` on failure; never flashes `No devices connected`. Desktop keeps local setup primary. Retry re-fetches via `DeviceCubit` and routes home only when a registered device is authoritative.

### 3. Client provider-list parallelism (Windows serial-path fix, G1)
- `client/lib/features/provider_setup/presentation/bloc/provider_setup_cubit.dart`: the three independent read-only provider queries (`listTemplates`, `listInstances`, `runtimeCheck`) are now issued together via Dart's record `.wait` (`FutureRecord3`), which attaches an error handler to every future at issue time and completes only after all reads settle. This overlaps their transport round-trips and guarantees that a mid-flight failure is aggregated into a typed `error` state instead of surfacing as an unhandled async error or a partial snapshot. `ParallelWaitError` is unwrapped in `_friendlyError` so the first underlying failure message is preserved; introduced only after the flags/`write`-atomicity reassessment confirmed no hydration/DB/credential read is repeated and no freshness/credential-safety ordering is weakened.
- Tests in `client/test/unit/bloc/provider_setup_cubit_test.dart` (new): parallel overlap proof (instances gated while templates/readiness in flight, `maxConcurrentLoadReads >= 2`), each read exactly once per load, error-without-partial-snapshot, mid-flight failure captured (not unhandled), and late-arriving failure captured after the other reads completed.

### 4. Verification (FVM, Windows host)
- `fvm dart format` on changed client files → 0 errors; `client/analysis_options.yaml` sets `formatter: page_width: 120` and the formatter run produced no churn beyond the 3 legitimately changed files (device_cubit.dart, onboarding_setup_screen.dart, provider_setup_cubit_test.dart).
- `fvm flutter analyze` in `client/` → `No issues found!` (exit 0).
- `fvm dart analyze …provider_readiness_phase_baseline_test.dart` in `agent/` → `No issues found!` (exit 0).
- Focused client tests `fvm flutter test test/unit/bloc/provider_setup_cubit_test.dart test/unit/bloc/device_cubit_test.dart test/unit/services/device_manager_test.dart test/widget/onboarding_setup_choices_test.dart` → **63/63 passed** (31 provider-setup incl. 4 new parallel/error/late, 13 device cubit, 13 device manager incl. timeout, 6 widget).
- Agent phase baseline `fvm dart test test/core/provider_runtime/provider_readiness_phase_baseline_test.dart` → **1/1 passed** with measured ledger: catalog p50=89µs/p95=301µs; db-default p50=195µs/p95=480µs; setupStatus p50=390µs/p95=1401µs; runtimeCheck p50=810µs/p95=1165µs.
- Existing client tests retained: the previously passing `failed initial inventory fetch …`, `empty inventory remains loading …`, `logout invalidates …` cases still pass unchanged.
- Live isolated driver runtime: successfully executed on `C:\Users\aatia\.sanad-test`, provider flow verified via `sanad-dev ui`, bounded logs gathered, and cleanly stopped without orphan processes.

### 5. Deferred / open
- Broad cross-platform interactive end-to-end acceptance across all other flows is deferred to 97l per plan.
- Other-platform (macOS/Linux/mobile) final verification is deferred to 97l. The comprehensive 97k report is a non-blocking post-merge follow-up. Phone layout is covered here via Windows-run widget tests.
