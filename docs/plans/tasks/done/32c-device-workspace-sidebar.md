---
title: "Task 32c: Device Workspace Sidebar"
parent_plan: "docs/plans/32-device-workspace-conversation-ux-redesign.md"
status: "complete"
current_gate: "Closed"
---

# Task 32c: Device Workspace Sidebar

## الحالة والاعتماديات

- الحالة: `complete` — اجتازت مراجعة Gate C4 وأصبحت جاهزة للدمج.
- يمكن تنفيذها بالتوازي مع `32d` و`32e` بعد تثبيت store APIs.
- ملكية الوكيل: sidebar presentation وwidget tests فقط؛ لا يغير protocol أو persistence schema منفردًا.

## قاعدة التنفيذ والتحديث

- [x] لا يبدأ C0 قبل إعلان 32b أن consumer API مستقرة.
- [x] يحدث الوكيل status/current gate ولوحة الخطة في كل انتقال.
- [x] أي نقص في store يعاد إلى 32b ولا يعالج بخريطة state جديدة داخل widget.
- [x] لا تصبح المهمة `complete` قبل C4 review.

## بوابات التنفيذ

### Gate C0: Presentation Contract and Widget Decomposition

- [x] تثبيت sidebar view models/intents القادمة من 32b و32e.
- [x] تقسيم widget ownership لتجنب rebuilds وتعارض وكلاء العمل.
- [x] تثبيت desktop/tablet/mobile composition قبل styling التفصيلي.

#### Gate C0 Exit

- [x] مراجعة composition والملكية قبل استبدال القائمة الحالية.

### Gate C1: Device and Workspace Structure

- [x] تنفيذ device selector الدائم وأيقونة settings.
- [x] تنفيذ Workspaces وConversations sections والـplus intents.
- [x] ربط expansion preference الدائمة وcached initial rendering.
- [x] اختبارات البنية والاختيار لكل جهاز ناجحة.

#### Gate C1 Exit

- [x] مراجعة السلوك الأساسي قبل pagination والanimation.

### Gate C2: Pagination, Live Ordering, and Actions

- [x] ربط lazy first page وLoad more لكل قسم مستقل.
- [x] ربط created/updated/deleted/live user ordering snapshots.
- [x] تنفيذ انتقال الصف للأعلى animation دون فقد selection/scroll.
- [x] الحفاظ على runtime/session indicators القائمة.

#### Gate C2 Exit

- [x] مراجعة ordering والpagination تحت updates متزامنة.

### Gate C3: Responsive and Accessibility Hardening

- [x] إثبات desktop/tablet/mobile layouts وmacOS spacing.
- [x] keyboard/focus/semantics/touch targets صحيحة.
- [x] offline/stale/refresh/error states غير حاجبة.
- [x] قياس rebuild scope وإزالة rebuild storms.

#### Gate C3 Exit

- [x] مراجعة بصرية ووظيفية متعددة المقاسات قبل الإغلاق.

### Gate C4: Verification, Documentation, and Handoff

- [x] إغلاق كل widget/unit scenarios في المهمة.
- [x] تحديث product spec وQA والcontracts المتأثرة.
- [x] تسجيل نتائج التحقق والملفات المعدلة في السجل.
- [x] تحديث لوحة الخطة الرئيسية.

#### Gate C4 Exit

- [x] status تصبح `in_review` ثم `complete` بعد المراجعة.

## الهدف

استبدال شجرة `Devices -> Sessions` بقائمة للجهاز المختار تعرض Workspaces وجلساتها ثم Conversations غير المرتبطة، مع pagination وحالة توسع دائمة وترتيب حي متحرك.

## تخطيط القائمة

- أعلى القائمة: Back/Forward ثم device selector وأيقونة settings.
- device selector متاح دائمًا ويعرض حالة online/offline/local دون منع استعراض cache.
- settings تفتح الإعدادات؛ زر `+` بجوار عنوان Devices في قائمتها الجانبية يفتح Add Device.
- عنوان Workspaces يملك زر `+` لإنشاء Workspace.
- كل Workspace تملك زر `+` لفتح New Conversation preselected.
- القسم الأخير `Conversations` للجلسات بلا Workspace.
- `Load more` مستقل لكل Workspace ولقسم Conversations.

## السلوك

- Workspace expanded افتراضيًا إذا لم توجد preference.
- الضغط على الاسم يبدل expanded/collapsed ويحفظ القيمة.
- refresh أو live event لا يغير expansion.
- Workspace المغلقة لا تطلب أول صفحة عن بعد حتى توسع، لكن تعرض cached count/data إن كانت موجودة وفق snapshot.
- switch device يعرض cache فورًا مع refresh indicator غير حاجب.
- offline device يعرض cache ويسمح بالتنقل، بينما إجراءات network تعرض حالتها بوضوح.
- الضغط على session يرسل navigation intent ولا يمسح العرض الحالي بنفسه.

## الترتيب والـanimation

- يعتمد الصف على `last_user_message_at` القادم من store.
- عند canonical user message لجلسة قديمة تتحرك إلى أول قسمها باستخدام animated list/reorder transition.
- الحركة لا تعيد بناء القائمة كاملة ولا تفقد scroll position أو expansion.
- الجلسة لا تنتقل بين Workspace وConversations لأن ارتباطها ثابت.
- session processing/recovery indicators القائمة تبقى متوافقة مع عقود الحالة الحالية وخطة 31.

## الاستجابة للمنصات

- Desktop: sidebar ثابتة بعرض مناسب.
- Tablet: يمكن طيها أو عرضها drawer وفق breakpoint المعتمد.
- Mobile: drawer مع touch targets مناسبة، ويغلق بعد اختيار session.
- لا تظهر أزرار Back/Forward إذا كان العرض لا يحتملها؛ يبقى system/browser navigation.
- macOS traffic-light spacing يبقى صحيحًا.

## حالات الاختبار

- جهازان يعرض كل منهما Workspaces/جلساته فقط.
- cache تظهر أثناء refresh ولا تعرض القائمة فارغة.
- expansion تستعاد بعد rebuild/restart.
- plus العام وplus Workspace يرسلان intents الصحيحة دون إنشاء session.
- Load more يحدث قسمًا واحدًا فقط.
- live user message يحرك الصف إلى الأعلى مع بقاء selection.
- حذف صف لا يترك separator أو selection شبحية.
- desktop/tablet/mobile لا تنتج overflow.
- rebuilds محدودة ولا يعاد بناء كل Workspace عند تغير صف واحد.

## الملفات المتوقعة

- `sanad-agent/client/lib/features/conversations/presentation/widgets/session_sidebar.dart`
- `sanad-agent/client/lib/features/conversations/presentation/bloc/session_sidebar_cubit.dart`
- `sanad-agent/client/lib/features/conversations/presentation/bloc/session_sidebar_state.dart`
- widgets صغيرة مستخرجة داخل conversations presentation.
- tests الخاصة بالـsidebar وresponsive behavior.

## تحديثات التوثيق المطلوبة عند التنفيذ

- `sanad-agent/docs/product/client_interface.md`
- `sanad-agent/client/lib/features/AGENTS.md` إذا تغير presentation ownership contract.
- QA scenarios للقائمة والترتيب والتحديث الحي.

## Definition of Done

- [x] لا تعرض sidebar كل الأجهزة كشجرة.
- [x] كل قسم paginated ومستقل ويعمل من cache.
- [x] الترتيب والanimation وحالة expansion صحيحة.
- [x] الوصول إلى Settings ثم زر `+` بجوار Devices لإضافة جهاز، وإنشاء Workspace/New Conversation واضح.
- [x] السلوك متحقق على mobile وdesktop.

## سجل التقدم

### Gate C0 — Presentation Contract and Widget Decomposition

```text
Date: 2026-07-13
Task/Gate: 32c / C0
Status transition: pending → in_progress (C0_in_review)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - SessionSidebarCubit rewritten as cache-backed projection of ConversationCacheRepository (Plan 32b store APIs). Emits SessionSidebarState with DeviceSidebarSnapshot, section lifecycle overlay, and initial-loading gate.
  - SessionSidebarState redesigned: activeDeviceId, snapshot, sectionStates, workspacesState, isRefreshing, showInitialLoading. Pure view-model — no cache maps, cursors, or drafts.
  - Widget decomposition into independently-rebuilding slices under widgets/sidebar/:
    * DeviceWorkspaceSidebar (shell, responsive layout, chrome, intent wiring)
    * SidebarDeviceHeaderBar (persistent device selector + settings, reads DeviceCubit only)
    * SidebarWorkspacesSection (Workspaces heading + create-workspace intent)
    * SidebarWorkspaceGroupTile (per-workspace expansion + new-conversation + load-more)
    * SidebarUnscopedConversationsSection (Conversations section)
    * SidebarConversationRow (most granular rebuild unit, narrow BlocBuilder.buildWhen)
    * sidebar_composition.dart (SidebarBreakpoints constants + composition contract doc)
  - Legacy SessionSidebar (session_sidebar.dart) forwards to DeviceWorkspaceSidebar with debug-hook bridge for existing tests.
  - HomeScreen DI updated: SessionSidebarCubit now receives ConversationCacheRepository.
Verification evidence:
  - fvm flutter analyze: 0 errors, 0 warnings across full client.
  - fvm flutter test: 416/416 tests pass (including 9 new SessionSidebarCubit unit tests).
Documentation updated:
  - This file (status, gate checkboxes, progress log).
  - Pending: product spec and features AGENTS.md update (Gate C4 batch).
Open findings/blockers:
  - None. All store APIs from 32b are sufficient for C0 composition.
Next gate/owner:
  - C0 Exit review → C1 (Device and Workspace Structure implementation).
```

### Gate C1 — Device and Workspace Structure

```text
Date: 2026-07-13
Task/Gate: 32c / C1
Status transition: C0_in_review → in_progress (C1_complete)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - ConversationCacheStore.applyWorkspaceCreated: optimistic single-workspace insert without forcing a full refreshWorkspaces round-trip.
  - ConversationCacheRepository.createWorkspace: transport (ConversationRepository.createWorkspace) + cache optimistic insert; mirrors the legacy SessionMessagesCubit path.
  - SessionSidebarCubit.prepareNewConversationWithWorkspace: sets the newConversationDraft workspaceId without creating a Session (Plan 32 §3.2).
  - SessionSidebarCubit.loadWorkspaceConversationsIfNeeded: lazy first-page fetch guard — triggers a remote refresh only when the workspace page state == notLoaded.
  - device_workspace_sidebar _SidebarBody rewired with correct intents:
    * onCreateWorkspace → opens WorkspaceBrowserDialog, then cacheRepository.createWorkspace + lazy fetch for the new workspace.
    * onNewConversation(workspaceId) → prepareNewConversationWithWorkspace + startNewChat + context.go(conversationLocation); no Session is created.
    * onToggleWorkspaceExpansion → toggleWorkspaceExpansion + lazy fetch when expanding a notLoaded workspace.
  - Pump-app helper updated: pumpTestApp now accepts optional GoRouter? router + ConversationCacheRepository/ConversationRepository providers.
  - Test file: test/widget/device_workspace_sidebar_structure_test.dart (5 widget tests covering device selector presence, Workspaces/Conversations section rendering, device switch projection, and new-conversation intent without session creation).
Verification evidence:
  - fvm flutter analyze: 0 errors, 0 warnings across full client.
  - fvm flutter test: 430/430 tests pass (including 5 new C1 widget tests; 9 C0 cubit tests + 2 rebuild tests still pass).
Documentation updated:
  - This file (frontmatter current_gate, status section, gate checkboxes, progress log).
  - Pending: product spec and features AGENTS.md ownership update (Gate C4 batch).
Open findings/blockers:
  - None. All store APIs from 32b are sufficient for C1 structure implementation.
Next gate/owner:
  - C1 Exit closed → C2 (Pagination, Live Ordering, Actions).
```

### Gate C2 — Pagination, Live Ordering, and Actions

```text
Date: 2026-07-14
Task/Gate: 32c / C2
Status transition: C2_start → in_progress (C2_in_review)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - SessionSidebarCubit exposes independent lazy first-page guards for workspace and unscoped sections and delegates Load more by section key.
  - Conversation cache live session mutations (created/updated/deleted/user-message accepted) project directly into sidebar snapshots so sections stay ordered by last user message.
  - Sidebar rows use AnimatedListDiffColumn with stable session keys so bumped rows slide to their new position without replacing the scroll view or clearing selection.
  - Existing row indicators for processing, pending permission, and pending question remain inside SidebarConversationRow and rebuild only for the affected row.
  - Test files were renamed from implementation-gate names to behavior names:
    * test/unit/bloc/session_sidebar_cubit_pagination_ordering_test.dart
    * test/widget/device_workspace_sidebar_structure_test.dart
    * test/widget/device_workspace_sidebar_pagination_ordering_test.dart
Verification evidence:
  - fvm flutter analyze: 0 errors, 0 warnings across full client.
  - fvm flutter test test/unit/bloc/session_sidebar_cubit_test.dart test/unit/bloc/session_sidebar_cubit_pagination_ordering_test.dart test/widget/device_workspace_sidebar_structure_test.dart test/widget/device_workspace_sidebar_pagination_ordering_test.dart test/widget/session_sidebar_rebuild_test.dart: 28/28 tests pass.
  - fvm flutter test test/widget/device_workspace_sidebar_pagination_ordering_test.dart --reporter expanded: 3/3 tests pass.
Documentation updated:
  - This file (frontmatter current_gate, status section, C2 checkboxes, progress log).
  - Main Plan 32 board row updated to C2_in_review.
Open findings/blockers:
  - None. Gate C2 review passed.
Next gate/owner:
  - C3 (Responsive and Accessibility Hardening).
```

### Gate C2 Exit Review

```text
Date: 2026-07-14
Task/Gate: 32c / C2 Exit
Status transition: C2_in_review → C3_start
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - Reviewed C2 implementation against the task checklist: independent lazy/load-more pagination, live ordering projection, row move animation, and existing runtime/session indicators are present.
  - Reviewed test naming: no test file/comment remains named after implementation gates; C2 coverage uses behavior names.
  - Fixed stale C1 progress-log reference to the renamed structure test file.
Verification evidence:
  - Prior focused verification remains valid for this review: fvm flutter analyze clean; focused sidebar cubit/widget/rebuild tests 28/28 pass; focused pagination widget tests 3/3 pass.
Documentation updated:
  - This file (frontmatter current_gate, status line, C2 Exit checkbox, review log).
  - Main Plan 32 board row moved to C3_start and handoff log updated.
Open findings/blockers:
  - None. Gate C2 review passed.
Next gate/owner:
  - C3 (Responsive and Accessibility Hardening).
```

### Gate C3 — Responsive and Accessibility Hardening

```text
Date: 2026-07-14
Task/Gate: 32c / C3
Status transition: C3_start → in_progress (C3_in_review)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - Centralized responsive sidebar sizing through SidebarBreakpoints so desktop width, home-screen tablet breakpoint, drawer width factor, and macOS chrome spacing stay aligned.
  - Added sidebar accessibility hardening: semantics labels, tooltips, 44px-class drawer touch targets, and mobile-friendly row density without changing the conversation/domain ownership model.
  - Added non-blocking status surfaces for offline, refreshing, and stale-error sidebar states while keeping cached workspaces/conversations visible and retryable.
  - Reduced unnecessary rebuild scope by moving workspace and unscoped section rendering behind narrow BlocSelector slices; added rebuild verification that unscoped cache updates do not rebuild the workspace section.
Verification evidence:
  - fvm flutter analyze: 0 issues.
  - fvm flutter test test/widget/device_workspace_sidebar_structure_test.dart test/widget/device_workspace_sidebar_pagination_ordering_test.dart test/widget/session_sidebar_rebuild_test.dart test/unit/bloc/session_sidebar_cubit_test.dart test/unit/bloc/session_sidebar_cubit_pagination_ordering_test.dart: 32/32 tests pass.
Documentation updated:
  - This file (frontmatter current_gate, C3 checkboxes, progress log).
  - docs/plans/32-device-workspace-conversation-ux-redesign.md board row / handoff log.
  - client/lib/features/AGENTS.md sidebar responsive/accessibility contract.
Open findings/blockers:
  - No functional blocker. C3 is ready for visual/functional review before Gate Exit closure.
Next gate/owner:
  - C3 Exit review, then C4 (Verification, Documentation, Handoff).
```

### Gate C3 Exit Review

```text
Date: 2026-07-14
Task/Gate: 32c / C3 Exit
Status transition: C3_in_review → C4_start
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - Reviewed responsive hardening against the task checklist: desktop/drawer sizing is centralized, macOS spacing remains reserved, drawer/mobile touch targets were enlarged, and semantics/tooltips cover key sidebar actions.
  - Reviewed non-blocking sidebar states: offline, refreshing, and stale-error banners keep cached content visible and retryable instead of replacing the list.
  - Reviewed rebuild-scope evidence: workspace and unscoped sections are now selected independently and focused tests confirm unscoped cache updates do not rebuild the workspace section.
Verification evidence:
  - Prior C3 verification remains valid for exit review: fvm flutter analyze clean; focused sidebar cubit/widget/rebuild tests 32/32 pass.
Documentation updated:
  - This file (frontmatter current_gate, C3 Exit checkbox, progress log).
  - docs/plans/32-device-workspace-conversation-ux-redesign.md board row and handoff log.
Open findings/blockers:
  - None. Gate C3 exit review passed.
Next gate/owner:
  - C4 (Verification, Documentation, Handoff).
```

### Gate C4 — Verification, Documentation, and Handoff

```text
Date: 2026-07-14
Task/Gate: 32c / C4
Status transition: C4_start → in_review (C4_in_review)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - Consolidated final focused verification coverage for sidebar structure, pagination, live ordering, responsive drawer behavior, accessibility touch targets, and rebuild-scope isolation.
  - Updated the product spec with the final device-scoped sidebar contract: persistent device selector, workspace/unscoped split, lazy pagination, live user-message ordering, cache-first refresh, responsive drawer behavior, and non-blocking offline/stale states.
  - Added a dedicated QA specification page for the device workspace sidebar and linked it from the QA MOC.
  - Updated the local feature contract to capture responsive sizing centralization and accessibility expectations for the sidebar.
Verification evidence:
  - fvm flutter analyze: 0 issues.
  - fvm flutter test test/widget/device_workspace_sidebar_structure_test.dart test/widget/device_workspace_sidebar_pagination_ordering_test.dart test/widget/session_sidebar_rebuild_test.dart test/unit/bloc/session_sidebar_cubit_test.dart test/unit/bloc/session_sidebar_cubit_pagination_ordering_test.dart: 37/37 tests pass after review fixes.
  - fvm flutter test --reporter compact: 451/451 tests pass after review fixes.
Files modified in this task session:
  - client/lib/features/AGENTS.md
  - client/lib/features/conversations/data/repositories/conversation_cache_repository.dart
  - client/lib/features/conversations/domain/stores/conversation_cache_store.dart
  - client/lib/features/conversations/presentation/bloc/session_sidebar_cubit.dart
  - client/lib/features/conversations/presentation/bloc/session_sidebar_state.dart
  - client/lib/features/conversations/presentation/widgets/session_sidebar.dart
  - client/lib/features/conversations/presentation/widgets/sidebar/device_workspace_sidebar.dart
  - client/lib/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart
  - client/lib/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart
  - client/lib/features/conversations/presentation/widgets/sidebar/sidebar_device_header_bar.dart
  - client/lib/features/conversations/presentation/widgets/sidebar/sidebar_sections.dart
  - client/lib/features/conversations/presentation/widgets/sidebar/sidebar_workspace_group_tile.dart
  - client/lib/features/home/presentation/screens/home_screen.dart
  - client/lib/features/home/presentation/widgets/conversation_workspace_layout.dart
  - client/test/helpers/fake_conversation_repository.dart
  - client/test/helpers/pump_app.dart
  - client/test/unit/bloc/conversation_bloc_imports_test.dart
  - client/test/unit/bloc/session_cubit_test.dart
  - client/test/unit/bloc/session_sidebar_cubit_pagination_ordering_test.dart
  - client/test/unit/bloc/session_sidebar_cubit_test.dart
  - client/test/widget/device_workspace_sidebar_pagination_ordering_test.dart
  - client/test/widget/device_workspace_sidebar_structure_test.dart
  - client/test/widget/session_sidebar_rebuild_test.dart
  - docs/plans/32-device-workspace-conversation-ux-redesign.md
  - docs/plans/tasks/32c-device-workspace-sidebar.md
  - docs/product/client_interface.md
  - docs/qa_maintenance/MOC.md
  - docs/qa_maintenance/device_workspace_sidebar_qa.md
  - docs/technical/client_conversation_cache_schema.md
Documentation updated:
  - docs/product/client_interface.md
  - docs/qa_maintenance/device_workspace_sidebar_qa.md
  - docs/qa_maintenance/MOC.md
  - client/lib/features/AGENTS.md
  - docs/plans/32-device-workspace-conversation-ux-redesign.md
  - docs/plans/tasks/32c-device-workspace-sidebar.md
Open findings/blockers:
  - None. Task is ready for your review; do not mark `complete` until review approval.
Next gate/owner:
  - C4 Exit review → `complete` after user review approval.
```

### C4 Review Remediation

```text
Date: 2026-07-14
Task/Gate: 32c / C4 Review
Status transition: in_review → in_review (review fixes applied)
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed:
  - Fixed collapsed-workspace refresh so an unloaded collapsed section remains lazy.
  - Preserved canonical create/update/delete/user-message mutations across in-flight page responses.
  - Protected optimistically created workspaces from older workspace-list responses.
  - Fixed stale sidebar snapshot retention when the active device is cleared.
  - Removed duplicate session activation on row selection and surfaced workspace-creation failure.
  - Installed the reorder animation before starting its controller and verified an intermediate frame.
  - Narrowed workspace-section selection so unscoped cache changes do not rebuild it.
  - Corrected QA frontmatter, cache design documentation, and the complete modified-file inventory.
Verification evidence:
  - fvm flutter analyze: 0 issues.
  - Focused sidebar unit/widget suite: 37/37 tests pass.
  - Full client fast suite: 451/451 tests pass.
Open findings/blockers:
  - docs/llms.txt is referenced by the repository contract but is absent from this worktree/branch; this is pre-existing and outside the 32c diff.
Next gate/owner:
  - User approved closure; commit, push, open the PR, and merge it.
```

### C4 Exit Review

```text
Date: 2026-07-14
Task/Gate: 32c / C4 Exit
Status transition: in_review → complete
Owner/worktree: 32c-device-workspace worktree (branch 32c-device-workspace)
Completed: User approved task closure after review remediation; all C4 exit conditions are satisfied.
Verification evidence: fvm flutter analyze clean; focused sidebar unit/widget suite passes (37/37); full client fast suite passes (451/451); git diff --check clean.
Documentation updated: Task status/checklist and parent plan board/handoff log.
Open findings/blockers: None in the 32c implementation.
Next gate/owner: Commit, push, PR, and merge; then proceed to the next worktree review.
```
