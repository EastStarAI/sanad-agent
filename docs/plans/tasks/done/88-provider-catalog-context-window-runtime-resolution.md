---
title: "المهمة 88 — استخدام نافذة سياق catalog أثناء التشغيل"
status: completed
current_gate: G3
remaining_estimate: 0%
---

# المهمة 88 — استخدام نافذة سياق catalog أثناء التشغيل

## الهدف

جعل مسار تنفيذ النماذج يستخدم `context_window` الديناميكية المخزنة لنفس provider instance، حتى تعمل النماذج الجديدة غير الموجودة في metadata الثابتة دون ضغط مبكر أو تعديل خاص باسم النموذج.

## القرارات والنطاق

- الحل عام ولا يحتوي شروطًا أو metadata خاصة بأي model id بعينه.
- `config.yaml` يبقى أعلى override صريح.
- catalog المخزن لنفس provider instance والمطابق لمراجعات الإعداد والاعتماد هو مصدر provider metadata التالي.
- لا تعديل على Client أو Backend أو schema قاعدة البيانات.
- غياب head قابل للضغط لا يجوز أن يسقط الجولة.

## البوابات

### G0 — تثبيت السبب والعقد

- [x] إثبات أن catalog الحي يخزن `context_window` داخل `provider_model_cache`.
- [x] إثبات أن مسار Codex الحالي يرجع fallback بقيمة `4000` ولا يستهلك الكاش أو `models.dev`.
- [x] تثبيت resolver precedence واختبارات القبول العامة.

### G1 — resolver وربط runtime

- [x] إضافة resolver provider-instance-scoped يرفض الكاش ذي revisions غير المطابقة.
- [x] ربط resolver بمحولات runtime دون تخزين session state داخل adapter.
- [x] إبقاء `config.yaml` أعلى أولوية وعدم ربط السلوك باسم نموذج محدد.

### G2 — أمان الضغط

- [x] جعل preflight compaction يتجاوز المحاولة عندما لا يوجد source head قابل للضغط.
- [x] الحفاظ على سلوك الضغط الطبيعي للمحادثات القابلة للضغط.

### G3 — التحقق والتوثيق والتجربة الحية

- [x] إضافة اختبارات catalog-only model، عزل instance، stale revisions، precedence، وno-head.
- [x] تحديث وثائق provider runtime وcontext compaction.
- [x] نجاح analyzer والاختبارات المركزة وتحديث Graphify.
- [x] إعادة تشغيل Agent بأمان والتحقق الحي في الجلسة المبلغ عنها؛ عاد catalog-only model برد مكتمل دون فشل compaction.

## معايير القبول

- [x] Given نموذج غير موجود في `ModelMetadata` وموجود في catalog صالح، when يبدأ turn، then يستخدم runtime قيمة `context_window` المخزنة لنفس instance.
- [x] Given override صريح في `config.yaml`، then يتقدم على catalog.
- [x] Given cache تابع لمراجعة إعداد أو اعتماد مختلفة، then لا يُستخدم.
- [x] Given ضغط متجاوز للحد وتاريخ بلا head قابل للضغط، then لا يرمي `ArgumentError` ولا تسقط الجولة.
- [x] لا يحتوي كود الإنتاج أو fixture الاختبار على شرط خاص باسم النموذج المبلغ عنه.

## Definition of Done

- [x] العقود والوثائق متوافقة مع التنفيذ.
- [x] `fvm dart analyze` والاختبارات المركزة ناجحة بمخرجات محدودة.
- [x] `graphify update .` ناجح.
- [x] commit وpush مصرحان صراحةً ضمن طلب إنشاء PR.

## الحالة الحالية

- البوابة الحالية: مكتملة.
- المتبقي التقديري: 0%.
