---
title: "Conversation Tool Groups and Compact Desktop Window"
status: "in_review"
current_gate: "user_visual_review_before_commit"
remaining_percent: 0
---

# Conversation Tool Groups and Compact Desktop Window

## Goal

Improve dense tool activity without weakening live conversation performance, fix stale tool completion during active-history hydration, preserve independent nested/timeline scroll-follow state, and add a desktop-only iPhone-sized window toggle.

## Locked UX Decisions

- A completed/error tool appears alone until a second contiguous completed/error tool arrives; then the run becomes one collapsible group.
- `system_ask_user` never joins a group and splits the runs before and after it.
- A single tool remains standalone. As soon as a second contiguous tool arrives, every tool in the run—including the latest running tool—enters one group without multi-row flashing.
- Error tools group like successful tools without a separate error count.
- A running `system_ask_user` timeline event is completely hidden. Its completed question/answer content appears without the generic icon/Ask/title header.
- Group titles use normal font weight and expose the operation summary without a leading icon or `Tool uses:` prefix. MCP calls aggregate by server as `<count> <server> tool(s)` rather than listing each MCP operation. Skill loads appear first, followed by other non-file operations; file searches and File Read calls labeled as `file explore(s)` appear before the deduplicated modified-file count. The modified-file count and its green added-line/red removed-line totals form one wrapping unit so they always remain on the same line. Repeated writes/edits of one canonical path count that modified file once. The expanded body starts directly with its child tools and does not repeat the aggregate title.
- Every numeric group-title metric is cached by stable projected identity and animates over 750ms only when its value changes; virtualization and expansion do not replay it. Added/removed metrics use the compact spacing from a file-edit title, and the group chevron uses the same gray as the title.
- The group introduces no new visual language: header typography, colors, spacing, borders, chevron, and surfaces reuse the current tool component values, including the current `Read:` / `Grep:` title color.
- Expanded groups reuse existing tool presentations, have the existing tool-body maximum height of 500 logical pixels, and scroll internally. The aggregate title remains only in the outer group header and is not repeated as the expanded body's first row. Group content is absent from the widget tree while collapsed; expanding the group does not expand its child tools, whose default and restored state is independently collapsed/expanded.
- One non-expandable `ConversationActivityTile` may appear only at the current timeline tail while authoritative attention is `runningOrResuming`. The current authoritative Activity appears immediately when an active conversation opens; later candidates use a one-second trailing debounce: the last confirmed row remains visible within the same active round, burst intermediates never render, and only the latest stable real detail—such as `Running: fvm flutter test …`—replaces it directly without any Activity entrance or text-transition animation. The generic provider/tool gap reads `Working…`, while explicit reasoning retains `Thinking: <preview>`. Reasoning may create the tile without a group; a temporary first standalone tool may retain the prior confirmed activity but never creates a duplicate activity for itself. Ask-user and every non-tool boundary prevent any later activity from being inserted under a historical group. User attention, waiting, blocked/fatal, stopping, interruption/idle, and errors remove the tile immediately, with no placeholder.
- Group-scroll follow starts enabled, follows appended/completed children, disables on user scrolling away, and re-enables when the user returns to its bottom.
- Group-scroll and timeline-scroll controllers/state are strictly independent.
- Sending a new user message preserves the current minimal reveal behavior but grants timeline follow eligibility. Later streamed growth follows unless the user scrolls away; manually returning to the bottom restores follow.
- The desktop-only compact-window button sits beside the sidebar pin button with the same 24px-class geometry.
- The preferred compact size is `500 × 874` logical pixels, while the desktop minimum is `500 × 600`; the shared width remains the smallest supported by the responsive design, while the lower minimum height lets short desktop work areas resize safely.
- The first compact toggle records the current normal window bounds and preserves its top-left `x/y`; resizing occurs only toward the right and bottom. The second restores the prior bounds. Maximized/full-screen state is exited safely before compacting, and manual enlargement clears compact mode so every compact/restore button updates.
- The compact/restore action remains visible in the narrow desktop conversation header beside the workspace/session identity after the wide sidebar header disappears.
- A new-conversation composer requests focus on first presentation; clicking any non-control blank area of the composer focuses the text field.
- Minimum-size enforcement applies in Dart and the native macOS, Windows, and Linux runners.

## Architecture

- Keep `CanonicalEvent` and `DeviceConversationStore` authoritative; presentation derives immutable timeline entries in one linear pass.
- Fix history/live reconciliation so a newer terminal tool event wins over a stale running history row with the same canonical identity.
- Represent each projected timeline item as either one canonical event or one completed contiguous tool group with a stable identity derived from child event ids.
- Keep aggregation pure and unit-testable. Parse normalized tool names, paths, and diff statistics once per projection; use sets for unique files.
- Keep expansion and nested follow state scoped by stable group identity. Never share a `ScrollController` with the conversation timeline.
- Place desktop window transitions behind `WindowManagerService`; presentation sends only toggle intent and observes compact state.

## Gates

### G0 — Discovery and Decisions (complete)

- [x] Update clean primary `main` with fast-forward only.
- [x] Confirm grouping threshold, error behavior, and iPhone 17 size.
- [x] Locate stale history/live reconciliation defect.
- [x] Identify timeline, tool tiles, sidebar controls, window service, and native runners.

### G1 — Authoritative State Reconciliation (complete)

- [x] Preserve terminal transient tool results over matching stale running history rows.
- [x] Add regression coverage for active history opened while a tool completes.
- [x] Ensure same-id status/output changes reach the emitted canonical message projection.

### G2 — Timeline Projection and Tool Group UI (complete)

- [x] Add linear, stable tool-group projection and aggregation.
- [x] Hide running ask-user rows and remove completed ask-user generic headers.
- [x] Add collapsible group header, unique-file/diff summaries, and animated counters.
- [x] Add bounded independent internal scroll-follow behavior.
- [x] Add focused unit/widget coverage for all grouping boundaries and updates.

### G3 — Timeline Follow Semantics (complete)

- [x] Grant follow eligibility on a newly sent user message without an immediate full-tail scroll.
- [x] Preserve manual opt-out and restore follow only on manual return to bottom.
- [x] Prove nested group scrolling and timeline scrolling use separate controllers and follow state.

### G4 — Compact Desktop Window (complete)

- [x] Add desktop-only compact/restore control beside sidebar pin.
- [x] Add `WindowManagerService` compact/restore and saved-bounds behavior.
- [x] Enforce the original `500 × 874` compact viewport in Dart and macOS/Windows/Linux native runners.
- [x] Add service/widget/native contract tests where practical.

### G5 — Documentation, Verification, and Live Review

- [x] Update `docs/product/client_interface.md` and focused QA documentation.
- [x] Update the closest contracts only if durable laws changed.
- [x] Format, analyze, run focused tests, then broader fast tests because timeline/state/window surfaces are shared.
- [x] Run `graphify update .`.
- [x] Review the diff and identify concurrent unrelated launcher-profile changes without modifying or reverting them.
- [x] Run `sanad-dev reload client` and inspect bounded client logs.
- [x] Complete human visual review of expanded grouping and compact/restore interaction in the active client.

### G6 — Follow-up Interaction and Performance Corrections

- [x] Keep grouped child tools collapsed by default and persist group, standalone, and child expansion state across virtualization/rebuilds.
- [x] Remove collapsed group bodies from the widget tree and prevent cached metrics from replaying on scroll.
- [x] Keep the aggregate operation/file/line summary only in the gray outer title, omit it from the expanded body, and place the chevron beside it.
- [x] Collapse parallel running batches into a group plus only the latest standalone running tool.
- [x] Preserve top-left window origin, adopt `500 × 874`, expose narrow-header restore, and reconcile manual enlargement.
- [x] Focus new-conversation input initially and focus it from blank composer clicks.
- [x] Add focused regression coverage and pass analyzer/focused suites.
- [x] Hot restart the client after the state-shape change and verify clean bounded startup logs.
- [x] Complete human visual review of the follow-up interactions.

### G7 — Transparent Conversation Activity and Group Summary

- [x] Group every contiguous tool from the second call onward, including running tools.
- [x] Replace reasoning rows and the trailing placeholder with one transient `ConversationActivityTile`.
- [x] Expose real current tool details and avoid duplicating one standalone tool.
- [x] Debounce activity candidates for one second, suppress burst intermediates, and replace stable text without entrance/transition animation.
- [x] Keep activity at the current tail across ask-user/non-tool boundaries, gate it to authoritative running/resuming only, and report post-debounce layout to the outer conversation follow owner without touching inner scroll state.
- [x] Remove the group-title icon, lead with non-file operations, place colored file line impact last, animate every changing number over 750ms, compact `+/-` spacing, and gray the chevron.
- [x] Update the owning contracts and product/technical/QA documentation.
- [x] Recover the expected Hot Reload state-shape mismatch with a Hot Restart; bounded post-restart logs contain no new exception.
- [x] Complete iterative human visual review of the active conversation behavior.
- [x] Add/correct focused regression tests and pass analyzer, focused suites, full fast suite, and macOS debug build.
- [x] Update Graphify after the final implementation and tests.

### G8 — Compact Desktop Chrome and MCP Summary Polish

- [x] Reuse wide-header action geometry and neutral gray styling in narrow desktop headers.
- [x] Align narrow macOS actions with native traffic lights and reserve the drawer's traffic-light region plus visual gap.
- [x] Keep compact/restore available in both active-session and New Conversation views.
- [x] Make Windows/Linux maximize captions react to maximize, restore, and full-screen lifecycle changes.
- [x] Remove the repeated aggregate title from expanded tool-group bodies.
- [x] Aggregate MCP group-title counts by server.
- [x] Add focused regressions, pass analyzer and 111 focused tests, pass the full fast suite (1056 passed, 1 skipped), build macOS debug, and update Graphify.
- [ ] User reviews the final uncommitted diff and authorizes any commit.

### G9 — Authoritative Turn Timer and Cursor-Aware File Drop

- [x] Persist one stable accepted-turn start across running, waiting, blocked, and resuming transitions.
- [x] Add an authoritative elapsed baseline to execution snapshots and final-answer metadata without resetting on recovery.
- [x] Refresh the baseline through live execution events and session/history hydration so reopening an active conversation resumes at the correct value.
- [x] Render `Working for …` at the trailing edge of `ConversationActivityTile`, updating seconds below one hour and minutes at one hour or more.
- [x] Insert dropped file paths at the current composer selection and restore the caret after the inserted paths.
- [x] Add focused Agent/client/widget regressions, update product/technical/QA docs, analyze both packages, and update Graphify.

### G10 — Stable Timer Digits

- [x] Render elapsed digits with tabular figures so same-length second updates do not shift the trailing timer horizontally.
- [x] Add focused style coverage, run the Client analyzer and Activity widget test, and refresh Graphify.

### G11 — Group Copy and Terminal Status

- [x] Rename grouped File Read metrics to `file explore(s)` without changing the underlying tool identity.
- [x] Keep the modified-file metric and its added/removed line totals together as one wrapping unit.
- [x] Render a running terminal header as `Running:` and a completed terminal header as `Ran:`.
- [x] Add focused projection/widget regressions, update documentation, analyze the Client, and refresh Graphify.

### G12 — Immediate Activity and Compact Group Padding

- [x] Show the current authoritative Activity on the first frame when opening an active conversation while retaining debounce for later changes.
- [x] Reduce expanded tool-group body padding to 4px horizontally and 8px vertically.
- [x] Add focused widget regressions, update documentation, analyze the Client, refresh Graphify, and reload the main-worktree Client.

## Acceptance Criteria

- [x] Given one completed/error tool, it renders with the existing standalone presentation; when a second contiguous completed/error tool arrives, both render as one collapsible group.
- [x] Given ask-user, user/assistant, plan, or informational events between tools, no group crosses that boundary; from the second contiguous tool onward every call, including running calls, enters the group.
- [x] Given a running ask-user event, no timeline row or generic header is visible; after completion, question/answer content appears without icon/`Ask`/title chrome.
- [x] Given active reasoning or an active grouped run, exactly one non-expandable activity row exposes the real current work; one standalone tool, ordinary answer text, terminal state, and history create no duplicate or placeholder.
- [x] Given mixed tool kinds, the icon-free title aggregates MCP calls by server, lists skill loads first, then other non-file operations, file activity, deduplicated modified files, and final green/red line totals without `Tool uses:`; expansion does not repeat that title.
- [x] Given tool diff outputs, added and removed lines aggregate correctly and changed numeric values animate.
- [x] Visual comparison confirms the group reuses the existing tool header/body typography, `Read:` / `Grep:` title color, spacing, border, surface, and chevron without introducing a new color or component style.
- [x] Given an expanded group taller than 500 logical pixels, only its inner viewport scrolls; nested follow starts enabled, disables after manual movement away, and restores at its bottom.
- [x] Scrolling the group never changes timeline follow state, and scrolling the timeline never changes group follow state.
- [x] Given a stale running history row and a newer matching terminal live event, hydration retains the terminal status/output and the visible row updates immediately.
- [x] Sending a user message performs only the existing minimal reveal, grants timeline follow eligibility, follows later streamed growth, and manual upward scrolling revokes follow until returning to bottom.
- [x] On native desktop only, the compact button changes the window to `500 × 874` while preserving top-left origin; the narrow-header button restores prior bounds, and manual enlargement clears compact state.
- [x] macOS, Windows, and Linux reject resize attempts below `500 × 600` while compact mode prefers `500 × 874`; mobile and web do not render the compact control or initialize desktop window APIs.
- [x] Focused automated tests prove grouping, aggregation, reconciliation, both scroll state machines, compact/restore intent, and platform guards.
- [x] Given an active turn that waits, resumes, reconnects, or is reopened later, its execution snapshot and final response retain one accepted-turn origin and the visible timer resumes from a fresh elapsed baseline.
- [x] Given an already-active conversation is opened, its current Activity and elapsed duration render on the first frame; only later Activity changes wait for the debounce.
- [x] Given a tool group is expanded, its body uses 4px horizontal and 8px vertical internal padding.
- [x] Given elapsed work below one hour, Activity shows seconds; at one hour or more it shows hours/minutes without visible second churn.
- [x] Given a desktop file drop at a caret or selection, paths insert at that selection, replace selected text, and leave the caret after the inserted paths.

## Definition of Done

- [x] Terminal tool runs group with correct boundaries, parallel-running batch behavior, and stable updates.
- [x] Deduplicated file and diff summaries are correct, cached across virtualization, and animated only on changes.
- [x] Ask-user history has no generic tool header and never shows while running.
- [x] Active-history hydration cannot regress a completed tool to running.
- [x] Nested and timeline follow behavior pass independent regression tests.
- [x] Desktop compact/restore preserves top-left origin and no supported desktop platform can resize below `500 × 600`.
- [x] Analyzer and relevant tests pass; documentation and Graphify are current after final reload.
- [x] No commit or push is performed without explicit user approval.

## Progress Log

- 2026-08-14 — G0 complete. Primary `main` was already current and clean. Decisions locked; root cause identified in history/live reconciliation. Remaining estimate: 85%.
- 2026-08-14 — G1 complete. Terminal live tool results now reapply over matching stale running history and preserve merged input/output; focused analyzer and command-service tests passed. Remaining estimate: 72%.
- 2026-08-14 — G2/G3 complete. Memoized linear projection, grouped tool UI, ask-user visibility, unique-file/diff metrics, nested follow, and send-enabled timeline follow are covered by focused analyzer and 61 passing tests. Remaining estimate: 38%.
- 2026-08-14 — G4 complete. Desktop compact/restore, iPhone 17 logical sizing, Dart and native minimum constraints, and header geometry are covered by analyzer and 21 passing focused tests. Remaining estimate: 18%.
- 2026-08-14 — G5 automated/documentation gates complete. Analyzer, 61 core focused tests, 21 window/sidebar tests, 14 ask-user regressions, macOS debug build, Graphify update, hot reload, and bounded logs passed. The full fast suite reached 1040 passing/1 skipped with one unrelated failure caused by the pre-existing ignored `client/android/key.properties`; only human visual review remains. Remaining estimate: 5%.
- 2026-08-14 — G6 follow-up corrections implemented. Parallel running batches, independent persistent expansion, lazy collapsed bodies, cached metrics, title/body summary split, adjacent chevron, trailing placeholder, `500 × 874` top-left-preserving compact bounds, narrow restore control, manual-resize reconciliation, and composer focus passed analyzer, 147 focused tests, and macOS debug build. Full fast suite reached 1048 passing/1 skipped with only the same unrelated ignored Android signing file failure. A Hot Reload exposed state-shape incompatibility as expected; a subsequent Hot Restart rebuilt cleanly and bounded startup logs contain no new exception. Remaining estimate: 5% human visual review.
- 2026-08-16 — G7 revised visual preview loaded. Activity now stays at the current tail, is eligible only for authoritative running/resuming attention, uses one-second trailing debounce with last-confirmed same-round continuity and no Activity entrance/text animation, preserves the prior row through a temporary first standalone tool, and disappears immediately at real boundaries or unsafe states. Post-debounce Activity layout now notifies only the outer conversation follow owner, preserving manual-scroll opt-out and strict nested-scroll isolation. Every title number animates over 750ms, `+/-` spacing is compact, and the chevron matches the gray title. The expected Hot Reload state-shape mismatch was recovered by Hot Restart; bounded post-restart logs and the final focused reload contain no new exception. Remaining estimate: 7%.
- 2026-08-16 — G7 verification and review handoff complete. Skill loads lead the group title while `terminal run(s)` remains unchanged. Analyzer and diff check pass; 34 core timeline/activity/scroll tests, 117 related surface tests, the full fast suite (1052 passed, 1 skipped), and macOS debug build pass. Graphify is current, final Hot Reload succeeded, and bounded logs contain no new exception.
- 2026-08-16 — G8 compact chrome and MCP summary polish complete. Narrow desktop actions now match wide-header geometry and neutral styling, macOS title-bar/drawer clearances are visually aligned, New Conversation retains compact restore, Windows/Linux caption state follows maximize/full-screen lifecycle events, expanded groups omit the duplicate title, and MCP counts aggregate by server. Analyzer and 111 focused tests pass; the full fast suite passes with 1056 tests and 1 skip; macOS debug build and Graphify update pass. Implementation remaining: 0%; the uncommitted diff awaits user review before commit authorization.
- 2026-08-16 — G9 authoritative timer and cursor-aware drop complete. Durable execution snapshots retain the accepted work-item start and publish a clock-skew-safe elapsed observation; recovered runners reuse that origin, equal-revision observations refresh safely, and Activity ticks `Working for …` from cached/hydrated state. File drops now edit at the current selection. Agent/client analyzers, 31 persistence tests, 66 interface tests, 30 focused client tests, the full Agent suite (1128 passed, 10 skipped), and the full Client suite (1062 passed, 1 skipped) pass; Graphify is current. Implementation remaining: 0%; the uncommitted diff awaits user review before commit authorization.
- 2026-08-16 — G10 stable timer digits complete. The elapsed label uses OpenType tabular figures (`tnum`), preventing proportional digit-width jitter during same-format second updates. The focused Activity widget suite (4 tests), Client analyzer, diff check, and Graphify update pass. Implementation remaining: 0%; the uncommitted diff awaits user review before commit authorization.
- 2026-08-16 — G10 short desktop minimum complete. Normal startup remains `1470 × 800`, compact mode uses `500 × 874`, and Dart plus all native runners enforce only `500 × 600` as the resize floor. Client analysis and 25 focused desktop-window/sidebar tests pass; Graphify is current. Implementation remaining: 0%; no commit or push performed.
- 2026-08-16 — Group-title typography follow-up complete. All aggregate title text, including colored added/removed line metrics, now uses normal font weight. Six focused widget tests and client analysis pass; Graphify is current. Implementation remaining: 0%; no commit or push performed.
- 2026-08-19 — G11/G12 copy and presentation follow-up complete. Grouped reads now say `file explore(s)`; modified-file and line totals wrap atomically; terminal headers distinguish `Running:` from `Ran:`; active-conversation Activity renders immediately on mount while later changes remain debounced; and expanded group content uses 4px horizontal/8px vertical padding. Twenty-three focused tests and Client analysis pass, Graphify is current, and the main-worktree Client was hot reloaded and reassembled. Implementation remaining: 0%; no commit or push performed.
