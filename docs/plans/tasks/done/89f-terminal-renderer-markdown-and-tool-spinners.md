---
title: "Task 89f: Terminal Renderer, Markdown, and Tool Spinners"
description: "تطوير محرك تصيير المخرجات في الطرفية: دعم Markdown، تظليل الشيفرات، مؤشرات الأدوات الحية (Spinners)، وصناديق التفكير اللحظي."
status: "completed"
current_gate: "Gate A2 Satisfied"
priority: "high"
depends_on: "Task 89a complete"
file_budget: 12
reference_grounding: "required"
evidence_id: "89f"
parallel_with: "Task 89e"
---

# Task 89f: Terminal Renderer, Markdown, and Tool Spinners

## 1. الهدف

تحويل المخرجات النصية الجافة في الطرفية إلى تجربة بصرية حية واحترافية تشمل تصيير Markdown ملون، تمييز الأكواد البرمجية (Syntax Highlighting)، مؤشرات حية أثناء عمل الأدوات (Spinners)، وصناديق مميزة لعرض تدفق التفكير اللحظي للنموذج (`thinking_mode`).

## Gate A0 — Visual Specifications

- [x] تصيير نصوص Markdown المنسقة (العناوين، القوائم، الجداول، النصوص العريضة والمائلة) باستخدام ألوان ANSI متوافقة.
- [x] دعم مؤشر حركة متحرك (Spinner) للأدوات الجارية مع عداد زمني يوضح مدة التنفيذ.
- [x] عرض صناديق مميزة لتدفق التفكير (Reasoning Stream) قابلة للطي أو التلخيص.

## Gate A1 — Implementation

- [x] بناء `TerminalRenderer` في `agent/lib/cli/ui/`.
- [x] بناء `ToolProgressSpinner` لإظهار حالة الأداة (`calling`, `completed ✓`, `failed ❌`).
- [x] دعم خيارات `tool_progress` (`off | all | verbose | new`).
- [x] دعم أنماط الألوان الفاتحة والداكنة (Light/Dark terminal palettes).

## Gate A2 — Verification (DoD)

- [x] اختبارات التصيير مع نصوص Markdown معقدة وأكواد برمجية بلغات متعددة.
- [x] التحقق من أن مسح الأسطر وتحديث الـ Spinners لا يلوث تيار الـ stdout ولا يسبب تشويهاً في النصوص عند إعادة تغيير حجم النافذة (Resize).

## Verification Evidence

- `fvm dart analyze`: 0 issues found (clean).
- `fvm dart test test/cli/terminal_renderer_test.dart`: 34 tests passed cleanly covering:
  - ANSI utility stripping & wrapping.
  - Light, dark, and plain terminal theme palettes.
  - Multi-language syntax highlighting (Dart, Python, Bash, JSON, YAML).
  - Rich Markdown parsing (Headers, Inlines, Lists, Blockquotes, Rules, Links, Code blocks, Tables).
  - ToolProgressSpinner animated frames, elapsed timer, status updates, verbose/newOnly/off modes, and non-TTY fallback.
  - ReasoningBox full stylized borders, compact collapsible recap, and live ReasoningStreamHandler.
  - TerminalRenderer unified API with banners, notices, errors, warnings, and matrix table formatting.
