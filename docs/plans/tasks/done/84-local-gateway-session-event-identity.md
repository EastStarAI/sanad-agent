---
title: "Task 84: Local Gateway Session Event Identity Stability"
description: "منع الأوامر الجانبية المشتركة على WebSocket من إعادة وسم أحداث المحادثة بهوية جهاز أخرى وإسقاطها من EventRouter."
status: "completed"
current_gate: "complete"
review_remaining: "0%"
priority: "critical"
scope: "Local Gateway session-bound device identity and live conversation event routing"
---

# Task 84: Local Gateway Session Event Identity Stability

## Goal

تظل أحداث المحادثة الحية على Local Gateway مرتبطة بالـ`device_id` المنطقية التي رُبطت بها الجلسة، حتى إذا أرسل الـWebSocket نفسه أوامر جانبية بهوية جهاز أو Hardware مختلفة.

## Locked Decisions and Scope

- هوية الجلسة الصريحة أعلى أولوية من آخر هوية محفوظة للـsocket.
- هوية الـsocket تبقى fallback للأحداث التي لا تملك هوية جلسة.
- لا يضيف العميل alias أو fallback جديدًا لإخفاء أخطاء الوكيل.
- يشمل الإصلاح `tool_use` و`tool_result` وحالة التنفيذ والإجابة النهائية وكل استجابة مرتبطة بالجلسة.

## Gates

### G0 — Diagnosis
- [x] إثبات وصول الأحداث إلى WebSocket بهوية Hardware مع اشتراك المحادثة في `local-agent`.
- [x] تحديد أن `_rememberSocketIdentity` كانت تسمح لأمر جانبي بتغيير الهوية التي تستخدمها `_withSocketIdentity`.

### G1 — Implementation
- [x] الحفاظ على هوية الجلسة الموجودة في envelope عند الإرسال المحلي.
- [x] إبقاء هوية الـsocket fallback فقط عند غياب هوية جلسة صريحة.
- [x] عدم إجراء workaround في EventRouter أو Conversation Cubit.

### G2 — Verification
- [x] إضافة اختبار WebSocket يربط جلسة بـ`local-agent`، ثم يرسل أمرًا جانبيًا بـHardware UUID، ثم يتحقق أن حدث الجلسة ما زال يحمل `local-agent`.
- [x] نجاح تحليل الوكيل والاختبار المحدد.
- [x] تحديث العقد والتوثيق الفني ومصفوفة QA.

## Acceptance Criteria

- [x] Given جلسة محادثة مربوطة بـ`local-agent`، when يصل أمر جانبي على الـsocket نفسه بـ`device_id` مختلفة، then تبقى أحداث الجلسة اللاحقة موسومة بـ`local-agent`.
- [x] EventRouter يستطيع تمرير الأحداث الحية إلى ConversationCommandGateway دون مغادرة المحادثة أو إعادة hydration.
- [x] حدث غير مرتبط بجلسة ما زال يستطيع استخدام هوية الـsocket كـfallback.

## Definition of Done

- [x] `fvm dart analyze` ينجح.
- [x] اختبار Local Gateway المحدد ينجح بتسلسل هوية قابل لإعادة الإنتاج.
- [x] `git diff --check` ينجح.
- [x] تحديث Graphify بعد تعديل المصدر.
- [x] تحقق بصري حي بعد إعادة تشغيل الـruntime وإعادة تجربة دفعة الأدوات المتسلسلة؛ أكد المستخدم ظهور الأدوات بالترتيب دون توقف التحديث.
