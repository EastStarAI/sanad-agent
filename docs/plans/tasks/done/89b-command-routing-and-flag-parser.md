---
title: "Task 89b: Command Routing and Flag Parser"
description: "إعادة بناء موزع الأوامر في `sanad_agent.dart` باستخدام حزمة `args` في Dart، ودعم الأوامر الفرعية والخيارات الموحدة."
status: "completed"
current_gate: "Completed"
priority: "high"
depends_on: "Task 89a complete"
file_budget: 10
reference_grounding: "required"
evidence_id: "89b"
---

# Task 89b: Command Routing and Flag Parser

## 1. الهدف

تطوير موزع أوامر احترافي وسريع باستخدام حزمة `args`، يتيح توجيه الأوامر الفرعية (`workspace`, `session`, `run`, `doctor`, `models`, `service`, `chat`) وتمرير الخيارات العامة (`--workspace`, `--model`, `--provider`, `--session`, `--quiet`, `--json`, `--thinking`).

## Gate A0 — Command Specification

- [x] تعريف شجرة الأوامر والخيارات المشتركة في `CommandRunner`.
- [x] تثبيت السلوك الافتراضي: تشغيل `sanad` بدون وسائط يطلق `chat` (REPL) بعد اكتشاف مساحة العمل.
- [x] دعم خيارات المساعدة التلقائية `--help` و `-h` المنسقة لكل أمر فرعي.

## Gate A1 — Implementation

- [x] بناء `SanadCommandRunner` في `agent/lib/cli/runner/`.
- [x] ربط الأوامر الحالية (`daemon`, `service`, `setup`, `version`) وتحديثها لتتوافق مع الموزع الجديد.
- [x] إضافة مدخلات الأوامر الجديدة (`ws / workspace`, `run`, `session`, `doctor`, `models`, `providers`, `skills`, `mcp`, `memory`, `schedule`).

## Gate A2 — Verification (DoD)

- [x] اختبارات التوجيه لجميع الأوامر والخيارات مع حالات الإدخال الخاطئة.
- [x] التأكد من عدم كسر أي سكريبت موجود يعتمد على أوامر `sanad daemon` أو `sanad setup`.

## 2. Verification Evidence

- `fvm dart analyze`: 0 issues found.
- `fvm dart test test/cli/`: 43 passed tests covering flag parsing, default fallbacks, subcommands, aliases, custom sinks, and error handling.
- `fvm dart test test/guards/cli_help_contract_test.dart`: 3 passed guard tests ensuring daemon supervisor and service help contracts are preserved.
