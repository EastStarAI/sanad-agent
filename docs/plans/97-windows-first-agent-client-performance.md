---
title: "Plan 97: Windows-first Agent and Client Performance"
status: ready-for-windows-execution
current_gate: 97a
remaining_estimate: "100% of new plan acceptance; existing implementations are not counted twice"
platforms: windows-first, macos-linux-mobile-final-verification
implementation_authorized: windows-handoff
commit_push_authorized: planning-delivery-only
---

# Plan 97 — تحسين أداء الوكيل والعميل: Windows أولًا

## 1. الهدف والحالة

إزالة التجمّد وحلقات عدم التقدم والاستدعاءات الزائدة وحمل الحركة المستمر، مع الحفاظ على واجهة حديثة وكل الأحداث الضرورية والأمان وصحة الاسترداد. الخطة مراجعة وجاهزة للتنفيذ على Windows ابتداءً من 97a، ثم تحقق المنصات المتأثرة في النهاية. إذن commit/push الحالي يخص تسليم الخطة والأرشفة فقط؛ تسليم تغييرات التنفيذ يحتاج إذنًا مستقلًا.

## 2. الأدلة وحدود اليقين

- بلاغ المستخدم المؤكد: ظهور مؤشر دوران أو حركة مستمرة على Windows يزيد CPU بنحو 15–30% ويقفز GPU من 0 إلى 100%، ويختفي الحمل فور اختفاء المؤشر. لم يلاحظ ذلك على macOS. هذه ملاحظة قبول معتمدة؛ لم يقس هذا الفرع تلك الأرقام بعد، ولم يوثق رابط Flutter upstream محدد. لا يتوقف الإصلاح على إيجاد ذلك الرابط.
- تصغير النافذة على macOS أعاد `provider.usage.support` و`model.snapshot` مرتين خلال نحو 162ms. إعادة البناء/responsive remount ليست سببًا مشروعًا لجلب نفس البيانات.
- تقرير Windows يربط بطء أدوات الملفات والتاريخ بعدم استقبال أوامر أثناء تنفيذ الأداة. يوجد IO متزامن في حل المسارات ومعالجة نصية متزامنة؛ السببية والجزء المسيطر يقاسان في 97f.
- سجل استئناف rate-limit يعرض استجابات 200 ثم إعادة استخدام checkpoint بلا تقدم. احتمال تصادم tool IDs له مالك مستقل في المهمة 96؛ لا نفترض أن rate-limit نفسه ما زال قائمًا.
- `get_sessions` تكرر تسع مرات خلال نحو 15ms؛ دون query/cursor لا يثبت أنه نفس الطلب. repository يجلب أقسام workspaces متعددة، بحجم أولي 6 ولاحق 10.
- شاشة الأجهزة لا تعكس loading في مسار الاختيارات رغم وجود حالة `isLoadingFromBackend`؛ المزودون لهم hydration وreadiness مستقلان يجب قياسهما.

## 3. القرارات المقفلة

1. العمل التطبيقي والقياس وإغلاق إصلاحات هذه الخطة على Windows؛ macOS/Linux والهاتف تحقق نهائي بعد نجاح Windows. المتطلبات الأمنية والـCI القديمة لا تلغى بل تؤجل إلى بوابة التحقق المناسبة.
2. إعادة بناء widget أو layout/theme/resize أو إعادة تركيب responsive subtree لا تطلب بيانات Agent. مالك المورد المنطقي يملك الجلب وإبطال البيانات والطلب الجاري، مستقلًا عن عمر widget.
3. UI تبقى authoritative وحديثة: لا إسقاط أحداث ولا debounce يضيع حالة نهائية ولا cache دائم يخفي التغيير. يسمح بتجميع/مشاركة الطلبات المتكافئة مع device/query/revision scope صحيح.
4. سياسة حركة مركزية واحدة تملك قرار السماح بالحركة المستمرة (مثل `allowContinuousActivityAnimation`). المنصة تُحسم في هذا المالك فقط؛ widgets ومؤشرات الأدوات والجلسات تستهلك القرار الدلالي ولا تفحص Windows أو أي OS بنفسها. Windows يبدأ بالسلوك الثابت: نقطة خضراء وحالات أدوات إنجليزية، دون اعتماد على اللون وحده. تفعيل نفس السلوك لأي منصة لاحقًا يغير السياسة فقط، بلا تعديل المستهلكين أو إضافة إعداد مستخدم غير مطلوب.
5. فصل loading عن empty/error/stale للأجهزة والمزودين؛ لا اعتبار غياب إجابة مبكرة غيابًا authoritative.
6. baseline قبل الكود وقبل إضافة اختبارات؛ after مطابق في الجهاز والبيانات ووضع البناء. نسب التحسن منفصلة لكل metric.
7. تحسين مرتفع التعقيد ضعيف المكسب يؤجل بقرار موثق. correctness/security fixes لا تسقط تحت هذا الشرط.
8. حجم الصفحة +50% تجربة مضبوطة (6→9 و10→15)، لا قرار مسبق ولا تغيير إلى 50 عنصرًا.
9. لا generic Job breakaway ولا قتل عمليات غير مثبتة الملكية ولا runtime switch. لا نسخ Home أو secrets لإعادة إنتاج المشكلة.
10. بعد كل بوابة: دليل ومعايير قبول وحالة ونسبة متبقي محدثة. لا يُحسب كتابة الكود إغلاقًا للبوابة.

## 4. إغلاق الخطط القديمة ونقل ملكية المتبقي

الخطط الأربع أدناه مغلقة إداريًا بحالة `superseded`، وليست مكتملة تقنيًا. نُقلت ملكية جميع البنود غير المنجزة إلى مهام 97 كما تبين جداول النقل داخل الملفات القديمة. الأدلة والإنجازات السابقة محفوظة؛ البنود المنقولة سجلات تاريخية لا قوائم تنفيذ موازية. نُقلت الملفات إلى `docs/plans/done/` مع تحديث المراجع؛ وجودها في done يعني إغلاقها بالاستبدال، لا إثبات اكتمال أعمالها التقنية. Task 96 ليست ضمن هذا الإغلاق وتبقى بملكية فرعها المستقل.

| المالك السابق | كيفية التعامل |
|---|---|
| `docs/plans/done/agent-windows-intermittent-tool-and-history-latency.md` | 97f و97g يملكان التنفيذ الجديد؛ تبقى الملاحظات السابقة أدلة، ولا مسار تنفيذ موازٍ. |
| `docs/plans/done/sanad-dev-windows-secure-runtime-file-performance.md` | الإصلاح الأساسي مدرج في a087238؛ 97c يوفق الأدلة ويستكمل الفجوات فقط. |
| `docs/plans/done/sanad-dev-stale-launcher-recovery.md` | مدرج في a087238؛ 97e لا يعيد التصميم المنفذ ولا يعتبر merge دليلًا على كل checkbox. |
| `docs/plans/done/sanad-dev-cross-platform-test-baseline-reliability.md` | 97d يملك Windows و97k/97l يستكملان بقية المنصات في النهاية. |
| Task 96، فرع `fix/96-tool-checkpoint-loop-and-recovery` | المرجع عند إتاحته: `docs/plans/tasks/96-tool-checkpoint-loop-and-recovery-fixes.md`. غير موجود في snapshot هذه الخطة؛ التنسيق والمقارنة شرط 97b و97i، لا استيراد تلقائي. |
| تحسين بدء الجولات c19bd57 | موجود في baseline الفرع؛ لا نسبة تحسن جديدة تنسبه لهذا العمل دون مقارنة تاريخية مستقلة. |

## 5. خريطة المهام

| المهمة | الاعتماديات | الحالة |
|---|---|---|
| [97a — خط الأساس وتوفيق الأعمال السابقة](docs/plans/tasks/97a-baseline-and-ownership.md) | none | planned |
| [97b — حلقة الاستئناف وهوية نتائج الأدوات](docs/plans/tasks/97b-recovery-loop-integration.md) | 97a | planned |
| [97c — استكمال التحقق من الكتابة الآمنة](docs/plans/tasks/97c-secure-runtime-verification.md) | 97a | planned |
| [97d — موثوقية اختبارات أدوات التشغيل](docs/plans/tasks/97d-windows-test-baseline.md) | 97a | planned |
| [97e — الملكية والاسترداد ودورة الحياة](docs/plans/tasks/97e-launcher-lifecycle-verification.md) | 97c, 97d | planned |
| [97f — استجابة الوكيل أثناء أدوات الملفات](docs/plans/tasks/97f-agent-responsiveness.md) | 97b, 97c | planned |
| [97g — جاهزية المزودين وتحميل الأجهزة](docs/plans/tasks/97g-readiness-and-loading.md) | 97f | planned |
| [97h — ملكية الجلب ومنع استدعاءات إعادة البناء](docs/plans/tasks/97h-request-ownership-and-dedup.md) | 97g | planned |
| [97i — كفاءة تحميل المحادثات والصفحات](docs/plans/tasks/97i-pagination-request-efficiency.md) | 97h | planned |
| [97j — مؤشرات نشاط ثابتة وخفض تكلفة رسم Windows](docs/plans/tasks/97j-windows-static-activity-ui.md) | 97h | planned |
| [97k — ميزانيات منع التراجع والتقرير المقارن](docs/plans/tasks/97k-regression-budgets-and-report.md) | 97e, 97f, 97g, 97h, 97i, 97j | planned |
| [97l — القبول التفاعلي النهائي عبر sanad-dev](docs/plans/tasks/97l-interactive-final-acceptance.md) | 97k | planned |

المسار الحرج يبدأ 97a ثم 97b. يمكن تنفيذ 97c/97d بالتوازي مع 97b بملكية منفصلة. 97h يسبق 97i/97j كي لا يختلط حمل الطلبات بحمل الرسم. 97k يجمع القبول الآلي والتقرير، و97l آخر بوابة تفاعلية. القياسات الحية التشخيصية المبكرة مسموحة؛ ليست قبولًا تفاعليًا نهائيًا.

## 6. التحقق والقياس

المصفوفة: `docs/qa_maintenance/windows_first_performance_qa.md`.
تُتبع مهارات Sanad Agentic Developer وSanad Client Tester للتنفيذ؛ لا تكرر الخطة أوامر تشغيلها. Static/format قبل tests، ثم focused ثم full fast وفق النطاق ثم integration لحدود النظام ثم التفاعل النهائي. اختبارات الهاتف المنطقية/widget تعمل على Windows؛ إثبات الجهاز الفعلي يأتي في النهاية.

## 7. بوابات قبول الخطة

- [x] المستخدم راجع النطاق وطلب تسليم الخطة لبدء Windows.
- [ ] تحديد واعتماد الميزانيات الرقمية من baseline في 97a قبل الإصلاحات.
- [ ] 97a مكتمل مع baseline وميزانيات واضحة وملاك الأعمال المتداخلة.
- [ ] الاستئناف يتقدم؛ الأداة البطيئة لا تجمد استقبال الأوامر؛ readiness/loading صحيحان.
- [ ] resize/rebuild/remount لنفس المورد يسبب صفر طلبات جلب إضافية، دون تعطيل تحديثات مشروعة.
- [ ] مؤشرات Windows الثابتة تزيل الحمل المستمر المستهدف وتحتفظ بكل حالات التنفيذ.
- [ ] اختبارات Windows ناجحة وتكلفتها مقاسة ومبررة؛ الفجوات الأمنية القديمة موفقة.
- [ ] التحقق النهائي لبقية المنصات المتأثرة مكتمل؛ غير المتاح blocked لا success.
- [ ] 97l مكتمل بأدلة UI وlogs وملكية التشغيل وتنظيفه؛ التقرير يحوي before/after ونسبًا مستقلة وتأجيلات معللة.
- [ ] إذن مستقل لتسليم تغييرات التنفيذ؛ الإذن الحالي لتسليم الخطة والأرشفة فقط.

## 8. التقرير النهائي والتأجيل

لكل metric: baseline/current/عدد العينات/p50/p95 أو مجال القياس/الفرق/نسبة التحسن/وضع البناء. للأزمنة والطلبات: `(before - after) / before × 100` عندما before أكبر من صفر. CPU/GPU يعرضان القيم المطلقة وفرق النقاط المئوية أيضًا؛ لا نسبة عند baseline صفر ولا مقارنة debug مع release. تكلفة الاختبارات: old-suite before/after + new-tests duration + FVM startup. كل تأجيل يسجل السبب والمكسب المتوقع والتعقيد والمخاطر والمالك وإشارة إعادة التقييم. لا تأجيل لفقد الأحداث أو فساد الاسترداد أو انتهاك الأمان.
