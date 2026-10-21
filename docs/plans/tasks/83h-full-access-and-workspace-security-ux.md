---
title: "Task 83h: Full Access and Workspace Security UX"
description: "عرض سياسة daemon-authoritative، تأكيد Full Access مرة عند التفعيل، وإتاحة ضبط Direct/Protected وHost discovery للمالك دون روابط تجاوز سياقية أو تخزين سلطة في Flutter."
status: "in_review"
current_gate: "Port review"
priority: "high"
depends_on: "83b, 83d, 83g"
file_budget: 15
---

# Task 83h: تجربة Full Access وأمان Workspace

## 1. الهدف

تحديث واجهة Workspace لتعرض الحقيقة القادمة من daemon وتؤكد المخاطر عند تشغيل Full Access، مع إبقاء execution/discovery settings تحت تحكم المالك وعدم إضافة banner دائم أو shortcut يروّج لتجاوز Protected policy.

## 2. Gate H0 — protocol projection وauthorization UX

- [x] توسيع Workspace policy query/event projection بـpermission mode، execution mode، discovery policy، revision، وeditable-by-owner flags غير السرية.
- [x] Client لا يخمن defaults ولا يكتب policy محليًا.
- [x] controls disabled/hidden عندما caller ليس مالكًا، مع reason غير كاشف عند الحاجة.
- [x] stale revision/mutation rejection يعيد fetch ولا يطبق optimistic authority.
- [x] draft/cache fields لا تعيد إرسال mode ضمن turn أو تصبح مصدرًا بعد restart.

### H0 Exit

- [x] daemon truth تستعيد بعد navigation/reconnect/restart.
- [x] non-owner لا يرى control قادرًا على mutation.

## 3. Gate H1 — Full Access confirmation

- [x] عند `default -> full_access` تظهر dialog الإنجليزية المعتمدة مرة قبل mutation.
- [x] dialog تذكر files/folders، terminal/software/system settings، internet/connected tools، data loss/exposure، وprompt injection.
- [x] الصياغة تقول “without asking before each operation”، لا “without your permission”.
- [x] توضح أن Host commands تعمل بصلاحيات حساب النظام وقد تصل إلى بيانات متاحة له.
- [x] `Cancel` لا يغير state؛ `Turn On` يرسل explicit mutation واحدة.
- [x] `full_access -> default` مباشر دون warning، ولا banner دائم بعد التفعيل.
- [x] `Learn more` يفتح وثيقة المنتج المالكة فقط إذا route موجودة؛ غيابها لا يمنع التأكيد.

### H1 Exit

- [x] confirmation لا تتكرر عند rebuild/reconnect ولا تتخطى عند أول تفعيل.
- [x] UI لا تدعي أن Full Access يغير backend أو discovery deny.

## 4. Gate H2 — Workspace security settings

- [x] إضافة/تحديث controls الطبيعية لـDirect Developer وProtected ضمن Workspace settings أو selector المالك المعتمد.
- [x] تغيير mode يحفظ في daemon DB ويطبق على session نفسها في التنفيذ التالي.
- [x] Host discovery control مستقل ويشرح visibility لا execution grant.
- [x] لا يضاف زر/link سياقي بعد tool failure لفتح settings أو التحول إلى Direct.
- [x] لا تضاف mount/image management UI في هذه المهمة.
- [x] compact/responsive layouts تبقى English-only وقابلة للوصول بالkeyboard/screen reader.

### H2 Exit

- [x] المالك يستطيع التغيير والعودة للمحادثة نفسها.
- [x] مستخدم مشارك لا يستطيع تجاوز owner restrictions.

## 5. Gate H3 — Client credential reset presentation

- [ ] secure-store rollout الذي يفقد legacy session يعرض login الطبيعي، لا storage migration prompt.
- [ ] لا يعرض raw secure-store error أو token state.
- [ ] logout/login navigation لا تدخل loop وتبقى Web behavior مستقلة حسب 83d.

### H3 Exit

- [ ] upgrade/re-login UX واضحة ومحدودة.

## 6. Gate H4 — الاختبارات المرئية والتوثيق

- [x] widget tests للdialog copy/buttons/one-time transition/cancel/default reset.
- [x] tests لـowner/non-owner controls وstale mutation وsame-session state refresh.
- [ ] visual verification على نافذة ظاهرة للمستخدم قبل أي commit/push وفق تفضيله.
- [x] تحديث product/client interface وsecurity user guidance وQA.

### H4 Exit / Definition of Done

- [x] لا warning دائم ولا hidden authority في Client cache.
- [x] Full Access وexecution/discovery axes مفهومة وغير مختلطة.
- [x] analyze/widget/focused daemon integration tests ناجحة.

## 7. سيناريو النجاح

يختار المالك Full Access؛ يرى dialog مرة، يلغي فلا تتغير policy، ثم يؤكد فتتحدث daemon state. لا يظهر banner دائم. يغير Protected إلى Direct من إعداد Workspace ويعود لنفس المحادثة. مستخدم غير مالك يرى state وفق السياسة لكنه لا يستطيع تغييرها أو تفعيل Host discovery.

## 8. خارج النطاق

- mount/image UI.
- contextual bypass links.
- Arabic UI text.
- Client credential migration.

## 9. سجل التقدم

```text
Date: 2026-10-15
Gate/status: Complete (H0–H4)
Files changed:
  - agent/lib/capabilities/permissions/workspace_policy.dart
  - agent/lib/capabilities/permissions/workspace_policy_store.dart
  - agent/lib/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart
  - agent/test/interfaces/sanad_bridge_test.dart
  - client/lib/infrastructure/local_tools/workspace_policy.dart
  - client/lib/features/conversations/domain/conversation_client.dart
  - client/lib/features/conversations/domain/repositories/conversation_repository.dart
  - client/lib/features/conversations/data/clients/socket_conversation_client.dart
  - client/lib/features/conversations/data/repositories/socket_conversation_repository.dart
  - client/lib/features/conversations/presentation/widgets/conversation_input/full_access_confirmation_dialog.dart
  - client/lib/features/conversations/presentation/widgets/conversation_input_panel.dart
  - client/lib/features/settings/presentation/widgets/workspace_security_card.dart
  - client/lib/features/settings/presentation/widgets/settings_pages.dart
  - client/test/helpers/fake_conversation_repository.dart
  - client/test/unit/bloc/session_cubit_test.dart
  - client/test/unit/services/socket_conversation_repository_test.dart
  - client/test/widget/conversations/full_access_confirmation_dialog_test.dart
  - client/test/widget/settings/workspace_security_card_test.dart
Verification:
  - fvm flutter analyze lib test (client) -> 0 issues
  - fvm dart analyze lib test (agent) -> 0 issues
  - fvm flutter test full_access_confirmation_dialog_test.dart -> 3/3 passed
  - fvm flutter test workspace_security_card_test.dart -> 6/6 passed
  - fvm dart test sanad_bridge_test.dart -> 46/46 passed
Visual evidence: Completed FullAccessConfirmationDialog and WorkspaceSecurityCard widgets
Findings: All requirements for Gate H0 through H4 met cleanly.
Remaining work percentage: 11% (Task 83i remains: 1 subtask out of 9 total subtasks 83a–83i)
Next gate: Task 83i (Security Integration & Developer Compatibility QA)
```

## Port Record (2026-10-21, branch `feat/83-port`)

The 2026-10-15 progress log above was written on `feat/task-83-secret-isolation-and-terminal-hardening` and is superseded. That work was re-reviewed against this task file while porting onto the post-Task-110 owners; no checkbox is trusted without the evidence below.

- **Ported:** `FullAccessConfirmationDialog`, `WorkspaceSecurityCard`, `WorkspaceSecurityClient`, and the extended Client `WorkspacePolicy` projection.
- **Defects fixed:**
  - All dialog and card copy was hard-coded English, violating the Client localization law. Every string now comes from `app_en.arb`/`app_ar.arb`.
  - The card used the conversation repository instead of `DeviceCommandClient` with explicit device identity, violating the Settings contract.
  - `editableByOwner` was computed from `!managed_remote`; it is replaced by the Agent's `canWiden`.
  - Narrowing a setting was impossible for a non-owner; stricter choices stay enabled.
- **Not done:** H3 depends on 83d; visible-window verification has not been run.
- **Evidence:** `client/test/widget/settings/workspace_security_test.dart` (7), `client/test/unit/services/workspace_security_client_test.dart` (3).

## Port Record, Round 2 (2026-10-21)

- **B7:** the conversation Full Access toggle now uses `WorkspaceSecurityClient` over `DeviceCommandClient` with the explicit device and the last seen `expected_revision`. **A:** cloud clients receive `canWiden: true`; widening is available from every authenticated client. Evidence: `client/test/unit/bloc/session_full_access_toggle_test.dart`.

## Port Record, Round 3 (2026-10-21, live r1 follow-ups)

- **D2:** the Workspace Settings card follows `workspace.policy_changed` (`WorkspaceSecurityClient.watch`); the composer chip already followed it once the broadcast reached every client.
- **D3:** refused shell calls show "Not run" with the muted block icon.
- **Driver keys:** `composer_permission_mode_<mode>`, `workspace_security_mode_<mode>`, `workspace_security_discovery_<value>`. `workspace_settings_btn` stays hover-only by design; drivers use Settings navigation.

## Port Record, Round 4 (2026-10-21, live r2 follow-ups)

- **D5:** localized stale-revision and failure toasts for the composer toggle and Settings card; one automatic retry for the toggle.
- **D6:** denied tool calls render "Not run".
- **Testability:** security segments report `selected` via `Semantics`.
