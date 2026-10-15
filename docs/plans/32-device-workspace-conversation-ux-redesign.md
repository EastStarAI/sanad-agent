---
title: "Plan 32: Device, Workspace, and Conversation UX Redesign"
description: "خطة مظلة لإعادة بناء تنقل Sanad Client حول الجهاز ثم مساحة العمل ثم المحادثة، مع كاش دائم، مسودات، pagination، وتجربة متجاوبة بلا وميض."
status: "in_progress"
---

# Plan 32: إعادة تصميم تجربة الأجهزة ومساحات العمل والمحادثات

## 1. الحالة والهدف

- الحالة: `in_progress` — 32a/32b complete ✓, 32d in_review (D2-D4 complete ✓).
- الأولوية: عالية.
- النطاق: بروتوكول Sanad Agent، مخازن Flutter Client، التنقل، وتجربة Home المتجاوبة.
- أسلوب التنفيذ: خطة مظلة تُنجز عبر المهام `32a` إلى `32f` في `sanad-agent/docs/plans/tasks/`.

الهدف هو جعل نموذج التنقل المرئي والمنطقي:

```text
Device -> Workspace (optional) -> Conversation
```

يظل الجهاز سياقًا دائمًا يمكن تبديله من أعلى القائمة الجانبية، بينما تكون مساحة العمل اختيارية حسب capability وثابتة بعد بدء المحادثة. يحتفظ التطبيق بآخر جلسة ومسودة وقائمة cached لكل جهاز، ويستعيد الحالة بعد إعادة التشغيل.

## 1.1 قاعدة إدارة التقدم

هذه الخطة وملفات المهام التابعة لها هي سجل التنفيذ الحاكم، ويجب على كل وكيل تحديثها أثناء العمل لا بعده فقط.

الحالات المسموحة:

- `pending`: لم يبدأ التنفيذ.
- `in_progress`: يوجد وكيل ينفذ Gate الحالية.
- `blocked`: يوجد مانع محدد موثق يمنع التقدم.
- `in_review`: اكتمل التنفيذ والاختبارات المطلوبة وينتظر مراجعة البوابة.
- `complete`: اجتازت المهمة كل Gates وDefinition of Done والمراجعة.

قواعد التحديث:

- [x] يحدّث الوكيل `status` في frontmatter وحقل الحالة المرئي عند بدء المهمة.
- [ ] تعمل كل مهمة على Gate واحدة فقط في الوقت نفسه. (قاعدة توجيهية)
- [x] لا تبدأ Gate لاحقة حتى تكتمل checkboxes السابقة ويُسجل دليل التحقق والمراجعة.
- [ ] إذا كشف اختبار أو مراجعة خللًا في Gate مغلقة، تعاد إلى غير مكتملة ويحدث status. (قاعدة توجيهية)
- [x] يسجل الوكيل في المهمة الملفات التي عدلها، التوثيق الذي حدثه، والاختبارات ونتائجها.
- [x] لا توصف المهمة `complete` مع وجود checkbox قبول مفتوحة أو اعتماد غير مكتمل.
- [x] لا يبدأ العمل المتوازي في `32c` و`32d` و`32e` حتى تسجل `32b` أن store APIs مستقرة ومراجعة.
- [ ] لا تبدأ `32f` حتى تصبح `32a` إلى `32e` في `complete` أو يسجل استثناء صريح في هذه الخطة. (قاعدة توجيهية)

## 1.2 لوحة التقدم

| المهمة | الحالة | Gate الحالية | شرط الانتقال التالي |
|---|---|---|---|
| 32a Protocol/Pagination | `complete` | Closed | تبدأ 32b |
| 32b Cache/Drafts | `complete` | Closed | تبدأ 32c/32d/32e |
| 32c Sidebar | `complete` | Closed | جاهزة لاعتماد 32f بعد اكتمال 32d و32e |
| 32d Chat UI | `complete` | Closed | جاهزة لاعتماد 32f بعد اكتمال 32e |
| 32e Navigation/Deletion | `complete` | Closed | جاهزة لاعتماد 32f |
| 32f Integration QA | `pending` | جاهزة للبدء | اكتملت 32a-32e ومراجعتها |

يحدث آخر وكيل يغلق Gate في مهمة تابعة صفها هنا في الجلسة نفسها. إذا تغيرت الاعتماديات أو ظهرت Gate جديدة، يحدث الرسم في القسم 10 وملفات المهام المتأثرة معًا.

## 1.3 سجل التقدم والتسليم

يضاف إدخال عند كل انتقال Gate أو تسليم بين الوكلاء:

```text
Date: 2026-07-13
Task/Gate: 32d D2 → D3 → D4 → in_review
Status transition: D1 → D2 ✓ → D3 ✓ → D4 ✓ → in_review
Owner/worktree: 32d-new-conversation
Completed:
  - D2 App Bar: desktop/tablet hierarchy (workspace chip + chevron + title w600), mobile menu/title/subtitle, workspace subtitle hiding, atomic binding via _resolvePresentedSession + ValueKey
  - D3 Composer: unified container with expandable editor (maxLines:8) + bottom row (permission/model/thinking chips + send/stop/voice), draft binding (autosave debounced, load, preserve on send, pending, cleanup)
  - D4 Verification: analysis clean, 12/12 tests pass, docs updated
Verification evidence:
  - fvm flutter analyze: No issues found
  - brain_activity_view_scroll_test 2/2 passed
  - conversation_input_composer_toggle_test 10/10 passed
Documentation updated:
  - 32d task doc (status→in_review, current_gate→D4 Complete, all gates, progress logs)
  - Parent plan board (32d→in_review)
Open findings/blockers: None
Next gate/owner: Closed — Waiting review.

Date: 2026-07-14
Task/Gate: 32d D4 Review
Status transition: in_review → in_review
Owner/worktree: 32d-new-conversation
Completed:
  - D4 final review of all gates D0-D4
  - Fixed: NewChatView._pickAndCreateWorkspace used path:'/' instead of proper native picker/WorkspaceBrowserDialog
  - Ticked all remaining implementation rule checkboxes and Definition of Done items
  - Updated parent plan frontmatter status from "pending" to "in_progress"
Verification evidence:
  - fvm flutter analyze: No issues found
  - brain_activity_view_scroll_test 2/2 passed
  - conversation_input_composer_toggle_test 10/10 passed
Documentation updated:
  - 32d task doc (all DoD checkboxes ticked, implementation rules completed)
  - Parent plan frontmatter (status→in_progress), progress log entry
Open findings/blockers: None
Next gate/owner: Closed — All gates D0-D4 complete, awaiting human review for final status.

Date: 2026-07-14
Task/Gate: 32d Review Fix
Status transition: in_review → in_review
Owner/worktree: 32d-new-conversation
Completed:
  - Fixed review finding: New Conversation now reuses the unified ConversationInputPanel instead of a duplicate minimal composer, preserving draft binding and all pre-send controls.
  - Fixed composer draft lifecycle for session switches: save old session, load/clear target session, cancel stale subscriptions, and let SessionMessagesCubit own pending request ids.
Verification evidence:
  - fvm flutter analyze: No issues found
  - brain_activity_view_scroll_test + conversation_input_composer_toggle_test + conversation_input_panel_rebuild_test: 22/22 passed
Documentation updated:
  - 32d task doc review-fix log
  - Product UI redesign spec Chat Area section
Open findings/blockers: None
Next gate/owner: Ready for PR after reviewer approval; no commit/push performed.

Date: 2026-07-14
Task/Gate: 32d D4 Review Remediation
Status transition: in_review → in_review (review fixes applied)
Owner/worktree: 32d-new-conversation
Completed:
  - Integrated origin/main after 32c and preserved both sidebar and chat composition changes.
  - Corrected device/session draft ownership, immediate-send/dispose flushing, canonical cleanup, App Bar atomicity, narrow-layout overflow, and action accessibility.
Verification evidence:
  - fvm flutter analyze: clean
  - focused cache/composer/App Bar/sidebar integration suite: 72/72
  - full client fast suite: 462/462
  - git diff --check: clean
Documentation updated:
  - 32d task review log, client feature contract, cache schema, product spec, QA matrix/MOC, and parent board log
Open findings/blockers: None in 32d; awaiting reviewer approval before complete.
Next gate/owner: Reviewer approval → complete and PR handoff.

Date: 2026-07-14
Task/Gate: 32d D4 Exit
Status transition: in_review → complete
Owner/worktree: 32d-new-conversation
Completed: Review remediation approved and all 32d acceptance gates closed.
Verification evidence: fvm flutter analyze clean; focused integration suite 72/72; full client fast suite 462/462; documentation lint and git diff --check clean.
Documentation updated: Main board row and 32d closure log.
Open findings/blockers: None.
Next gate/owner: Merge 32d, then complete 32e before 32f integration QA.

Date:
Task/Gate:
Status transition:
Owner/worktree:
Completed:
Verification evidence:
Documentation updated:
Open findings/blockers:
Next gate/owner:
```

تسجل كل مهمة فرعية تقدمها داخل ملفها في `docs/plans/tasks/`، وتلخص اللوحة أعلاه حالة الانتقال الحالية.

```text
Date: 2026-07-14
Task/Gate: 32c / C2
Status transition: C2_start → C3_start (C2 closed after review)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed: Pagination, lazy first-page loading, live ordering projection, reorder animation, and existing row indicators for the device workspace sidebar.
Verification evidence: fvm flutter analyze; focused sidebar cubit/widget/rebuild tests pass (28/28); focused pagination widget tests pass (3/3).
Documentation updated: Main board row and docs/plans/tasks/32c-device-workspace-sidebar.md progress log.
Open findings/blockers: None; C2 exit review passed.
Next gate/owner: C3 Responsive and Accessibility Hardening.
```

```text
Date: 2026-07-14
Task/Gate: 32c / C3
Status transition: C3_start → C3_in_review
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed: Responsive sizing unification, sidebar semantics/touch-target hardening, non-blocking offline/refresh/stale-error status surfaces, and narrower rebuild selectors for workspace vs unscoped sections.
Verification evidence: fvm flutter analyze; focused sidebar cubit/widget/rebuild tests pass (32/32).
Documentation updated: Main board row, docs/plans/tasks/32c-device-workspace-sidebar.md progress log, and client/lib/features/AGENTS.md sidebar contract.
Open findings/blockers: None; awaiting C3 Exit review only.
Next gate/owner: C3 Exit review, then C4.
```

```text
Date: 2026-07-14
Task/Gate: 32c / C3 Exit
Status transition: C3_in_review → C4_start
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed: C3 review confirmed responsive sizing, accessibility hardening, non-blocking cached-state UX, and limited rebuild scope for the redesigned sidebar.
Verification evidence: Prior C3 verification remains valid — fvm flutter analyze clean; focused sidebar cubit/widget/rebuild tests pass (32/32).
Documentation updated: Main board row and docs/plans/tasks/32c-device-workspace-sidebar.md progress log.
Open findings/blockers: None; C3 exit review passed.
Next gate/owner: C4 Verification, Documentation, and Handoff.
```

```text
Date: 2026-07-14
Task/Gate: 32c / C4
Status transition: C4_start → C4_in_review
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed: Final focused verification consolidated; product spec, QA documentation, and feature contract updated for the device-scoped sidebar.
Verification evidence: fvm flutter analyze clean; focused sidebar cubit/widget/rebuild tests pass (32/32).
Documentation updated: docs/product/client_interface.md, docs/qa_maintenance/device_workspace_sidebar_qa.md, docs/qa_maintenance/MOC.md, client/lib/features/AGENTS.md, and the plan/task logs.
Open findings/blockers: None; waiting for user review before marking complete.
Next gate/owner: User review → C4 Exit review / complete.
```

```text
Date: 2026-07-14
Task/Gate: 32c / C4 Review Remediation
Status transition: C4_in_review → C4_in_review (review fixes applied)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed: Fixed collapsed-workspace lazy refresh, in-flight canonical mutation preservation, create-workspace/list-refresh ordering, stale snapshot clearing, duplicate selection, and visible reorder animation; corrected QA/cache documentation.
Verification evidence: fvm flutter analyze clean; focused sidebar cubit/widget/rebuild tests pass (37/37); full client fast suite passes (451/451).
Documentation updated: Task log, cache schema, sidebar QA, feature contract, and this handoff log.
Open findings/blockers: Contract-referenced docs/llms.txt is absent from the branch and is not part of the 32c diff.
Next gate/owner: Commit/push/PR handoff after review approval.
```

```text
Date: 2026-07-14
Task/Gate: 32c / C4 Exit
Status transition: C4_in_review → complete
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed: Review remediation approved and all 32c acceptance gates closed.
Verification evidence: fvm flutter analyze clean; focused sidebar tests pass (37/37); full client fast suite passes (451/451); git diff --check clean.
Documentation updated: Main board row and docs/plans/tasks/32c-device-workspace-sidebar.md closure log.
Open findings/blockers: None in the 32c implementation.
Next gate/owner: Merge 32c, then continue 32d/32e before 32f integration QA.
```

## 2. مشكلات الوضع الحالي

1. منتقي الجهاز داخل composer يصبح معطّلًا بعد بدء المحادثة، واختيار جهاز جديد يبدأ محادثة جديدة بدل تبديل السياق.
2. القائمة الجانبية تنظّم المحتوى حسب الأجهزة ثم الجلسات، ولا تعرض `Workspaces -> Conversations` للجهاز المختار.
3. `SessionCubit` يملك `selectedSession` عالمية واحدة رغم وجود conversation store مستقل لكل جهاز.
4. `get_sessions` يعيد قائمة غير paginated ولا يدعم تصفية Workspace.
5. فتح جلسة يمسح المحتوى الحالي قبل وصول history، فيظهر `NewChatView` كوميض.
6. حذف الجلسة المفتوحة قد يترك رسائلها معروضة.
7. Workspace المختارة لا يمكن مسحها قبل بدء المحادثة رغم أنها اختيارية لبعض الأجهزة.
8. حالة توسع Workspaces والمسودات وآخر جلسة لكل جهاز ليست حالة دائمة موحدة.
9. ترتيب الجلسات لا يملك عقدًا صريحًا يعتمد على آخر رسالة مستخدم ولا يتحرك حيًا بشكل متسق.

## 3. تجربة المستخدم المستهدفة

### 3.1 القائمة الجانبية

```text
[ Back ] [ Forward ]
[ Selected device v ] [ Settings ]

Workspaces                              +
  workspace-a                          +
    Conversation A
    Conversation B
    Load more

  workspace-b                          +
    Conversation C

Conversations
  Unscoped conversation
  Load more
```

- منتقي الجهاز دائم في أعلى القائمة.
- أيقونة الترس تفتح الإعدادات؛ إضافة جهاز تتم من زر `+` بجوار عنوان الأجهزة في القائمة الجانبية للإعدادات، ويفتح صفحة إضافة جهاز.
- القائمة تعرض بيانات الجهاز المختار فقط.
- كل Workspace مفتوحة افتراضيًا أول مرة، ويحفظ اختيار المستخدم لكل `deviceId + workspaceId` بعد إعادة التشغيل.
- `+` بجوار `Workspaces` يبدأ إنشاء Workspace.
- `+` بجوار Workspace يفتح New Conversation مع الجهاز وWorkspace محددين دون إنشاء Session.
- `Conversations` تعرض الجلسات التي لا تملك `workspace_id`.
- اسم الواجهة المعتمد هو Devices وConversations؛ تبقى Session تسمية داخلية.

### 3.2 New Conversation

- لا يظهر conversation App Bar.
- يظهر عنوان كبير `Sanad Agent` ورسالة مساعدة تتغير عند فتح view جديدة.
- يظهر منتقيا الجهاز وWorkspace أعلى composer في هذه الحالة فقط.
- Workspace اختيارية إذا كانت capability تسمح بذلك، ويمكن إزالتها عبر `No workspace`.
- إذا كانت `workspaceRequired == true` يمنع الإرسال بلا Workspace.
- تغيير الجهاز لا ينشئ Session، بل يبدل draft context والقائمة الجانبية وWorkspaces المتاحة.
- Session تنشأ فقط عند إرسال أول رسالة.

### 3.3 المحادثة القائمة

- يختفي منتقيا الجهاز وWorkspace من أعلى composer.
- يظهر App Bar أعلى منطقة المحادثة، ولا يظهر في New Conversation.
- Desktop/tablet يعرض Workspace ثم اسم المحادثة.
- Mobile يعرض زر القائمة واسم المحادثة في السطر الأول، واسم Workspace بخط أصغر في السطر الثاني إن وجدت.
- Workspace لا يمكن تغييرها أو نقل الجلسة منها أو إليها بعد بدء المحادثة.

### 3.4 Composer

- container واحد يضم مساحة كتابة كاملة العرض وصف إجراءات سفليًا.
- الصف السفلي يضم permissions وprovider/model وthinking mode وزر send/stop.
- حقل الكتابة يتوسع تدريجيًا حتى نحو ثمانية أسطر، ثم يمرر داخليًا.
- التخطيط يلتف أو يجمع الإجراءات الثانوية على الشاشات الضيقة دون تقليص مساحة الكتابة.

## 4. نموذج الحالة المستهدف

الحالة ذات السياق الواحد لكل تطبيق لا تكفي. النموذج المطلوب يحفظ حالة مستقلة لكل جهاز:

```text
activeDeviceId
deviceContexts[deviceId]:
  lastSelectedSessionId
  newConversationDraft
  cachedWorkspaces
  unscopedConversationPage
  workspaceConversationPages[workspaceId]
  workspaceExpansion[workspaceId]
  refreshMetadata

conversationDrafts[deviceId + sessionId]
navigationHistory
```

قواعد المصدر:

- daemon هو مصدر الحقيقة للأجهزة وWorkspaces والجلسات والرسائل.
- persistent client cache نسخة عرض واستعادة سريعة وليست مصدر حقيقة منافسًا.
- widgets لا تملك خرائط cache أو pagination أو مسودات محلية مستقلة.
- domain/data store مركزي واحد يعرض snapshots للـcubits والواجهة.

## 5. عقد الاستعلام والترتيب

يمتد عقد `get_sessions` ليقبل دلاليًا:

```text
workspace_id: optional
unscoped_only: boolean
limit: positive integer
cursor: optional opaque value
```

ويعيد:

```text
sessions
next_cursor
has_more
```

قواعد العقد:

1. الفرز authoritative تنازلي حسب `last_user_message_at` مع tie-breaker ثابت.
2. session payload يعيد `workspace_id`, `workspace_name`, `workspace_path`, و`last_user_message_at`.
3. `workspace_id` و`unscoped_only` لا يجتمعان في الطلب نفسه.
4. cursor opaque ومستقر بالنسبة إلى ترتيب الصفحة المطلوبة.
5. القائمة الأولية تعرض ست جلسات لكل قسم، و`Load more` يجلب عشر جلسات إضافية افتراضيًا.
6. لا تُجلب جلسات Workspace المغلقة قبل حاجة العرض، عدا البيانات الموجودة في الكاش.
7. canonical `user_message` المؤكد يحدث `last_user_message_at` ويعيد ترتيب الصف حيًا.
8. أحداث tool/system/assistant وحدها لا تغير ترتيب الجلسة.

## 6. استراتيجية الكاش الدائمة

تستخدم الواجهة مستويين:

- memory cache أثناء التشغيل.
- persistent cache تستمر بعد إعادة التشغيل.

عند اختيار جهاز تطبق `stale-while-revalidate`: تعرض snapshot المحفوظة فورًا، ثم تحدّثها في الخلفية وتدمج الفروقات دون إفراغ القائمة.

كل resource يملك حالة واضحة: `notLoaded`, `loading`, `refreshing`, `ready`, أو `staleError`. تحفظ الكاش وقت آخر تحديث وcursor وحالة `hasMore` لكل قسم، وتزيل بيانات الأجهزة والجلسات المحذوفة. logout يمسح بيانات الحساب السحابية دون إزالة inventory/state المحلية التي يملكها سطح desktop المحلي.

لا تشمل المرحلة الأولى حفظ تاريخ رسائل جميع الجلسات على القرص. يمكن إبقاء رسائل الجلسات المفتوحة في الذاكرة، بينما history الدائمة تبقى daemon-owned.

## 7. المسودات

- تحفظ persistent draft لكل `deviceId + sessionId`.
- تحفظ New Conversation draft لكل جهاز تحت مفتاح مستقل.
- تشمل المسودة النص وWorkspace الاختيارية للمحادثة الجديدة وprovider/model وthinking وpermission mode ووقت التعديل.
- autosave مؤجل زمنيًا لتجنب كتابة كل حرف منفردًا.
- الانتقال بين جهاز أو جلسة يستعيد مسودتها.
- لا تحذف المسودة عند محاولة الإرسال؛ تحذف بعد تأكيد قبول رسالة المستخدم canonical من daemon.
- فشل الإرسال يبقي المسودة.
- عند إنشاء Session من New Conversation تنتقل هوية draft إلى session الجديدة ثم تنظف بعد التأكيد.
- حذف session يحذف draft الخاصة بها.

## 8. الانتقالات بلا وميض

فتح جلسة جديدة يمر بحالة pending منفصلة عن presented conversation:

1. تبقى المحادثة الحالية معروضة أثناء طلب history الجديدة.
2. لا يتغير App Bar إلى الجلسة الجديدة قبل جاهزية رسائلها.
3. إذا انتهى الطلب بسرعة يتم الاستبدال ذريًا بلا loading surface.
4. إذا تجاوز عتبة قصيرة يظهر overlay تحميل هادئ فوق المحتوى السابق ويمنع التفاعل معه.
5. عند النجاح ينتقل العنوان والرسائل والcomposer state معًا.
6. عند الفشل تبقى المحادثة السابقة وتظهر إمكانية retry.
7. أي استجابة متأخرة لطلب superseded أو session محذوفة تُرفض.

## 9. الحذف والتنقل

- حذف جلسة غير مفتوحة لا يغير العرض الحالي.
- حذف الجلسة المفتوحة يزيلها من cache والمسودات وسجل التنقل ويلغي طلباتها.
- بعدها تفتح آخر وجهة صالحة في تاريخ الجهاز نفسه، وإلا يظهر New Conversation.
- route الحالية تستبدل ولا يضاف deleted route إلى Back history.
- Back/Forward يعملان عبر الأجهزة والجلسات وNew Conversation، ويتزامنان مع URL وأزرار المتصفح.
- فتح وجهة جديدة بعد Back يمسح forward branch، والوجهات المحذوفة أو غير المتاحة يتم تجاوزها.
- أزرار Back/Forward تظهر في القائمة الجانبية على desktop/tablet ويمكن إخفاؤها في mobile الضيق، مع بقاء تنقل النظام والمتصفح.

## 10. ترتيب التنفيذ والعمل المتوازي

```text
32a Protocol, pagination, ordering
                 |
                 v
32b Cache, drafts, client state
                 |
       +---------+----------+
       |         |          |
       v         v          v
32c Sidebar  32d Chat UI  32e Navigation/deletion
       +---------+----------+
                 |
                 v
          32f Integration QA
```

- `32a` يثبت العقد قبل اعتماد client state النهائي.
- `32b` يثبت واجهات store التي تستهلكها مهام UI.
- `32c`, `32d`, و`32e` يمكن تنفيذها بالتوازي بعد ذلك، مع ملكية ملفات غير متقاطعة متى أمكن.
- `32f` يغلق التكامل متعدد المنصات وحالات الاستعادة والفشل.
- أي تغيير في contract مشترك بعد بدء المهام المتوازية يجب أن ينعكس أولًا في الخطة الرئيسية ثم في كل مهمة متأثرة.

## 11. خطط المهام

1. [32a: Session Query Pagination and Ordering](tasks/32a-session-query-pagination-and-ordering.md)
2. [32b: Client Conversation Cache and Drafts](tasks/32b-client-conversation-cache-and-drafts.md)
3. [32c: Device Workspace Sidebar](tasks/32c-device-workspace-sidebar.md)
4. [32d: New Conversation, Composer, and App Bar](tasks/32d-new-conversation-composer-and-app-bar.md)
5. [32e: Navigation History and Deletion Safety](tasks/32e-conversation-navigation-history-and-deletion.md)
6. [32f: Responsive Integration QA](tasks/32f-responsive-integration-and-regression-qa.md)
7. [37: Workspace Sidebar Drag Reorder](tasks/37-workspace-sidebar-drag-reorder.md)

## 12. Definition of Done الكلية

- [ ] تبديل الجهاز يعيد آخر جلسة وقائمة cached ومسودات الجهاز فورًا ثم يحدثها في الخلفية.
- [ ] Sidebar تعرض Workspaces وجلساتها ثم Conversations غير المرتبطة مع pagination مستقلة.
- [ ] ترتيب الجلسات يعتمد على آخر رسالة مستخدم ويتحدث حيًا مع animation.
- [ ] New Conversation لا تنشئ Session حتى أول إرسال ولا تعرض App Bar.
- [ ] Workspace اختيارية وقابلة للمسح حسب capability وثابتة بعد بدء session.
- [ ] composer وApp Bar والقائمة تعمل على desktop/tablet/mobile/web دون overflow أو فقد وظائف.
- [ ] فتح جلسة لا يعرض New Conversation أو blank/loading flash.
- [ ] حذف الجلسة المفتوحة لا يترك رسائلها ولا يسمح لاستجابة متأخرة بإعادتها.
- [ ] Back/Forward وأزرار المتصفح متزامنة ولا تعيد فتح جلسة محذوفة.
- [ ] الكاش والمسودات وحالة التوسع وآخر جلسة تستعاد بعد إعادة التشغيل.
- [ ] الاختبارات والتحليل والتوثيق المملوك لكل طبقة محدثة وفق مهام التنفيذ.

## 13. خارج النطاق

- نقل session بين Workspaces أو إضافة Workspace لها بعد البدء.
- أكثر من New Conversation draft متوازية للجهاز نفسه.
- offline archive كامل لتاريخ كل رسائل المحادثات داخل Flutter.
- تغيير تصميم timeline events أو بروتوكول تنفيذ الوكيل خارج ما يلزم للترتيب والاستعلام.
- إعادة تصميم إدارة الأجهزة نفسها، عدا ضمان الوصول إلى الإعدادات من أيقونة الترس وفتح Add Device من زر `+` بجوار عنوان الأجهزة في قائمتها الجانبية.
