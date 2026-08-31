---
title: "Task 55: GitHub Copilot Subscription Provider"
description: "إضافة مزود اشتراك GitHub Copilot المباشر داخل Sanad عبر تدفق Device Code وتبادل توكن Copilot الداخلي، مع التجديد الاستباقي وإدارة الترويسات الديناميكية واكتشاف النماذج الحية دون أي CLI أو SDK خارجي."
status: "in_progress"
priority: "high"
scope: "Sanad agent provider registry, instance-scoped OAuth credentials, internal token exchange, dynamic headers, model discovery/routing, provider setup protocol, and documentation"
reference_grounding: "packets/55-github-copilot-subscription-provider.md"
evidence_id: "55"
packet_fingerprint: "sha256:5f6a0beb6b3156f6e0a9d70170399cc2b7cea0891d9d672987ce2462503fdb40"
depends_on: "Plan 29 provider instances and credential isolation; existing Codex device-code runtime; current OpenAI Chat Completions and Responses adapters"
coordinates_with: "Provider setup UI, model catalog, provider protocol, and runtime route selection"
current_gate: "done"
---

# Task 55: GitHub Copilot Subscription Provider

## 1. Goal

تمكين مستخدمي Sanad من إضافة حسابات واشتراكات **GitHub Copilot** كـ Provider Instances مستقلة ومعزولة، وتسجيل الدخول عبر **GitHub OAuth Device Code Flow**، وتبادل التوكن للحصول على توكن Copilot API قصير الأجل، وتجديده استباقياً تلقائياً، وإرسال طلبات النماذج مع الترويسات الديناميكية المطلوبة، واكتشاف النماذج الحية المدعومة مباشرة عبر Dart HTTP دون أي اعتماد على Copilot CLI أو GitHub CLI أو SDKs خارجية.

---

## 2. Locked Decisions and Scope Boundaries

### 2.1 Direct Native Dart Runtime (No External CLI / SDK / Daemon)
- الاتصال بـ GitHub و Copilot API يتم عبر عميل HTTP القياسي في Dart (`http.Client`).
- لا يتم استدعاء أو تثبيت `copilot` CLI أو `gh` CLI عبر subprocess.
- لا يتم تضمين GitHub Copilot SDK ولا تفويض دورة حياة الوكيل (Agent Loop) إلى عملية خارجية.
- يبقى Sanad المالك الحصري لدورة الوكيل، استدعاء الأدوات، إدارة الصلاحيات، سجل الجلسات، البث المباشر، ومعالجة الإلغاء.
- بروتوكول ACP الخاص بـ Copilot خارج نطاق هذا التنفيذ.

### 2.2 GitHub App Identity and Authentication Scope
- استخدام Client ID القياسي المعتمد لتبادل التوكن الداخلي (`Iv1.b507a08c87ecfe98`) مع نطاق الصلاحيات الأدنى `read:user`.
- حفظ معرف العميل في إعدادات مركزية غير سرية (`ProviderProtocolConstants`).
- دعم تدفق Device Code المتوافق مع مواصفة RFC 8628 مع معالجة حالات `authorization_pending` و `slow_down` (زيادة فاصل الاستعلام بـ 5 ثوانٍ) و `expired_token` و `access_denied`.
- رفض الرموز الشخصية الكلاسيكية (`ghp_*`) برسالة خطأ واضحة لأنها غير مدعومة من واجهة برمجة Copilot.

### 2.3 Credential Lifecycle and Instance Isolation (Plan 29)
- يُخزن `GitHub user token` (طويل الأجل) كـ `refreshToken` أو أصل التبادل في `SecretRecord` الخاص بـ `provider_instance_id`.
- يُخزن `Copilot API token` (قصير الأجل) كـ `accessToken` مع وقت الانتهاء `expiresAt`.
- **التجديد الاستباقي (Proactive Refresh):** قبل إرسال أي طلب نموذج، إذا كان التوكن سينتهي خلال 120 ثانية (`now >= expiresAt - 120_000`)، يتم تنفيذ تبادل توكن داخلي جديد تلقائياً وتحديث `SecretRecord` وإبطال الكاش المرتبط.
- **التعافي من 401 (Reactive 401 Recovery):** عند استلام استجابة `401 Unauthorized` أثناء استدعاء النماذج، يتم فوراً إبطال التوكن وإجراء محاولة تبادل توكن واحدة وإعادة الطلب مرة واحدة فقط. في حال الفشل مجدداً، يتم تحويل حالة المزود إلى `relogin_required`.
- عزل تام للمفاتيح والـ instances: إجراء التجديد أو تسجيل الدخول لحساب لا يؤثر إطلاقاً على أي حساب Copilot آخر أو مزود آخر.

### 2.4 Account Endpoint Discovery and Host Security
- استخدام النطاق الافتراضي الموثوق `https://api.githubcopilot.com`.
- دعم نقاط النهاية المخصصة لحسابات Enterprise / Data Residency المعادة في استجابة التبادل عبر حقل `endpoints.api` أو المشتقة من تلميح `proxy-ep` في التوكن (مع استبدال `proxy.` بـ `api.`).
- التحقق الإلزامي من النطاق ضد قائمة النطاقات المسموحة (`*.githubcopilot.com`, `copilot-proxy.githubusercontent.com`, أو نطاقات Enterprise الموثوقة) لمنع ثغرات SSRF.
- تطبيق نقطة النهاية المكتشفة على الـ instance المالكة فقط.

### 2.5 Dynamic Request Headers
- دعم الترويسات المطلوبة للطلبات:
  - `Copilot-Integration-Id: vscode-chat`
  - `Openai-Intent: conversation-edits`
  - `Editor-Version: vscode/1.104.1`
  - `x-initiator`: تكون قيمتها `"user"` في أول طلب للنموذج ضمن دورة المستخدم (User Turn)، وتكون `"agent"` أثناء استدعاءات الأدوات المتتالية داخل الدورة.
  - `Copilot-Vision-Request: true`: تضاف فقط عند احتواء الطلب على صور أو مدخلات رؤية.

### 2.6 Dynamic Model Discovery and Routing
- دعم اكتشاف النماذج الحية عبر استدعاء `GET ${baseUrl}/models` بتوكن Copilot Bearer.
- استخراج حدود السياق الفعلية وإمكانيات النماذج (`tool_calls`, `streaming`, `vision`, `reasoning_effort`).
- استبعاد النماذج غير المهيأة أو المعطلة بسياسة المؤسسة (`policy.state`).
- توجيه نماذج Chat Completions إلى `BaseOpenAIAdapter` (مع ترويسات Copilot)، وتوجيه نماذج Responses API إلى محول Responses المناسب.

---

## 3. Execution Gates

### Gate R0 — Reference Grounding & Decision Alignment
- [x] دراسة مشروعي `hermes-agent` و `openclaw` وتحديد آليات المصادقة والتبادل والترويسات واكتشاف النماذج.
- [x] توثيق حزمة الأدلة في `refrence_projects/.sanad-evidence/packets/55-github-copilot-subscription-provider.md`.
- [x] ربط ومطابقة الإصدارات المرجعية في `packet-sources.tsv` والتحقق من أمر `resolve_packet.sh 55` بنجاح (`status=ready`).
- [x] إنشاء سجل التشغيل المرجعي `55-github-copilot-reference-grounding-2026-08-30.md`.

### Gate A — Provider Registry, Template, & Contract Definitions
- [x] إضافة قالب `github-copilot` في `ProviderRegistry` بالمعرفات والأسماء والبدائل (`copilot`, `github-copilot`).
- [x] تحديد خصائص القالب: `authType: 'oauth_external'`, `authFlow: 'device_code'`, `apiMode: 'chat_completions'`, و `authMethods: [ProviderAuthMethod.deviceCode]`.
- [x] تعريف الثوابت المركزية لـ GitHub Copilot OAuth ونقاط التبادل في `ProviderProtocolConstants` (Client ID، نقاط النهاية الافتراضية، الترويسات الثابتة).
- [x] تعريف بنية البيانات المكتوبة (Typed DTOs) لاستجابة التبادل: `CopilotTokenExchangeResult` (تحتوي على `token`, `expiresAt`, `accountEndpoint`).
- [x] توثيق العقد والمخطط في `docs/technical/provider_protocol.md`.

### Gate B — GitHub Device Code Flow & Internal Token Exchange
- [x] إضافة دعم مسار GitHub Device Code داخل `ProviderAuthSessionService` (`_startGithubCopilotDeviceCode`).
- [x] تحديث `poll()` ليصبح مدركاً لنوع المزود والجلسة (Provider/Flow-aware) وعدم حصر التوجيه في Codex.
- [x] معالجة استجابات التدفق وفق RFC 8628: `authorization_pending`, `slow_down` (زيادة 5 ثوانٍ في الفاصل), `expired_token`, `access_denied`.
- [x] تنفيذ وظيفة تبادل التوكن الداخلي `_exchangeCopilotToken` باستدعاء `https://api.github.com/copilot_internal/v2/token` بالترويسات المطلوبة.
- [x] استخراج التوكن ووقت الانتهاء ونقطة النهاية الحسابية المشتقة بأمان مع التحقق من النطاق.
- [x] كتابة `SecretRecord` المكتمل لحساب الـ instance عبر `ProviderCredentialService` بعد نجاح الخطوتين فقط.

### Gate C — Instance-Scoped Refresh & Reactive 401 Recovery
- [x] إضافة آلية التجديد الاستباقي للتوكن داخل طبقة حل الاعتمادات (`ProviderCredentialResolver` / `AgentRuntimeService`) عندما يقترب التوكن من الانتهاء (أقل من 120 ثانية).
- [x] تحديث `SecretRecord` بالتوكن الجديد وزيادة `credentialRevision` لإبطال كاش المحولات القديمة.
- [x] تطبيق آلية التعافي من خطأ 401: عند استلام `401 Unauthorized` من خادم Copilot، تنفيذ تبادل توكن فوري وإعادة محاولة الطلب لمرة واحدة.
- [x] تحويل حالات الفشل الدائم (رفض الحساب، إلغاء التفويض) إلى حالة `relogin_required` بصورة typed دون الدخول في حلقات إعادة لا نهائية.

### Gate D — Dynamic Request Headers & Model Execution Routing
- [x] بناء سياسة حقن الترويسات لطلبات Copilot (`Copilot-Integration-Id`, `Openai-Intent`, `Editor-Version`).
- [x] حقن `x-initiator`: تحديد `"user"` لأول طلب في دورة المستخدم، و `"agent"` للاستدعاءات اللاحقة الناتجة عن تنفيذ الأدوات.
- [x] حقن `Copilot-Vision-Request: true` تلقائياً عند وجود مدخلات صور ورؤية.
- [x] ربط محولات النماذج المناسبة (`BaseOpenAIAdapter` / `CodexResponsesAdapter`) وتطبيق نقطة النهاية الحسابية المكتشفة لكل instance.
- [x] التحقق من تدفق البث المباشر (Streaming)، استدعاء الأدوات (Tool Calling)، وتمرير النتائج بسلاسة.

### Gate E — Setup UI, Live Model Catalog, & Protocol Integration
- [x] دعم اكتشاف النماذج الحية عبر `GET ${baseUrl}/models` داخل `ModelOptionsService` وتصفية النماذج القابلة للاستخدام.
- [x] إدراج قائمة النماذج الاحتياطية الافتراضية الموثوقة (مثل `claude-sonnet-4.6`, `claude-haiku-4.6`, `gpt-5.4`, `gpt-4o`).
- [x] عرض مزود GitHub Copilot في مسار إعداد المزودات (CLI & UI) ودعم بدء تدفق Device Code وإتمام الربط.
- [x] دعم عمليات إعادة الاتصال (Reconnect) وقطع الاتصال (Disconnect) للـ instance المعنية فقط.
- [x] ضمان عدم تسريب التوكنات أو الترويسات السرية في السجلات (Logs) أو استجابات البروتوكول أو واجهة المستخدم.

### Gate F — Verification, Regression Testing, & Documentation
- [x] اختبارات الوحدة الشاملة لـ `ProviderRegistry` وقالب `github-copilot`.
- [x] اختبارات تدفق Device Code وحالات `slow_down`, `pending`, `expired`, `denied`, `cancelled`.
- [x] اختبارات تبادل التوكن الداخلي، استخراج النطاق، والتحقق ضد ثغرات SSRF.
- [x] اختبارات التجديد الاستباقي للتوكن ومعالجة انتهاء الصلاحية والتنافس المتزامن.
- [x] اختبارات التعافي من خطأ 401 وإعادة المحاولة لمرة واحدة.
- [x] اختبارات الترويسات الديناميكية (`x-initiator` و `Copilot-Vision-Request`).
- [x] اختبارات عزل الـ instances المتعددة وتكامل دورة حياة المزود.
- [x] تشغيل الفحص والتحليل `fvm dart analyze` والاختبارات المركزة مع الالتزام بـ bounded output.
- [x] تحديث وثائق `docs/technical/provider_protocol.md` وتحديث `docs/llms.txt` وفهارس الوثائق.
- [x] تشغيل `graphify update .` لتحديث شجرة المعرفة.

---

## 4. Acceptance Criteria

- [x] يظهر قالب `github-copilot` كمزود اشتراك مستقل يدعم تدفق `device_code` فقط.
- [x] يتمكن المستخدم من بدء تسجيل الدخول، وتظهر شاشة Sanad رابط التحقق والكود المخصص، ويكتمل التوثيق بعد الموافقة في المتصفح.
- [x] لا يُطلب من المستخدم تثبيت أو استخدام أي CLI خارجي أو SDK.
- [x] يتم تبادل توكن GitHub تلقائياً والحصول على توكن Copilot API وتخزينهما في `SecretStore` معزولين لكل instance.
- [x] يتم تجديد توكن Copilot تلقائياً قبل انقضاء صلاحيته بساعتين/دقيقتين دون مقاطعة محادثة المستخدم.
- [x] عند استلام خطأ 401 يتم تجديد التوكن وإعادة المحاولة مرة واحدة، ثم التحول إلى `relogin_required` إذا استمر الفشل.
- [x] ترسل جميع طلبات النماذج ترويسات Copilot الصحيحة (`x-initiator: user|agent` و `Copilot-Vision-Request: true`).
- [x] تعمل النماذج المدعومة مع البث المباشر وتنفيذ الأدوات والمحادثة المتعددة الأدوار دون أي خلل.
- [x] اختبارات الوحدة والتحليل البرمجي `fvm dart analyze` تمر بنجاح تام وبدون أخطاء.

---

## 5. Definition of Done (DoD)

- [x] إغلاق البوابات (Gates R0 إلى F) مع وجود أدلة واختبارات مؤتمتة لكل بوابة.
- [x] لا توجد أي قيم سرية أو رموز اعتماد تظهر في السجلات أو واجهة المستخدم أو ملفات الإعدادات المكشوفة.
- [x] عزل كامل لبيانات الاعتماد وفق معمارية Plan 29.
- [x] توثيق الميزات والبروتوكول في `docs/technical/provider_protocol.md`.
- [x] اجتياز جميع اختبارات `fvm dart analyze` و `fvm dart test` المركزة.
- [x] تحديث رسم المعرفة المعماري عبر `graphify update .`.

---

## 6. Verification Commands

```bash
cd agent
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test test/core/provider_runtime 2>&1 | tail -5
set -o pipefail; fvm dart test test/engine 2>&1 | tail -5
```

## 7. Progress Log

| Gate | Status | Closed | Evidence |
|---|---|---|---|
| R0 | closed | 2026-08-30 | Review re-verified: `resolve_packet.sh 55` → `status=ready`; fingerprint `sha256:5f6a0beb6b3156f6e0a9d70170399cc2b7cea0891d9d672987ce2462503fdb40` matches frontmatter; pinned `hermes`/`openclaw` revisions present; mandatory files exist; Client ID, RFC 8628 states, `/copilot_internal/v2/token`, 120s margin, headers, `/models`, and `ghp_*` rejection confirmed in source. |
| A | closed | 2026-08-30 | Review re-verified: registry template `github-copilot` (`oauth_external`/`device_code`/`chat_completions`, aliases `copilot`/`github-copilot`), `GithubCopilotProtocol` constants, `CopilotTokenExchangeResult`, and `docs/technical/provider_protocol.md`. Focused tests: `provider_registry_github_copilot_test.dart` + `copilot_token_exchange_result_test.dart` (+17). |
| B | closed | 2026-08-30 | Review re-verified: provider-aware start/poll, RFC 8628 states, `_exchangeCopilotToken` via `CopilotTokenExchanger`, SecretRecord only after both steps, account endpoint on owning instance. Fixed stray indent in `writeOAuthBundle`. Focused test: `github_copilot_auth_session_test.dart` (+13). |
| C | closed | 2026-08-30 | Review re-verified: `CopilotCredentialLifecycle` + `CopilotAuthRecoveryAdapter` in DI. Proactive 120s (including exact-boundary tests), coalesced in-flight, 401 retry-once, second 401/`403`/PAT → `relogin_required`. Fixed stream retry to `await for` so a second stream 401 marks relogin. Focused tests: lifecycle + recovery adapter + wrap case (+34). |
| D | closed | 2026-08-30 | Review re-verified: static Copilot headers plus `x-initiator` (`user` then `agent` after tools) and vision-only `Copilot-Vision-Request`. Chat Completions → `BaseOpenAIAdapter`; Responses-named models → `CodexResponsesAdapter` using instance `baseUrl` and the same Copilot headers. Focused tests: `github_copilot_headers_test.dart`, routing in `agent_runtime_service_test.dart`, tool-loop initiator in `agent_runner_test.dart` (+24 plus tool-loop). |
| E | closed | 2026-08-30 | Review re-verified: live Copilot `/models` filtered by `policy.state`, streaming, and tool_calls. Instance cache uses adapter discovery; wrapper now preserves fallback source. Fallback models on the template. Catalog lists `github-copilot` for CLI and Flutter. `AuthPollDto.interval` plus cubit `slow_down` retune. `features.md` names GitHub Copilot Subscription. Focused tests: catalog, model options, headers live-model, cache wrapper, `auth_poll_dto_test.dart`, `provider_setup_cubit_test.dart`. |
| F | closed | 2026-08-30 | Review re-verified and repaired: cancel now surfaces `AuthSessionStatus.cancelled` on the next poll. `fvm dart analyze` clean. `fvm dart test test/core/provider_runtime` (+275 ~1) and `test/engine` (+241) passed. `fvm flutter analyze` clean. `graphify update .` rebuilt `graphify-out` (20197 nodes). `docs/llms.txt` indexes `provider_protocol.md` and `features.md`. |

Remaining: none. Gates R0–F reviewed and closed. No git commit (not requested).
