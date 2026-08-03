---
title: "Task 63: sanad-dev Component Runtime Controls"
description: "تشغيل الوكيل والواجهات بالتوازي والتحكم المستقل حسب المكوّن والجهاز مع إيقاف وكيل قابل للاستكمال وإلغاء صريح عبر --force."
status: "in_progress"
current_gate: "C3 — live resumable-work and force-cancellation validation pending"
priority: "high"
depends_on: "Plan 30 durable runtime recovery; Task 50 run cancellation; sanad-dev managed runtime ownership"
file_budget: 38
design_contract: "docs/technical/sanad_dev_runtime_ownership.md"
qa_contract: "docs/qa_maintenance/sanad_dev_runtime_ownership_qa.md"
---

# Task 63: sanad-dev Component Runtime Controls

## 1. الهدف

تحويل `sanad-dev` من launcher يفترض زوجًا متلازمًا إلى supervisor يملك Agent
وواحدًا أو أكثر من Flutter clients كمكوّنات مستقلة. يجب أن يستطيع المطور تشغيل
الوكيل أو الواجهة أو الاثنين، تشغيل Agent وClient بالتوازي، مشاهدة سجلاتهما في
طرفيات مستقلة، وإيقاف Client محددة بالجهاز دون التأثير في الوكيل. إيقاف الوكيل
العادي يحفظ العمل غير المكتمل عند checkpoint آمنة ويستكمله عند التشغيل التالي؛
`--force` وحده يطلب الإلغاء النهائي قبل الإيقاف.

## 2. عقد الأوامر

```text
sanad-dev run [all|agent|client] [-d|--device <id>] [run options]
sanad-dev stop [all|agent|client] [-d|--device <id>] [--force]
```

القواعد:

- غياب target في `run` أو `stop` يعني `all` للتوافق.
- `run all` يبدأ Agent وClient بالتوازي؛ لا ينتظر spawn أحدهما readiness الآخر.
- `run client -d <id>` و`run all -d <id>` يمران device id إلى Flutter.
- `run agent -d <id>` usage error لأن Agent لا يملك Flutter device.
- `stop client -d <id>` يوقف Client المطابقة فقط.
- `stop client` بلا `-d` ينجح فقط عندما توجد Client مملوكة واحدة؛ تعددها يفشل
  بأمان ويعرض device/VM port selectors.
- غياب Client مطابقة أو تعدد Clients تحمل device id نفسه يفشل بلا mutation؛
  يمكن استخدام `-p <vm-port>` لحسم التطابق عند الحاجة.
- `--force` صالح فقط مع `stop agent` و`stop all`، ويُرفض مع `stop client`.
- `stop agent` لا يوقف أي Client؛ تبقى الواجهة مفتوحة وتعرض disconnected ثم
  تعيد الاتصال عند عودة الوكيل.
- `stop client` لا يوقف Agent ولا Clients أخرى ولا ينهي supervisor ما دام مكوّن
  آخر مملوكًا.
- `stop all` هو mutation ذرية من منظور القبول: لا تُغلق Clients قبل قبول pause
  الآمنة للوكيل. عند رفض pause تبقى المجموعة كما هي.

## Gate C0 — Command, state, and compatibility contract

- [x] فصل target parsing عن default target التاريخي وإضافة `all|agent|client`.
- [x] إضافة `-d` كمرادف كامل لـ`--device` مع validation حسب command/target.
- [x] قصر `--force` على Agent-owning stop targets ورفض التركيبات المضللة.
- [x] تعريف typed component control state مع إبقاء launcher record الحالي متوافقًا وإضافة حالات المكوّنات الموثقة.
- [x] تعريف device-selection result: exact, missing, ambiguous.
- [x] تحديث help والأمثلة مع الحفاظ على أوامر logs/restart/reload الحالية.

### C0 Exit

- [x] parser/selector tests تغطي كل التركيبات الصحيحة والمرفوضة.
- [x] launcher record الحالية تبقى مقروءة وتقبل component statuses دون schema migration.

## Gate C1 — Independent supervisor and parallel launch

- [x] استبدال pair-exit coupling بـruntime supervisor يملك Agent وClients مستقلين.
- [x] خروج Client لا يستدعي إيقاف Agent أو Clients أخرى.
- [x] خروج Agent لا يقتل Clients، ويحدّث component state فقط.
- [x] `run all` يبدأ عمليتي `Process.start` دون انتظار Agent health بينهما، ثم
      يتحقق من Agent identity وClient VM identity كلٌ على حدة ضمن deadlines.
- [x] فشل spawn/identity ينظف process tree والـlease؛ النتيجة typed وتصف المكوّن الفاشل.
- [x] run لاحق لمكوّن ناقص يرسل command nonce-bound إلى supervisor المالك بدل
      إنشاء launcher ثانية للمجموعة نفسها.
- [x] stop component request موجهة إلى launcher lease نفسها وتنتظر نتيجة typed.
- [x] lease تسجل component status ومجموعة Client PID/VM/profile الدقيقة؛ Agent identity تثبتها health والـlauncher nonce.
- [x] status يعرض حالة كل مكوّن ولا يختزل المجموعة في أول Client.

### C1 Exit

- [x] Agent وClient يبدآن بالتوازي وتبقى ملكية واحدة قابلة للتحقق.
- [x] كل transition مستقل لا يمس process غير مستهدف.

## Gate C2 — Device-targeted clients and terminal log surfaces

- [x] `run client -d <id>` يضيف/يشغل Client بذلك الجهاز تحت supervisor المالك.
- [x] `stop client -d <id>` يختار من Clients المملوكة فقط ويمنع cross-owned أو
      unverifiable targets.
- [x] `-p <vm-port>` يحسم duplicate device ids ولا يمنح ownership بذاته.
- [x] كل Client تحفظ launch profile الكامل لإعادة attach/restart/source switch.
- [x] `run all` يفتح سطحين للسجلات فورًا في interactive desktop mode: Client
      الحالي وAgent sidecar؛ watcher ينتظر endpoint بدل تأخير process spawn.
- [x] non-interactive/CI لا يفتح GUI terminal ويطبع fallback command محدودًا.
- [x] إغلاق component يغلق watcher التابعة لها دون إبقاء reconnect loop دائمة.
- [x] فشل terminal launcher غير قاتل ولا يغيّر process ownership.

### C2 Exit

- [x] تشغيل وإيقاف macOS Client محددة لا يؤثر في Agent أو Client أخرى.
- [x] سجلا Agent وClient مرئيان بالتزامن دون تسلسل startup مصطنع.

## Gate C3 — Resumable Agent pause and explicit force cancellation

- [x] إضافة daemon shutdown contract يميز `pause` عن `cancel` وعن restart.
- [x] `stop agent` يغلق admission ويستخدم global checkpoint drain الحالي.
- [x] normal timeout أو unsafe executing tool يرفض pause ويترك daemon والعمل
      والطابور يعملون؛ لا kill fallback ولا success جزئي.
- [x] بعد قبول pause تبقى الحالة durable قابلة للاستكمال، ثم يخرج child وsupervisor دائمًا دون `requestStopAll()`.
- [x] startup restoration تستعيد running/resuming checkpoint-safe work وتحتفظ
      بـwaiting permission/questions وFIFO queued input بلا replay غير آمن.
- [x] `stop agent --force` يعني cancel semantics: `requestStopAll()`، terminal
      cancellation، bounded resource cleanup، ثم permanent exit.
- [x] `stop all` يحضّر Agent pause قبل إغلاق Clients؛ `--force` يثبت cancellation
      بينما Clients متصلة قبل إغلاقها.
- [x] crash أو transport failure أثناء shutdown يبقي durable ownership قابلة
      للتشخيص ولا يحذف history أو credentials.

### C3 Exit

- [ ] daemon-backed test يثبت: active work → stop agent → daemon absent → run
      agent/all → same work resumes once.
- [ ] force test يثبت أن العمل cancelled ولا يُستكمل بعد التشغيل التالي.

## Gate C4 — Integration, documentation, and verification

- [x] تحديث `docs/technical/sanad_dev_runtime_ownership.md`.
- [x] تحديث `docs/operations/developer_guide.md` والأمثلة.
- [x] تحديث `docs/qa_maintenance/sanad_dev_runtime_ownership_qa.md`.
- [x] تحديث recovery QA عند تغيير daemon pause/startup behavior.
- [x] تحديث أقرب `AGENTS.md` فقط إذا تغيّر durable law فعليًا.
- [x] تشغيل analyzers والاختبارات المركزة ثم fast suites حسب blast radius.
- [ ] تشغيل daemon-backed E2E لعزل worktree والاستكمال عبر process boundary.
- [x] تشغيل `graphify update .` بعد اكتمال الكود.

### C4 Exit / Definition of Done

- [ ] أوامر run/stop المستقلة تعمل من primary checkout وlinked worktree.
- [x] device targeting exact وfail-closed عند ambiguity.
- [x] لا component exit يقتل sibling بلا طلب صريح.
- [ ] normal Agent stop قابل للاستكمال وforce cancellation نهائية — يحتاج اختبار الاستكمال الحي عبر جلسة جديدة.
- [x] runtime ownership، source switch، restart/reload، status، وlogs لم تنتكس في الاختبارات الآلية.
- [x] التغيير داخل file budget أو توثيق سبب الزيادة قبل تجاوزها.

## 3. الملفات المتوقعة

### Launcher/runtime

- `scripts/sanad_dev/cli.dart`
- `scripts/sanad_dev/runtime_commands.dart`
- `scripts/sanad_dev/runtime_ownership.dart`
- `scripts/sanad_dev/switch_commands.dart`
- `scripts/sanad_dev/developer_actions.dart`
- component supervisor/control request وterminal launcher كملفات مركزة جديدة

### Agent pause/recovery

- `agent/lib/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart`
- `agent/lib/interfaces/runtime/daemon_restart_coordinator.dart`
- `agent/lib/interfaces/runtime/session_run_orchestrator.dart`
- `agent/lib/interfaces/runtime/session_recovery_restorer.dart`
- durable work repositories/schema فقط إذا احتاجت state transition صريحة

### Verification/docs

- focused launcher ownership/process-state tests تحت `client/test/unit/scripts/`
- restart/recovery tests تحت `agent/test/interfaces/` وdaemon-backed E2E
- design, developer, and QA docs المذكورة في C4

## 4. سيناريو النجاح

```text
sanad-dev run all -d macos
  Agent spawn ─────────────── health verified
  Client spawn ───────────── VM identity verified

sanad-dev stop client -d macos
  macOS client exits; Agent and its active work remain running

sanad-dev run client -d macos
  client rejoins the same managed runtime

sanad-dev stop agent
  active work reaches durable checkpoint; daemon exits; client stays open

sanad-dev run agent
  daemon restores the same work once; client reconnects

sanad-dev stop all --force
  work is terminally cancelled, clients close, daemon exits, no later resume
```

## 5. سجل التقدم

```text
Date: 2026-07-30
Gate/status: implementation complete; live component/resume validation pending on a launcher started from the new source
Files changed: component parser/control/supervisor/log terminal, daemon pause/cancel boundary, focused tests, contracts, design/developer/QA docs
Verification: script analyzer passed; client analyzer passed; Agent analyzer passed; 77 script tests passed; 73 focused Agent interface/recovery tests passed; full client suite passed (783); full Agent suite passed with runtime gateway variables removed (950, 2 skipped); temporary isolated daemon `/shutdown?mode=pause` returned safe and its supervisor exited; Graphify updated
Findings: live `stop client -d macos` against the pre-change launcher timed out without mutation; the stale request was removed and timeout cleanup was added/tested. Loading the new component supervisor requires ending that old launcher, which would interrupt the current Agent session. Concurrent unrelated worktree edits were preserved.
Next gate: from a fresh session, start the launcher from this source and run the live matrix: stop/run client, stop/run Agent with a resumable active turn, then force-cancellation smoke.
```

```text
Date: 2026-08-03
Gate/status: C1/C2 live component matrix complete; C3 resumable-work and force-cancellation validation remains
Files changed: wrapper worktree redispatch, silent Flutter readiness, active-Home ownership resolution, cold-start polling/control timeout, POSIX atomic control publication, bounded interactive Client history, focused regressions and docs
Verification: `sanad-dev run --home user` started one managed Agent/Client group; bounded Agent and Client logs succeeded; `stop client` retained Agent and `run client` rejoined it; `stop agent` retained Client and `run agent --home user` succeeded after a roughly two-minute cold start; Client `r`/`R` performed reload/restart; Agent `r`/`R` each performed supervised restart; script and Client analyzers passed; all 111 script tests passed with one platform skip; full Client fast suite passed with 898 tests and one platform skip; Graphify updated
Findings: the previous 30-second missing-Agent start timeout raced the requester's cleanup, and a redundant POSIX chmod after atomic rename could fail after immediate consumer deletion, terminating the supervisor and its Client. Both boundaries are now time-aligned and race-safe without relaxing owner-only permissions.
Next gate: run the remaining active-work pause/resume and `--force` cancellation scenarios before marking Task 63 complete.
```
