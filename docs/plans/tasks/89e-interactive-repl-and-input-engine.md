---
title: "Task 89e: Interactive REPL and Input Engine"
description: "بناء حلقة الإدخال التفاعلية المتقدمة (REPL) لدعم تصفح السجل بالأسهم، التحرير متعدد الأسطر، واستعراض الأسئلة التوضيحية وبطاقات الموافقات."
status: "completed"
current_gate: "Done"
priority: "high"
depends_on: "Task 89b complete; Task 89c complete"
file_budget: 12
reference_grounding: "required"
evidence_id: "89e"
parallel_with: "Task 89f"
---

# Task 89e: Interactive REPL and Input Engine

## 1. الهدف

تطوير واجهة إدخال طرفية تفاعلية حديثة تشبه Hermes و OpenCode، تدعم مفاتيح الأسهم، سجل الأوامر المحفوظ، التحرير متعدد الأسطر (Multi-line buffer)، والتعامل التفاعلي مع أسئلة الوكيل التوضيحية والموافقات.

## Gate A0 — Specifications

- [x] استخدام مكتبة طرفية متقدمة في Dart لإدارة الـ Raw Mode وسجل التاريخ (History).
- [x] دعم سطر إدخال ديناميكي يعرض اسم مساحة العمل والنموذج: `sanad [workspace : model] > `.
- [x] دعم مفاتيح الاختصار (Ctrl+C للمقاطعة اللحظية، Ctrl+D للخروج).

## Gate A1 — Implementation

- [x] بناء `InteractiveReplSession` في `agent/lib/cli/repl/`.
- [x] حفظ واسترجاع سجل الإدخال من `SANAD_HOME/cli_history`.
- [x] معالجة حدث `system_ask_user`: عرض بطاقة تفاعلية بالأسئلة والخيارات، وتوفير خيار إدخال حر مع إعادة استئناف الدور.
- [x] معالجة طلبات الأذونات التفاعلية مع خيارات النطاق (`Once`, `Session`, `Workspace`).

## Gate A2 — Verification (DoD)

- [x] اختبارات التفاعل اليدوية والآلية لمحاكاة ضغط المفاتيح والتنقل بالسجل (`agent/test/cli/repl_session_test.dart`).
- [x] التأكد من عدم حدوث تعليق أو تداخل في المدخلات أثناء بث المخرجات.
- [x] التحقق من اجتياز `fvm dart analyze` بنسبة 0 أخطاء و 0 تحذيرات، واجتياز كافة اختبارات الـ 28 بنجاح تام.
