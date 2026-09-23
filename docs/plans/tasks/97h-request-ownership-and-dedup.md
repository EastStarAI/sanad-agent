---
title: "97h: ملكية الجلب ومنع استدعاءات إعادة البناء"
status: review
current_gate: G2
remaining_estimate: "G0/G1 closed with implementation and proof; G2 verification complete on Windows via deterministic tests; full interactive acceptance remains in 97l"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97g"
---

# 97h — ملكية الجلب ومنع استدعاءات إعادة البناء

## Goal

تقليل استدعاءات العميل دون فقد أحداث أو تقادم غير معلن، وجعل إعادة البناء بلا آثار نقل.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `client/lib/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart`، `client/lib/features/conversations/presentation/widgets/conversation_input/conversation_bottom_actions.dart`، `client/lib/features/provider_setup/presentation/bloc/provider_usage_cubit.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي: مالكا الاستهلاك (composer `_ModelChip` و`ConversationBottomActions`) كانا يجلبان `model.snapshot` و`usage.support` من دورة حياة widget مستقلة؛ إعادة التركيب تعيد كل حارس محلي؛ `onInstancesLoaded` كان يعيد استعلام support في كل مرة بلا مشاركة طلب جارٍ.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات: P02 «صفر طلبات إضافية عبر 20 دورة resize/rebuild/remount» وP03 «طلب واحد لكل مورد منطقي device/query؛ 100% deduplication» (مجمّدة في `docs/qa_maintenance/windows_first_performance_qa.md`).

### G1 — العمل المحدد

- [x] تتبع startup/device/session/send/edit/provider-page/resize/theme/rebuild مع device/resource/query/revision وrequest count دون payload سري: الاختبارات الحتمية تعدّ request counts لكل أمر (`usage.get`, `usage.support`, `model.snapshot`) عبر fake client، لكل (device, query) بمفاتيح `deviceId|sortedIds` ومراجعات per-device.
- [x] إزالة جلب البيانات من build/builders وpost-frame الناتج عن rebuild ومن إعادة تركيب responsive widgets؛ lifecycle لا يجلب إلا عند تغير المورد المنطقي: حُذف الجلب المحلي من `_ModelChip` و`ConversationBottomActions`؛ lifecycle الآن يطلب من المالك (`ProviderUsageCubit`) فقط، والملكية في cubit تجعل إعادة الدخول لنفس المورد no-op.
- [x] توحيد جلب model.snapshot وusage.support لدى المالك الحالي ومشاركة الطلب الجاري حسب device/query؛ حماية remount وحدها محليًا غير كافية: `ProviderUsageCubit` يملك catalog أسماء المزودين (`ensureProviderDisplayNames`) وusage/support (`onInstancesLoaded` للمجموعة الكاملة، `ensureInstanceUsage` للمستهلك الفردي بدون pruning)، مع مشاركة in-flight لكل من (device, instance-set) و(device, instance) عبر نطاقات futures مشتركة.
- [x] اعتماد authoritative invalidation/reconnect/user refresh مع stale projection واضحة؛ دمج responses فقط إذا فشلت البدائل الأبسط وأثبت القياس فائدة مع فصل المسؤوليات: لم يُدمج أي response؛ اعتمد المشاركة (أبسط بديل) مع `refresh(force)` و`clearDevice`/`onInstanceRemoved` كمسارات إبطال صريحة، ومراجعات per-device تمنع تسرب استجابة قديمة بين الأجهزة.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير: `fvm dart format` نظيف؛ `fvm flutter analyze` خرج 0 (6 infos أسلوبية سابقة موجودة في أسطر محفوظة من HEAD)؛ الاختبارات الممتلكة للمسارات المتأثرة كلها خضراء (انظر Evidence).
- [x] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا: السيناريوهات P02/P03 أُثبتت باختبارات حتمية تعدّ الطلبات لا بالأرقام السردية؛ زمن الاختبارات في Evidence؛ قياس interactive النهائي يبقى في 97l.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود: حُدّث هذا الملف و`docs/qa_maintenance/windows_first_performance_qa.md`؛ لا تغيير بقانون دائم في AGENTS.md؛ Graphify حُدّث بعد تعديل الكود.
- [x] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [x] بعد تحميل نفس المورد، 20 دورة resize عبر compact/wide مع theme/rebuild/remount لا تنتج أي استدعاء Agent إضافي: أُثبت في `conversation_input_panel_rebuild_test.dart` («20 resize/theme/rebuild/remount cycles add zero Agent requests after initial load») عبر `_CountingProviderClient` (modelSnapshot/usageSupport/usageGet تبقى عند عدادها الأولي بعد 20 دورة كاملة).
- [x] مستهلكان لنفس الطلب الجاري يشتركان في طلب واحد؛ أجهزة أو queries مختلفة لا تتداخل: أُثبت في `provider_usage_cubit_test.dart` («two consumers of the same in-flight usage load share one request» و«loads for different devices or queries run independently» و«catalog model.snapshot load is shared…») — مقدار واحد على الشبكة للمورد المكافئ، واستقلال تام بين الأجهزة، وسقوط كتالوج الجهاز عند switch.
- [x] حدث تحديث أو تغيير جهاز أو refresh مشروع يجلب/يحدّث مرة حسب العقد؛ جميع الأحداث الضرورية تظهر مرتبة: اختبارات freshness/refresh/clearDevice/removal السابقة كلها خضراء؛ fetch قسري واحد فقط لكل `refresh`، ومراجعة per-device تُسقط الاستجابات المتأخرة من نطاق قديم.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة (انظر Evidence).
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح: لا تحسين نسبي يُدعى خارج السيناريوهات المعتمدة؛ القياس التفاعلي الحي وCPU/GPU يبقى في 97j/97l؛ لا تأجيل لفقد أحداث أو فساد استرداد.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ إذن هذا العمل يقتصر على فرع 97h في worktree المعزول ولا يمس aggregation أو runtime switch أو PR/merge.

## Evidence

Implemented and verified on the 97h worktree (Windows host, FVM Flutter 3.47 / Dart 3.13):

- **Change**: fetch ownership for provider display names + usage/support moved from widget lifecycle into `ProviderUsageCubit`; in-flight sharing by (device, query) and (device, instance); per-device revisions; composer consumers delegate via `ensureProviderDisplayNames` + `ensureInstanceUsage`.
- **Analyzer**: `fvm flutter analyze` exit 0 (only 6 pre-existing `curly_braces` infos in untouched preserved composer lines).
- **Format**: `fvm dart format` clean.
- **Focused tests (all passed, 0 failures)**:
  - `client/test/features/provider_setup/bloc/provider_usage_cubit_test.dart` — 16 tests (incl. new share-one-request per in-flight consumer; independent devices/queries; catalog shared/20 re-entries no re-fetch).
  - `client/test/widget/conversation_input_panel_rebuild_test.dart` — 42 tests (incl. 20 resize/theme/rebuild/remount cycles with zero extra Agent requests; model-chip lookup ownership now through the cubit).
  - `client/test/widget/conversation_input_composer_toggle_test.dart` — composer regressions green.
  - `client/test/features/provider_setup` (widgets/section/flow), `client/test/widget/provider_setup_flow_test.dart`, `client/test/unit/bloc/provider_setup_cubit_test.dart`, `client/test/unit/bloc/provider_runtime_cubit_test.dart`, `client/test/unit/utils/provider_route_label_test.dart` — provider surfaces green.
- **Timing note**: test wall-clock on this Windows host is dominated by FVM wrapper startup (~5s); the suites themselves complete in single-digit seconds. No new sleeps or broad timeouts were introduced.
- **Skipped**: final interactive acceptance (resize on real window, logs) remains in 97l per plan; GPU/CPU static-indicator budget remains owned by 97j.