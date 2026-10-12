---
title: "Task 89h: CLI Integration, Regression QA, and Documentation"
description: "إجراء اختبارات التكامل الشاملة لجميع أوامر الـ CLI، والتحقق من التوافقية عبر المنصات (macOS, Linux, Windows)، وتحديث وثائق المشروع الرسمية."
status: "completed"
current_gate: "Completed"
priority: "high"
depends_on: "Tasks 89a–89g complete"
file_budget: 14
reference_grounding: "required"
evidence_id: "89h"
---

# Task 89h: CLI Integration, Regression QA, and Documentation

## 1. الهدف

إجراء الفحص والتكامل الشامل لكافة قدرات أداة السطر البرمجي لسند عبر اختبارات E2E حقيقية، والتأكد من استقرار الأداء وعدم كسر أي عقود سابقة للوكيل أو الـ Daemon، وتحديث الوثائق الرسمية للمشروع.

## Gate A0 — Test Matrix and Scenarios

- [x] إعداد سيناريوهات اختبارات E2E تغطي:
  - الاكتشاف التلقائي لمساحات العمل من مجلدات متفرقة.
  - تنفيذ مهام فورية عبر الأنابيب (`cat | sanad run`).
  - محادثة تفاعلية كاملة تتضمن استدعاء أدوات، موافقات، وأسئلة توضيحية.
  - التوجيه أثناء العمل (`/steer`) وإلغاء المهمة (`/stop`).
  - التبديل بين النماذج ومساحات العمل.
  - فحص تشخيص النظام `sanad doctor`.

## Gate A1 — Cross-Platform Verification

- [x] تشغيل الاختبارات وفحص سلوك الطرفية على macOS و Linux و Windows.
- [x] التأكد من دعم ألوان ومحارف ANSI على طرفيات Windows PowerShell و CMD.
- [x] التحقق من استقرار استهلاك الذاكرة وعدم حدوث تسريب في اتصالات المقبس (WebSocket leak).

## Gate A2 — Documentation and DoD

- [x] تحديث `README.md` بقسم مخصص لأداة الـ CLI وطرق استخدامها السريعة.
- [x] تحديث `docs/operations/user_guide.md` بدليل شامل لجميع أوامر الـ CLI وخيارات الأتمتة.
- [x] تحديث `docs/technical/sanad_cli_architecture.md`.
- [x] تشغيل `fvm dart analyze` والتأكد من خلو الشيفرة من أي تحذيرات أو أخطاء.
- [x] تحديث الرسم البياني المعرفي عبر `graphify update .`.
