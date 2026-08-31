---
title: "Task 83h: Full Access and Workspace Security UX"
description: "عرض سياسة daemon-authoritative، تأكيد Full Access مرة عند التفعيل، وإتاحة ضبط Direct/Protected وHost discovery للمالك دون روابط تجاوز سياقية أو تخزين سلطة في Flutter."
status: "pending"
current_gate: "Waiting"
priority: "high"
depends_on: "83b, 83d, 83g"
file_budget: 15
---

# Task 83h: تجربة Full Access وأمان Workspace

## 1. الهدف

تحديث واجهة Workspace لتعرض الحقيقة القادمة من daemon وتؤكد المخاطر عند تشغيل Full Access، مع إبقاء execution/discovery settings تحت تحكم المالك وعدم إضافة banner دائم أو shortcut يروّج لتجاوز Protected policy.

## 2. Gate H0 — protocol projection وauthorization UX

- [ ] توسيع Workspace policy query/event projection بـpermission mode، execution mode، discovery policy، revision، وeditable-by-owner flags غير السرية.
- [ ] Client لا يخمن defaults ولا يكتب policy محليًا.
- [ ] controls disabled/hidden عندما caller ليس مالكًا، مع reason غير كاشف عند الحاجة.
- [ ] stale revision/mutation rejection يعيد fetch ولا يطبق optimistic authority.
- [ ] draft/cache fields لا تعيد إرسال mode ضمن turn أو تصبح مصدرًا بعد restart.

### H0 Exit

- [ ] daemon truth تستعيد بعد navigation/reconnect/restart.
- [ ] non-owner لا يرى control قادرًا على mutation.

## 3. Gate H1 — Full Access confirmation

- [ ] عند `default -> full_access` تظهر dialog الإنجليزية المعتمدة مرة قبل mutation.
- [ ] dialog تذكر files/folders، terminal/software/system settings، internet/connected tools، data loss/exposure، وprompt injection.
- [ ] الصياغة تقول “without asking before each operation”، لا “without your permission”.
- [ ] توضح أن Host commands تعمل بصلاحيات حساب النظام وقد تصل إلى بيانات متاحة له.
- [ ] `Cancel` لا يغير state؛ `Turn On` يرسل explicit mutation واحدة.
- [ ] `full_access -> default` مباشر دون warning، ولا banner دائم بعد التفعيل.
- [ ] `Learn more` يفتح وثيقة المنتج المالكة فقط إذا route موجودة؛ غيابها لا يمنع التأكيد.

### H1 Exit

- [ ] confirmation لا تتكرر عند rebuild/reconnect ولا تتخطى عند أول تفعيل.
- [ ] UI لا تدعي أن Full Access يغير backend أو discovery deny.

## 4. Gate H2 — Workspace security settings

- [ ] إضافة/تحديث controls الطبيعية لـDirect Developer وProtected ضمن Workspace settings أو selector المالك المعتمد.
- [ ] تغيير mode يحفظ في daemon DB ويطبق على session نفسها في التنفيذ التالي.
- [ ] Host discovery control مستقل ويشرح visibility لا execution grant.
- [ ] لا يضاف زر/link سياقي بعد tool failure لفتح settings أو التحول إلى Direct.
- [ ] لا تضاف mount/image management UI في هذه المهمة.
- [ ] compact/responsive layouts تبقى English-only وقابلة للوصول بالkeyboard/screen reader.

### H2 Exit

- [ ] المالك يستطيع التغيير والعودة للمحادثة نفسها.
- [ ] مستخدم مشارك لا يستطيع تجاوز owner restrictions.

## 5. Gate H3 — Client credential reset presentation

- [ ] secure-store rollout الذي يفقد legacy session يعرض login الطبيعي، لا storage migration prompt.
- [ ] لا يعرض raw secure-store error أو token state.
- [ ] logout/login navigation لا تدخل loop وتبقى Web behavior مستقلة حسب 83d.

### H3 Exit

- [ ] upgrade/re-login UX واضحة ومحدودة.

## 6. Gate H4 — الاختبارات المرئية والتوثيق

- [ ] widget tests للdialog copy/buttons/one-time transition/cancel/default reset.
- [ ] tests لـowner/non-owner controls وstale mutation وsame-session state refresh.
- [ ] visual verification على نافذة ظاهرة للمستخدم قبل أي commit/push وفق تفضيله.
- [ ] تحديث product/client interface وsecurity user guidance وQA.

### H4 Exit / Definition of Done

- [ ] لا warning دائم ولا hidden authority في Client cache.
- [ ] Full Access وexecution/discovery axes مفهومة وغير مختلطة.
- [ ] analyze/widget/focused daemon integration tests ناجحة.

## 7. سيناريو النجاح

يختار المالك Full Access؛ يرى dialog مرة، يلغي فلا تتغير policy، ثم يؤكد فتتحدث daemon state. لا يظهر banner دائم. يغير Protected إلى Direct من إعداد Workspace ويعود لنفس المحادثة. مستخدم غير مالك يرى state وفق السياسة لكنه لا يستطيع تغييرها أو تفعيل Host discovery.

## 8. خارج النطاق

- mount/image UI.
- contextual bypass links.
- Arabic UI text.
- Client credential migration.

## 9. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Visual evidence:
Findings:
Remaining work percentage:
Next gate:
```
