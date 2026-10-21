---
title: "Task 84: Interactive Secret Acquisition and Zero-Leak Vault Tools"
description: "أداة يطلب بها الوكيل أسرارًا من المستخدم عبر بطاقة في عميل سند، تُحفظ في خزينة الوكيل وتُحقن فقط في الأوامر التي تطلبها صراحةً، دون أن تصل أي قيمة إلى النموذج."
status: "in_review"
current_gate: "Port review"
priority: "high"
depends_on: "Plan 83 (83c vault, 83e child environment, 83b command authority, 83g backends)"
file_budget: 30
---

# Task 84: طلب الأسرار التفاعلي وأدوات الخزينة بلا تسريب

## 1. الهدف

أن يستطيع الوكيل طلب بيانات سرية (مفاتيح API، كلمات مرور) من المستخدم عند الحاجة، فيُدخلها المستخدم في بطاقة داخل عميل سند، وتُحفظ في خزينة الوكيل (`custom:`)، ثم تُحقن في أمر shell بعينه فقط حين يسمّيها ذلك الأمر. لا تظهر أي قيمة في مخرجات النموذج أو نتائج الأدوات أو السجلات أو تفريغات الطلبات أو التاريخ أو الخط الزمني للعميل.

التصميم المعتمد موثّق في [Execution Trust and Permission Authority §10](../../technical/execution_trust_and_permission_authority.md).

## 2. البوابات

### G0 — الخزينة والأسماء

- [x] نطاق `custom:` في `SecretVaults` بلا ملف legacy، مع فهرس مستقل وكتابة متحقَّق منها.
- [x] `UserSecretVault`: تحقق الأسماء (اسم بيئة صالح، ليس متغيرًا محميًا ولا اعتمادًا لسند)، تخزين، حلّ أسماء محددة فقط، حذف.

### G1 — الحقن الصريح وحجب الصدى

- [x] `shell_execute` يقبل `secrets` (حتى 16 اسمًا)؛ بلا هذا الوسيط لا يصل أي سر. لا wildcard ولا ربط ضمني بالجلسة أو مساحة العمل.
- [x] الحقن يتطلب سلطة `owner`؛ الاسم المجهول يفشل قبل الموافقة ولا يعمل الأمر.
- [x] مفتاح الموافقة يتضمن الأسماء المطلوبة.
- [x] الخلفية Direct تحجب القيم المحقونة من كل مخرج تُبلّغ عنه.

### G2 — حدّ القرار بلا قيم

- [x] `PlatformRuntimeBridge` يقبل رد السر من `owner` فقط ويتحقق من الحقول المطلوبة.
- [x] `SecretAcquisition` يكتب القيم في الخزينة ويُسلّم الأداة والسجل الداخلي و`resolved_decision` والاستئناف قرارًا بلا قيم.
- [x] `SuspendedResumeService` يستأنف نقطة توقف السر بالنتيجة نفسها دون إعادة تشغيل الأداة.

### G3 — الأدوات

- [x] `system_request_secret` و`system_list_secrets` و`system_delete_secret` تُعرض في دورة `owner` فقط.
- [x] `system_ask_user` و`system_request_secret` يتشاركان `InteractiveUserInput`.
- [x] الحذف حساس ويطلب الموافقة في كل مرة.

### G4 — العميل والطرفية

- [x] `SecretRequestCard` بنصوص en/ar ومفاتيح driver، ترسل `secret_values` فقط وتمسح الحقول فور الإرسال أو التخطي.
- [x] الطرفية لا تجمع الأسرار ولا توافق عليها تلقائيًا.

### G5 — التحقق

- [x] اختبارات red ثم green لكل إصلاح (السجلات في `temp/84/`).
- [x] اختبار تكامل بعملية فرعية حقيقية يثبت أن `env` لا يحوي سرًّا غير مطلوب.
- [ ] سيناريوهات حية على Test Home (انظر §5).

## 3. معايير القبول

- **AC-84.1:** طلب عدة حقول مع إخفاء الحقول الحساسة — مُثبت بـ `secret_request_card_test.dart`.
- **AC-84.2:** نتيجة الأداة لا تحوي أي قيمة — `secret_tools_test.dart`, `secret_request_bridge_test.dart`.
- **AC-84.3:** التخطي يعيد نتيجة `skipped` نظيفة — `secret_tools_test.dart`.
- **AC-84.4:** الحفظ في `AgentSecretStore` تحت `custom:<NAME>` دون قاعدة بيانات جديدة — `user_secret_vault_test.dart`.
- **AC-84.5:** القائمة تعيد الأسماء فقط ومن `custom:` فقط — `secret_tools_test.dart`.
- **AC-84.6:** يُحقن السر فقط حين يُطلب، ولا يظهر صداه — `shell_secret_injection_test.dart`.
- **AC-84.7:** لا قيمة في `resolved_decision` ولا في حدث العميل — `secret_request_bridge_test.dart`, `secret_tools_test.dart`.

## 4. خارج النطاق

- كتابة الأسرار في ملف `.env` داخل مساحة العمل (أُزيلت: ملف سرّ نصي صريح).
- مجموعات/خزائن فرعية (`target_vault`): الاسم هو هوية السر.
- صفحة إعدادات لإدارة الأسرار في العميل (مقترحة؛ تحتاج قرار نطاق).
- حجب الأسرار المحوّلة (base64 وغيرها) من المخرجات.

## 5. سيناريوهات حية مقترحة (Test Home واحد)

1. اطلب من الوكيل الاتصال بخدمة تحتاج مفتاحًا؛ تأكد من ظهور البطاقة، والإخفاء، وزر الإظهار، والنص العربي.
2. أدخل قيمة وهمية، احفظ، ثم اطلب `env` دون `secrets`: لا يظهر الاسم ولا القيمة.
3. اطلب أمرًا يسمّي السر ويطبعه: يظهر `[REDACTED:NAME]` في الخط الزمني.
4. ابحث في `request_dumps` وقاعدة الحالة عن القيمة الوهمية بـ grep نصي فقط (عدد التطابقات = 0).
5. أعد تشغيل الـ daemon والبطاقة معلّقة، ثم احفظ: يكمل الدور بنتيجة `stored`.
6. اطلب حذف السر ووافق؛ ثم أمرًا يسمّيه: يفشل بـ `secret_not_found`.
7. من عميل السحابة: البطاقة تعمل بالسلطة نفسها.

## 6. سجل الجولات (Round Log)

### Port round 1 (2026-10-21, branch `feat/84-port` from `feat/83-port` `cef8390f`)

The old draft (PR #208, `feat/task-84-interactive-secret-acquisition`, commit `8b97f2d3`) was re-reviewed against its own plan file and current owners. No checkbox from it was trusted; everything above is re-proved here.

**Triage (old design vs current code and docs):**

1. The draft wrote secrets and its own index directly through `AgentSecretStore`; 83c made `SecretVaults` the single owner of verified writes, the cross-process lock and the generation marker. Ported onto a `custom:` `SecretVaults` namespace (the prefix 83 already reserved).
2. The draft's `ProcessEnvironmentPolicy(customSecrets:)` and `DirectExecutionBackend` changes targeted the older 83e API and resolved the store from DI inside the backend; 83g says the tool owns selection and permission. The tool now resolves explicit names and passes them in `ShellCommandRequest.secretEnvironment`.
3. `write_to_workspace_env` wrote plaintext secrets into a workspace file; it contradicts "no plaintext secret files" and 83's `.env` handling. Dropped.
4. `system_list_secrets` listed `providers:` and `mcp:` keys, contradicting per-owner namespace isolation. Lists `custom:` only.
5. The draft predates 83b `CommandAuthority`; responses and tools were not owner-gated. Now owner-only end to end.
6. The persisted-checkpoint path (Task 108/110 resume owners) persists `resolved_decision`; the draft would have stored plaintext values there and re-run the tool.
7. Tools were 360 inline `CallbackTool` lines in the catalog; current law wants typed `executeResult` tools. Moved to `capabilities/tools/system/secret_tools.dart`.
8. Client copy was hard-coded English, contradicting the localization law.
9. `target_vault` groups were keyed `custom:<group>:<key>` but injected by the last segment, so names collided. Flattened to `custom:<NAME>`.
10. The plan file sat in `docs/plans/done/` with every gate ticked and no evidence; replaced by this task record.

**Defects found and fixed (red then green, logs under `temp/84/`):**

- **D1, critical:** `resolveVaultSecrets` without `targetVault` injected every custom secret into every shell. Fixed: explicit `secrets` only, default none. Red `02-shell-injection-red.log`, green `02-shell-injection-green.log` (`shell_secret_injection_test.dart`, real `env` child).
- **D2:** a verbatim echo of an injected secret reached the tool result, history and request dumps. Fixed: Direct backend redaction of every reported output (same test).
- **D3:** a session/workspace grant for a command extended to the same command with secrets. Fixed: approval key includes sorted names (same test).
- **D4:** secret names were not validated; `PATH`, `LD_*` or `OPENAI_API_KEY` could be stored and a Sanad credential reintroduced. Fixed in `UserSecretVault.nameRejection` and at injection (`user_secret_vault_test.dart`, `execution_isolation_test.dart`).
- **D5:** the bridge accepted secret values from any transport authority. Fixed: `PERMISSION_DENIED` unless stamped `owner`; request stays pending. Red `03-bridge-red.log`, green `03-bridge-green.log`.
- **D6:** the waiting tool received plaintext values and the resolution record kept non-JSON answers. Fixed: only the value-free decision is completed and retained (same test).
- **D7:** on the persisted path, values would be claimed into `suspended_checkpoints.resolved_decision` and the tool re-run (asking again, values lost). Fixed in the bridge (sanitize before claim, vault write on claim) and `SuspendedResumeService` (forced value-free result). Red `04-resume-red.log`, green `04-resume-green.log`.
- **D8:** submitted values were not checked against the requested fields (any name could be stored, required fields unenforced). Fixed: `INVALID_SECRET_VALUES` (bridge test).
- **D9:** vault failures were swallowed (index write `catch (_) {}`) or, with no store, reported every key as `keys_stored`. Fixed: verified `SecretVaults.put`, `failed` outcome, and an unavailable vault fails before prompting (`secret_tools_test.dart`).
- **D10:** `--allow-all-tools` auto-approved a secret request with an empty allow and the REPL offered a y/n prompt. Fixed: terminals never answer it. Red `05-cli-red.log`, green `05-cli-green.log`.
- **D11:** the Client card sent values as a trimmed `answer`, had no l10n and promised a `.env` write. Fixed: `secret_values` untrimmed, en/ar, driver keys, controllers cleared. Red `06-client-transport-red.log`, `07-client-card-red.log`; green `07-client-green.log`.
- **D12:** no revocation or deletion existed. Added `system_delete_secret` with a per-call approval; deleted names fail later as `secret_not_found` (`secret_tools_test.dart`).
- **D14 (found by E2E, pre-existing in 83):** a turn reconstructed from durable work read `command_authority` from the top level of the stored event metadata, where it never is, so every recovered turn became `unverified`. With owner-only secret tools the tool set changed across recovery and the replacement provider request differed from its predecessor (`durable_recovery_restart_e2e_test.dart` F.2.10 failed 2/2). The restorer now restores the stamp from the stored command payload. Red `08-recovery-authority-red.log`; green `08-recovery-file-84x3.log` (3/3). F.2.10 is also intermittently flaky on `feat/83-port` (1 of 3 whole-file runs, `08-recovery-file-83x3.log`).
- **D13:** the gitleaks allowlist was widened for a test with realistic keys. Not ported; tests use `dummy-` values.

**Open questions:**

- A Client Settings page to list and delete secrets without the model (new product scope).
- Whether Full Access should still prompt when a command names secrets (today it does not, consistent with Full Access).
- Values cross the Cloud Gateway relay inside `tool_permission_response` for a cloud client; the private Backend's logging of that command should be confirmed.
- Redaction catches verbatim echoes only; transformed output is a known limit.

**Verification (2026-10-21):**

- `fvm dart analyze` and `fvm flutter analyze`: no issues.
- Agent fast suite: 3342 passed, 15 skipped, 0 failed.
- Client fast suite: 1956 passed, 1 skipped, 0 failed.
- Affected Agent E2E (`--concurrency=1`: shell environment isolation, local tool permissions, platform tool execution, Sanad gateway platform, durable recovery restart): 24 passed, 2 failed, identical to the `feat/83-port` baseline (the two known `local_tool_permissions` failures).
- Client E2E not run: the Client change is a payload field and a composer card, with no socket, bootstrap or daemon-contract change.
- `lint_wiki`: success.
