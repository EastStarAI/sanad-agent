---
title: "97x: إزالة عوائق تنفيذ الخطة"
status: active-non-blocking-follow-up
current_gate: "G2 (batches 1–3 independently accepted; remaining backlog does not block Plan97 merge unless a specific item directly blocks the active product gate or CI)"
remaining_estimate: "future Plan97 blockers"
platforms: windows-first, cross-platform-when-affected
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
execution_worktree: plan-97-aggregation
delegated_authority: "user-authorized closure, commit/push, separated PR delivery, and squash-merge by reviewer agy"
---

# 97x — إزالة عوائق تنفيذ الخطة

## Goal

مسار مفتوح لتسجيل وإزالة عوائق سير العمل دون خلطها مع تغييرات المنتج التي تملكها 97c–97l. backlog هذه المهمة غير مانع لدمج Plan97 ويُستكمل بعد الدمج؛ الاستثناء الوحيد عائق محدد مثبت يمنع بوابة المنتج الحالية أو CI مباشرة. يشمل عوائق التفويض، supervisor، المهارات، التشغيل المتوازي، CI، و`sanad-dev` عندما تعيق runtime أو الاختبارات أو logs أو الاسترداد.

## Ownership

- تُنفذ هذه المهمة في worktree التجميع لـPlan97 نفسها، لا في worktree فرعية.
- كل عائق جديد يضاف إلى backlog هنا بعد دليل حقيقي، ثم يصلح في أصغر طبقة مالكة مع regression ووثائق.
- يجوز للمراجع المستقل كتابة بند جديد هنا لتحسين جودة الكود أو فصل المسؤوليات أو تقسيم ملف كبير، لكن بعد triage تنسيقي سريع يثبت أن البند يقلل تعقيد/زمن/مخاطر تنفيذ قائمة المهام الحالية؛ لا تنظيف معماري عام بلا أثر تشغيلي مباشر.
- لا تستخدم المهمة لتوسيع نطاق المنتج أو إخفاء فشل؛ العائق الذي تملكه مهمة 97 أخرى ينقل إليها بدل التكرار.
- تبقى `active` حتى إغلاق Plan97، وتعالج العوائق على دفعات صغيرة قابلة للمراجعة.

## Current backlog

- [x] **Three-role orchestration contract (batch 1):** aligned in `sanad-orchestrator` (non-blocking orchestrator, summary-then-continue), `sanad-subagent-developer` (scoped implementer, Draft PR after first accepted gate), `sanad-pull-request-review` (independent reviewer on provider `ChatGPT` / model `gpt-5.6-sol`, fail-closed, repair/commit/push/update Draft PR), and `sanad-pull-request-lifecycle` (Draft gate flow). Ready/merge/protected labels remain authorization boundaries.
- [x] **Explicit Home propagation (batch 1):** supervisor spec accepts `home` for Sanad tasks, validates it (absolute, existing directory), rejects duplicate `--home` in args, and injects `--home` into the worker invocation; recorded in the manifest. Tests cover attachment (mock argv) and all failure paths without tokens or a second runtime.
- [x] **Bootstrap diagnostics (batch 1):** `bootstrap check` now distinguishes a missing installed CLI from a validated source-development fallback (checkout entry + fvm/dart launcher) and reports actionable, non-blocking diagnostics in both text and JSON.
- [x] **Bounded PR-check monitor (batch 1):** Pure-Dart `scripts/workflow_guards/bin/pr_checks_watch.dart` — 5s interval, fail-fast on first failure, 7-minute maximum, bounded output, preserved exit status, Windows-safe without `for /f`, fully tested with a fake `gh`.
- [x] **Quiet watch continuity (batch 1):** documented caller-timeout ≠ worker-failure re-entry from the cursor with bounded status; regression added to the supervisor suite.
- [x] **Windows merge/quoting safety (batch 1):** fail-closed procedure in `sanad-pull-request-lifecycle` (reconstruct base/ours/theirs via `git show :1:/:2:/:3:`, reject markers/corrupt syntax before stage, focused validation) plus tested `scripts/workflow_guards/bin/merge_validate.dart`. No broad merge framework.
- [x] **Maintainability blockers (batch 1):** reviewer may propose SRP/large-file blockers; orchestrator quick triage admits them to this backlog only with a direct reduction in active-plan execution time/complexity/risk. Mechanism documented in `sanad-orchestrator` and `sanad-pull-request-review`.
- [x] **Monitoring observability and stalled-session triage (batch 2):**
  - Full ISO date/time/timezone on observed events (`YYYY-MM-DDTHH:mm:ss.sssZ`), with strict distinction between source timestamps, receipt timestamps (`(received: <ISO>)`), and unknown historical timestamps (`[unknown time]`), never synthesizing fake timestamps from file mtime.
  - Persistent nonterminal session state & cause tracking (`working`, `waiting`, `blocked`, `resuming`, `needs_input`, `needs_permission`) across Agent runtime artifacts (`run_artifacts.dart`, `oneshot_runner.dart`) and supervisor (`supervisor.mjs`), with strict terminal latching (monotonicity) preventing terminal states from being overwritten.
  - Authoritative classification of provider timeout (`provider_timeout`), rate limits, network, quota, and authentication errors from structured code/notices.
  - Bounded session observability footer for `status`, `logs`, and `timeline` displaying true known session state, cause, state-since, last progress, elapsed duration, observation source, and current time. Existing JSON consumers remain fully compatible.
  - Observer cancellation tracking in `observers/<pid>.json` capturing start and cancellation cleanly; if hard kill prevents end recording, end time remains unknown rather than manufacturing an artificial duration.
  - Reviewer repair: snake_case runtime artifact fields are consumed correctly; legacy terminal timeout uses its observed terminal time and `timeout` cause rather than launch time/`-`; PID liveness alone reports `unknown`; structured cause codes are authoritative; progress writes are throttled and never persisted per token; default `watch-once` surfaces blocked/waiting/resuming; static logs distinguish source timestamps from unknown time.
- [x] **Bounded verification timer/log follow-up (batch 3):** Pure-Dart runner in `scripts/workflow_guards/bin/verify.dart`, `scripts/workflow_guards/lib/bounded_verify.dart`, `scripts/workflow_guards/lib/src/bounded_verify.dart`, and `scripts/workflow_guards/test/bounded_verify_test.dart`. Measures elapsed wall time in milliseconds, bounds console output to final tail lines (default 5) plus 1-line summary, writes full stdout/stderr to a unique temporary log file, preserves exact child exit code, and handles Windows batch/executable invocation safety. Fully tested with unit and end-to-end CLI tests (9/9 pass, 33/33 in package).
- [ ] **Bounded command and monitor output (future batch — uncompleted):** عائق تشغيلي ملحوظ فعلياً أثناء مراقبة المهام وسير العمل:
  - **الملاحظة الفعلية (Observed obstacle):**
    - أداة `pr_checks_watch` طبعت رسائل استطلاع دورية (poll) كل 5 ثوانٍ مما لوّث المخرجات.
    - أمر `supervisor status` أعاد تاريخاً مطولاً (verbose history) ملأ سياق المحادثة (context flood).
  - **معيار المعالجة المطلوب للدفعة المستقبلية:**
    - المخرجات الافتراضية مقيدة وموجزة (default bounded summary / changes / final).
    - التفاصيل وسجلات التتبع الموسعة اختيارية صراحة (details opt-in).
    - السجلات والبيانات الكاملة محفوظة دون اقتطاع في ملفات logs مخصصة (full logs preserved).
    - الحفاظ التام والدقيق على رمز الخروج للعملية (exit code preserved).
  - **حالة البند:** مجدول كدفعة مستقبلية قيد الانتظار (future batch — uncompleted)؛ هذا التوثيق لحصر العائق وتعميم معيار القبول فقط دون تنفيذ أي كود برمجي أو ادعاء قياسات في هذه المرحلة.
- [ ] **Result data fidelity and semantic terminal validation (future batch — uncompleted):** عائق دقة بيانات نتائج المهام والنجاح الدلالي الزائف (Semantic false success):
  - **الملاحظة الفعلية والدليل (Observed obstacle & evidence):**
    - مهمة `97f` أبلغت عن حالة `completed` مع رمز خروج `exit 0`، لكن حقل `finalMessage` احتوى على رسالة تقدم مرحلية فقط (progress: مثل «جاري...») دون أي خلاصة أو نتيجة نهائية فعلية للمهمة.
  - **الخلل الجذري ومعيار المعالجة المطلوب للدفعة المستقبلية:**
    - مجرد مطابقة الـ schema شكلياً (`schema-valid`) لا تكفي لضمان صحة النتيجة أو اكتمالها.
    - الفصل الصارم بين رسائل التقدم المؤقتة (`progress`) والرسالة الختامية (`finalMessage` / final summary).
    - منع حالات النجاح النهائي الدلالي الناقص (incomplete semantic terminal success)؛ إتمام العملية تقنياً مع مخرجات مبتورة يُعد خللاً في دقة البيانات.
  - **معيار القبول الصريح (Acceptance Criteria):**
    - غياب النتيجة أو الخلاصة الختامية (`missing final`) يجب أن يوسم النتيجة كـ `incomplete` أو `needs_review` أو كفشل صريح (`explicit failure`)، ويمنع اعتبارها نجاحاً نهائياً.
    - إضافة وتطبيق اختبارات تعاقدية (`contract tests`) تمنع النجاح الزائف (`false success`) وتتحقق دلالياً من اكتمال مخرجات النتيجة.
  - **حالة البند:** مجدول كدفعة مستقبلية قيد الانتظار (future batch — uncompleted)؛ توثيق لحصر العائق وتحديد معيار القبول الدلالي دون تنفيذ إصلاح كود الآن.
- [ ] **Self-healing `sanad-dev status` setup (future non-blocking batch):**
  - **الملاحظة الفعلية:** `sanad-dev status` يفشل كثيرًا برسالة تطلب تشغيل `sanad-dev setup` يدويًا بدل إكمال طلب الحالة.
  - **السلوك المطلوب:** عندما يثبت status أن setup مطلوب وقابل للإصلاح الآمن، يطبع سطر log موجزًا يوضح أن setup مطلوب، يشغّل setup تلقائيًا مرة واحدة، ثم يعيد محاولة status ويعرض مخرجات status الطبيعية فقط؛ لا يعيد payload الطويل الخاص بـsetup في المسار الناجح.
  - **حدود الأمان:** لا loop أو retry غير مقيد، ولا إخفاء لفشل setup؛ failure يعرض سببًا موجزًا وقابلًا للتنفيذ ويحافظ على exit code. لا source switch أو runtime restart أو إنشاء runtime إضافية، ولا auto-setup لأخطاء ownership/security/explicit-home غير القابلة للإصلاح.
  - **القبول:** اختبارات تغطي setup-required→setup-success→normal-status، setup failure، repeated failure/no-loop، JSON/text output، ومخرجات bounded؛ يبقى البند متابعة بعد دمج Plan97 ما لم يمنع بوابة حالية مباشرة.
- [ ] **Supervisor watch-once stalled-error wakeup (batch 4):** إذا كان الأوركستريتور في وضع المراقبة وحدث خطأ داخل محادثة الوكيل الفرعي (`blocked`, provider timeout, invalid request, gateway loss, or stopped/failed) ثم بقيت المحادثة بلا تعافٍ تلقائي لأكثر من 60 ثانية، يجب أن يعود `watch-once` فورًا بحدث قابل للتصرف بدل الاستمرار في الانتظار حتى انتهاء نافذة المراقبة. هذا يمنع حالة مراقبة مضللة حيث يبدو العمل جارياً بينما الوكيل متوقف، كما حدث أثناء مراقبة 97h بعد `provider_timeout`. DoD: regression يثبت أن الأخطاء العابرة الأقصر من 60 ثانية لا توقظ المراقب إذا تعافت، وأن الخطأ المستمر لأكثر من 60 ثانية يوقظ `watch-once` مع task/session/cause/state-since وبدون scheduled polling.
- [ ] **Future blockers:** أي خلل مثبت في `sanad-dev` أو delegation/supervisor/skills/CI يعطل العمل أو الاختبارات أو logs أو ownership يضاف هنا قبل إصلاحه.

## Gates for each batch

### G0 — Triage

- [ ] سجل reproduction، التأثير، الطبقة المالكة، والاعتماديات؛ ارفض التخمين والتكرار مع مهام المنتج.

### G1 — Repair

- [ ] أصلح أصغر سطح مالك، وحدّث skill/docs/contracts المتأثرة فقط، وأضف regression للحالة الحقيقية ومسار الفشل.

### G2 — Acceptance

- [ ] analyzer/syntax والفحوص المركزة تنجح؛ شغّل full suite فقط إذا عُيّنت لهذه الدفعة.
- [ ] أثبت أن workflow المتعطل يعمل end-to-end دون workaround مؤقت أو تخفيف أمان.
- [ ] راجع المخرجات والأسرار والمسارات المولدة، ثم حدّث backlog وحالة الأب والأدلة.

## Acceptance criteria

- **معيار المخرجات المقيدة (Bounded Output Standard):** المخرجات الافتراضية لأدوات المراقبة والأوامر تكون مقيدة وموجزة حصرًا (default bounded summary / changes / final)، والتفاصيل الموسعة والتاريخ المطول اختيارية صراحة (details opt-in)، مع حفظ السجلات الكاملة في ملفات logs مخصصة (full logs preserved)، والحفاظ الدقيق على رمز الخروج (exit code preserved / صحيح).
- **معيار دقة النتائج والتحقق الدلالي (Result Fidelity & Semantic Acceptance):** مجرد مطابقة الـ schema شكلياً (`schema-valid`) لا تكفي؛ يجب فصل الـ progress عن الـ final، ومنع النجاح النهائي الدلالي الناقص (terminal success). عند غياب الخلاصة النهائية (`missing final`)، يجب تصنيف النتيجة كـ `incomplete` أو `needs_review` أو فشل صريح (`failure`)، مع فرض اختبارات تعاقدية (`contract tests`) تمنع النجاح الزائف (`false success`).
- العائق المثبت لا يتكرر في السيناريو نفسه، ويعطي الفشل المستقبلي رسالة fail-closed قابلة للتنفيذ.
- لا runtime إضافية على Home واحدة، ولا workspace mutation، ولا source handoff ضمن الإصلاح.
- لا polling مجدول غير مقيد في المخرجات، ولا انتظار blocking داخل الأوركستريتور، ولا تكرار full suites بلا invalidation.
- العوائق المستقبلية تبقى مرئية هنا حتى الإصلاح أو التأجيل المعلل.

## Evidence

### Batch 4: Deterministic run_delegation nonterminal/allow-all-tools waits (urgent CI fix)

- **Obstacle:** In `agent/test/cli/run_delegation_test.dart` the `needs_input`/`needs_permission` surfacing test and the `--allow-all-tools`-leaves-`system_ask_user`-pending test waited on the oneshot runner's serialized, asynchronous artifact writes and permission handling via hardcoded `Future.delayed(30ms)` sleeps. Under slow/parallel CI those sleeps race the async record queue and intermittently observe `readResult() == null` or a stale status — a timing flake, not a weak assertion.
- **Repair (smallest owning fixture, machine contract preserved):** Added a bounded `waitFor(predicate)` helper plus `_statusIs(outDir, status, {requestId})` to the test fixture and replaced every timing sleep in these tests with a wait on the *actual* emitted contract condition (`result.json` status + `pending_intervention` fields, or `permissionResponses` count). Initial-start waits now await `fakeClient.turnDispatched` instead of a fixed delay. None of the assertions were weakened; step-specific assertions on status/`pending_intervention`/`tool_name`/`sessionId`/auto-approval counts remain byte-for-byte intact.
- **Files changed:** `agent/test/cli/run_delegation_test.dart` (fixture only; no production source change).
- **Focused regressions (run on Windows, real fvm):** `fvm dart test test/cli/run_delegation_test.dart` — 21/21 pass, repeated 5× (stable); `fvm dart analyze test/cli/run_delegation_test.dart` — 0 issues. Blast radius: `fvm dart test test/cli/run_delegation_test.dart test/cli/run_command_test.dart test/cli/session_command_test.dart test/cli/run_artifacts_test.dart` — 77/77 pass; `fvm dart analyze lib/cli test/cli` — 0 issues.
- **Constraints honored:** no production source change, no weakened assertions, no second runtime, no source switch.

### Batch 1 (implemented in the Plan97 aggregation worktree, branch `perf/97-windows-first-performance`)

- **Files changed:** `.agents/skills/delegate-task-supervisor/{SKILL.md,scripts/supervisor.mjs,scripts/bootstrap.mjs,test/supervisor_test.mjs,test/bootstrap_test.mjs}`; `.agents/skills/{sanad-orchestrator,sanad-subagent-developer,sanad-pull-request-review,sanad-pull-request-lifecycle,sanad-delegate}/SKILL.md`; `scripts/workflow_guards/**` (new Pure-Dart package); `docs/agent_engine/sanad_delegate_relay.md`; `docs/operations/developer_guide.md`; `docs/plans/97-windows-first-agent-client-performance.md` (parent reconciliation); this file.
- **Focused regressions (run on Windows, real fvm):**
  - `node --test test/supervisor_test.mjs` in `delegate-task-supervisor` — 17/17 pass after independent review repairs (including Home propagation, watch continuity, observability, legacy timeout, log timestamps, and observer cancellation), 20.497s.
  - `node --test test/bootstrap_test.mjs` — 2/2 pass, ~0.3s.
  - `cd scripts/workflow_guards && fvm dart pub get && fvm dart analyze && fvm dart test` — focused analyzer clean; accepted PR-check/merge suites 24/24 pass in 8.032s. The separate bounded-verification files are excluded and pending.
- **CLI smoke:** `merge_validate` rejects corrupt JSON (exit 4) and passes clean Markdown (exit 0); `pr_checks_watch --gh <missing>` fails closed with exit 2; fake-`gh` scenarios cover success/pending/fail-fast/timeout/exit-8/parse/missing/metachar.
- **Constraints honored:** no commit/push (candidate left for the independent ChatGPT/gpt-5.6-sol reviewer), no second runtime, no tokens, no scheduled polling, no source handoff, no CI/`.github` changes, `git diff --check` passes. The recurring 97x task stays `active`; only the resolved blocker items are checked off.

### Batch 2 (implemented in the Plan97 aggregation worktree, branch `perf/97-windows-first-performance`)

- **Files changed:**
  - `agent/lib/cli/artifacts/run_artifacts.dart`
  - `agent/lib/cli/oneshot/oneshot_runner.dart`
  - `agent/test/cli/run_artifacts_test.dart`
  - `.agents/skills/delegate-task-supervisor/scripts/supervisor.mjs`
  - `.agents/skills/delegate-task-supervisor/test/supervisor_test.mjs`
  - `docs/plans/tasks/97x-workflow-obstacle-removal.md`
- **Focused regressions (run on Windows, real fvm & node):**
  - Agent run artifacts & nonterminal transitions: `fvm dart test test/cli/run_artifacts_test.dart` — 9/9 pass in 7.271s (monotonic latching, nonterminal notices, structured cause classification, throttled progress persistence, exact-millisecond timestamps, terminal precedence).
  - Agent CLI commands: `fvm dart test test/cli/run_delegation_test.dart` (21/21 pass), `fvm dart test test/cli/run_command_test.dart` (25/25 pass), `fvm dart test test/cli/session_command_test.dart` (22/22 pass).
  - Agent analyzer: `fvm dart analyze lib/cli test/cli` — 0 issues found.
  - Supervisor: `node --test test/supervisor_test.mjs` — 17/17 pass in 20.497s (including timeline/log ISO/unknown formatting, snake_case footer resolution, PID-not-progress handling, blocked/resuming watch wakes, JSON compatibility, and observer start/cancellation timing without manufactured duration).
  - Supervisor bootstrap: `node --test test/bootstrap_test.mjs` — 2/2 pass.
- **Live smoke verification:**
  - `node scripts/supervisor.mjs timeline --run C:/Users/aatia/.sanad-delegations/plan97/run --task plan97x-timed-tests-followup` rendered full ISO timestamps, terminal timeout transition, and the session footer (`stopped`, elapsed `2h 0m 15s`, source `result.json (process exited)`).
- **Independent review evidence (ChatGPT / `gpt-5.6-sol`):** Agent CLI analyzer passed in 11.227s; run-artifact regressions passed 9/9 in 7.271s; delegation regressions passed 21/21 in 7.936s; supervisor passed 17/17 in 20.497s; bootstrap passed 2/2 in 0.416s; accepted workflow-guard analyzer passed in 11.236s and tests passed 24/24 in 8.032s. Unique temporary log paths are retained in the reviewer handoff rather than tracked documentation.
- **Replay limitation:** the historical `plan97x-timed-tests-followup` artifact replay now reports `stopped`, `Cause: timeout`, terminal state-since, and unknown last progress. This is proof of formatter/fallback behavior only; source checkout differs from the running daemon, so no live-runtime claim is made. The `.sanad-test` Agent/Client was not stopped or restarted.
- **Constraints honored:** no second runtime or source switch invoked; no secrets or tokens logged; backwards compatibility for JSON consumers intact; 97x task remains `active`.

### Batch 3: Bounded verification runner (implemented and independently reviewed in the Plan97 aggregation worktree)

- **Files changed:**
  - `scripts/workflow_guards/bin/verify.dart` (CLI runner: async/await, exit preservation, bounded tail output)
  - `scripts/workflow_guards/lib/bounded_verify.dart` (public library export)
  - `scripts/workflow_guards/lib/src/bounded_verify.dart` (bounded execution core: allowMalformed UTF-8, Future.wait stream completion, direct PATH extension resolution, directory creation)
  - `scripts/workflow_guards/test/bounded_verify_test.dart` (unit and CLI regressions)
  - `scripts/workflow_guards/test/fixtures/failing_test_fixture.dart` (reproducible failing test fixture for runner proof)
  - `scripts/workflow_guards/test/pr_checks_monitor_test.dart` (robust timeout under Windows subprocess latency)
  - `scripts/workflow_guards/README.md` (CLI documentation for `verify`)
  - `docs/plans/tasks/97x-workflow-obstacle-removal.md`
- **Focused regressions (run on Windows, real fvm):**
  - Full package suite: `cd scripts/workflow_guards && fvm dart test` — 33/33 pass in 2.0s.
  - Analyzer: `cd scripts/workflow_guards && fvm dart analyze` — 0 issues found.
  - Supervisor suite: `cd .agents/skills/delegate-task-supervisor && node --test test/supervisor_test.mjs` — 17/17 pass in 22.2s.
  - Bootstrap suite: `cd .agents/skills/delegate-task-supervisor && node --test test/bootstrap_test.mjs` — 2/2 pass in 0.35s.
- **Live CLI smoke proof (real passing and real failing tests):**
  - Real passing test execution: `fvm dart run bin/verify.dart --tail 5 -- fvm dart test test/merge_validator_test.dart` — elapsed 11407ms, exit 0, console output bounded to 5 lines of stdout plus single summary line, full output captured in untracked temporary log file (`verify-...-b5b19a.log`).
  - Real failing test execution: `fvm dart run bin/verify.dart --tail 5 -- fvm dart test test/fixtures/failing_test_fixture.dart` — elapsed 7067ms, exit 1, console output bounded to 5 lines of stdout plus single summary line, full failure assertion (`Expected: <3>, Actual: <2>`) and stack trace captured in untracked temporary log file (`verify-...-915824.log`). Not a 0-test filter (exit 79), but an actual test assertion failure (exit 1).
- **Independent review repairs (agy):**
  - UTF-8 decode safety: added `allowMalformed: true` to prevent unhandled `FormatException` on malformed bytes or OEM codepage output from Windows child processes.
  - Stream lifecycle safety: synchronized process exit and output streams via `Future.wait([process.exitCode, stdoutFuture, stderrFuture])`.
  - PATH lookup robustness: checked direct `$dir\$command` existence before appending `pathext` entries so commands already containing extensions (e.g. `fvm.bat`, `git.exe`) resolve cleanly.
  - Log persistence safety: ensured target directory exists via `Directory(logDir).createSync(recursive: true)`.
  - Modernized entrypoint: converted `bin/verify.dart` `main` to `Future<void> main` with async/await and structured try/catch.
  - Test robustness: adjusted `pr_checks_monitor_test.dart` timeout to 600ms and assertion to `>= 2` polls to absorb Windows subprocess startup latency without flakiness.
- **Delegated delivery path:**
  - Per direct user authorization, 97x changes (Batches 1–3) are delivered via a clean branch isolated from unfinished Plan97 product tasks (97a, 97b, 97i) to protect `main` stability.
  - No second runtime, source switch, or daemon/Client stop was performed.
  - Task 97x remains `active` in the Plan97 aggregation worktree for future workflow obstacles.
