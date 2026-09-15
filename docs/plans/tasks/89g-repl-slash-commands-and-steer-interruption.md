---
title: "Task 89g: REPL Slash Commands, Steer, and Interruption"
description: "بناء نظام الأوامر المائلة الفورية داخل الطرفية (`/help`, `/workspace`, `/model`, `/session`, `/skills`, `/compact`) ودعم التوجيه اللحظي (`steer`) والمقاطعة."
status: "completed"
current_gate: "completed"
priority: "high"
depends_on: "Task 89e complete; Task 89f complete"
file_budget: 10
reference_grounding: "required"
evidence_id: "89g"
---

# Task 89g: REPL Slash Commands, Steer, and Interruption

## 1. الهدف

تمكين المطور أثناء جلسة المحادثة التفاعلية من إدارة السياق والتبديل بين النماذج ومساحات العمل عبر أوامر مائلة فورية، مع تفعيل قدرات سند الفريدة في التوجيه أثناء العمل (`steer`) والمقاطعة الآمنة (`stop`).

## Gate A0 — Slash Commands Contract

- [x] تعريف أوامر: `/help`, `/workspace`, `/ws`, `/model`, `/session`, `/steer`, `/queue`, `/skills`, `/mcp`, `/compact`, `/clear`, `/stop`, `/exit`.
- [x] دعم استدعاء الأوامر المائلة دون إرسالها إلى نموذج الذكاء الاصطناعي كرسالة مستخدم.

## Gate A1 — Implementation

- [x] بناء `CliSlashCommandHandler` وربطه بموجه الـ REPL.
- [x] دعم التوجيه اللحظي: عند إرسال `/steer <text>` أثناء تشغيل الوكيل، يتم استدعاء حدث `steer` في بروتوكول البوابة وتوجيه المسار دون قطع التقدم.
- [x] دعم الإيقاف اللحظي: عند إرسال `/stop` أو الضغط على `Ctrl+C`، يتم إرسال حدث `stop` وتفريغ النص غير المنفذ إلى المسودة.
- [x] ربط `/compact` بآلية ضغط السياق الدائمة (Plan 53).

## Gate A2 — Verification (DoD)

- [x] اختبارات التوجيه والمقاطعة اللحظية للتأكد من عدم حدوث Race Condition مع خادم البوابة.
- [x] اختبارات استجابة كافة الأوامر المائلة وصحة مخرجاتها.

## 2. Verification Evidence

- `fvm dart analyze`: 0 errors, 0 warnings.
- `fvm dart test test/cli/slash_command_handler_test.dart`: 22 passed tests covering parsing, dispatching, model switching, workspace switching, sessions, skills, MCP, `/compact`, live steering, queued prompts, `/stop`, and REPL prompt synchronization.
- `fvm dart test test/cli/`: All 158 CLI test cases passed cleanly without regressions.
