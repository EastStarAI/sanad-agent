---
title: "97e: الملكية والاسترداد ودورة الحياة"
status: completed
current_gate: G2-closed
remaining_estimate: "Automated lifecycle matrix green on Windows; only the full interactive Agent+Client cycle remains and is owned by 97l."
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97d"
---

# 97e — الملكية والاسترداد ودورة الحياة

## Goal

التحقق من stale recovery المدمج وعزل مشكلة Job Object دون إضعاف الاحتواء.

## Locked scope and ownership

- جميع negative cases ومعايير القبول غير المثبتة من stale-launcher المتقاعد مملوكة هنا. توفيق مراجعة الأمن والتسليم السابق بدل إنشاء PR مكرر؛ أي تغيير جديد يحتفظ بمتطلبات الحماية.

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/plans/done/sanad-dev-stale-launcher-recovery.md`، `docs/technical/sanad_dev_runtime_ownership.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

**دليل:** رُوجعت `scripts/sanad_dev/AGENTS.md`، `docs/technical/sanad_dev_runtime_ownership.md`، و`docs/plans/done/sanad-dev-stale-launcher-recovery.md`. تظهر مصفوفة G1 في الاختبارات القائمة جزئيًا (`sanad_dev_doctor_stop_test.dart`، `sanad_dev_ownership_test.dart`) مع 3 فجوات: دورة الحياة كاملة على host يحوي runtime حي، no-components عبر doctor كامل، وClient-only عبر `handleTargetOrphanCleanup` بلا أي تغطية. أُعيد إنتاج الفشل حتميًا: اختبارا force-stop واختبار doctor-fix نفذا discovery حقيقيًّا على مستوى النظام (لا يوجد seam)، فأرجع `discoverClientInstances()` عميل المستخدم الحي (PID 18684، port 58085، Home `C:\Users\aatia\.sanad`) فصنّفه `unverifiable` ورفض قبل الوصول إلى منطق ownership المزروع. كما أن `_callerDirectory` يقرأ `SANAD_DEV_CALLER_DIR` البيئي (المُصدَّر هنا إلى `C:\Users\aatia\projects\sanad-agent`)، فقسم port للـ Agent بخلاف ما كتبته الاختبارات في `Directory.current`. هذان السببان أثبتا فرط اعتماد اختبارات دورة الحياة على host نظيف، وهو gap test-determinism مثبت.

### G1 — العمل المحدد

- [x] توفيق بوابات ملف stale recovery مع أدلة الدمج والاختبار الحي السابق.
- [x] اختبار no-components/Agent-only/Client-only/both وPID reuse وnonce mismatch وforeign Home/source وخروج جزئي ورفض daemon.
- [x] فصل agent-origin kill-on-close عن تشغيل الطرفية البشرية؛ لا breakaway عام ولا kill يدوي ولا cleanup ضمني داخل run.
- [x] إذا ثبت احتياج lifecycle handoff جديد، إنتاج قرار تصميم ومراجعة أمنية مستقلة قبل تنفيذه؛ تبقى بوابته معلقة بدل ادعاء الحل.

**دليل (المصفوفة):** أُصلحت فقط الفجوات المثبتة بلا breakaway عام أو kill غير مملوك أو إضعاف الحماية:

- **Seams حقن discovery متسقة** في `handleRuntimeStop` و`handleRuntimeDoctor` و`handleTargetOrphanCleanup` (`discoverAgents`/`discoverClients`)، مطابقة لنمط `processRunning`/`processIdentity`/`terminateProcess` الموجود. القيم الافتراضية تستدعي discovery الحقيقي نفسه، فسلوك الإنتاج محايد ولا تتغير ملكية/حدود الرفض. هذا يجعل اختبارات دورة الحياة حتمية حتى على host فيه runtime حي خارج نطاقها.
- **no-components:** test `doctor --fix removes a stale record when no live surface remains` و`doctor --fix preserves ... while any live surface remains` (`sanad_dev_recovery_matrix_test.dart`) + `canRemoveStaleLauncherRecord` الحالي.
- **Agent-only stale:** تغطية القبول/الرفض والنظام والترتيب موجودة وتعمل (`doctor` group في `sanad_dev_doctor_stop_test.dart`).
- **Client-only:** `target orphan Client-only cleanup` (نجاح نظيف + رفض عند بقاء Agent الهدف حي) أُضيفت في `sanad_dev_orphaned_runtime_stop_safety_test.dart`؛ لا يوجد لها أي تغطية سابقة.
- **both:** ثابت عبر `canRemoveStaleLauncherRecord` وblocker الـ`live Clients` و`validateManagedRuntimeRecord`.
- **PID reuse / nonce mismatch / foreign Home+source:** تغطية موجودة (`validateManagedRuntimeRecord`، blocker، recycled-PID force-stop) وتعمل.
- **partial exit:** `preserves the lease when the launcher returns during recovery (partial exit)` + `did not stop` أُضيفت.
- **رفض daemon:** `requestPermanentRestart: false` → `rejected`، والرفض بملكية متقاطعة يبقي الـlease (تم التحقق).

أُصلح 3 اختبارات مسبقة كانت تفشل على هذا host (السببان في G0) عبر seams + مساعد `resolveHandlerRuntime` الذي يحاكي معادلة `_callerDirectory` بدقّة. لا يوجد kill لعمليات حية: كل الاختبارات تكتب records في Homes مؤقتة وتستخدم PIDs مزيفة؛ runtime المستخدم الحي (18684, 22408, 24912) ظل حيًّا وغير متأثر قبل/بعد.

**قرار:** لا يحتاج تنفيذ stale recovery الجديد إلى lifecycle handoff أمني جديد؛ التصميم المدمج fail-closed وهويّته/نونسه/Home/source واضحة. لا توجد بوابة معلقة لأمان جديد هنا، ويبقى التفاعل الكامل في 97l.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [x] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [x] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

**دليل (Windows):**

- `fvm dart format` نظيف؛ `fvm dart analyze` في `scripts/sanad_dev/`: "No issues found!".
- focused: `sanad_dev_doctor_stop_test.dart` + `sanad_dev_orphaned_runtime_stop_safety_test.dart` + `sanad_dev_recovery_matrix_test.dart` كلها خضراء.
- full fast: `00:07 +191 ~18: All tests passed!` (wall 14.37s بالـreporter 7s). في السطر قبل الإصلاح كانت المثيلات lifecycle الثلاثة تفشل بسبب discovery الحي؛ الآن خضراء.
- تكلفة new tests (5 حالات): `sanad_dev_recovery_matrix_test.dart` = 7.17s wall (منها ~5s FVM bootstrap)، group الـcleanup = 7.2s wall. FVM startup المقاس هنا median ~5.02s (5 عينات: 5.01–5.06s)، متطابق مع baseline رقمي 97d (5,042ms). تغيير الإنتاج محايد (seams الافتراضية تستدعي discovery نفسه)، فلا تراجع في old-suite.
- لا يوجد تغيير في قوانين durability/ownership الدائمة (seams داخلية فقط)، فلم تتعدّل `docs/technical/sanad_dev_runtime_ownership.md` ولا `AGENTS.md`؛ تبقى العقود منطبقة كما هي.
- لا يوجد `graphify-out/graph.json` في هذا worktree، فلم يُبنَ رسم بياني جديد؛ يتوافق هذا مع سابقة G5 في `docs/plans/done/sanad-dev-stale-launcher-recovery.md` (يشغَّل `/graphify update .` فقط إذا وُجد رسم بياني). سيُحدَّث الرسم عند البناء في 97k.

## Acceptance criteria and success scenarios

- [x] لا signal أو حذف lease قبل ثبوت الملكية والخروج؛ الفشل يبقي الأدلة ويعود nonzero (مثبت عبر `recoverStaleAgentLease` وsequencing و`doctor --fix` preserve).
- [x] اختبارات دورة الحياة الآلية خضراء على Windows؛ دورة Agent+Client التفاعلية الكاملة محفوظة للبوابة الأخيرة (97l).

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

- التنفيذ والتسليم المستقل لهذه البوابة (seams + تغطية المصفوفة + إصلاح الفجوة المثبتة في determinism اختبارات دورة الحياة) على Windows بطول `scripts/sanad_dev` فقط.
- الاختبارات الفعلية: `sanad_dev_recovery_matrix_test.dart` (no-components)، group `target orphan Client-only cleanup` + السببية في `sanad_dev_doctor_stop_test.dart` / `sanad_dev_orphaned_runtime_stop_safety_test.dart`، مع `sanad_dev_caller_env.dart` (مساعد معادلة `_callerDirectory`).
- Runtime المستخدم الحي لم يُفصل ولم يُقتل (بقيت العمليات 18684/22408/24912 بعد التشغيل كما كانت قبله)؛ لا kill لعمليات غير مثبتة الملكية.
- لا جديد في Handoff الأمني؛ التفاعل الكامل (Agent+Client) مؤجل إلى 97l كما هو مقرر في خطة 97.