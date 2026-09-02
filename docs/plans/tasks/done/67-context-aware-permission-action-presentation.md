---
title: "Context-Aware Permission Action Presentation"
description: "تصنيف طلبات إذن الأدوات حسب الإجراء وعرض مدخلاتها كحقول مقروءة وآمنة بدل النص العام وتمثيل Map الخام."
status: "completed"
current_gate: "Complete — verified locally"
priority: "high"
scope: "Flutter client inline permission card and permission UX documentation"
---

# Task 67: Context-Aware Permission Action Presentation

## 1. المشكلة

تعرض بطاقة الإذن حاليًا العنوان العام `Allow this tool action?` لكل الأدوات.
كما تعرض `command` كنص منفرد، أو تستدعي `toolInput.toString()` لبقية الأدوات،
فتظهر المدخلات بصيغة Map خام مثل `{action: file_read, path: ...}`. لا يستطيع
المستخدم تمييز قانون الإجراء بسرعة بين تنفيذ أمر، قراءة ملف، تعديل ملف، بحث،
أو استخدام أداة MCP.

## 2. الهدف

تحويل بطاقة الإذن إلى عرض يعتمد على نوع الحدث مع الحفاظ على البطاقة المدمجة
ومصدر الحقيقة الحاليين:

- عنوان موحد بصيغة `Allow Sanad to …?` ومحدد للإجراء المطلوب.
- عرض الأمر أو المسار الرئيسي مباشرة دون label مكرر، مع `Label: Value` للمدخلات الثانوية فقط.
- تمييز أدوات MCP بهوية `server / tool` مباشرة.
- fallback آمن ومقروء للأدوات الجديدة أو غير المعروفة.
- عدم إعادة عرض محتوى الكتابة/التعديل الذي ينزعه الوكيل من payload العرض.

## 3. بوابات التنفيذ

### Gate A — Presentation contract

- [x] تعريف نموذج عرض مشتق من `DeviceSuspendedRequest` دون إنشاء runtime state جديد.
- [x] تصنيف shell وfile read/write/edit وsearch وMCP والعرض العام.
- [x] تعريف labels بشرية وتحويل القيم المركبة إلى نص مقروء ومحدود.
- [x] الحفاظ على payload الآمن الذي يرسله الوكيل وعدم استرجاع arguments الأصلية.

### Gate B — Inline card implementation

- [x] استبدال العنوان العام بعنوان `Allow Sanad to …?` المصنف.
- [x] استبدال `Map.toString()` بهدف رئيسي بلا label وحقول ثانوية `Label: Value` واضحة.
- [x] استخدام monospace للقيم التقنية مع دعم الالتفاف والنسخ البصري الواضح.
- [x] إبقاء خيارات الموافقة والرفض واختصارات لوحة المفاتيح دون تغيير.

### Gate C — Regression coverage

- [x] اختبار عنوان وتنظيم `shell_execute`.
- [x] اختبار عنوان ومسار `file_read` الخارجي دون Map خام.
- [x] اختبار file write/edit مع عدم ظهور محتوى غير موجود في payload الآمن.
- [x] اختبار عرض MCP باسم الخادم والأداة ومدخلاته.
- [x] إصلاح بوابة MCP لتستدعي `PermissionManager` قبل التنفيذ مع تغطية الموافقة والرفض ونطاقات session/workspace.
- [x] ترحيل قيم CLI السرية المعروفة إلى `McpSecretStore` مع placeholder ومراجع لا تظهر في snapshots.
- [x] اختبار fallback لأداة غير معروفة وقيم nested/list.

### Gate D — Documentation and verification

- [x] تحديث وصف واجهة الإذن في وثائق المنتج.
- [x] تحديث QA لإزالة شرط العنوان action-neutral واستبداله بعناوين دقيقة مع fallback عام.
- [x] تحديث عقد presentation الدائم إذا أصبح شرطه الحالي قديمًا.
- [x] نجاح `fvm flutter analyze`.
- [x] نجاح اختبار widget المركّز.
- [x] تشغيل `graphify update .` بعد تعديل الكود.

## 4. معايير القبول

- [x] يظهر `Allow Sanad to run this command?` عند `shell_execute` وتظهر قيمة الأمر مباشرة.
- [x] يظهر عنوان `Allow Sanad to …?` دقيق عند القراءة أو الكتابة أو التعديل أو البحث.
- [x] يظهر `Allow Sanad to use this MCP tool?` مع هوية `server / tool` مباشرة.
- [x] لا تظهر المدخلات بصيغة `{key: value}` أو JSON خام في البطاقة.
- [x] تعرض المفاتيح غير المعروفة كـlabels بشرية بدل إسقاطها.
- [x] لا تتعطل البطاقة عند وجود Map أو List أو null أو payload فارغ.
- [x] يبقى العنوان العام fallback فقط عندما لا يمكن تصنيف الإجراء.
- [x] الموافقة تدعم once/session/workspace، بينما الرفض يوقف الاستدعاء الحالي فقط ولا يمنع الطلب لاحقًا.
- [x] صندوق محتوى الطلب أغمق بصريًا من السؤال والخيارات.
- [x] صف الأداة المعلقة يعرض أيقونة permission أو question بدل مؤشر الدوران، مع إبقاء progress للتنفيذ غير المعلق.

## 5. خارج النطاق

- تغيير سياسات الأذونات أو approval keys أو scopes.
- تغيير checkpoint/resume أو بروتوكول حسم الطلب.
- عرض arguments الأصلية التي حجبها الوكيل لأسباب أمنية.
- إعادة تصميم composer أو مؤشرات تعليق الجلسات.
