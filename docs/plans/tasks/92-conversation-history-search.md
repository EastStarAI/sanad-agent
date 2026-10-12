---
title: "المهمة 92 — البحث في سجل المحادثات"
status: complete
current_gate: complete
remaining_estimate: 0%
reference_grounding:
  evidence_id: "92"
  packet_fingerprint: "sha256:bdd9f53324ce8fb2f5d510afc92d0a7557fda858921f9c808b4aa8b5a46eb683"
---

# المهمة 92 — البحث في سجل المحادثات

## Goal

تمكين المستخدم من إيجاد محادثة قديمة من سجل الجهاز المحدد عبر عنوانها أو نص رسائلها المرئي، ثم فتحها من نتيجة واحدة واضحة لكل محادثة، دون الاعتماد على الصفحات الجزئية المحمّلة في الـClient أو كشف بيانات داخلية.

## Current Status

- **Current gate:** مكتملة.
- **Closed gates:** G0–G5، بما فيها تصحيح الحفاظ على عنوان نتيجة البحث خارج صفحات sidebar المحمّلة.
- **Remaining estimate:** 0%.
- **G5 evidence:** analyzers واختبارات Agent/Client المركزة ناجحة؛ live driver أثبت ظهور نتيجة `سأبحث` من thought، فتح نتيجة خارج صفحات sidebar الجزئية بلا `Loading...` قابل للرصد، وإعادة فتح نفس الجلسة عند anchor بعد تحريك timeline؛ اختبار route resolver يثبت الحفاظ على العنوان/الـworkspace مع إبقاء placeholder للرابط المباشر غير المعروف؛ Graphify محدث.
- **G2 evidence:** `session_search_test.dart` (6 حالات) واختبار bridge مركز؛ `fvm dart analyze` بلا أخطاء.
- **G3 evidence:** `session_search_cubit_test.dart` (3 حالات تشمل stale/clear/pagination/retry)؛ `fvm flutter analyze` بلا أخطاء.
- **Evidence:** الحزمة المحلية ذات المعرّف `92` والبصمة المثبتة في frontmatter؛ تفاصيل المصادر الخارجية محفوظة خارج الملفات المتتبعة.

## Locked Decisions and Scope

### مثبت من العقود والدراسة

- الـAgent هو المالك المرجعي للبحث في السجل الدائم؛ لا يجوز للـClient اعتبار فلترة المحادثات المحمّلة حاليًا بحثًا كاملًا.
- نتائج البحث منفصلة عن صفحات الـsidebar العادية ولا تغيّر cursors أو توسعة Workspaces أو snapshot الخاص بها.
- كل طلب وصفحة تالية مرتبطان بنص البحث المطبع وبجيل request محدد؛ الاستجابات القديمة لا تستبدل نتائج أحدث ولا تُلحق بها.
- النتائج والـsnippets محدودة الحجم، ولا تحتوي reasoning أو system/compaction rows أو tool arguments/results أو provider state أو attachment payloads أو رسائل superseded.
- واجهة المستخدم وكل النصوص الظاهرة تظل بالإنجليزية فقط.
- لا Semantic/RAG search ولا خدمة فهرسة خارجية في الإصدار الأول.

### النطاق المعتمد في G1

1. البحث داخل **الجهاز المحدد حاليًا فقط**.
2. المطابقة في **عنوان المحادثة + كل النص المرئي لرسائل المستخدم والمساعد**، بما فيه `thought` المرئي والإجابة النهائية، مع استبعاد reasoning/tools/system/private/superseded.
3. **نتيجة واحدة لكل محادثة** تشمل العنوان، Workspace إن وجد، وقت آخر نشاط، نوع المطابقة، وsnippet واحدة محدودة.
4. اختيار النتيجة يفتح المحادثة عبر مسار التنقل الحالي و**يقفز إلى الرسالة المطابقة** باستخدام anchored-history event id الحالية، لا pixel offset ولا تحميل transcript كامل.
5. بحث نصي deterministic يدعم العربية والإنجليزية، مع trim ودمج whitespace وخفض ASCII case فقط؛ تبقى code points غير ASCII وعلامات التشكيل كما هي في الإصدار الأول.
6. مدخل البحث زر/حقل في الـsidebar يفتح لوحة نتائج responsive على wide وcompact layouts.

### خارج النطاق الأولي

- البحث المتزامن عبر كل الأجهزة أو fan-out بين Agents.
- البحث الدلالي أو سؤال النموذج عن المحادثات السابقة.
- فلاتر متقدمة، حفظ استعلامات البحث، أو البحث داخل المرفقات.
- إضافة Archive كميزة جديدة.

## Architecture Direction

### Agent

- يوسّع عقد session query أو يضيف query واضحًا مملوكًا لـ`SessionManager`/`SessionDB` لاستقبال نص مطبع وlimit وcursor محدودين.
- ينفذ المطابقة على `sessions.title` والرسائل النشطة المسموح بعرضها فقط، ويعيد DTO مخصصًا للبحث بدل تحميل transcript كامل.
- يرتب النتائج ترتيبًا حتميًا ويضع query/scope fingerprint داخل cursor لمنع إعادة استخدامه مع استعلام آخر.
- يحافظ على نفس عقد `get_sessions` المحلي/السحابي أو يضيف أمرًا canonical واحدًا إذا كان فصل DTO أكثر أمانًا؛ يحسم ذلك قبل G2 بعد مراجعة blast radius.

### Client

- يمر عبر المسار المعماري الحالي: UI → Cubit → Repository → managed conversation client → transport.
- يملك Cubit حالة إدخال/عرض مؤقتة فقط: idle, loading, ready, empty, stale-transition, failure, loading-more.
- يستخدم debounce محدودًا وgeneration token، ويمنع load-more أثناء عرض نتائج قديمة أو عند تغيّر query.
- يعرض مدخل البحث داخل سطح المحادثات على wide وcompact layouts، مع clear/Escape، تنقل لوحة المفاتيح، وIME-safe Enter.
- يسجل anchor النتيجة كوجهة العرض المقصودة للجلسة ثم يفتحها باستخدام هوية الجهاز والجلسة الحالية؛ `BrainActivityView` و`SessionMessagesCubit` يعيدان استخدام anchored-history pagination القائمة، من دون cache authority موازية أو scroll offset مصطنع.

## Gates

### G0 — Discovery and Reference Grounding

- [x] إنشاء Worktree معزولة وفرع `feature/92-conversation-search`.
- [x] تشغيل Resolver للمهمة وتوثيق حالة `authoring_required`.
- [x] اختيار مصادر مفتوحة ذات تنفيذ واختبارات مناسبة، تثبيت revisions، ومراجعة التعليمات والتراخيص.
- [x] فحص source/tests مباشرة وإنشاء Evidence Packet وRun Record.
- [x] تشغيل Resolver حتى `status=ready` وتثبيت البصمة.
- [x] تحويل النتائج إلى Adopt / Adapt / Reject والتزامات محايدة المصدر.

### G1 — Product Scope Approval

- [x] اعتماد active device، title + visible user/assistant text (including visible thoughts)، وone result/session؛ صُحح النطاق بعد تجربة المستخدم للكلمة `سأبحث`.
- [x] اعتماد القفز إلى الرسالة المطابقة عبر anchored-history event id القائمة.
- [x] تثبيت normalization: trim + collapsed whitespace + ASCII-case folding، مع الحفاظ على non-ASCII code points والتشكيل.
- [x] اعتماد زر/حقل في الـsidebar يفتح لوحة نتائج responsive على wide/compact.

### G2 — Agent Query and Protocol

- [x] إضافة نماذج request/result typed وحدود query/page/snippet.
- [x] تنفيذ البحث المرجعي في قاعدة بيانات الـAgent مع فلترة الرسائل الخاصة/غير المرئية.
- [x] إضافة cursor حتمي مرتبط بالاستعلام والنطاق.
- [x] تمرير العقد عبر الواجهة canonical المحلية والسحابية من دون ازدواج منطق.
- [x] اختبار title-only وcontent-only وdeduplication والترتيب والحدود وinvalid cursor والخصوصية وUnicode.

### G3 — Client State and Data Flow

- [x] إضافة نماذج domain وrepository/client/transport typed.
- [x] إضافة مالك presentation واحد لحالة البحث وdebounce وgeneration وpagination.
- [x] منع stale first-page وstale load-more ومنع أي mutation لصفحات sidebar العادية.
- [x] إضافة اختبارات Cubit/repository لمسارات النجاح، empty، failure/retry، query clear، والسباقات.

### G4 — Responsive Search UX

- [x] إضافة مدخل البحث ونتائجه في wide layout.
- [x] إضافة السلوك المكافئ في compact/drawer layout.
- [x] دعم clear/Escape، لوحة المفاتيح، focus semantics، وIME-safe Enter.
- [x] عرض title/workspace/time/match-kind/snippet مع حالة loading/empty/error/retry واضحة.
- [x] فتح النتيجة عبر device/session navigation الحالي وإغلاق drawer عند الحاجة.
- [x] إضافة widget tests للمظهر، الوصول، والانتقال.

### G5 — Documentation, Verification, and Grounding Audit

- [x] تحديث مواصفات UX والتصميم التقني وQA matrix و`docs/llms.txt` في نفس جلسة التغيير.
- [x] تشغيل analyzers واختبارات Agent/Client المركزة بمخرجات محدودة مع حفظ exit status.
- [x] تشغيل E2E daemon-backed لأن التغيير يعبر عقد Local/Cloud session query والسجل الدائم.
- [x] تشغيل `graphify update .` بعد تعديل الكود.
- [x] إعادة فتح Run Record وتقييم كل التزام adopted/adapted كـsatisfied/deviated/not applicable.
- [x] مراجعة diff وحالة Worktree؛ لا commit أو push دون إذن المستخدم.
- [x] تصحيح البحث ليشمل `thought` المرئي، مع اختبار استبعاد reasoning/tools/system/private/superseded.
- [x] إعادة فتح anchored timeline عند اختيار نتيجة داخل الجلسة الحالية حتى لو كان الحدث محمّلًا.
- [x] مطابقة زر Search بصريًا مع New Session ووضعه فوقه، ثم إعادة analyzer/tests/E2E وتحديث Graphify.
- [x] منع route initialization من استبدال جلسة نتيجة البحث المطابقة بـ`Loading...` مع إبقاء placeholder للرابط المباشر غير المعروف.

## Acceptance Criteria

- [x] Given محادثة عنوانها يطابق الاستعلام، when يبحث المستخدم في الجهاز الحالي، then تظهر مرة واحدة حتى لو طابق محتواها أيضًا.
- [x] Given محادثة عنوانها لا يطابق لكن نص مستخدم أو مساعد مرئي (بما فيه thought) يطابق، then تظهر مع snippet محدودة وآمنة.
- [x] Given تطابق موجود فقط داخل reasoning أو system/compaction أو tool/private/superseded content، then لا تظهر المحادثة بسبب هذا التطابق.
- [x] Given سجل أكبر من الصفحات المحمّلة في sidebar، then يعثر البحث على نتائج غير محمّلة لأن الـAgent يبحث في السجل الدائم.
- [x] Given كتابة سريعة تغيّر الاستعلام أو load-more جارٍ، then لا تُعرض أو تُلحق أي نتيجة من generation قديم.
- [x] Given cursor من استعلام/نطاق مختلف أو limit غير صالح، then يرفضه الـAgent بنتيجة typed ولا يعيد صفحة مضللة.
- [x] Given استعلام عربي أو إنجليزي بتغيرات الحالة/Unicode المعتمدة في G1، then تطابق النتائج fixtures المعلنة حتميًا.
- [x] Given فشل البحث، then تبقى الواجهة قابلة لإعادة المحاولة ولا تستبدل الخطأ بنتائج cache جزئية على أنها كاملة.
- [x] Given اختيار نتيجة على desktop أو compact، then يُفتح الجهاز/session الصحيح عند anchored event المطابق حتى لو كان خارج الصفحة المحمّلة، ويُحترم سلوك drawer الحالي.
- [x] Given استخدام لوحة مفاتيح أو IME، then Escape/clear/selection تعمل ولا يؤدي تأكيد composition إلى فتح نتيجة بالخطأ.

## Definition of Done

- [x] كل بوابات التنفيذ ومعايير القبول مغلقة بأدلة.
- [x] عقود الملكية في Agent وClient لم تتغير أو تم تحديث أقرب `AGENTS.md` فقط إذا أصبح قانون دائم قديمًا.
- [x] وثائق product/technical/QA و`docs/llms.txt` متسقة ولا تذكر تفاصيل المصادر الخارجية سوى Evidence ID والبصمة.
- [x] analyzers والاختبارات المركزة وE2E المطلوبة تمر.
- [x] Graphify محدث بعد تغييرات الكود.
- [x] تدقيق reference parity النهائي بلا deviation غير معتمد.
- [x] لا أسرار أو نصوص محادثات أو payloads خاصة في logs أو fixtures.
- [x] لا commit أو push إلا بعد موافقة المستخدم.
