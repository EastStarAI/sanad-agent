---
title: "Provider Model Refresh Crash Containment"
status: ready_for_pr
current_gate: complete
remaining_estimate: "0%"
---

# Provider Model Refresh Crash Containment

## Goal

منع أي Base URL قديم أو غير صالح وفشل model discovery الخلفي من إنهاء daemon، مع إبقاء نتيجة `model.refresh` النهائية صادقة (`updated` أو `failed`).

## Locked Decisions and Scope

- إصلاح مسار OpenAI-compatible وAnthropic-compatible المشترك دون تغيير عقود اختيار النموذج أو readiness.
- تطبيع بادئة النسخ القديمة `url ` والقيم المكافئة قبل بناء URI، مع قبول `http` و`https` فقط.
- إبقاء fallback المحلي الموثق عند فشل discovery داخل adapter.
- إذا رمى cache refresh ولا يوجد نجاح سابق، تُحفظ معلومات الفشل ثم يُعاد رمي الخطأ كي يرسل handler حدث `failed`؛ لا يُحوّل الفشل إلى `updated` بقائمة فارغة.
- لا يشمل العمل أي تغيير في واجهة Flutter أو runtime restart.

## Gates

### G0 — Discovery
- [x] مراجعة stack trace والتعديلات الموجودة وعقود core/adapters/gateway.
- [x] تحديد Future المنفصل الناتج من `whenComplete` كمسار محتمل للاستثناء غير المعالج.
- [x] تحديد انحراف `failed` إلى `updated` في التعديل الأولي.

### G1 — Implementation and Regression Coverage
- [x] توحيد تطبيع/تحقق endpoint وإصلاح القيم القديمة المخزنة عند القراءة والكتابة.
- [x] تنظيف coalesced refresh دون إنشاء Future خطأ غير مراقب.
- [x] احتواء مهمة gateway الخلفية بما في ذلك فشل إرسال الحدث النهائي.
- [x] إضافة اختبارات تمنع رجوع crash أو انحراف الحالة النهائية.
- [x] تحديث وثائق التصميم وQA.

### G2 — Verification and PR Readiness
- [x] تشغيل formatter وanalyzer والاختبارات المركزة بمخرجات محدودة.
- [x] تشغيل full fast agent suite لأن التغيير يمس provider runtime المشترك.
- [x] تحديث Graphify ومراجعة diff النهائي.
- [x] تسجيل نتائج التحقق وتقدير المتبقي النهائي دون commit أو push.

## Acceptance Criteria

- [x] القيمة القديمة `url https://api.cursor.com/v1` تنتج endpoint صحيحًا ولا ترمي `FormatException`.
- [x] URL غير صالح يتحول إلى fallback موثق أو terminal `failed` ولا يصل كاستثناء غير معالج إلى event loop.
- [x] cache refresh الفاشل بلا cache سابق يحفظ `last_error` ويظل Future الخاص بالطالب فاشلًا.
- [x] اكتمال أو فشل coalesced refresh ينظف ownership مرة واحدة ويمكن إعادة المحاولة.
- [x] مهمة `model.refresh` الخلفية لا تنهي daemon حتى إذا فشل refresh أو إرسال النتيجة.

## Definition of Done

- [x] `fvm dart analyze` ينجح.
- [x] اختبارات provider endpoint/cache/adapter/gateway المركزة تنجح.
- [x] full fast agent suite تنجح أو تُوثق أي مشكلة سابقة غير مرتبطة.
- [x] `docs/technical/provider_protocol.md` و`docs/qa_maintenance/provider_setup_plan29_regression_matrix.md` يعكسان العقد المصحح.
- [x] `graphify update .` يكتمل، والـdiff جاهز للمراجعة.

## Verification Evidence

- `fvm dart analyze`: نجح دون ملاحظات.
- الاختبارات المركزة للـendpoint/instance/cache/adapters: `98` اختبارًا ناجحًا.
- اختبار gateway لمسار `model.refresh started → failed`: ناجح.
- full fast agent suite: `1150` اختبارًا ناجحًا و`10` اختبارات skipped، دون فشل.
- `git diff --check`: ناجح.
- `graphify update .`: اكتمل؛ لا تغييرات topology إضافية في التشغيل النهائي.
