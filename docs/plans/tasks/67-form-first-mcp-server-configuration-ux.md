---
title: "Task 67: Form-First MCP Server Configuration UX"
description: "استبدال إدارة MCP المعتمدة على JSON بتجربة Form آمنة وسهلة، مع Import/Export وAdvanced JSON محدود، ونقل الفحص والمصادقة والأسرار إلى daemon."
status: "complete"
current_gate: "complete"
priority: "high"
reference_grounding: "mcp-server-ux"
evidence_fingerprint: "sha256:81816121ac1cf33e985e7b72eefe7c54bfd8cc1c5ff55216539acae711a22b70"
file_budget: 24
---

# Task 67: تجربة Form مبسطة وآمنة لإضافة خوادم MCP

## 1. المشكلة

تجربة إدارة MCP الحالية تجعل محرر JSON جزءًا دائمًا وأساسيًا من الصفحة، وتطلب من المستخدم فهم بنية ملف الإعداد بدل توجيهه عبر خيارات واضحة. شاشة الإضافة الحالية تخفف ذلك جزئيًا، لكنها لا تغطي الأنواع الشائعة بصورة كاملة ولا تقدم تجربة موحدة للإضافة والتعديل:

- محرر JSON يشغل مساحة كبيرة من صفحة الإدارة ويعرض تفاصيل تنفيذية لا يحتاجها معظم المستخدمين.
- خيارات المصادقة الحالية غير واضحة، وتفتقد Bearer Token وCustom Headers.
- Arguments وEnvironment Variables تُدخل كنصوص خام دون صفوف منظمة أو أخطاء حقلية دقيقة.
- لا يوجد مسار Edit واضح ومتكامل للخادم بعد إضافته.
- فحص STDIO الحالي يتحقق من شكل الإعداد فقط ولا يشغل اتصالًا حقيقيًا، ومع ذلك يظهر كنتيجة نجاح.
- اختبار الشبكة وOAuth موجودان في Flutter Client رغم أن daemon هو مالك MCP والتنفيذ والأسرار.
- التوكنات والأسرار ممثلة داخل إعداد الخادم بدل فصلها وتقديم حالة masked فقط للواجهة.
- لا يوجد importer متسامح يحول صيغ MCP الشائعة إلى draft قابل للمراجعة.
- حالة Enabled وحالة الاتصال والمصادقة واكتشاف الأدوات ليست مقدمة كتدفقات مستقلة وواضحة.

هذه ليست مشكلة تجميلية فقط؛ استمرارها يخلق مصادر سلطة متنافسة بين الواجهة والـdaemon، ويصعّب دعم الأجهزة والنطاقات والمصادقة بصورة آمنة.

## 2. الهدف

بناء تجربة Form-first تسمح للمستخدم بإضافة وتعديل واختبار خوادم MCP الشائعة دون الحاجة إلى JSON، مع الحفاظ على التوافق الكامل للمستخدم التقني عبر Import JSON وExport JSON منقح وAdvanced JSON Editor اختياري ومحدود بخادم واحد.

يجب أن تحقق المهمة ما يلي:

1. جعل صفحة MCP قائمة بطاقات واضحة بدل List + JSON Editor.
2. دعم STDIO وStreamable HTTP وSSE، مع كشف transport البعيد تلقائيًا افتراضيًا.
3. دعم المصادقة البعيدة: None وBearer Token وOAuth وCustom Headers.
4. تقديم Arguments وEnvironment Variables وHeaders كحقول منظمة، مع دعم اللصق والتحويل إلى draft typed.
5. نقل الفحص الحقيقي وOAuth والتوكنات والأسرار واكتشاف الأدوات إلى daemon.
6. إضافة Add/Edit/Test/Enable/Disable/Remove واختيار الأدوات ضمن تدفق واحد متسق.
7. ترحيل الإعدادات الحالية دون فقد البيانات ودون كشف الأسرار في snapshots أو logs أو errors.
8. دعم Import JSON مع preview، وExport JSON متوافق ومنقح من الأسرار، وAdvanced JSON Edit اختياري لخادم واحد مع validation وdiff/typed preview قبل الحفظ.
9. الحفاظ على Device/Workspace scope وworkspace precedence والحد الأمني الحالي الذي يجعل إدارة MCP محلية فقط.

## 3. تجربة المستخدم المستهدفة

1. يفتح المستخدم `Settings → MCP Servers` فيرى بطاقات الخوادم وحالاتها، دون JSON.
2. يضغط `Add server` ثم يختار:
   - `Remote server`
   - `Local command`
   - `Import configuration` كخيار ثانوي
3. في Remote يكتب URL ويختار المصادقة. يكون transport على `Auto-detect` افتراضيًا، مع HTTP/SSE ضمن Advanced عند الحاجة.
4. في Local يكتب أو يلصق الأمر، ويراجع Command وArguments، ويضيف متغيرات البيئة في صفوف Key/Value مع تمييز القيم السرية.
5. في Import يلصق document أو server object بصيغة شائعة، ثم يرى preview typed وتحذيرات الحقول قبل أي حفظ.
6. يضغط `Test connection` فينفذ daemon فحصًا حقيقيًا، ويعيد transport المكتشف وحالة المصادقة والأدوات أو خطأ قابلًا للتصرف.
7. إذا كان OAuth مطلوبًا، تفتح الواجهة رابط التفويض الذي أنشأه daemon وتعرض حالة pending/approved/error/cancelled دون استلام التوكن.
8. يراجع المستخدم الأدوات المكتشفة ويحدد المسموح منها، ثم يحفظ الخادم.
9. تظهر بطاقة الخادم بحالات مستقلة: Enabled، connection health، authentication، tool count، scope.
10. يستطيع المستخدم لاحقًا Test أو Edit أو Enable/Disable أو Remove دون التعامل مع JSON.
11. يفتح المستخدم التقني قائمة Advanced للخادم ليختار `Export JSON` أو `Edit JSON`. التصدير لا يحتوي أسرارًا، والتحرير يخص الخادم المحدد فقط ويعرض validation وdiff/typed preview قبل Save.

## 4. Gate R0 — بوابة التنفيذ والمواءمة

لا يبدأ أي تعديل في كود agent أو client قبل إغلاق هذه البوابة.

- [x] اعتماد user flow النهائي للإضافة والتعديل والاستيراد والاختبار واختيار الأدوات.
- [x] تثبيت نموذج transports: STDIO وStreamable HTTP وSSE، مع Auto-detect كافتراضي للremote.
- [x] تثبيت نموذج authentication: None وBearer وOAuth وCustom Headers، وإزالة خيار `Mixed` غير الواضح من UX الجديدة.
- [x] تحديد owner دائم لأسرار MCP وطريقة حفظ bearer tokens وsecret headers وOAuth tokens وclient secrets.
- [x] تحديد migration آمن للقيم السرية الموجودة في ملفات MCP الحالية، مع rollback وعدم فقد إعدادات المستخدم.
- [x] تحديد protocol states لـinspection وOAuth، بما يشمل pending/authorization-required/approved/error/cancelled/expired.
- [x] تحديد سياسة Custom Headers: validation، الأسماء الممنوعة، redaction، والتعامل مع القيم غير السرية.
- [x] اعتماد importer shapes المدعومة وقاعدة preview-before-save وعدم استبدال document كامل ضمن import العادي.
- [x] اعتماد redacted export schema: حذف secret values أو تمثيلها كconfigured references غير قابلة لإعادة بناء السر.
- [x] اعتماد Advanced JSON contract: خادم واحد فقط، canonical redacted initial value، validation وdiff/typed preview قبل mutation، ومنع whole-document editing.
- [x] تأكيد أن remote MCP management يبقى خارج النطاق وأن الإدارة المحلية فقط لا تتغير.
- [x] مراجعة file budget وتقسيم التنفيذ إلى وحدات قابلة للاختبار بدل توسيع الشاشات الحالية الكبيرة.

### Gate R0 Exit

- [x] اعتماد المستخدم لهذه المهمة وتدفق UX المكتوب.
- [x] توثيق قرارات secret ownership وmigration وheader policy وOAuth state machine في الوثيقة التقنية المالكة.
- [x] لا توجد فجوة أمنية أو product decision مفتوحة تمنع تنفيذ daemon contract أولًا.
- [x] evidence fingerprint ما زال صالحًا أو تم تحديث grounding قبل بدء التنفيذ.

## 5. Gate G1 — عقد إعداد MCP والأسرار في daemon

- [x] استبدال auth model الغامض بنموذج typed يغطي none/bearer/oauth/custom headers دون خلط transport بالمصادقة.
- [x] دعم headers غير السرية وsecret references دون إعادة secret values في snapshots.
- [x] إنشاء owner واحد لأسرار MCP داخل Sanad Home المحمي، مع permissions وatomic writes متوافقة مع عقود حماية بيانات المستخدم.
- [x] نقل OAuth access/refresh tokens وclient secret والقيم السرية الحالية إلى owner الجديد.
- [x] تنفيذ migration idempotent يحافظ على الإعداد الحالي، ولا يحذف المصدر القديم قبل نجاح النقل والتحقق.
- [x] إبقاء ملفات config محتوية على metadata/references فقط بعد migration الناجح.
- [x] ضمان أن list/save/delete/replace وeffective merge لا تعرض أو تمحو سرًا دون mutation صريحة.
- [x] الحفاظ على precedence: تعريف Workspace بنفس الاسم يتغلب على تعريف Device.

### Gate G1 Exit

- [x] round-trip لكل transport/auth shape ناجح دون secret leakage.
- [x] migration يعاد تشغيله بأمان وينجح مع config قديم أو جزئي أو غائب.
- [x] snapshots وerrors وlogs لا تحتوي bearer token أو header secret أو OAuth token أو client secret.

## 6. Gate G2 — الفحص الحقيقي وOAuth في daemon

- [x] نقل remote connection testing وtransport detection من Flutter إلى daemon.
- [x] تنفيذ inspection حقيقي لخوادم STDIO عبر نفس runtime owner، مع cleanup محدود الزمن وعدم ترك process orphan.
- [x] تجربة Streamable HTTP ثم SSE وفق policy موثقة، أو احترام override صريح من Advanced.
- [x] تنفيذ OAuth discovery/PKCE/registration عند الدعم، مع state machine typed وflow id غير سري.
- [x] فصل authorization URL عن token material؛ الواجهة تستلم URL والحالة والأدوات فقط.
- [x] دعم cancellation وexpiry وbrowser-close/retry semantics بصورة bounded.
- [x] إعادة inspection result موحدة: success، transport، auth state، tools، redacted actionable error.
- [x] عدم حفظ configuration من inspection إلا ضمن mutation صريحة ناجحة.

### Gate G2 Exit

- [x] STDIO success يعني أن الخادم بدأ ونجح handshake/list-tools، لا مجرد صحة command field.
- [x] HTTP/SSE/Bearer/Headers/OAuth تستخدم التنفيذ نفسه الذي سيستخدمه runtime بعد الحفظ.
- [x] كل failure أو cancellation تنظف session/process/callback resources ولا تسجل الأسرار.

## 7. Gate G3 — Import/Export/Advanced JSON وprotocol/client models

- [x] إضافة daemon command أو domain parser يقرأ input غير موثوق ضمن bounds واضحة.
- [x] قبول root `mcpServers` وbare name-to-config map وsingle named server shape المتفق عليها في R0.
- [x] تطبيع aliases الشائعة دون اختراع قيم أو إسقاط fields بصمت.
- [x] رفض document غير صالح، transport متناقض، duplicate name، أو secret shape غير مدعوم برسائل حقلية.
- [x] إرجاع typed preview يتضمن servers وwarnings وunsupported fields، دون persistence.
- [x] إضافة mutation منفصلة تحفظ server واحدًا أو مجموعة راجعها المستخدم صراحة.
- [x] إضافة Export لخادم واحد أو selection صريحة بصيغة ecosystem-compatible، مع redaction قطعي لكل bearer/header/OAuth/client secret وعدم تضمين configured markers قابلة للاستخدام كcredentials.
- [x] إضافة Advanced JSON read/preview/save لخادم واحد فقط؛ القراءة canonical ومنقحة، والحفظ يمر عبر parser والvalidation وtyped/diff preview ونفس mutation contract.
- [x] منع Advanced JSON من قراءة أو استبدال root document أو تغيير خوادم أخرى أو scopes أخرى.
- [x] تحديث Client domain/data models لاستهلاك daemon snapshots والنتائج typed دون networking أو file access محلي.

### Gate G3 Exit

- [x] import لا يستبدل ملف Device أو Workspace كاملًا ضمن المسار العادي.
- [x] export لا يحتوي secret material ويمكن نسخه بأمان مع تنبيه واضح بأن credentials مستبعدة.
- [x] Advanced JSON لا يحفظ قبل preview ولا يستطيع تعديل أكثر من الخادم المحدد.
- [x] malformed أو oversized input يفشل بصورة bounded ولا يغير configuration.
- [x] preview ثم save ينتجان نفس الإعداد canonical الذي عرضه preview.

## 8. Gate G4 — إعادة تصميم صفحة الإدارة وAdd/Edit flow

- [x] إزالة JSON pane وكل imports/controllers/actions الخاصة بالتحرير الخام من صفحة الإدارة الأساسية.
- [x] عرض server cards بحالات مستقلة لـenabled/health/auth/tools/scope.
- [x] إضافة أفعال واضحة: Test، Edit، Enable/Disable، Remove.
- [x] بناء Add/Edit flow مشترك بدل نسخ منطق الحقول بين شاشتين.
- [x] عرض Remote/Local كاختيار بصري واضح، مع Advanced disclosure للخيارات غير الأساسية.
- [x] تمثيل args كعناصر منظمة مع paste parsing يمكن مراجعته.
- [x] تمثيل env وheaders كصفوف Key/Value مع secret toggle وحذف/إضافة وfield validation.
- [x] عدم إعادة secret values عند Edit؛ تعرض `Configured` مع Replace وRemove صريحين.
- [x] تقديم Import كمسار ثانوي يحول input إلى نفس Add/Edit draft.
- [x] إضافة `Export JSON` داخل قائمة Advanced للخادم، مع copy/download feedback وتنبيه أن credentials مستبعدة.
- [x] إضافة `Edit JSON` داخل قائمة Advanced للخادم، يفتح editor محدودًا بالخادم المحدد ويعرض validation ثم diff/typed preview قبل تفعيل Save.
- [x] عدم عرض Advanced JSON كpane دائم أو كطريقة افتراضية للإضافة والتعديل.
- [x] إنشاء review step يعرض نتيجة inspection والأدوات ويتيح اختيارها قبل Save.
- [x] استخدام footer ثابت للأفعال في overlays المحدودة، مع body قابل للscroll ودعم compact layouts.
- [x] توفير keyboard navigation وfocus order وsemantics وtouch targets وعدم الاعتماد على اللون وحده.

### Gate G4 Exit

- [x] المستخدم يضيف ويعدل كل نوع شائع دون كتابة JSON.
- [x] لا يوجد raw secret في widget state بعد انتهاء الإدخال أو في UI feedback.
- [x] Add/Edit/Import/Advanced JSON تستخدم domain validation وmutation authority واحدة ولا تنشئ مصادر إعداد منافسة.
- [x] Export JSON منقح، وAdvanced JSON scoped لخادم واحد وغير ظاهر في المسار الأساسي.
- [x] الصفحة تعمل داخل Device وWorkspace Settings وتحافظ على origin/override presentation.

## 9. Gate G5 — الاختبارات والتوثيق والتحقق

- [x] اختبارات daemon model/serialization لكل transport/auth combination.
- [x] اختبارات secret write/read/replace/remove/redaction/permissions/migration/rollback.
- [x] اختبارات inspection الحقيقية أو adapters المركزة لـSTDIO وHTTP وSSE وtimeouts وcleanup.
- [x] اختبارات OAuth states: approval، cancellation، expiry، discovery failure، registration failure، refresh، late result.
- [x] اختبارات importer: supported roots، aliases، duplicate names، contradictions، unsupported fields، oversized input، preview parity.
- [x] اختبارات Export تثبت حذف كل secret shape واستقرار canonical non-secret output.
- [x] اختبارات Advanced JSON تثبت single-server scope، validation، diff/typed preview، stale-edit rejection، ومنع whole-document mutation.
- [x] اختبارات protocol local path مع الحفاظ على remote-management rejection الحالي.
- [x] widget tests لـRemote/Local/Auth branching وAdd/Edit/Import/Export/Advanced JSON وconfigured-secret replacement وtool selection. (Remote/Local, Add/Edit, Import, and configured-secret coverage pass; management Export/Advanced/tool-selection widget coverage remains.)
- [x] widget tests للبطاقات والحالات وDevice/Workspace origins وcompact width وkeyboard/accessibility.
- [x] تشغيل `fvm dart analyze` وfocused agent tests وفق العقود.
- [x] تشغيل `fvm flutter analyze` وfocused client tests وفق العقود.
- [x] تقييم daemon-backed E2E وتشغيل الضروري فقط: نجح local protocol عبر daemon مؤقت وحالة معزولة؛ migration وOAuth loopback تستخدمان fixtures حقيقية محدودة داخل اختبارات agent، ولم تُشغّل fixture خارجية لـSTDIO/OAuth لعدم توفر fixture إضافية آمنة تضيف دليلًا غير مغطى.
- [x] تحديث وثائق product وtechnical وagent_engine وQA والـAGENTS الأقرب فقط عندما تتغير invariants.
- [x] تحديث Graphify بعد تغييرات الكود وفق عقد المستودع.

### Gate G5 Exit / Definition of Done

- [x] التحليل والاختبارات المركزة المطلوبة ناجحة.
- [x] لا regression في tool discovery أو workspace precedence أو remote-management boundary.
- [x] لا raw JSON editor في تجربة الإدارة الأساسية.
- [x] لا client-owned network/OAuth/process execution في MCP feature.
- [x] لا secret value في snapshot أو log أو error أو history.
- [x] الوثائق تصف السلوك المنفذ فعليًا ولا تذكر تفاصيل مصدر مرجعي خارجي.

## 10. معايير القبول

### تجربة المستخدم

- [x] يستطيع مستخدم غير تقني إضافة Remote MCP عبر URL واختيار None أوBearer أوOAuth دون معرفة بنية JSON.
- [x] يستطيع إضافة Local STDIO بلصق command ومراجعة args/env قبل الاختبار.
- [x] يستطيع استيراد snippet شائعة، مراجعة preview، وتصحيح الأخطاء قبل الحفظ.
- [x] يستطيع تصدير JSON متوافق لخادم محدد مع تأكيد واضح أن credentials مستبعدة.
- [x] يستطيع المستخدم التقني فتح Advanced JSON لخادم واحد، مراجعة validation وdiff/typed preview، ثم الحفظ عبر نفس mutation authority.
- [x] يستطيع تعديل الخادم واختباره وتعطيله وحذفه من بطاقة واضحة.
- [x] لا تعرض Edit أي token أو secret محفوظ؛ تقدم Configured/Replace/Remove فقط.
- [x] تعرض حالات الاتصال والمصادقة والتفعيل والأدوات بصورة مستقلة وقابلة للفهم.

### السلوك والمعمارية

- [x] daemon هو السلطة الوحيدة للفحص وOAuth والأسرار والتخزين وruntime discovery.
- [x] client لا يفتح MCP socket مباشرة ولا يشغل process ولا يقرأ ملفات إعداد MCP.
- [x] transport المكتشف والأدوات في الاختبار تأتي من نفس runtime path المستخدم في الجولات.
- [x] Device وWorkspace scopes وsame-name override تبقى صحيحة ومعلّمة.
- [x] cloud-origin conversations تستمر في استخدام MCP tools المكوّنة محليًا، بينما cloud management يبقى مرفوضًا.

### الأمان والموثوقية

- [x] كل الأسرار مخزنة ضمن owner محمي ولا تظهر في config snapshots أو diagnostics.
- [x] migration لا يفقد الإعدادات ويملك failure/rollback tests.
- [x] failed Test أو OAuth أو Import أو Advanced JSON validation/preview لا يحفظ configuration جزئية.
- [x] Export وAdvanced JSON initial value لا يحتويان raw secret material تحت أي auth shape.
- [x] STDIO inspection ينظف process tree في النجاح والفشل والtimeout والإلغاء.
- [x] Custom Headers تخضع للvalidation وredaction policy المعتمدة في R0.

### الجودة والتوثيق

- [x] توجد اختبارات behavior-level تغطي المسارات الرئيسية وحالات الفشل، لا snapshots شكلية فقط.
- [x] الواجهة responsive وقابلة للاستخدام بالkeyboard وscreen-reader ولا تحتوي overflow في العرض الضيق.
- [x] وثائق Product/Technical/QA محدثة في جلسة التنفيذ نفسها.
- [x] لا يتجاوز التنفيذ file budget دون مراجعة وتقسيم المهمة.

## 11. خارج النطاق

- Catalog أو متجر MCP أو one-click installation.
- تشغيل git clone أو package-manager/bootstrap scripts من الواجهة.
- remote/cloud MCP configuration management.
- mTLS وcustom CA/proxy/sampling/parallel-tool-call controls ما لم تُعتمد صراحة بإعادة فتح R0.
- نسخ implementation من مشروع مرجعي؛ المرجع مصدر سلوكي واختباري فقط.
- تغيير permission policy العامة لأدوات MCP خارج اختيار أدوات الخادم.

## 12. الملفات والمناطق المتوقعة

- `agent/lib/capabilities/mcp/`
- MCP command handlers والبروتوكول ضمن `agent/lib/interfaces/`
- Sanad Home/secret owner المناسب داخل `agent/lib/core/`
- `client/lib/features/mcp/`
- client command/data mappings ذات الصلة دون تجاوز `DeviceCommandClient`
- اختبارات agent/client وdaemon-backed E2E المركزة
- `client/lib/features/mcp/AGENTS.md` و`agent/lib/capabilities/mcp/AGENTS.md` إذا تغير invariant
- `docs/product/settings_hub.md`
- وثيقة تقنية جديدة أو محدثة لعقد MCP configuration/authentication/import
- `docs/agent_engine/capability_runtime.md`
- QA matrix جديدة لإدارة MCP form-first والأسرار والمصادقة

## 13. سيناريو النجاح النهائي

يضيف المستخدم خادمًا بعيدًا محميًا بـOAuth من Settings دون كتابة JSON. يرسل client draft غير سري إلى daemon، ينشئ daemon flow ويعيد authorization URL، تفتح الواجهة المتصفح وتعرض `Waiting for authorization`. بعد الموافقة يعيد daemon حالة Approved والأدوات المكتشفة دون token. يختار المستخدم الأدوات ويحفظ؛ تظهر بطاقة Enabled وConnected مع عدد الأدوات. بعد restart تبقى البطاقة صحيحة، ويستخدم agent الأدوات، ولا يظهر token في config snapshot أو client cache أو logs.

في مسار STDIO، يلصق المستخدم command كاملًا، يراجع args/env، وينفذ Test حقيقيًا. إذا فشل launch أو handshake يرى خطأ redacted ولا يُحفظ شيء ولا تبقى process orphan. وإذا استورد snippet، تتحول إلى نفس form والمراجعة بدل تحرير ملف كامل. يستطيع المستخدم التقني تصدير JSON منقح أو فتح Advanced JSON للخادم نفسه؛ لا يصبح Save متاحًا حتى نجاح validation ومراجعة diff/typed preview، ولا يمكن لهذا المسار تعديل خادم آخر أو كشف سر محفوظ.

## 14. سجل التقدم

```text
Date: 2026-08-09
Gate/status: R0 and G1 complete; G2 runtime inspection complete except OAuth flow; G3 in progress
Files changed: docs/technical/mcp_server_configuration.md; local ignored grounding run record
Verification: resolver status=ready; fingerprint=sha256:81816121ac1cf33e985e7b72eefe7c54bfd8cc1c5ff55216539acae711a22b70; mandatory evidence and owning contracts inspected
Findings: daemon remains the sole authority; secret owner, migration, header policy, import/export, Advanced JSON, inspection, OAuth states, local-only management, and 24-file implementation budget are fixed
Next gate: finish G3 protocol/client models, then G4 UI; OAuth lifecycle remains an explicit G2 sub-block

Date: 2026-08-09 (session pause checkpoint)
Gate/status: G3 paused during client model migration
Files changed: daemon MCP model/secret store/codec/runtime/protocol/tests; client MCP typed model/runtime client and disabled legacy networking shim; R0/G1 technical docs
Verification: agent full analyzer clean; 15 focused agent/security tests pass. Client formatter passes, but client analyzer is intentionally not yet clean because Add/Edit and legacy manager/tests still reference the removed secret-bearing model API.
Findings: resume by completing client call-site migration; do not restore client-owned tokens, OAuth, HTTP, process, or raw config-file authority merely to satisfy old callers.
Next gate: complete typed client compilation, then G4 form/card UI and G2 OAuth lifecycle.

Date: 2026-08-09 (G3 completion checkpoint)
Gate/status: G3 complete; G4 active
Files changed: client MCP typed models/runtime client/call sites and focused tests; daemon codec focused tests; task record
Verification: `fvm flutter analyze` clean; `fvm dart analyze` clean; client runtime-client tests 4/4 pass; daemon MCP configuration tests 8/8 pass
Findings: client call sites compile without restoring client-owned networking, OAuth, process, file, or secret persistence authority; import/export/Advanced responses are typed and whole-document replacement remains daemon-rejected. Evidence resolver reports external source HEAD drift, while mandatory working files hash-match the pinned revision; no checkout outside this worktree was modified.
Next gate: G4 card-first management and shared Add/Edit/Import/Advanced flow, then remaining G2 OAuth lifecycle and G5.

Date: 2026-08-09 (safe pause after G4 and OAuth)
Gate/status: G2, G3, and G4 complete; G5 active with only management widget/E2E closure remaining
Files changed: daemon MCP OAuth service/runtime/protocol/security tests; client card-first management/shared form/typed OAuth runtime; product/technical/agent-engine/QA/contracts; Graphify output; evidence audit record
Verification: both analyzers clean; focused agent suite 64/64 pass; focused client suite 14/14 pass; full client fast suite 914 pass with 1 skipped; `git diff --check` clean; `graphify update .` complete (17,706 nodes / 23,919 edges). Full agent suite has two unrelated environment-sensitive failures: configured gateway port expected 59123 but process environment resolves 58085, and cloud-connection validation expects FormatException while the process-managed environment correctly returns StateError.
Findings: no client-owned MCP network/process/file/config authority remains; draft inspection credentials are ephemeral; daemon OAuth covers discovery, dynamic registration, S256 PKCE, state validation, loopback callback, token exchange/refresh, cancellation/expiry, redacted status, and cloud-management rejection. No commit, push, runtime switch, or stop was performed.
Next gate: add focused management-card Export/Advanced/tool-selection/origin/compact/accessibility widget coverage; decide whether daemon-backed E2E fixtures are available/required; rerun focused suites and analyzers, record the two unrelated full-agent failures, finish G5 docs/evidence audit, then review diff. Do not commit or push.

Date: 2026-08-09 (G5 completion)
Gate/status: G5 complete; Task 67 ready for review
Files changed: management-card accessibility/lifecycle fixes and focused widget tests; MCP QA and task records; final Graphify/evidence audit
Verification: both analyzers clean; focused agent 24/24 and client 20/20 pass; management widget 6/6 pass; daemon-backed local MCP protocol E2E 1/1 passes with isolated temporary state; full client fast suite 920 pass with 1 skipped; `git diff --check` clean; `graphify update .` complete (17,727 nodes / 23,959 edges). Full agent suite reaches 1049 passes with 3 skipped and 4 unrelated process-environment failures: three gateway-port expectations resolve the injected 58085 instead of test-local values, and cloud-connection validation receives the expected process-owned `StateError` before the test's `FormatException` assertion.
Findings: Export, Advanced preview/save, tool selection, Device/Workspace origin and precedence, compact width, keyboard/screen-reader semantics, and dialog controller teardown are behavior-tested. E2E was limited to the local daemon protocol boundary; migration and OAuth loopback use bounded real filesystem/HTTP fixtures, while no external STDIO/OAuth fixture was run. Reference resolver still reports external HEAD drift; the pinned packet and source-neutral obligations remain unchanged.
Next gate: human diff review only. No commit, push, runtime switch, or stop was performed.
```
