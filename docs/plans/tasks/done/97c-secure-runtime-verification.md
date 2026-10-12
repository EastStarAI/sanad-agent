---
title: "97c: استكمال التحقق من الكتابة الآمنة"
status: moved-out-of-plan
current_gate: plan-scope-closed
remaining_estimate: "0% inside Plan 97; valuable regression coverage may be delivered independently"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
---

# 97c — إغلاق تصحيح النطاق

## القرار

أُغلق هذا المسار داخل Plan97 دون دمج تنفيذ فرعه في فرع التجميع. اتضح أن نطاقه الخاص بملفات runtime الداخلية لـ`sanad-dev` لا يطابق المشكلة الأساسية التي طلبها المستخدم: بطء `file_read` و`file_edit` وحجب استقبال socket/WebSocket أثناء تنفيذ أداة الملف.

الإصلاح الأساسي السابق لمسار secure-runtime موجود أصلًا في baseline الموروث من `a087238`، ولا تحتاج Plan97 إلى إعادة فتحه كي تبدأ معالجة استجابة الوكيل. مع ذلك، يضيف فرع المهمة تغطية regression أمنية وتصحيحًا وثائقيًا مفيدين. تُنقّى هذه القيمة من تعديلات إدارة Plan97 وتُسلّم، بعد مراجعتها وتصنيفها، عبر PR مستقلة مبنية من `main`؛ لا يدخل commit `2a3054d` نفسه في فرع تجميع Plan97.

## نقل الملكية

- مشكلة أدوات الملفات واستجابة event loop مملوكة حصريًا لـ`docs/plans/tasks/97f-agent-responsiveness.md`.
- نموذج الصلاحيات يبقى كما هو: `full_access` يسمح بالمسارات الخارجية، و`default` يطلب إذن المستخدم للمسار الخارجي فقط.
- 97e تعتمد على baseline الحالي و97d، ولا تعتمد على دمج فرع 97c المرفوض.

## دليل عدم الأثر

مراجعة diff لـ`2a3054d` أثبتت عدم وجود تغييرات في `agent/lib` أو `agent/test` أو PermissionManager أو WorkspacePathResolver أو handlers أدوات الملفات. لم يُدمج commit في التجميع أو `main`.

## التنظيف

بعد استخراج التغطية المفيدة إلى فرع مستقل مبني من `main` وفصل أي commit مقبول يخص 97d، تُحذف worktree وفرع 97c الأصليان؛ لا تبقى المهمة معلقة ولا تتحول إلى dependency لمسار Plan97.
