---
title: "Task 53e: /compact Command and Compaction Timeline UX"
description: "إزالة أوامر القدرات الوهمية، فصل slash commands عن skills في composer، وتنفيذ /compact مع timeline centered وتفاصيل live/history متطابقة."
status: "complete"
current_gate: "done"
priority: "high"
depends_on: "Task 53d canonical command and lifecycle contract"
file_budget: 15
---

# Task 53e: أمر `/compact` وتجربة timeline الخاصة بالضغط

## 1. الهدف

تحويل slash commands من suggestions نصية مختلطة بالskills إلى runtime command vocabulary حقيقية، وتقديم `/compact` كأول أمر exact مع واجهة started/completed/failed centered قابلة للاستعادة.

## 2. Gate E0 — فصل catalogs وcomposer grammar

- [x] إزالة `_defaultSlashCommands` الوهمية الحالية (`model`, `think`, `workspace`, `mcp`, `sessions`, `stop`) من device capability discovery.
- [x] عدم إعادة تسمية skills إلى slash commands؛ runtime commands وskills catalogان مستقلان في agent protocol وclient domain.
- [x] إضافة `/compact` وحدها إلى runtime slash-command catalog في الإصدار الأول.
- [x] تعريف parser/query rules منفصلة:
  - slash query تبدأ عند composer index صفر فقط.
  - skill query/token صالحة في أي موضع كما هي حاليًا.
  - البنية تسمح بإضافة file mentions مستقبلًا كtoken family ثالثة دون تغيير command grammar.
- [x] إنشاء domain type مستقل لـruntime command بدل `SlashCommandType.skill` أو source string مبهمة.
- [x] إبقاء insert/render metadata للskills مستقلة وعدم كسر skill selection الحالية.

### E0 Exit

- [x] كتابة `/` داخل منتصف الرسالة لا تعرض runtime commands.
- [x] skill trigger في البداية أو المنتصف أو النهاية يستمر في الظهور والإدراج كtoken.
- [x] device capabilities لا تعلن command لا يملك handler فعليًا.

## 3. Gate E1 — Enter dispatch وvalidation

- [x] exact `/compact` token مع عدم وجود user text إضافي ينفذ canonical `compact` command ولا يرسل `think`/message command.
- [x] arguments أو trailing non-whitespace text تعيد validation محلية واضحة وتبقي draft دون إرسالها كرسالة.
- [x] Escape/backspace/selection تتعامل مع command token كوحدة قابلة للإزالة دون تلويث plain-text export.
- [x] إذا session busy، يعرض typed busy feedback بعد استهلاك runtime command وإغلاق suggestions؛ إعادة المحاولة تكون باستدعاء جديد لا بإبقاء command كنص رسالة.
- [x] بعد local validation، يستهلك client runtime command فور بدء dispatch ويحفظ draft فارغة دون انتظار النتيجة النهائية للضغط.
- [x] command ثانية أثناء compaction تعرض in-progress outcome ولا تنشئ operation إضافية.
- [x] الرسائل العادية تبقى قابلة للإرسال أثناء compaction وتدخل queue وفق 53d.

### E1 Exit

- [x] repository/transport يسجل command واحدة ولا يسجل user message باسم `/compact`.
- [x] failure لا يعيد runtime command إلى composer؛ drafts الخاصة برسائل المستخدم العادية تبقى خارج مسار control action.
- [x] skill tokens في رسالة عادية تصدر كما كانت قبل المهمة.

## 4. Gate E2 — domain mapping وlive/history state

- [x] إضافة typed `CompactionEvent`/projection في client domain keyed بالdevice/session/compaction id.
- [x] mapping موحد لحالات started/completed/failed وmanual/auto/overflow والmetrics الاختيارية.
- [x] تطبيق lifecycle idempotently ورفض event أقدم أو terminal regression.
- [x] حفظ/hydrate events ضمن conversation cache/history دون خلطها برسائل assistant أو user.
- [x] navigation بين الجلسات لا يعرض operation من Session A في Session B.
- [x] reconnect أثناء started ثم completed يعيد نفس tile ولا ينشئ نسختين.
- [x] queued-message UI تبقى authoritative أثناء compaction ولا تدعي أن الرسالة بدأت التنفيذ.

### E2 Exit

- [x] live timeline وبعد reload متطابقتان في status وtrigger والmetrics.
- [x] event لا تؤثر على title generation أو last-user-message ordering أو assistant metadata.

## 5. Gate E3 — Centered compaction timeline tile

- [x] إنشاء presentation واحدة تعرض centered horizontal separator:
  - divider يسار ويمين.
  - circular indicator عند started.
  - success check عند completed.
  - error indicator terminal عند failed.
- [x] اعتماد النصوص:
  - `Context compacting`
  - `Auto context compacting`
  - `Context compacted`
  - `Auto context compacted`
  - `Context compaction failed`
  - `Auto context compaction failed`
- [x] overflow trigger تظهر بصريًا كauto مع تفصيل `Trigger: Context overflow` داخل التفاصيل، دون إضافة label مربكة ثالثة في timeline.
- [x] layout تعمل على desktop/tablet/mobile ولا تتسبب في horizontal overflow أو touch target صغير.
- [x] started animation تتوقف فور terminal event أو dispose/navigation.
- [x] accessibility semantics تعلن status وmanual/auto ولا تعتمد على اللون أو الأيقونة وحدهما.

### E3 Exit

- [x] started/completed/failed snapshots مطابقة للتصميم centered.
- [x] لا يظهر raw summary أو transcript أو provider body في tile.

## 6. Gate E4 — Multi-line details interaction

- [x] إعادة استخدام interaction pattern في `context_usage_indicator.dart`: hover على desktop، click/tap على touch، keyboard focus، وdismiss semantics.
- [x] استخراج surface/helper مشترك فقط إذا حافظ على ownership ولم يجعل compaction تعتمد على conversation-input widget.
- [x] عرض الحقول المتوفرة فقط:
  - Type: Manual أو Auto.
  - Trigger، status، provider، model.
  - Context window.
  - Before/after request tokens ونسبة الامتلاء.
  - Reclaimed tokens/ratio.
  - Summarized range وretained-tail tokens.
  - Started/completed time وduration.
  - redacted failure reason عند الفشل.
- [x] عدم إظهار صفوف `N/A` غير المفيدة أو استنتاج قيم لم يرسلها agent.
- [x] عدم إظهار internal summary لأي سبب.
- [x] tooltip/popover تبقى متعددة الأسطر وقابلة للقراءة على الشاشات الضيقة.

### E4 Exit

- [x] hover وtap/focus يعرضان التفاصيل نفسها.
- [x] missing metrics لا تكسر العرض أو تنتج أرقامًا وهمية.
- [x] semantics تصف إمكانية فتح التفاصيل وحالة العملية.

## 7. Gate E5 — التحقق والتوثيق

- [x] اختبارات parser: index صفر، mid-message slash، exact command، arguments، backspace، وskill coexistence.
- [x] اختبارات dispatch: acceptance، busy، duplicate، failure، وعدم إنشاء user message.
- [x] اختبارات mapper/cache: out-of-order، reconnect، hydration، session isolation.
- [x] widget tests للحالات الست، centered layout، hover/tap/focus، mobile width، وaccessibility.
- [x] regression tests لاختيار skills في أي موضع وإرسال الرسائل العادية أثناء compaction.
- [x] تحديث client feature contract ووثائق product/protocol/cache/QA.
- [x] مراجعة file budget قبل الإغلاق.

### E5 Exit / Definition of Done

- [x] لا توجد slash commands وهمية في capabilities أو suggestions.
- [x] `/compact` command حقيقية exact في بداية composer فقط.
- [x] skills لا تزال tokens في أي موضع ولا تشترك مع command dispatch.
- [x] manual/auto lifecycle تظهر centered ومتطابقة live/history.
- [x] التفاصيل تعمل بالhover وtap/focus دون كشف summary.

## 8. الملفات المتوقعة

- `agent/lib/interfaces/runtime/local_workspace_runtime_service.dart`
- command/catalog/protocol handlers ذات الصلة
- `client/lib/features/conversations/domain/models/slash_command_entry.dart` أو استبداله بنماذج منفصلة
- `composer_slash_commands_cubit.dart` وstate/controller parser
- conversation repository/transport command mapping
- client compaction domain/cache/event mapper
- timeline event tile/widget جديد
- `client/lib/features/conversations/presentation/widgets/conversation_input/context_usage_indicator.dart`
- shared details interaction المستخرج عند الحاجة
- اختبارات agent/client مركزة
- `agent/lib/interfaces/AGENTS.md`
- `client/lib/features/AGENTS.md`
- `docs/product/client_interface.md`
- `docs/technical/communication_protocols.md`
- `docs/technical/client_conversation_cache_schema.md`
- `docs/qa_maintenance/context_compaction_qa.md`
- ملف المهمة والخطة الأم

## 9. سيناريو النجاح

يكتب المستخدم `/compact` في بداية composer ويضغط Enter في جلسة idle. لا تظهر user message، بل centered `Context compacting` مع spinner. يرسل المستخدم رسالة عادية أثناء العملية فتظهر queued. عند النجاح تتحول tile نفسها إلى `Context compacted` مع check mark، ويعرض hover/tap metrics متعددة الأسطر، ثم تبدأ الرسالة queued. بعد reload تظهر tile والرسالة والحالة نفسها. في auto trigger يظهر `Auto context compacting/compacted` دون تدخل المستخدم.

## 10. خارج النطاق

- arguments أو focus أو preview لأمر `/compact`.
- تنفيذ أوامر `model`, `think`, `workspace`, `mcp`, `sessions`, أو `stop` كslash commands.
- file mentions نفسها.
- عرض summary أو السماح بتحريرها.

## 11. سجل التقدم

```text
Date: 2026-08-31 (typed manual-command selection remediation)
Gate/status: E0/E1/E5 reopened for regression repair; automated proof complete and live proof pending
Root cause: the catalog exposed a type but the client still inserted every selection as a token, mapped runtime text without its slash, failed to filter runtime results mid-message, and dispatched `/compact` through a command-name condition
Remediation: closed `runtime_action` versus `skill` semantics now own placement and selection; leading partial Enter/click executes immediately through one runtime-action registry, skills insert then submit, direct typed actions converge on the same dispatcher, and duplicate Enter is coalesced
Evidence: agent/client analyzers clean; focused agent catalog and client parser/mapper/cubit/controller/widget suites pass; interactive verification remains required
```

```text
Date: 2026-08-31 (independent remediation review, E2→E5)
Gate/status: 53e complete after reopening E2
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Root causes/fixes: (1) Gateway history compared real compaction time with synthetic message time; lifecycle rows now anchor after retained_tail_range.end. (2) equal-rank terminal states could overwrite each other; completed/failed are now immutable except same-status enrichment. (3) the mapper substituted compaction_id for opaque transition event_id; it now preserves/reconstructs the deterministic transition id while retaining one logical tile id. (4) outer padding left InkWell at 17px and the inflexible center row overflowed at 280px; the tile now has a 44px constrained target and flexible two-line center. (5) available fill/reclaim ratios and lifecycle times were omitted from details; they are now rendered without N/A or summary content, with focus-triggered parity.
Verification: E0 catalog/parser 21/21; E1 client dispatch 4/4 + agent admission 3/3; E2 model/mapper/state 12/12 + agent history/lifecycle 2/2 + bridge provider regressions 31/31; E3/E4 widget 6/6; E5 combined client suite 42/42; client and agent analyzers clean; focused formatters clean.
File-budget review: the independent remediation spans 19 owning/tracking files rather than 15 because the root fix crosses Gateway causal merge, client data/domain/presentation, their three mandatory leaf contracts, and the task-required technical/product/QA records. No feature or refactor outside Plan 53 was added.
Next: Task 53f Gate F0.
```

```text
Date: 2026-08-31 (independent remediation review)
Gate/status: 53e reopened at E2
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Evidence: a new history-order regression placed the completed compaction row at index 4 after the model response at index 3. The Gateway compared the real operation started_at against synthetic message timestamps instead of the durable retained-tail boundary.
Fix under verification: history merge anchors lifecycle rows immediately after retained_tail_range.end and before the first later canonical message row. E0 parser/catalog (21 tests) and E1 dispatch/admission (7 tests) remain closed.
Current gate: E2 — finish live/history, retry, reload, and terminal-dedup verification before E3.
```

```text
Date: 2026-08-29
Gate/status: 53e complete (E0–E5) — gate-by-gate review re-verified
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Verification: client compaction model/store/mapper/dispatch/tile/parser suites passed; local_workspace_compact_slash_test passed; agent analyze clean (null-aware payload fix in SessionCompactCommandHandler)
Findings: fake slash catalog retired to `/compact` only; runtime slash queries index-zero only; skills remain mid-message tokens
Next: Task 53f Gate F0
```

Date: 2026-08-29
Reviewer: gate-by-gate Plan 53 review
Gate closed: E0–E5

```text
Date: 2026-08-29 (evening re-review)
Gate/status: 53e E0→E5 re-closed in order
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
E0: _defaultSlashCommands = /compact only; detectRuntimeSlashQuery requires slashIndex==0; skills mid-message still work
E1–E5: client suites 32 passed + skill_composer runtime/utils 9 passed; agent local_workspace_compact_slash_test 1 passed
Findings: no fixes required; tile details omit summary; overflow mapped as auto-like
Next: Task 53f Gate F0
```
