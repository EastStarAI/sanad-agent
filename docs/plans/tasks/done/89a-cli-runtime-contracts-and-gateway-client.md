---
title: "Task 89a: CLI Runtime Contracts and Gateway Client"
description: "تأسيس بنية العميل الطرفي المستقل، واكتشاف بيانات اعتماد الخادم المحلي، وإنشاء عميل WebSocket خفيف يستهلك قنوات SanadProtocolBridge."
status: "completed"
current_gate: "All gates completed"
priority: "critical"
depends_on: "Local Gateway protocol stability; Plan 89 approved"
file_budget: 12
reference_grounding: "completed"
evidence_id: "89a"
design_contract: "docs/technical/sanad_cli_architecture.md"
---

# Task 89a: CLI Runtime Contracts and Gateway Client

## 1. الهدف

تأسيس طبقة العميل الطرفي في `agent/lib/cli/`، وتوفير آلية موثوقة لاكتشاف منفذ وبيانات اعتماد خادم البوابة المحلي من `SANAD_HOME`، والاتصال به عبر عميل WebSocket خفيف الوزن (`LocalGatewayCliClient`) لتبادل أحداث البروتوكول القياسي (`think`, `steer`, `stop`, `permissions`).

## Gate R0 — External Reference Grounding

- [x] قراءة implementation عميل Daemon في OpenCode (`packages/cli/src/services/daemon.ts`).
- [x] دراسة بروتوكول Hermes للتواصل عبر المقابس والأدوات الطرفية.
- [x] استخراج مصفوفة `Adopt / Adapt / Reject` لنمط اكتشاف الخادم والمصادقة.

## Gate A0 — Contract Freeze

- [x] تثبيت عقد `LocalGatewayCliClient`: الاتصال، المصادقة برمز البوابة، الاستماع للأحداث، وإرسال الأوامر.
- [x] تثبيت آلية الـ Standalone Fallback عند عدم تشغيل الـ Daemon في الخلفية.
- [x] تثبيت دورة حياة الاتصال وإعادة المحاولة التلقائية عند انقطاع المقبس.

## Gate A1 — Gateway Discovery and Connection

- [x] قراءة مسار `SANAD_HOME` واكتشاف منفذ البوابة والرمز السري من ملف بيانات الاعتماد.
- [x] بناء `LocalGatewayCliClient` للاتصال بـ `ws://127.0.0.1:<port>/gateway`.
- [x] دعم المصادقة برأس `X-Sanad-Gateway-Token` ومطابقة الأصل المسموح.
- [x] اختبارات اتصال حقيقية واختبارات معالجة الأخطاء عند غياب الخادم.

## Gate A2 — Fallback and Verification (DoD)

- [x] توفير مسار تشغيل محلي فوري (In-process platform) عند تفعيل خيار `--standalone` أو غياب الخادم.
- [x] تغطية اختبارات الوحدة للعميل بنسبة 100%.
- [x] توثيق العقد في `docs/technical/sanad_cli_architecture.md`.

## Deliverables & Evidence Summary

1. **`agent/lib/cli/models/cli_events.dart`**: Strongly typed events for streaming chunks, reasoning deltas, tool calls, tool results, permission requests, turn completions, runtime notices, and error events.
2. **`agent/lib/cli/discovery/local_gateway_discovery.dart`**: Robust discovery engine resolving `SANAD_HOME`, loading `.local_token`, health-probing candidate loopback ports (58085-58185), and supporting overrides.
3. **`agent/lib/cli/client/local_gateway_cli_client.dart`**: Full-featured WebSocket client with authentication headers, command dispatch (`think`, `steer`, `stop`, `respondPermission`, `query`), typed event streaming, request correlation, and auto-reconnection.
4. **`agent/lib/cli/fallback/standalone_fallback_strategy.dart`**: Strategy determining attached daemon vs in-process execution.
5. **`agent/lib/cli/cli.dart`**: Clean public barrel export.
6. **`agent/test/cli/local_gateway_cli_client_test.dart`**: Comprehensive unit tests covering parsing, WebSocket communication, discovery, commands, and fallback (20/20 passed).
7. **`docs/technical/sanad_cli_architecture.md`**: Architectural specification and contract documentation.
